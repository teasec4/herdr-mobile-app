package service

import (
	"net"
	"net/url"

	"herdrelay/internal/domain"
	"herdrelay/internal/infrastructure/netdetect"
)

// PairingService builds the /pair response describing how other machines
// can reach this relay (see docs/07-onboarding.md).
type PairingService struct {
	detector   netdetect.Detector
	identity   domain.Identity
	mode       string // config Mode: lan | tailscale | funnel | gateway
	port       string // listen port, e.g. "8375"
	gatewayURL string // gateway mode only
	token      string
}

// NewPairingService creates a pairing service.
func NewPairingService(detector netdetect.Detector, identity domain.Identity, mode, port, gatewayURL, token string) *PairingService {
	return &PairingService{
		detector:   detector,
		identity:   identity,
		mode:       mode,
		port:       port,
		gatewayURL: gatewayURL,
		token:      token,
	}
}

// PairInfo collects the available connection modes.
func (s *PairingService) PairInfo() domain.PairInfo {
	urls := map[string]domain.PairMode{}
	var primary string
	add := func(mode, wsURL, description string, params map[string]string, available bool) {
		urls[mode] = domain.PairMode{
			URL:         wsURL,
			Link:        pairLink(mode, params, s.token, s.identity.RelayID, s.identity.Name),
			Available:   available,
			Description: description,
		}
		if primary == "" && available {
			primary = mode
		}
	}

	if ip := s.detector.LANIP(); ip != "" {
		add("lan", "ws://"+net.JoinHostPort(ip, s.port), "Local network", map[string]string{"host": ip, "port": s.port}, true)
	}
	if ts := s.detector.Tailscale(); ts != nil {
		tsAvailable := s.detector.TailscaleReachable(ts.DNSName, s.port)
		add("tailscale", "ws://"+net.JoinHostPort(ts.DNSName, s.port), "Tailscale VPN", map[string]string{"host": ts.DNSName, "port": s.port}, tsAvailable)

		// Funnel requires manual setup, check if it's actually enabled
		add("funnel", "https://"+ts.DNSName, "Public HTTPS via Tailscale Funnel", map[string]string{"host": ts.DNSName}, s.detector.FunnelEnabled())
	}
	if s.gatewayURL != "" {
		add("gateway", s.gatewayURL, "Gateway mode", map[string]string{"url": s.gatewayURL}, true)
	}

	// Generate universal QR link (without mode) that triggers mode selection in the app
	universalQR := generateUniversalLink(urls, s.token, s.identity.RelayID, s.identity.Name)

	return domain.PairInfo{
		Mode:        s.mode,
		Primary:     primary,
		URLs:        urls,
		Token:       s.token,
		UniversalQR: universalQR,
		RelayID:     s.identity.RelayID,
		Name:        s.identity.Name,
	}
}

// pairLink builds the custom-scheme link for a single mode.
func pairLink(mode string, params map[string]string, token, relayID, name string) string {
	q := url.Values{}
	for k, v := range params {
		q.Set(k, v)
	}
	// Include mode in the link for backwards compatibility and direct mode selection
	q.Set("mode", mode)
	q.Set("token", token)
	if relayID != "" {
		q.Set("relay_id", relayID)
	}
	if name != "" {
		q.Set("name", name)
	}
	return "herdrelay://pair?" + q.Encode()
}

// generateUniversalLink creates a QR link without mode that triggers mode selection.
// It uses the primary available host for initial /pair request.
func generateUniversalLink(urls map[string]domain.PairMode, token, relayID, name string) string {
	// Prefer LAN for universal link (fastest for initial /pair request)
	var host, port string
	if lan, ok := urls["lan"]; ok && lan.Available {
		// Parse host and port from lan URL: ws://192.168.x.x:8375
		u, err := url.Parse(lan.URL)
		if err == nil {
			host = u.Hostname()
			port = u.Port()
		}
	}
	// Fallback to tailscale if LAN not available
	if host == "" {
		if ts, ok := urls["tailscale"]; ok && ts.Available {
			u, err := url.Parse(ts.URL)
			if err == nil {
				host = u.Hostname()
				port = u.Port()
			}
		}
	}
	if host == "" {
		return "" // No available modes
	}

	q := url.Values{}
	q.Set("host", host)
	if port != "" {
		q.Set("port", port)
	}
	q.Set("token", token)
	if relayID != "" {
		q.Set("relay_id", relayID)
	}
	if name != "" {
		q.Set("name", name)
	}
	// No "mode" parameter - this triggers mode selection in the app
	return "herdrelay://pair?" + q.Encode()
}