package ws

import (
	"encoding/json"
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
			client.Close()
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

// Client represents a single WebSocket connection.
type Client struct {
	conn *websocket.Conn
	mu   sync.Mutex
}

// NewClient creates a new WebSocket client.
func NewClient(conn *websocket.Conn) *Client {
	return &Client{conn: conn}
}

// Write sends data to the client.
func (c *Client) Write(data []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.conn.WriteMessage(websocket.TextMessage, data)
}

// Close closes the client connection.
func (c *Client) Close() error {
	return c.conn.Close()
}

// ReadMessage reads a message from the client.
func (c *Client) ReadMessage() ([]byte, error) {
	_, data, err := c.conn.ReadMessage()
	return data, err
}
