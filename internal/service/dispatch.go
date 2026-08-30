package service

import (
	"encoding/json"
)

// Protocol error codes returned to clients (mirror the ws error codes).
const (
	CodeBadParams     = "bad_params"
	CodeUnknownMethod = "unknown_method"
	CodeHerdrError    = "herdr_error"
)

// DispatchError carries a protocol error code alongside the message.
type DispatchError struct {
	Code    string
	Message string
}

func (e *DispatchError) Error() string { return e.Message }

func badParams() error {
	return &DispatchError{Code: CodeBadParams, Message: "invalid parameters"}
}

func unknownMethod(method string) error {
	return &DispatchError{Code: CodeUnknownMethod, Message: method}
}

func herdrError(err error) error {
	return &DispatchError{Code: CodeHerdrError, Message: err.Error()}
}

// Dispatch routes a relay request method to the repository-backed operations.
// It is shared by the WebSocket and HTTP transports so both answer identically
// (and the HTTP /api/rpc endpoint can act as a drop-in fallback for /ws).
func (s *AgentService) Dispatch(method string, params json.RawMessage) (interface{}, error) {
	switch method {
	case "agents.snapshot":
		snap, err := s.GetSnapshot()
		if err != nil {
			return nil, herdrError(err)
		}
		// Backward-compatible flat list of agents only.
		return map[string]interface{}{"agents": snap.Agents}, nil

	case "session.snapshot":
		snap, err := s.GetSnapshot()
		if err != nil {
			return nil, herdrError(err)
		}
		return snap, nil

	case "agent.start":
		var p struct {
			Name   string `json:"name"`
			Kind   string `json:"kind"`
			PaneID string `json:"pane_id"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, badParams()
		}
		if err := s.StartAgent(p.Name, p.Kind, p.PaneID); err != nil {
			return nil, herdrError(err)
		}
		return map[string]bool{"ok": true}, nil

	case "pane.output":
		var p struct {
			PaneID string `json:"pane_id"`
			Lines  int    `json:"lines"`
			Format string `json:"format"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, badParams()
		}
		output, err := s.GetPaneOutput(p.PaneID, p.Lines, p.Format)
		if err != nil {
			return nil, herdrError(err)
		}
		return output, nil

	case "pane.send_text":
		var p struct {
			PaneID string `json:"pane_id"`
			Text   string `json:"text"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, badParams()
		}
		if err := s.SendText(p.PaneID, p.Text); err != nil {
			return nil, herdrError(err)
		}
		return map[string]bool{"ok": true}, nil

	case "workspace.create":
		var p struct {
			Label string `json:"label"`
			Cwd   string `json:"cwd"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, badParams()
		}
		id, label, err := s.CreateWorkspace(p.Label, p.Cwd)
		if err != nil {
			return nil, herdrError(err)
		}
		return map[string]string{"workspace_id": id, "label": label}, nil

	case "agent.output":
		var p struct {
			Target string `json:"target"`
			Lines  int    `json:"lines"`
			Format string `json:"format"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, badParams()
		}
		output, err := s.GetOutput(p.Target, p.Lines, p.Format)
		if err != nil {
			return nil, herdrError(err)
		}
		return output, nil

	case "agent.keys":
		var p struct {
			Target string   `json:"target"`
			Keys   []string `json:"keys"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, badParams()
		}
		if err := s.SendKeys(p.Target, p.Keys); err != nil {
			return nil, herdrError(err)
		}
		return map[string]bool{"ok": true}, nil

	case "agent.prompt":
		var p struct {
			Target string `json:"target"`
			Text   string `json:"text"`
		}
		if err := json.Unmarshal(params, &p); err != nil {
			return nil, badParams()
		}
		if err := s.SendPrompt(p.Target, p.Text); err != nil {
			return nil, herdrError(err)
		}
		return map[string]bool{"ok": true}, nil

	default:
		return nil, unknownMethod(method)
	}
}
