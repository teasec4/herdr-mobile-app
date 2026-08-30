package domain

import (
	"encoding/json"
	"testing"
)

func TestParseEventAgentStatusChanged(t *testing.T) {
	data := json.RawMessage(`{"pane_id":"wF:p5","agent":"codex","agent_status":"blocked","display_agent":"codex","workspace_id":"wF","title":"codex — /tmp/x"}`)
	e, err := ParseEvent("pane.agent_status_changed", data)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	as, ok := e.(AgentStatusChangedEvent)
	if !ok {
		t.Fatalf("expected AgentStatusChangedEvent, got %T", e)
	}
	if as.PaneID != "wF:p5" || as.AgentStatus != "blocked" {
		t.Fatalf("unexpected core fields: %#v", as)
	}
	// herdr's extra fields must survive (docs/10-herdr-api.md §5.3).
	if as.Agent != "codex" || as.DisplayAgent != "codex" || as.WorkspaceID != "wF" || as.Title != "codex — /tmp/x" {
		t.Fatalf("extra fields lost: %#v", as)
	}
}

func TestParseEventAgentStatusChangedMinimal(t *testing.T) {
	// Old relays / minimal payloads must still parse.
	data := json.RawMessage(`{"pane_id":"p1","agent_status":"working"}`)
	e, err := ParseEvent("pane.agent_status_changed", data)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	as := e.(AgentStatusChangedEvent)
	if as.PaneID != "p1" || as.AgentStatus != "working" || as.Agent != "" || as.WorkspaceID != "" {
		t.Fatalf("unexpected parse: %#v", as)
	}
}

func TestParseEventOutputChanged(t *testing.T) {
	// scroll_changed and output_changed both map to OutputChangedEvent.
	for _, name := range []string{"pane.output_changed", "pane.scroll_changed"} {
		data := json.RawMessage(`{"pane_id":"p1","revision":42}`)
		e, err := ParseEvent(name, data)
		if err != nil {
			t.Fatalf("%s parse: %v", name, err)
		}
		oc, ok := e.(OutputChangedEvent)
		if !ok || oc.PaneID != "p1" || oc.Revision != 42 {
			t.Fatalf("%s: unexpected parse %#v", name, e)
		}
	}
}

func TestParseEventUnknown(t *testing.T) {
	e, err := ParseEvent("some.unknown", json.RawMessage(`{}`))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if _, ok := e.(GenericEvent); !ok {
		t.Fatalf("expected GenericEvent, got %T", e)
	}
}
