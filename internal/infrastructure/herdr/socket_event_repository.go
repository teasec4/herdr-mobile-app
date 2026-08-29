package herdr

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"sync"
	"time"

	"herdrelay/internal/domain"
)

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

	for {
		r.mu.Lock()
		if r.closed {
			r.mu.Unlock()
			close(events)
			return nil
		}
		r.mu.Unlock()

		if err := r.subscribeOnce(events); err != nil {
			log.Printf("herdr socket: %v (retrying in %s)", err, backoff)
			time.Sleep(backoff)
			if backoff < 30*time.Second {
				backoff *= 2
			}
			continue
		}

		backoff = 2 * time.Second
		time.Sleep(time.Second) // avoid hot reconnect loop
	}
}

func (r *SocketEventRepository) subscribeOnce(events chan<- domain.Event) error {
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

	// Subscribe to global pane.updated event
	if err := r.subscribe(conn, "pane.updated", nil); err != nil {
		return fmt.Errorf("subscribe to pane.updated: %w", err)
	}

	log.Printf("herdr socket: connected to %s", r.socket)

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	for scanner.Scan() {
		var notification struct {
			Event string          `json:"event"`
			Data  json.RawMessage `json:"data"`
		}

		if err := json.Unmarshal(scanner.Bytes(), &notification); err != nil || notification.Event == "" {
			continue // response frames, keepalives, etc.
		}

		// Handle pane.updated to subscribe to scroll changes for new panes
		if notification.Event == "pane.updated" {
			var data struct {
				PaneID string `json:"pane_id"`
			}
			if json.Unmarshal(notification.Data, &data) == nil && data.PaneID != "" {
				// Subscribe to scroll_changed for this pane
				_ = r.subscribe(conn, "pane.scroll_changed", map[string]interface{}{
					"pane_id": data.PaneID,
				})
			}
		}

		// Map scroll_changed to output_changed for clients
		if notification.Event == "pane.scroll_changed" {
			notification.Event = "pane.output_changed"
		}

		// Parse and send typed event
		event, err := domain.ParseEvent(notification.Event, notification.Data)
		if err != nil {
			log.Printf("herdr socket: failed to parse event %s: %v", notification.Event, err)
			continue
		}

		select {
		case events <- event:
		case <-time.After(5 * time.Second):
			log.Printf("herdr socket: event channel blocked, dropping event %s", notification.Event)
		}
	}

	if err := scanner.Err(); err != nil {
		return fmt.Errorf("read: %w", err)
	}

	return nil
}

// subscribe sends a JSON-RPC subscribe request to herdr socket.
func (r *SocketEventRepository) subscribe(conn net.Conn, event string, params interface{}) error {
	req := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      fmt.Sprintf("sub-%s-%d", event, time.Now().UnixNano()),
		"method":  "subscribe",
		"params": map[string]interface{}{
			"event":  event,
			"params": params,
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
