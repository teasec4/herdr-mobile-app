package main

import (
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"strings"
)

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) handlePair(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.pairInfo())
}

func (s *Server) handleSnapshot(w http.ResponseWriter, _ *http.Request) {
	snap, err := s.herdr.Snapshot()
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, snap)
}

// handleAgent:
//
//	GET  /api/agents/<id>/output?lines=N&format=text|ansi
//	POST /api/agents/<id>/keys   {"keys":["esc"]}
//	POST /api/agents/<id>/prompt {"text":"..."}
func (s *Server) handleAgent(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/api/agents/")
	parts := strings.Split(rest, "/")
	if len(parts) != 2 || parts[0] == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "expected /api/agents/<id>/output|keys|prompt"})
		return
	}
	id, op := parts[0], parts[1]

	switch op {
	case "output":
		lines := 200
		if v := r.URL.Query().Get("lines"); v != "" {
			if n, err := strconv.Atoi(v); err == nil && n > 0 {
				lines = n
			}
		}
		out, err := s.herdr.Read(id, lines, r.URL.Query().Get("format"))
		if err != nil {
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"output": out, "target": id})

	case "keys", "prompt":
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			Keys []string `json:"keys"`
			Text string   `json:"text"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "bad json"})
			return
		}
		var err error
		if op == "keys" {
			err = s.herdr.Keys(id, req.Keys)
		} else {
			err = s.herdr.Prompt(id, req.Text)
		}
		if err != nil {
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "target": id})

	default:
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unknown op: " + op})
	}
}

// handleEvent accepts an event from the herdr plugin (or an emulation) and
// broadcasts it to every connected WS client.
func (s *Server) handleEvent(w http.ResponseWriter, r *http.Request) {
	var ev struct {
		Event string `json:"event"`
		Data  any    `json:"data"`
	}
	if err := json.NewDecoder(r.Body).Decode(&ev); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "bad json"})
		return
	}
	s.hub.broadcast(mustJSON(frame{Type: "event", Event: ev.Event, Data: ev.Data}))
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// handleHerdrEvent forwards an agent-status hook payload from the herdr plugin
// to WS clients. The event name is pinned by the plugin manifest, so this is a
// thin wrapper over handlePluginEvent.
func (s *Server) handleHerdrEvent(w http.ResponseWriter, r *http.Request) {
	s.handlePluginEvent(w, r, "pane.agent_status_changed")
}

// handleOutputEvent forwards a pane.output_changed hook payload from the herdr
// plugin (live terminal output change) to WS clients; the client re-reads the
// tail on the signal.
func (s *Server) handleOutputEvent(w http.ResponseWriter, r *http.Request) {
	s.handlePluginEvent(w, r, "pane.output_changed")
}

// handlePluginEvent parses a raw herdr hook payload — env HERDR_PLUGIN_EVENT_JSON,
// format {"data":{...}} — and broadcasts it to every connected WS client under
// the given canonical event name. herdr does not pass the hook name in env, so
// it is fixed by the plugin manifest and mapped to a name here.
func (s *Server) handlePluginEvent(w http.ResponseWriter, r *http.Request, name string) {
	var ev struct {
		Data json.RawMessage `json:"data"`
	}
	if err := json.NewDecoder(r.Body).Decode(&ev); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "bad json"})
		return
	}
	if len(ev.Data) == 0 || string(ev.Data) == "null" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing data"})
		return
	}
	log.Printf("[relay] Broadcasting event %s to %d clients: %s", name, len(s.hub.clients), string(ev.Data))
	s.hub.broadcast(mustJSON(frame{Type: "event", Event: name, Data: ev.Data}))
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}