package main

import (
	"log"
	"net/http"
	"os"
)

func main() {
	// `herdrelay pair [--qr]` — клиентская команда пары, без сервера.
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
	srv := newServer(cfg, token, &Herdr{Bin: cfg.HerdrBin, Socket: cfg.Socket})
	log.Printf("herdrelay listening on %s (mode=%s, token=%s…)", cfg.Listen, cfg.Mode, token[:8])
	log.Fatal(http.ListenAndServe(cfg.Listen, srv.routes()))
}