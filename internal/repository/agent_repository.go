package repository

import "herdrelay/internal/domain"

// AgentRepository defines operations for interacting with herdr agents.
type AgentRepository interface {
	// Snapshot returns the complete session snapshot: workspaces, panes,
	// agents and focused targets.
	Snapshot() (*domain.Snapshot, error)

	// ReadOutput reads the terminal output of an agent.
	ReadOutput(target string, lines int, format string) (string, error)

	// ReadPaneOutput reads a pane's terminal output (works for plain
	// terminals without an agent).
	ReadPaneOutput(paneID string, lines int, format string) (string, error)

	// SendKeys sends key sequences to an agent.
	SendKeys(target string, keys []string) error

	// SendPrompt sends a text prompt to an agent.
	SendPrompt(target, text string) error

	// SendText writes literal text into a pane (plain terminal input).
	SendText(paneID, text string) error

	// StartAgent launches an agent of the given kind into an existing pane.
	StartAgent(name, kind, paneID string) error

	// CreateWorkspace creates a workspace and returns its id and label.
	CreateWorkspace(label, cwd string) (string, string, error)
}
