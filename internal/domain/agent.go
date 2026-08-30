package domain

// Agent represents an AI agent instance running in a terminal pane.
type Agent struct {
	Agent                 string `json:"agent"`
	AgentStatus           string `json:"agent_status"`
	DisplayAgent          string `json:"display_agent,omitempty"`
	Cwd                   string `json:"cwd"`
	Focused               bool   `json:"focused"`
	PaneID                string `json:"pane_id"`
	TabID                 string `json:"tab_id"`
	TerminalID            string `json:"terminal_id"`
	TerminalTitle         string `json:"terminal_title"`
	TerminalTitleStripped string `json:"terminal_title_stripped"`
	WorkspaceID           string `json:"workspace_id"`
}

// Snapshot contains the complete view of all active agents.
type Snapshot struct {
	Agents []Agent `json:"agents"`
}

// AgentOutput represents the terminal output of an agent.
type AgentOutput struct {
	Target string `json:"target"`
	Output string `json:"output"`
}
