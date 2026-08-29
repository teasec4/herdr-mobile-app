package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"

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
	req, err := http.NewRequest("GET", base+"/pair", nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "herdrelay pair: %v\n", err)
		return 1
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Fprintf(os.Stderr, "herdrelay pair: релей не отвечает (%v) — запустите его (launchctl start / install.sh)\n", err)
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		fmt.Fprintf(os.Stderr, "herdrelay pair: релей ответил %s: %s\n", resp.Status, strings.TrimSpace(string(b)))
		return 1
	}
	var info pairInfo
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		fmt.Fprintf(os.Stderr, "herdrelay pair: %v\n", err)
		return 1
	}
	pm, ok := info.URLs[info.Primary]
	if !ok {
		fmt.Fprintf(os.Stderr, "herdrelay pair: нет доступного режима подключения\n")
		return 1
	}
	fmt.Printf("Режим: %s\nWS:    %s\nСсылка: %s\n", info.Primary, pm.URL, pm.Link)
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
