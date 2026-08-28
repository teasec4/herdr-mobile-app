package main

import (
	"encoding/json"
	"net/http"
	"sync"

	"github.com/gorilla/websocket"
)

// frame — JSON-конверт протокола (см. docs/01-architecture.md).
type frame struct {
	Type   string          `json:"type"`
	ID     any             `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	OK     *bool           `json:"ok,omitempty"`
	Result any             `json:"result,omitempty"`
	Error  *envErr         `json:"error,omitempty"`
	Event  string          `json:"event,omitempty"`
	Data   any             `json:"data,omitempty"`
}

type envErr struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func okFrame(id any, result any) frame {
	t := true
	return frame{Type: "response", ID: id, OK: &t, Result: result}
}

func errFrame(id any, code, msg string) frame {
	return frame{Type: "response", ID: id, Error: &envErr{Code: code, Message: msg}}
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return b
}

// Client — одно WS-соединение телефона. Пишем из разных горутин (ответы и
// события), поэтому запись под мьютексом.
type Client struct {
	conn *websocket.Conn
	mu   sync.Mutex
}

func (c *Client) write(b []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.conn.WriteMessage(websocket.TextMessage, b)
}

// Hub — множество подключённых клиентов; события рассылаются всем.
type Hub struct {
	mu      sync.Mutex
	clients map[*Client]struct{}
}

func newHub() *Hub {
	return &Hub{clients: make(map[*Client]struct{})}
}

func (h *Hub) add(c *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.clients[c] = struct{}{}
}

func (h *Hub) remove(c *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.clients, c)
}

func (h *Hub) broadcast(b []byte) {
	h.mu.Lock()
	clients := make([]*Client, 0, len(h.clients))
	for c := range h.clients {
		clients = append(clients, c)
	}
	h.mu.Unlock()
	for _, c := range clients {
		if c.write(b) != nil {
			c.conn.Close()
		}
	}
}

func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	c := &Client{conn: conn}
	s.hub.add(c)
	defer func() {
		s.hub.remove(c)
		conn.Close()
	}()
	for {
		_, raw, err := conn.ReadMessage()
		if err != nil {
			return
		}
		var f frame
		if err := json.Unmarshal(raw, &f); err != nil {
			continue
		}
		switch f.Type {
		case "ping":
			_ = c.write(mustJSON(frame{Type: "pong"}))
		case "request":
			_ = c.write(mustJSON(s.dispatch(f)))
		}
	}
}

// dispatch выполняет метод протокола и возвращает frame-ответ.
func (s *Server) dispatch(f frame) frame {
	switch f.Method {
	case "agents.snapshot":
		snap, err := s.herdr.Snapshot()
		if err != nil {
			return errFrame(f.ID, "herdr_error", err.Error())
		}
		return okFrame(f.ID, snap)

	case "agent.output":
		var p struct {
			Target string `json:"target"`
			Lines  int    `json:"lines"`
			Format string `json:"format"`
		}
		if err := json.Unmarshal(f.Params, &p); err != nil || p.Target == "" {
			return errFrame(f.ID, "bad_params", "target required")
		}
		if p.Lines <= 0 {
			p.Lines = 200
		}
		out, err := s.herdr.Read(p.Target, p.Lines, p.Format)
		if err != nil {
			return errFrame(f.ID, "herdr_error", err.Error())
		}
		return okFrame(f.ID, map[string]string{"output": out, "target": p.Target})

	case "agent.keys":
		var p struct {
			Target string   `json:"target"`
			Keys   []string `json:"keys"`
		}
		if err := json.Unmarshal(f.Params, &p); err != nil || p.Target == "" {
			return errFrame(f.ID, "bad_params", "target required")
		}
		if err := s.herdr.Keys(p.Target, p.Keys); err != nil {
			return errFrame(f.ID, "herdr_error", err.Error())
		}
		return okFrame(f.ID, map[string]bool{"ok": true})

	case "agent.prompt":
		var p struct {
			Target string `json:"target"`
			Text   string `json:"text"`
		}
		if err := json.Unmarshal(f.Params, &p); err != nil || p.Target == "" {
			return errFrame(f.ID, "bad_params", "target required")
		}
		if err := s.herdr.Prompt(p.Target, p.Text); err != nil {
			return errFrame(f.ID, "herdr_error", err.Error())
		}
		return okFrame(f.ID, map[string]bool{"ok": true})

	default:
		return errFrame(f.ID, "unknown_method", f.Method)
	}
}