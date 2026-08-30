package domain

// PairMode describes one way to reach the relay (lan, tailscale, funnel, gateway).
type PairMode struct {
	URL         string `json:"url"`         // ws/wss endpoint to connect to
	Link        string `json:"link"`        // custom-scheme herdrelay://pair?... link (with mode)
	Available   bool   `json:"available"`   // true if this mode is currently reachable
	Description string `json:"description"` // human-readable description
}

// PairInfo is the /pair response: every reachable mode plus the primary one.
type PairInfo struct {
	Mode        string              `json:"mode"`
	Primary     string              `json:"primary"`
	URLs        map[string]PairMode `json:"urls"`
	Token       string              `json:"token"`
	UniversalQR string              `json:"universal_qr"` // QR without mode, triggers mode selection
	RelayID     string              `json:"relay_id"`     // stable relay identity
	Name        string              `json:"name"`         // host name, human-readable
}
