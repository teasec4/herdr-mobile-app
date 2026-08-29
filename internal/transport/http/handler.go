package http

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"strings"

	"herdrelay/internal/domain"
	"herdrelay/internal/service"
)

// Handler handles HTTP API requests.
type Handler struct {
	agentService *service.AgentService
	eventService *service.EventService
}

// NewHandler creates a new HTTP handler.
func NewHandler(agentService *service.AgentService, eventService *service.EventService) *Handler {
	return &Handler{
		agentService: agentService,
		eventService: eventService,
	}
}

func writeJSON(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

// HandleHealth returns server health status.
func (h *Handler) HandleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// HandleSnapshot returns the current snapshot of all agents.
func (h *Handler) HandleSnapshot(w http.ResponseWriter, r *http.Request) {
	snap, err := h.agentService.GetSnapshot()
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, snap)
}

// HandleAgent handles agent-specific operations:
//   GET  /api/agents/<id>/output?lines=N&format=text|ansi
//   POST /api/agents/<id>/keys   {"keys":["esc"]}
//   POST /api/agents/<id>/prompt {"text":"hello"}
func (h *Handler) HandleAgent(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/api/agents/")
	parts := strings.Split(path, "/")
	if len(parts) < 2 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid path"})
		return
	}

	target := parts[0]
	action := parts[1]

	switch action {
	case "output":
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		h.handleOutput(w, r, target)

	case "keys":
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		h.handleKeys(w, r, target)

	case "prompt":
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		h.handlePrompt(w, r, target)

	default:
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "unknown action"})
	}
}

func (h *Handler) handleOutput(w http.ResponseWriter, r *http.Request, target string) {
	lines := 200
	if s := r.URL.Query().Get("lines"); s != "" {
		if n, err := strconv.Atoi(s); err == nil && n > 0 {
			lines = n
		}
	}

	format := r.URL.Query().Get("format")
	if format == "" {
		format = "text"
	}

	output, err := h.agentService.GetOutput(target, lines, format)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}

	// Return plain text output directly
	w.Header().Set("Content-Type", "text/plain")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(output.Output))
}

func (h *Handler) handleKeys(w http.ResponseWriter, r *http.Request, target string) {
	var req struct {
		Keys []string `json:"keys"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}

	if err := h.agentService.SendKeys(target, req.Keys); err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (h *Handler) handlePrompt(w http.ResponseWriter, r *http.Request, target string) {
	var req struct {
		Text string `json:"text"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}

	if err := h.agentService.SendPrompt(target, req.Text); err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}

	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// HandlePluginEvent handles events from herdr plugin hooks.
func (h *Handler) HandlePluginEvent(w http.ResponseWriter, r *http.Request, eventName string) {
	var payload struct {
		Data json.RawMessage `json:"data"`
	}

	if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid json"})
		return
	}

	if len(payload.Data) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing data"})
		return
	}

	// Parse into typed event and broadcast
	event, err := domain.ParseEvent(eventName, payload.Data)
	if err != nil {
		log.Printf("http: failed to parse plugin event %s: %v", eventName, err)
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid event data"})
		return
	}

	h.eventService.Broadcast(event)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}
