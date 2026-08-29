package repository

import "herdrelay/internal/domain"

// AgentRepository defines operations for interacting with herdr agents.
type AgentRepository interface {
	// Snapshot returns the current state of all agents.
	Snapshot() (*domain.Snapshot, error)

	// ReadOutput reads the terminal output of an agent.
	ReadOutput(target string, lines int, format string) (string, error)

	// SendKeys sends key sequences to an agent.
	SendKeys(target string, keys []string) error

	// SendPrompt sends a text prompt to an agent.
	SendPrompt(target, text string) error
}
