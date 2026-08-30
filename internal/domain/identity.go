package domain

// Identity identifies a relay instance: a stable relay_id (persisted across
// restarts) plus a human-readable name. Clients use relay_id to recognise a
// relay when switching sessions or machines.
type Identity struct {
	RelayID string `json:"relay_id"`
	Name    string `json:"name"`
}