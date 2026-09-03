package http

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"

	"herdrelay/internal/service"
)

// Handler handles HTTP API requests.
type Handler struct {
	agentService   *service.AgentService
	eventService   *service.EventService
	pairingService *service.PairingService
}

// NewHandler creates a new HTTP handler.
func NewHandler(agentService *service.AgentService, eventService *service.EventService, pairingService *service.PairingService) *Handler {
	return &Handler{
		agentService:   agentService,
		eventService:   eventService,
		pairingService: pairingService,
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

// HandlePair returns the connection info (URLs, token, universal QR) a
// client needs to reach this relay.
func (h *Handler) HandlePair(w http.ResponseWriter, r *http.Request) {
	if h.pairingService == nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "pairing not configured"})
		return
	}
	writeJSON(w, http.StatusOK, h.pairingService.PairInfo())
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
//
//	GET  /api/agents/<id>/output?lines=N&format=text|ansi
//	POST /api/agents/<id>/keys   {"keys":["esc"]}
//	POST /api/agents/<id>/prompt {"text":"hello"}
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
	_, _ = w.Write([]byte(output.Output))
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

// HandleRPC accepts a relay request frame via POST /api/rpc and returns the
// response frame as JSON — the HTTP twin of the WebSocket dispatch, so a
// client can fall back to plain HTTP when WebSockets are blocked. The wire
// format matches the WS protocol exactly (docs/01-architecture.md).
func (h *Handler) HandleRPC(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var frame struct {
		ID     interface{}     `json:"id"`
		Method string          `json:"method"`
		Params json.RawMessage `json:"params"`
	}
	if err := json.NewDecoder(r.Body).Decode(&frame); err != nil || frame.Method == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request frame"})
		return
	}

	result, err := h.agentService.Dispatch(frame.Method, frame.Params)
	if err != nil {
		code, message := "herdr_error", err.Error()
		var de *service.DispatchError
		if errors.As(err, &de) {
			code, message = de.Code, de.Message
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{
			"type": "response",
			"id":   frame.ID,
			"error": map[string]string{
				"code":    code,
				"message": message,
			},
		})
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"type":   "response",
		"id":     frame.ID,
		"ok":     true,
		"result": result,
	})
}

// HandleEventStream streams relay events to the client over Server-Sent
// Events (`data: <event frame JSON>\n\n` per event). This is the HTTP
// counterpart of the WebSocket event broadcast, used by the HTTP transport
// fallback.
//
// A slow SSE consumer must not stall the broadcast: the handler goroutine
// only enqueues marshalled frames into a per-client queue (dropping for THIS
// client when the queue overflows), and a writer goroutine drains the queue
// into the socket (docs/12-fix-plan.md C2).
func (h *Handler) HandleEventStream(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)
	// Send the headers now: Go buffers them until the first write/flush, and
	// the client waits for them before it starts reading events.
	flusher.Flush()

	events := h.eventService.Subscribe()
	defer h.eventService.Unsubscribe(events)

	const queueSize = 100
	queue := make(chan []byte, queueSize)
	done := make(chan struct{})
	writerDone := make(chan struct{})

	go func() {
		defer close(writerDone)
		for {
			select {
			case data := <-queue:
				if _, err := fmt.Fprintf(w, "data: %s\n\n", data); err != nil {
					return
				}
				flusher.Flush()
			case <-done:
				return
			}
		}
	}()
	// Wait for the writer goroutine to stop before returning: once the handler
	// returns, the http server finishes the response and starts tearing down
	// the underlying bufio.Writer, so a background Flush racing with that
	// teardown trips the race detector (chunkWriter.close vs Flush).
	defer func() {
		close(done)
		<-writerDone
	}()

	for {
		select {
		case event, ok := <-events:
			if !ok {
				return
			}
			frame := map[string]interface{}{
				"type":  "event",
				"event": event.EventName(),
				"data":  event.EventData(),
			}
			data, err := json.Marshal(frame)
			if err != nil {
				continue
			}
			select {
			case queue <- data:
			default:
				// Slow consumer: drop for this client only — the broadcast
				// and other subscribers are unaffected.
				log.Printf("http: sse queue full, dropping event for slow client")
			}
		case <-r.Context().Done():
			return
		}
	}
}
