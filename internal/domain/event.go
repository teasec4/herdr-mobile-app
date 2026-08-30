package domain

import "encoding/json"

// Event represents a relay event that can be sent to clients.
type Event interface {
	EventName() string
	EventData() interface{}
}

// AgentStatusChangedEvent is fired when an agent's status changes.
//
// The extra fields (agent, display_agent, workspace_id, title) mirror the
// payload herdr sends on pane.agent_status_changed (docs/10-herdr-api.md §5.3)
// so clients can refresh an agent from the event alone instead of re-reading
// the whole snapshot.
type AgentStatusChangedEvent struct {
	PaneID       string `json:"pane_id"`
	Agent        string `json:"agent,omitempty"`
	AgentStatus  string `json:"agent_status"`
	DisplayAgent string `json:"display_agent,omitempty"`
	WorkspaceID  string `json:"workspace_id,omitempty"`
	Title        string `json:"title,omitempty"`
}

func (e AgentStatusChangedEvent) EventName() string {
	return "pane.agent_status_changed"
}

func (e AgentStatusChangedEvent) EventData() interface{} {
	return e
}

// PaneUpdatedEvent is fired when a pane is created, destroyed, or modified.
type PaneUpdatedEvent struct {
	PaneID string `json:"pane_id"`
	// Revision is the pane's output revision carried by herdr's PaneInfo
	// (docs/10-herdr-api.md §6.1). 0 when the payload did not include it.
	Revision int `json:"revision,omitempty"`
	// Data retains the original normalized payload for clients that need it.
	Data json.RawMessage `json:"data,omitempty"`
}

func (e PaneUpdatedEvent) EventName() string {
	return "pane.updated"
}

func (e PaneUpdatedEvent) EventData() interface{} {
	return e
}

// OutputChangedEvent is fired when a pane's terminal output changes.
type OutputChangedEvent struct {
	PaneID   string `json:"pane_id"`
	Revision int    `json:"revision,omitempty"`
}

func (e OutputChangedEvent) EventName() string {
	return "pane.output_changed"
}

func (e OutputChangedEvent) EventData() interface{} {
	return e
}

// ParseEvent parses a raw event from herdr into a typed Event.
func ParseEvent(name string, data json.RawMessage) (Event, error) {
	switch name {
	case "pane.agent_status_changed":
		var e AgentStatusChangedEvent
		if err := json.Unmarshal(data, &e); err != nil {
			return nil, err
		}
		return e, nil

	case "pane.updated":
		var e PaneUpdatedEvent
		if err := json.Unmarshal(data, &e); err != nil {
			return nil, err
		}
		return e, nil

	case "pane.output_changed", "pane.scroll_changed":
		// scroll_changed maps to output_changed for clients
		var e OutputChangedEvent
		if err := json.Unmarshal(data, &e); err != nil {
			return nil, err
		}
		return e, nil

	default:
		// Unknown event - wrap as generic
		return GenericEvent{Name: name, Data: data}, nil
	}
}

// GenericEvent wraps unknown events.
type GenericEvent struct {
	Name string
	Data json.RawMessage
}

func (e GenericEvent) EventName() string {
	return e.Name
}

func (e GenericEvent) EventData() interface{} {
	return e.Data
}
