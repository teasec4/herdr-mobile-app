package main

import (
	"crypto/subtle"
	"net/http"
	"strings"

	httpTransport "herdrelay/internal/transport/http"
	"herdrelay/internal/transport/ws"
)

// buildMux wires all relay HTTP routes. Everything except /healthz requires
// the pairing token (via Authorization: Bearer or ?token=).
func buildMux(token string, h *httpTransport.Handler, wsHandler *ws.Handler) http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/healthz", h.HandleHealth)
	mux.HandleFunc("/api/snapshot", authMiddleware(token, h.HandleSnapshot))
	mux.HandleFunc("/api/agents/", authMiddleware(token, h.HandleAgent))

	// WebSocket
	mux.HandleFunc("/ws", authMiddleware(token, wsHandler.ServeHTTP))

	// HTTP fallback for clients that cannot use WebSockets: the RPC twin of
	// /ws and the SSE event stream.
	mux.HandleFunc("/api/rpc", authMiddleware(token, h.HandleRPC))
	mux.HandleFunc("/api/events/stream", authMiddleware(token, h.HandleEventStream))

	// Pairing endpoint
	mux.HandleFunc("/pair", authMiddleware(token, h.HandlePair))

	return mux
}

func authMiddleware(token string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !verifyToken(r, token) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func verifyToken(r *http.Request, token string) bool {
	var candidate string
	if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
		candidate = h[len("Bearer "):]
	} else {
		candidate = r.URL.Query().Get("token")
	}
	return subtle.ConstantTimeCompare([]byte(candidate), []byte(token)) == 1
}
