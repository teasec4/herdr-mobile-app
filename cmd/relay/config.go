package main

import (
	"net"
	"os"
	"path/filepath"
)

// Config holds the relay's env parameters (see docs/03-relay.md).
type Config struct {
	Mode         string // lan | tailscale | funnel | gateway
	Listen       string // HTTP listen address
	GatewayURL   string // gateway mode only
	Token        string // env token (wins over file); may be empty
	TokenFile    string
	IdentityFile string // relay identity (relay_id + name), created on first run
	Socket       string // herdr unix socket
	HerdrBin     string
}

func homeDir() string {
	h, _ := os.UserHomeDir()
	return h
}

func defaultConfigDir() string {
	if d := os.Getenv("XDG_CONFIG_HOME"); d != "" {
		return filepath.Join(d, "herdr")
	}
	return filepath.Join(homeDir(), ".config", "herdr")
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func loadConfig() (Config, error) {
	dir := defaultConfigDir()
	cfg := Config{
		Mode:         envOr("HERDRELAY_MODE", "lan"),
		GatewayURL:   os.Getenv("HERDRELAY_GATEWAY_URL"),
		Token:        os.Getenv("HERDRELAY_TOKEN"),
		TokenFile:    envOr("HERDRELAY_TOKEN_FILE", filepath.Join(dir, "herdrelay.token")),
		IdentityFile: envOr("HERDRELAY_IDENTITY_FILE", filepath.Join(dir, "herdrelay.id")),
		Socket:       envOr("HERDR_SOCKET", filepath.Join(dir, "herdr.sock")),
		HerdrBin:     firstNonEmpty(os.Getenv("HERDRELAY_HERDR_BIN"), os.Getenv("HERDR_BIN_PATH"), "herdr"),
	}
	if l := os.Getenv("HERDRELAY_LISTEN"); l != "" {
		cfg.Listen = l
	} else if cfg.Mode == "funnel" {
		cfg.Listen = "127.0.0.1:8375"
	} else {
		cfg.Listen = ":8375"
	}
	return cfg, nil
}

// firstNonEmpty returns the first non-empty argument (last one is the default).
func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

// listenPort extracts the port from the listen address, defaulting to 8375.
func listenPort(cfg Config) string {
	_, port, err := net.SplitHostPort(cfg.Listen)
	if err != nil {
		return "8375"
	}
	return port
}