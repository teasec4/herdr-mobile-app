package main

import (
	"log"
	"net/http"
	"os"

	"herdrelay/internal/infrastructure/herdr"
	"herdrelay/internal/infrastructure/netdetect"
	"herdrelay/internal/service"
	httpTransport "herdrelay/internal/transport/http"
	"herdrelay/internal/transport/ws"
)

func main() {
	// Client-side subcommands (`pair`, `status`) run before any server wiring.
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "pair":
			os.Exit(runPairCmd(os.Args[2:]))
		case "status":
			os.Exit(runStatusCmd())
		}
	}

	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("herdrelay: config: %v", err)
	}
	token, err := loadToken(cfg)
	if err != nil {
		log.Fatalf("herdrelay: token: %v", err)
	}
	identity, err := loadIdentity(cfg)
	if err != nil {
		log.Fatalf("herdrelay: identity: %v", err)
	}

	// Wire up clean architecture layers
	cliRepo := herdr.NewCLIRepository(cfg.HerdrBin, cfg.Socket)
	agentService := service.NewAgentService(cliRepo)

	eventRepo := herdr.NewSocketEventRepository(cfg.Socket)
	eventService := service.NewEventService(eventRepo)

	hub := ws.NewHub()

	// Subscribe event service to broadcast to WebSocket hub
	events := eventService.Subscribe()
	go func() {
		for event := range events {
			hub.BroadcastEvent(event)
		}
	}()

	// Start event subscription
	if err := eventService.Start(); err != nil {
		log.Printf("herdrelay: event service: %v", err)
	}

	// Handlers
	pairingService := service.NewPairingService(netdetect.NewSystemDetector(), identity, cfg.Mode, listenPort(cfg), cfg.GatewayURL, token)
	httpHandler := httpTransport.NewHandler(agentService, eventService, pairingService)
	wsHandler := ws.NewHandler(hub, agentService, eventService)

	log.Printf("herdrelay listening on %s (mode=%s, token=%s…)", cfg.Listen, cfg.Mode, token[:8])
	log.Fatal(http.ListenAndServe(cfg.Listen, buildMux(token, httpHandler, wsHandler)))
}