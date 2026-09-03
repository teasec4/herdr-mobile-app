package main

import (
	"fmt"
	"net/http"
	"os"
	"sort"
	"time"
)

// runStatusCmd implements `herdrelay status`: prints the relay's configured
// mode, identity and live pairing state. Exit 0 if the relay is running,
// 1 otherwise. Read-only: it never creates token/identity files.
func runStatusCmd() int {
	cfg, err := loadConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "herdrelay status: %v\n", err)
		return 1
	}

	fmt.Printf("Mode:     %s\n", cfg.Mode)
	fmt.Printf("Listen:   %s\n", cfg.Listen)

	// Identity is read-only here: loadIdentity would create the file anew.
	identity := ""
	if _, err := os.Stat(cfg.IdentityFile); err == nil {
		if ident, ierr := loadIdentity(cfg); ierr == nil {
			identity = fmt.Sprintf("%s (%s)", ident.RelayID, ident.Name)
		}
	}
	if identity == "" {
		fmt.Printf("Relay:    not configured\n")
	} else {
		fmt.Printf("Relay:    %s\n", identity)
	}

	fmt.Println("Files:")
	paths := [][2]string{
		{"token", cfg.TokenFile},
		{"identity", cfg.IdentityFile},
		{"herdr socket", cfg.Socket},
	}
	for _, p := range paths {
		mark := ""
		if _, err := os.Stat(p[1]); err != nil {
			mark = " (missing)"
		}
		fmt.Printf("  %-14s %s%s\n", p[0]+":", p[1], mark)
	}
	fmt.Printf("  %-14s %s\n", "herdr binary:", cfg.HerdrBin)

	base := "http://127.0.0.1:" + listenPort(cfg)
	if !relayAlive(base) {
		fmt.Println("\nStatus: NOT RUNNING")
		fmt.Println("Start the relay: install.sh or 'launchctl start com.herdrelay.relay'")
		return 1
	}

	token, err := loadToken(cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "herdrelay status: %v\n", err)
		return 1
	}
	info, err := fetchPairInfo(base, token)
	if err != nil {
		fmt.Printf("\nStatus: RUNNING, but /pair unavailable: %v\n", err)
		return 1
	}

	fmt.Println("\nStatus: RUNNING")
	fmt.Printf("  primary: %s\n", info.Primary)
	names := make([]string, 0, len(info.URLs))
	for n := range info.URLs {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		m := info.URLs[n]
		avail := "unavailable"
		if m.Available {
			avail = "available"
		}
		fmt.Printf("  %-10s %-11s %s\n", n+":", avail, m.URL)
	}
	fmt.Println("\nQR for your phone: herdrelay pair --qr")
	return 0
}

// relayAlive reports whether the local relay answers /healthz.
func relayAlive(base string) bool {
	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get(base + "/healthz")
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}