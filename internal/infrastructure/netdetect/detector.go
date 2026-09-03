// Package netdetect detects how the relay is reachable from other machines:
// LAN IP, Tailscale (MagicDNS) presence and Tailscale Funnel status.
package netdetect

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"
)

// TailscaleInfo describes the machine's Tailscale identity.
type TailscaleInfo struct {
	DNSName string // MagicDNS name, e.g. mac.tailnet.ts.net
}

// Detector discovers the machine's network reachability modes.
type Detector interface {
	// LANIP returns the machine's private IPv4, or "" if unknown.
	LANIP() string
	// Tailscale returns the MagicDNS name if Tailscale is running, else nil.
	Tailscale() *TailscaleInfo
	// TailscaleReachable verifies the Tailscale hostname actually accepts TCP.
	TailscaleReachable(host, port string) bool
	// FunnelEnabled reports whether `tailscale funnel` is set up for this port.
	FunnelEnabled() bool
}

// SystemDetector implements Detector using OS commands.
type SystemDetector struct{}

// NewSystemDetector creates a detector backed by the local system.
func NewSystemDetector() *SystemDetector {
	return &SystemDetector{}
}

// LANIP returns the machine's private IPv4 for the lan mode.
func (SystemDetector) LANIP() string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	switch runtime.GOOS {
	case "darwin":
		for _, iface := range []string{"en0", "en1"} {
			if out, err := exec.CommandContext(ctx, "ipconfig", "getifaddr", iface).Output(); err == nil {
				if ip := strings.TrimSpace(string(out)); ip != "" {
					return ip
				}
			}
		}
	case "linux":
		if out, err := exec.CommandContext(ctx, "hostname", "-I").Output(); err == nil {
			for _, ip := range strings.Fields(string(out)) {
				if !strings.Contains(ip, ":") { // IPv4 only
					return ip
				}
			}
		}
	}
	return ""
}

// Tailscale returns the machine's MagicDNS name if Tailscale is running.
func (SystemDetector) Tailscale() *TailscaleInfo {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	// Try common tailscale binary locations
	tailscaleBin := "tailscale"
	for _, path := range []string{"/usr/local/bin/tailscale", "/usr/bin/tailscale"} {
		if _, err := os.Stat(path); err == nil {
			tailscaleBin = path
			break
		}
	}

	out, err := exec.CommandContext(ctx, tailscaleBin, "status", "--json").Output()
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
	return &TailscaleInfo{DNSName: name}
}

// TailscaleReachable verifies that the Tailscale hostname is reachable.
// This ensures the VPN is actually working, not just installed.
func (SystemDetector) TailscaleReachable(host, port string) bool {
	addr := net.JoinHostPort(host, port)
	conn, err := net.DialTimeout("tcp", addr, 2*time.Second)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

// FunnelEnabled checks if Tailscale Funnel is enabled for this machine.
// Funnel requires manual setup via `tailscale funnel --bg <port>`.
func (SystemDetector) FunnelEnabled() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	// Try to query the funnel status
	out, err := exec.CommandContext(ctx, "tailscale", "funnel", "status").Output()
	if err != nil {
		return false
	}
	// If funnel is running, the output contains port information
	return len(out) > 0 && !strings.Contains(string(out), "not running")
}