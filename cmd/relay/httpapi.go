package main

import (
	"encoding/json"
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

// handleEvent принимает событие от плагина herdr (или эмуляцию) и рассылает
// его всем подключённым WS-клиентам.
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

// handleHerdrEvent принимает сырой JSON события от плагина herdr
// (env HERDR_PLUGIN_EVENT_JSON, формат {"data":{...}}) и рассылает его
// WS-клиентам с каноническим именем pane.agent_status_changed — имя события
// хук от herdr в env не получает, оно фиксировано манифестом плагина.
func (s *Server) handleHerdrEvent(w http.ResponseWriter, r *http.Request) {
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
	s.hub.broadcast(mustJSON(frame{Type: "event", Event: "pane.agent_status_changed", Data: ev.Data}))
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}