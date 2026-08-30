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

// Workspace is a herdr workspace ("space"): a terminal project area holding
// tabs and panes (docs/10-herdr-api.md §6.1).
type Workspace struct {
	WorkspaceID string `json:"workspace_id"`
	Label       string `json:"label"`
	AgentStatus string `json:"agent_status"`
	TabCount    int    `json:"tab_count"`
	PaneCount   int    `json:"pane_count"`
	Focused     bool   `json:"focused"`
}

// Pane is a terminal pane in a workspace — with an agent or a plain terminal.
type Pane struct {
	PaneID        string `json:"pane_id"`
	WorkspaceID   string `json:"workspace_id"`
	TabID         string `json:"tab_id"`
	Agent         string `json:"agent,omitempty"`
	AgentStatus   string `json:"agent_status"`
	Cwd           string `json:"cwd,omitempty"`
	TerminalTitle string `json:"terminal_title,omitempty"`
	Focused       bool   `json:"focused"`
}

// Snapshot is the complete herdr session snapshot: workspaces, panes, agents
// and the focused targets. `herdr api snapshot` returns exactly this shape
// (docs/10-herdr-api.md §6.1).
type Snapshot struct {
	Workspaces         []Workspace `json:"workspaces"`
	Panes              []Pane      `json:"panes"`
	Agents             []Agent     `json:"agents"`
	FocusedWorkspaceID string      `json:"focused_workspace_id,omitempty"`
	FocusedTabID       string      `json:"focused_tab_id,omitempty"`
	FocusedPaneID      string      `json:"focused_pane_id,omitempty"`
}

// AgentOutput represents the terminal output of an agent.
type AgentOutput struct {
	Target string `json:"target"`
	Output string `json:"output"`
}
