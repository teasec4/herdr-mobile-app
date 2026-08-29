package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strings"

	"herdrelay/internal/infrastructure/herdr"
	"herdrelay/internal/service"
	httpTransport "herdrelay/internal/transport/http"
	"herdrelay/internal/transport/ws"
)

func main() {
	// `herdrelay pair [--qr]` is the client-side pairing command, no server.
	if len(os.Args) > 1 && os.Args[1] == "pair" {
		os.Exit(runPairCmd(os.Args[2:]))
	}

	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("herdrelay: config: %v", err)
	}
	token, err := loadToken(cfg)
	if err != nil {
		log.Fatalf("herdrelay: token: %v", err)
	}

	// Wire up clean architecture layers
	cliRepo := herdr.NewCLIRepository(cfg.HerdrBin, cfg.Socket)
	agentService := service.NewAgentService(cliRepo)

	eventRepo := herdr.NewSocketEventRepository(cfg.Socket)
	eventService := service.NewEventService(eventRepo)

	hub := ws.NewHub()

	// Subscribe event service to broadcast to WebSocket hub
	go func() {
		events := eventService.Subscribe()
		for event := range events {
			hub.BroadcastEvent(event)
		}
	}()

	// Start event subscription
	if err := eventService.Start(); err != nil {
		log.Printf("herdrelay: event service: %v", err)
	}

	// Handlers
	httpHandler := httpTransport.NewHandler(agentService, eventService)
	wsHandler := ws.NewHandler(hub, agentService, eventService)

	// Routes
	mux := http.NewServeMux()

	// HTTP API
	mux.HandleFunc("/healthz", httpHandler.HandleHealth)
	mux.HandleFunc("/api/snapshot", authMiddleware(token, httpHandler.HandleSnapshot))
	mux.HandleFunc("/api/agents/", authMiddleware(token, httpHandler.HandleAgent))

	// Plugin event hooks
	mux.HandleFunc("/api/events/pane.agent_status_changed", authMiddleware(token, func(w http.ResponseWriter, r *http.Request) {
		httpHandler.HandlePluginEvent(w, r, "pane.agent_status_changed")
	}))
	mux.HandleFunc("/api/events/pane.updated", authMiddleware(token, func(w http.ResponseWriter, r *http.Request) {
		httpHandler.HandlePluginEvent(w, r, "pane.updated")
	}))

	// WebSocket
	mux.HandleFunc("/ws", authMiddleware(token, wsHandler.ServeHTTP))

	// Pairing endpoint
	mux.HandleFunc("/pair", authMiddleware(token, func(w http.ResponseWriter, r *http.Request) {
		servePair(w, r, cfg, token)
	}))

	log.Printf("herdrelay listening on %s (mode=%s, token=%s…)", cfg.Listen, cfg.Mode, token[:8])
	log.Fatal(http.ListenAndServe(cfg.Listen, mux))
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
	if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") && h[len("Bearer "):] == token {
		return true
	}
	return r.URL.Query().Get("token") == token
}

func servePair(w http.ResponseWriter, r *http.Request, cfg Config, token string) {
	port := "8375"
	if _, p, err := strings.Cut(cfg.Listen, ":"); err {
		port = p
	}

	urls := make(map[string]interface{})
	primary := ""

	add := func(mode, wsURL string, params map[string]string) {
		q := make(map[string]string)
		for k, v := range params {
			q[k] = v
		}
		q["mode"] = mode
		q["token"] = token

		var linkParts []string
		for k, v := range q {
			linkParts = append(linkParts, k+"="+v)
		}

		urls[mode] = map[string]string{
			"url":  wsURL,
			"link": "herdrelay://pair?" + strings.Join(linkParts, "&"),
		}
		if primary == "" {
			primary = mode
		}
	}

	// LAN mode
	if ip := detectLANIP(); ip != "" {
		add("lan", "ws://"+ip+":"+port, map[string]string{"host": ip, "port": port})
	}

	// Tailscale mode
	if ts := tailscaleInfo(); ts != nil {
		add("tailscale", "ws://"+ts.DNSName+":"+port, map[string]string{"host": ts.DNSName, "port": port})
		add("funnel", "https://"+ts.DNSName, map[string]string{"host": ts.DNSName})
	}

	// Gateway mode
	if cfg.GatewayURL != "" {
		add("gateway", cfg.GatewayURL, map[string]string{"url": cfg.GatewayURL})
	}

	response := map[string]interface{}{
		"mode":    cfg.Mode,
		"primary": primary,
		"urls":    urls,
		"token":   token,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(response)
}