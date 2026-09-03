package ws

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"

	"github.com/gorilla/websocket"
	"herdrelay/internal/service"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

// Handler handles WebSocket connections.
type Handler struct {
	hub          *Hub
	agentService *service.AgentService
	eventService *service.EventService
}

// NewHandler creates a new WebSocket handler.
func NewHandler(hub *Hub, agentService *service.AgentService, eventService *service.EventService) *Handler {
	return &Handler{
		hub:          hub,
		agentService: agentService,
		eventService: eventService,
	}
}

// ServeHTTP handles WebSocket upgrade and message processing.
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("ws: upgrade error: %v", err)
		return
	}

	client := NewClient(conn)
	h.hub.Register(client)
	go client.StartWriter()
	defer func() {
		h.hub.Unregister(client)
		_ = client.Close()
	}()

	for {
		data, err := client.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
				log.Printf("ws: read error: %v", err)
			}
			return
		}

		var frame Frame
		if err := json.Unmarshal(data, &frame); err != nil {
			log.Printf("ws: invalid frame: %v", err)
			continue
		}

		h.handleFrame(client, frame)
	}
}

func (h *Handler) handleFrame(client *Client, frame Frame) {
	switch frame.Type {
	case "ping":
		h.sendFrame(client, PongFrame())

	case "request":
		result, err := h.agentService.Dispatch(frame.Method, frame.Params)
		if err != nil {
			h.sendFrame(client, ErrorFrame(frame.ID, dispatchCode(err), err.Error()))
			return
		}
		h.sendFrame(client, OKFrame(frame.ID, result))
	}
}

// dispatchCode maps a service dispatch error to its protocol error code.
func dispatchCode(err error) string {
	var de *service.DispatchError
	if errors.As(err, &de) {
		return de.Code
	}
	return "herdr_error"
}

func (h *Handler) sendFrame(client *Client, frame Frame) {
	data, err := json.Marshal(frame)
	if err != nil {
		log.Printf("ws: marshal error: %v", err)
		return
	}

	if err := client.Write(data); err != nil {
		log.Printf("ws: write error: %v", err)
	}
}
