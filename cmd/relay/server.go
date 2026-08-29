package main

import (
	"net/http"
	"strings"

	"github.com/gorilla/websocket"
)

// Server — HTTP/WS-сервер релея для телефона.
type Server struct {
	cfg   Config
	token string
	herdr AgentAPI
	hub   *Hub
}

func newServer(cfg Config, token string, herdr AgentAPI) *Server {
	return &Server{cfg: cfg, token: token, herdr: herdr, hub: newHub()}
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", s.handleHealth)
	mux.HandleFunc("/pair", s.auth(s.handlePair))
	mux.HandleFunc("/api/snapshot", s.auth(s.handleSnapshot))
	mux.HandleFunc("/api/agents/", s.auth(s.handleAgent))
	mux.HandleFunc("/api/events", s.auth(s.handleEvent))
	mux.HandleFunc("/api/events/herdr", s.auth(s.handleHerdrEvent))
	mux.HandleFunc("/api/events/output", s.auth(s.handleOutputEvent))
	mux.HandleFunc("/ws", s.auth(s.handleWS))
	return logRequests(mux)
}

// verify принимает токен в Authorization: Bearer или в query-параметре token
// (query нужен для WS, где веб-клиент не всегда может ставить заголовки).
func (s *Server) verify(r *http.Request) bool {
	if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") && h[len("Bearer "):] == s.token {
		return true
	}
	return r.URL.Query().Get("token") == s.token
}

func (s *Server) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.verify(r) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

var upgrader = websocket.Upgrader{
	// Релей служит только паре «телефон ↔ ноут»; доступ без токена невозможен.
	CheckOrigin: func(r *http.Request) bool { return true },
}