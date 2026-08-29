package ws

import (
	"encoding/json"
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
	defer func() {
		h.hub.Unregister(client)
		client.Close()
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
		response := h.dispatch(frame)
		h.sendFrame(client, response)
	}
}

func (h *Handler) dispatch(frame Frame) Frame {
	switch frame.Method {
	case "agents.snapshot":
		snap, err := h.agentService.GetSnapshot()
		if err != nil {
			return ErrorFrame(frame.ID, "herdr_error", err.Error())
		}
		return OKFrame(frame.ID, snap)

	case "agent.output":
		var params struct {
			Target string `json:"target"`
			Lines  int    `json:"lines"`
			Format string `json:"format"`
		}
		if err := json.Unmarshal(frame.Params, &params); err != nil {
			return ErrorFrame(frame.ID, "bad_params", "invalid parameters")
		}

		output, err := h.agentService.GetOutput(params.Target, params.Lines, params.Format)
		if err != nil {
			return ErrorFrame(frame.ID, "herdr_error", err.Error())
		}
		return OKFrame(frame.ID, output)

	case "agent.keys":
		var params struct {
			Target string   `json:"target"`
			Keys   []string `json:"keys"`
		}
		if err := json.Unmarshal(frame.Params, &params); err != nil {
			return ErrorFrame(frame.ID, "bad_params", "invalid parameters")
		}

		if err := h.agentService.SendKeys(params.Target, params.Keys); err != nil {
			return ErrorFrame(frame.ID, "herdr_error", err.Error())
		}
		return OKFrame(frame.ID, map[string]bool{"ok": true})

	case "agent.prompt":
		var params struct {
			Target string `json:"target"`
			Text   string `json:"text"`
		}
		if err := json.Unmarshal(frame.Params, &params); err != nil {
			return ErrorFrame(frame.ID, "bad_params", "invalid parameters")
		}

		if err := h.agentService.SendPrompt(params.Target, params.Text); err != nil {
			return ErrorFrame(frame.ID, "herdr_error", err.Error())
		}
		return OKFrame(frame.ID, map[string]bool{"ok": true})

	default:
		return ErrorFrame(frame.ID, "unknown_method", frame.Method)
	}
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
