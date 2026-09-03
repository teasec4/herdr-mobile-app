package ws

import (
	"encoding/json"
	"errors"
	"log"
	"sync"

	"github.com/gorilla/websocket"
	"herdrelay/internal/domain"
)

// Hub manages WebSocket clients and broadcasts events to them.
type Hub struct {
	mu      sync.RWMutex
	clients map[*Client]struct{}
}

// NewHub creates a new WebSocket hub.
func NewHub() *Hub {
	return &Hub{
		clients: make(map[*Client]struct{}),
	}
}

// Register adds a client to the hub.
func (h *Hub) Register(client *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.clients[client] = struct{}{}
	log.Printf("ws: client registered, total: %d", len(h.clients))
}

// Unregister removes a client from the hub.
func (h *Hub) Unregister(client *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.clients[client]; ok {
		delete(h.clients, client)
		log.Printf("ws: client unregistered, total: %d", len(h.clients))
	}
}

// Broadcast sends a message to all connected clients.
func (h *Hub) Broadcast(data []byte) {
	h.mu.RLock()
	clients := make([]*Client, 0, len(h.clients))
	for client := range h.clients {
		clients = append(clients, client)
	}
	h.mu.RUnlock()

	for _, client := range clients {
		if err := client.Write(data); err != nil {
			log.Printf("ws: broadcast error: %v", err)
			_ = client.Close()
		}
	}
}

// BroadcastEvent sends a typed event to all connected clients.
func (h *Hub) BroadcastEvent(event domain.Event) {
	frame := Frame{
		Type:  "event",
		Event: event.EventName(),
		Data:  event.EventData(),
	}

	data, err := json.Marshal(frame)
	if err != nil {
		log.Printf("ws: failed to marshal event: %v", err)
		return
	}

	h.Broadcast(data)
}

// ClientCount returns the number of connected clients.
func (h *Hub) ClientCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.clients)
}

// sendQueue is the per-client outgoing buffer. A slow consumer that fills
// the queue is closed instead of blocking the broadcast loop (docs/12-fix-
// plan.md C1).
const sendQueue = 128

// Client represents a single WebSocket connection. Outgoing frames go
// through an internal queue drained by [Client.StartWriter], so a broadcast
// never blocks on a slow reader.
type Client struct {
	conn *websocket.Conn
	send chan []byte
	done chan struct{}
	once sync.Once
}

// NewClient creates a new WebSocket client.
func NewClient(conn *websocket.Conn) *Client {
	return &Client{
		conn: conn,
		send: make(chan []byte, sendQueue),
		done: make(chan struct{}),
	}
}

// StartWriter drains the outgoing queue; run it as a goroutine after the
// client is registered (or before writing anything).
func (c *Client) StartWriter() {
	for {
		select {
		case msg := <-c.send:
			if err := c.conn.WriteMessage(websocket.TextMessage, msg); err != nil {
				log.Printf("ws: write error: %v", err)
				_ = c.Close()
				return
			}
		case <-c.done:
			return
		}
	}
}

// Write enqueues a frame. Returns an error (and closes the client) when the
// queue is full — the consumer is too slow, keeping the connection would
// only accumulate lag; the client reconnects and re-reads the snapshot.
func (c *Client) Write(data []byte) error {
	select {
	case c.send <- data:
		return nil
	default:
		log.Printf("ws: client queue full, closing slow consumer")
		_ = c.Close()
		return errors.New("ws: slow consumer, connection closed")
	}
}

// Close closes the client connection (idempotent).
func (c *Client) Close() error {
	c.once.Do(func() {
		close(c.done)
		if c.conn != nil {
			_ = c.conn.Close()
		}
	})
	return nil
}

// ReadMessage reads a message from the client.
func (c *Client) ReadMessage() ([]byte, error) {
	_, data, err := c.conn.ReadMessage()
	return data, err
}
