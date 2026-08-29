package domain

import "encoding/json"

// Event represents a relay event that can be sent to clients.
type Event interface {
	EventName() string
	EventData() interface{}
}

// AgentStatusChangedEvent is fired when an agent's status changes.
type AgentStatusChangedEvent struct {
	PaneID      string `json:"pane_id"`
	AgentStatus string `json:"agent_status"`
}

func (e AgentStatusChangedEvent) EventName() string {
	return "pane.agent_status_changed"
}

func (e AgentStatusChangedEvent) EventData() interface{} {
	return e
}

// PaneUpdatedEvent is fired when a pane is created, destroyed, or modified.
type PaneUpdatedEvent struct {
	PaneID string          `json:"pane_id"`
	Data   json.RawMessage `json:"data,omitempty"`
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
