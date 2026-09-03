package main

import (
	"fmt"
	"os"

	"github.com/mdp/qrterminal/v3"
)

// runPairCmd implements `herdrelay pair [--qr]`: prints the pairing link for
// the local relay so the phone can connect. Used by the plugin's show-QR action.
func runPairCmd(args []string) int {
	qr := false
	for _, a := range args {
		switch a {
		case "--qr":
			qr = true
		default:
			fmt.Fprintf(os.Stderr, "herdrelay pair: unknown flag %q\n", a)
			return 2
		}
	}
	cfg, err := loadConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "herdrelay pair: %v\n", err)
		return 1
	}
	token, err := loadToken(cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "herdrelay pair: %v\n", err)
		return 1
	}
	base := "http://127.0.0.1:" + listenPort(cfg)
	info, err := fetchPairInfo(base, token)
	if err != nil {
		fmt.Fprintf(os.Stderr, "herdrelay pair: %v\n", err)
		return 1
	}
	pm, ok := info.URLs[info.Primary]
	if !ok {
		fmt.Fprintf(os.Stderr, "herdrelay pair: no connection mode available\n")
		return 1
	}
	fmt.Printf("Mode:  %s\nWS:    %s\nLink:  %s\n", info.Primary, pm.URL, pm.Link)
	if qr {
		qrterminal.GenerateWithConfig(pm.Link, qrterminal.Config{
			Level:      qrterminal.M,
			Writer:     os.Stdout,
			HalfBlocks: true,
			QuietZone:  1,
		})
	}
	return 0
}