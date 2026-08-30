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
}

// NewSocketEventRepository creates a new socket-based event repository.
func NewSocketEventRepository(socket string) *SocketEventRepository {
	return &SocketEventRepository{
		socket: socket,
	}
}

// Subscribe starts listening for events from herdr socket.
func (r *SocketEventRepository) Subscribe(events chan<- domain.Event) error {
	backoff := 2 * time.Second

	// Known pane ids are tracked across reconnects so every new connection
	// subscribes to everything in a single events.subscribe message.
	subscribed := make(map[string]bool)

	for {
		r.mu.Lock()
		if r.closed {
			r.mu.Unlock()
			close(events)
			return nil
		}
		r.mu.Unlock()

		err := r.subscribeOnce(events, subscribed)
		if err != nil {
			if errors.Is(err, errRestart) {
				// New pane discovered: reconnect immediately with the full
				// subscription set.
				backoff = 2 * time.Second
				continue
			}
			log.Printf("herdr socket: %v (retrying in %s)", err, backoff)
			time.Sleep(backoff)
			if backoff < 30*time.Second {
				backoff *= 2
			}
			continue
		}

		// Clean EOF: reconnect, but pace it to avoid a hot loop if herdr
		// closes idle connections.
		backoff = 2 * time.Second
		log.Printf("herdr socket: connection closed, reconnecting")
		time.Sleep(time.Second)
	}
}

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

func (r *SocketEventRepository) subscribeOnce(events chan<- domain.Event, subscribed map[string]bool) error {
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
	// subscriptions are re-applied for every known pane id.
	subs := make([]subscription, 0, len(subscribed)+1)
	subs = append(subs, subscription{Type: "pane.updated"})
	for paneID := range subscribed {
		subs = append(subs, subscription{Type: "pane.scroll_changed", PaneID: paneID})
	}

	if err := r.subscribe(conn, subs...); err != nil {
		return fmt.Errorf("subscribe: %w", err)
	}

	log.Printf("herdr socket: connected to %s (%d pane subscriptions)", r.socket, len(subscribed))

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

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
			// scroll_changed maps to output_changed for clients.
			notification.Event = "pane.output_changed"
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

// subscribe sends a JSON-RPC events.subscribe request to herdr's socket. The
// full subscription set is always sent in a single message; herdr treats
// subscriptions as cumulative, and writing a second subscribe on a live
// connection causes herdr 0.8.0 to drop it.
func (r *SocketEventRepository) subscribe(conn net.Conn, subs ...subscription) error {
	req := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      fmt.Sprintf("sub-%d", time.Now().UnixNano()),
		"method":  "events.subscribe",
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
	if r.conn != nil {
		return r.conn.Close()
	}
	return nil
}
