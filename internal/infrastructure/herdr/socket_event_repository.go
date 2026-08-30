package herdr

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"sync"
	"time"

	"herdrelay/internal/domain"
)

// errRestart signals that a new pane was discovered and the connection was
// intentionally closed so that the outer loop reconnects with the full
// subscription set. herdr 0.8.0 drops a connection when a second reactive
// events.subscribe is written mid-stream, so new pane subscriptions are always
// applied by restarting the connection with the complete subscription list
// instead of writing a second subscribe on the live connection.
var errRestart = errors.New("new pane discovered, restarting subscription")

// SocketEventRepository implements EventRepository using herdr's Unix socket.
type SocketEventRepository struct {
	socket string
	mu     sync.Mutex
	conn   net.Conn
	closed bool
	stopCh chan struct{}
	once   sync.Once
}

// NewSocketEventRepository creates a new socket-based event repository.
func NewSocketEventRepository(socket string) *SocketEventRepository {
	return &SocketEventRepository{
		socket: socket,
		stopCh: make(chan struct{}),
	}
}

// Subscribe starts listening for events from herdr socket.
func (r *SocketEventRepository) Subscribe(events chan<- domain.Event) error {
	backoff := 2 * time.Second

	// Known pane ids are tracked across reconnects so every new connection
	// subscribes to everything in a single events.subscribe message.
	subscribed := make(map[string]bool)

	// Per-pane output revisions, persisted across reconnects (docs/12-fix-plan.md
	// D5): pane.updated carries PaneInfo.revision (docs/10-herdr-api.md §6.1),
	// while pane.scroll_changed does not (gotcha #5). The relay attaches the
	// last known revision to pane.output_changed only when it strictly increased
	// since the last forwarded one — a stale/equal revision would let the
	// client's revision guard wrongly skip a real output change.
	lastRevision := make(map[string]int)
	lastSentRevision := make(map[string]int)

	for {
		r.mu.Lock()
		if r.closed {
			r.mu.Unlock()
			close(events)
			return nil
		}
		r.mu.Unlock()

		err := r.subscribeOnce(events, subscribed, lastRevision, lastSentRevision)
		if err != nil {
			if errors.Is(err, errRestart) {
				// New pane discovered: reconnect immediately with the full
				// subscription set.
				backoff = 2 * time.Second
				continue
			}
			log.Printf("herdr socket: %v (retrying in %s)", err, backoff)
			if !r.sleep(backoff) {
				close(events)
				return nil
			}
			if backoff < 30*time.Second {
				backoff *= 2
			}
			continue
		}

		// Clean EOF: reconnect, but pace it to avoid a hot loop if herdr
		// closes idle connections.
		backoff = 2 * time.Second
		log.Printf("herdr socket: connection closed, reconnecting")
		if !r.sleep(time.Second) {
			close(events)
			return nil
		}
	}
}

// sleep pauses the reconnect loop for d, or returns false immediately when the
// repository was closed (so Close() does not wait out the backoff).
func (r *SocketEventRepository) sleep(d time.Duration) bool {
	select {
	case <-time.After(d):
		return true
	case <-r.stopCh:
		return false
	}
}

// debounceInterval paces scroll_changed forwarding per pane: herdr emits it on
// every scroll/output change and it carries no revision (docs/10-herdr-api.md
// gotcha #5), so forwarding every frame would spam the client and hammer the
// herdr CLI subprocess behind every agent.output request.
const debounceInterval = 500 * time.Millisecond

// subscription is a single entry of the events.subscribe `subscriptions` list:
// {"type":"pane.updated"} or {"type":"pane.scroll_changed","pane_id":"wH:p3"}.
type subscription struct {
	Type   string `json:"type"`
	PaneID string `json:"pane_id,omitempty"`
}

// socketNotification is a single decoded frame from the herdr socket, whether
// a response frame (subscription_started), keepalive, or an event notification.
type socketNotification struct {
	Event string          `json:"event"`
	Data  json.RawMessage `json:"data"`
}

func (r *SocketEventRepository) subscribeOnce(events chan<- domain.Event, subscribed map[string]bool, lastRevision, lastSentRevision map[string]int) error {
	conn, err := net.Dial("unix", r.socket)
	if err != nil {
		return fmt.Errorf("dial herdr socket: %w", err)
	}

	r.mu.Lock()
	r.conn = conn
	r.mu.Unlock()

	defer func() {
		r.mu.Lock()
		r.conn = nil
		r.mu.Unlock()
		conn.Close()
	}()

	// Subscribe to everything in a single events.subscribe message. pane.updated
	// fires once per pane (existing panes included on subscribe); scroll_changed
	// and agent_status_changed subscriptions are re-applied for every known
	// pane id. Status changes come over the socket even without the plugin hook.
	subs := make([]subscription, 0, len(subscribed)*2+1)
	subs = append(subs, subscription{Type: "pane.updated"})
	for paneID := range subscribed {
		subs = append(subs,
			subscription{Type: "pane.scroll_changed", PaneID: paneID},
			subscription{Type: "pane.agent_status_changed", PaneID: paneID},
		)
	}

	if err := r.subscribe(conn, subs...); err != nil {
		return fmt.Errorf("subscribe: %w", err)
	}

	log.Printf("herdr socket: connected to %s (%d pane subscriptions)", r.socket, len(subscribed))

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	// Per-pane last forward time for scroll_changed debounce (D4).
	lastScroll := make(map[string]time.Time)

	for scanner.Scan() {
		var notification socketNotification

		if err := json.Unmarshal(scanner.Bytes(), &notification); err != nil || notification.Event == "" {
			continue // response frames (subscription_started), keepalives, etc.
		}

		switch notification.Event {
		case "pane_updated", "pane.updated":
			// herdr emits pane_updated (underscore) with pane_id nested under
			// data.pane. Extract it and normalize to the client-visible
			// pane.updated event with a flat payload.
			paneID := paneIDFrom(notification.Data)
			if paneID == "" {
				continue
			}
			// PaneInfo carries the pane's output revision; remember it so
			// output_changed events can carry a revision for client-side dedup.
			if rev := revisionFrom(notification.Data); rev > 0 {
				lastRevision[paneID] = rev
			}
			notification.Event = "pane.updated"
			notification.Data, _ = json.Marshal(map[string]string{"pane_id": paneID})

			if !subscribed[paneID] {
				// New pane: remember it and restart the connection with the
				// full subscription set. Writing a second subscribe on this
				// live connection makes herdr drop it.
				subscribed[paneID] = true
				log.Printf("herdr socket: discovered new pane %s, restarting to subscribe scroll_changed", paneID)
				emitEvent(events, notification)
				return errRestart
			}

		case "pane.scroll_changed":
			// Debounce per pane: herdr emits this on every scroll/output
			// change without a revision, so forwarding every frame would
			// spam clients and the herdr CLI subprocess.
			paneID := paneIDFrom(notification.Data)
			if paneID != "" {
				if last, ok := lastScroll[paneID]; ok && time.Since(last) < debounceInterval {
					continue
				}
				lastScroll[paneID] = time.Now()
			}
			// scroll_changed maps to output_changed for clients. Attach the
			// pane's last known revision (from pane.updated) only when it
			// strictly increased since the last forwarded one; otherwise the
			// event goes out without a revision and the client falls back to
			// its debounce.
			notification.Event = "pane.output_changed"
			if paneID != "" {
				if rev := lastRevision[paneID]; rev > lastSentRevision[paneID] {
					lastSentRevision[paneID] = rev
					notification.Data, _ = json.Marshal(map[string]interface{}{
						"pane_id":  paneID,
						"revision": rev,
					})
				}
			}
		}

		emitEvent(events, notification)
	}

	if err := scanner.Err(); err != nil {
		return fmt.Errorf("read: %w", err)
	}

	return nil
}

// emitEvent parses and forwards a single socket notification to the events
// channel, dropping it if the channel is blocked for too long.
func emitEvent(events chan<- domain.Event, notification socketNotification) {
	event, err := domain.ParseEvent(notification.Event, notification.Data)
	if err != nil {
		log.Printf("herdr socket: failed to parse event %s: %v", notification.Event, err)
		return
	}

	select {
	case events <- event:
	case <-time.After(5 * time.Second):
		log.Printf("herdr socket: event channel blocked, dropping event %s", notification.Event)
	}
}

// paneIDFrom extracts the pane id from a pane_updated / pane.updated payload,
// which herdr emits either flat ({"pane_id": ...}) or nested
// ({"pane": {"pane_id": ...}}).
func paneIDFrom(data json.RawMessage) string {
	var flat struct {
		PaneID string `json:"pane_id"`
	}
	if json.Unmarshal(data, &flat) == nil && flat.PaneID != "" {
		return flat.PaneID
	}
	var nested struct {
		Pane struct {
			PaneID string `json:"pane_id"`
		} `json:"pane"`
	}
	if json.Unmarshal(data, &nested) == nil {
		return nested.Pane.PaneID
	}
	return ""
}

// revisionFrom extracts the pane output revision from a pane_updated payload,
// which herdr emits either flat ({"revision": N}) or nested
// ({"pane": {"revision": N}}).
func revisionFrom(data json.RawMessage) int {
	var flat struct {
		Revision int `json:"revision"`
	}
	if json.Unmarshal(data, &flat) == nil && flat.Revision > 0 {
		return flat.Revision
	}
	var nested struct {
		Pane struct {
			Revision int `json:"revision"`
		} `json:"pane"`
	}
	if json.Unmarshal(data, &nested) == nil {
		return nested.Pane.Revision
	}
	return 0
}

// subscribe sends a JSON-RPC events.subscribe request to herdr's socket. The
// full subscription set is always sent in a single message; herdr treats
// subscriptions as cumulative, and writing a second subscribe on a live
// connection causes herdr 0.8.0 to drop it.
func (r *SocketEventRepository) subscribe(conn net.Conn, subs ...subscription) error {
	req := map[string]interface{}{
		"id":     fmt.Sprintf("sub-%d", time.Now().UnixNano()),
		"method": "events.subscribe",
		"params": map[string]interface{}{
			"subscriptions": subs,
		},
	}

	data, err := json.Marshal(req)
	if err != nil {
		return err
	}

	_, err = conn.Write(append(data, '\n'))
	return err
}

// Close stops the event subscription.
func (r *SocketEventRepository) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()

	r.closed = true
	r.once.Do(func() { close(r.stopCh) })
	if r.conn != nil {
		return r.conn.Close()
	}
	return nil
}
