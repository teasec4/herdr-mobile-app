package main

import (
	"encoding/json"
	"net"
	"net/url"
	"os"
	"os/exec"
	"runtime"
	"strings"
)

type pairMode struct {
	URL  string `json:"url"`  // ws/wss endpoint to connect to
	Link string `json:"link"` // custom-scheme herdrelay://pair?... link
}

type pairInfo struct {
	Mode    string              `json:"mode"`
	Primary string              `json:"primary"`
	URLs    map[string]pairMode `json:"urls"`
	Token   string              `json:"token"`
}

func listenPort(cfg Config) string {
	_, port, err := net.SplitHostPort(cfg.Listen)
	if err != nil {
		return "8375"
	}
	return port
}

// pairInfo collects the available connection modes (see docs/07-onboarding.md).
func (s *Server) pairInfo() pairInfo {
	port := listenPort(s.cfg)
	urls := map[string]pairMode{}
	var primary string
	add := func(mode, wsURL string, params map[string]string) {
		urls[mode] = pairMode{
			URL:  wsURL,
			Link: pairLink(mode, params, s.token),
		}
		if primary == "" {
			primary = mode
		}
	}
	if ip := detectLANIP(); ip != "" {
		add("lan", "ws://"+net.JoinHostPort(ip, port), map[string]string{"host": ip, "port": port})
	}
	if ts := tailscaleInfo(); ts != nil {
		add("tailscale", "ws://"+net.JoinHostPort(ts.DNSName, port), map[string]string{"host": ts.DNSName, "port": port})
		add("funnel", "https://"+ts.DNSName, map[string]string{"host": ts.DNSName})
	}
	if s.cfg.GatewayURL != "" {
		add("gateway", s.cfg.GatewayURL, map[string]string{"url": s.cfg.GatewayURL})
	}
	return pairInfo{Mode: s.cfg.Mode, Primary: primary, URLs: urls, Token: s.token}
}

func pairLink(mode string, params map[string]string, token string) string {
	q := url.Values{}
	for k, v := range params {
		q.Set(k, v)
	}
	q.Set("mode", mode)
	q.Set("token", token)
	return "herdrelay://pair?" + q.Encode()
}

// detectLANIP returns the machine's private IPv4 for the lan mode.
func detectLANIP() string {
	switch runtime.GOOS {
	case "darwin":
		for _, iface := range []string{"en0", "en1"} {
			if out, err := exec.Command("ipconfig", "getifaddr", iface).Output(); err == nil {
				if ip := strings.TrimSpace(string(out)); ip != "" {
					return ip
				}
			}
		}
	case "linux":
		if out, err := exec.Command("hostname", "-I").Output(); err == nil {
			for _, ip := range strings.Fields(string(out)) {
				if !strings.Contains(ip, ":") { // IPv4 only
					return ip
				}
			}
		}
	}
	return ""
}

type tailscaleInfoT struct {
	DNSName string
}

// tailscaleInfo returns the machine's MagicDNS name if Tailscale is running.
func tailscaleInfo() *tailscaleInfoT {
	// Try common tailscale binary locations
	tailscaleBin := "tailscale"
	for _, path := range []string{"/usr/local/bin/tailscale", "/usr/bin/tailscale"} {
		if _, err := os.Stat(path); err == nil {
			tailscaleBin = path
			break
		}
	}

	out, err := exec.Command(tailscaleBin, "status", "--json").Output()
	if err != nil {
		return nil
	}
	var st struct {
		BackendState string `json:"BackendState"`
		Self         struct {
			DNSName string `json:"DNSName"`
		} `json:"Self"`
	}
	if err := json.Unmarshal(out, &st); err != nil {
		return nil
	}
	if st.BackendState != "Running" {
		return nil
	}
	name := strings.TrimSuffix(st.Self.DNSName, ".")
	if name == "" {
		return nil
	}
	return &tailscaleInfoT{DNSName: name}
}