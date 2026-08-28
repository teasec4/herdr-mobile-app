package main

// Agent — данные агента из herdr snapshot (поля, которые нужны клиенту).
type Agent struct {
	Agent                 string `json:"agent"`
	AgentStatus           string `json:"agent_status"`
	Cwd                   string `json:"cwd"`
	Focused               bool   `json:"focused"`
	PaneID                string `json:"pane_id"`
	TabID                 string `json:"tab_id"`
	TerminalID            string `json:"terminal_id"`
	TerminalTitle         string `json:"terminal_title"`
	TerminalTitleStripped string `json:"terminal_title_stripped"`
	WorkspaceID           string `json:"workspace_id"`
}

// Snapshot — весь видимый клиенту срез herdr.
type Snapshot struct {
	Agents []Agent `json:"agents"`
}