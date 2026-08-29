package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"sync"
	"time"
)

// herdrSubscriber streams live pane events from herdr's unix-socket JSON-RPC
// API and pushes them to WS clients.
//
// Why this exists: herdr's plugin hook system has no event for terminal
// output (verified: pane.updated / pane.output_changed / pane.scroll_changed
// are all rejected as unknown events by the plugin linker), so plugin hooks
// cannot drive the live-update half of the phone terminal. The socket API can:
// a subscription on `pane.scroll_changed` (per pane_id) fires whenever that
// pane's scrollable output changes. The subscriber maps it to the stable
// client event name `pane.output_changed` (client only re-reads on that name).
//
// Wire format: newline-delimited JSON-RPC 2.0. Requests carry a string id;
// notifications are flat {"event":..., "data":...} objects.
type herdrSubscriber struct {
	socket string
	hub    *Hub

	mu    sync.Mutex
	known map[string]bool // pane_ids with an active scroll_changed subscription
}

func newHerdrSubscriber(socket string, hub *Hub) *herdrSubscriber {
	return &herdrSubscriber{socket: socket, hub: hub, known: map[string]bool{}}
}

// seedKnown pre-registers pane_ids so the first connect subscribes to their
// scroll changes without waiting for an initial pane_updated notification.
// Safe to call from any goroutine before run() starts.
func (h *herdrSubscriber) seedKnown(ids ...string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, id := range ids {
		if id != "" {
			h.known[id] = true
		}
	}
}

// run keeps a subscription alive, reconnecting with exponential backoff on
// any error so the relay survives herdr restarts and socket glitches.
func (h *herdrSubscriber) run() {
	backoff := 2 * time.Second
	for {
		if err := h.runOnce(); err != nil {
			log.Printf("herdr events: %v (retrying in %s)", err, backoff)
			time.Sleep(backoff)
			if backoff < 30*time.Second {
				backoff *= 2
			}
			continue
		}
		backoff = 2 * time.Second
		time.Sleep(time.Second) // avoid a hot reconnect loop after a clean close
	}
}

// runOnce dials the herdr socket, subscribes to pane.updated (global, tracks
// new panes) plus pane.scroll_changed per known pane_id, then forwards
// notifications to the hub until the connection dies.
func (h *herdrSubscriber) runOnce() error {
	conn, err := net.Dial("unix", h.socket)
	if err != nil {
		return fmt.Errorf("dial herdr socket: %w", err)
	}
	defer conn.Close()

	if err := h.writeSubs(conn, h.subscriptions()); err != nil {
		return fmt.Errorf("subscribe: %w", err)
	}
	log.Printf("herdr events: subscribed on %s (%d pane(s))", h.socket, h.paneCount())

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		var n struct {
			Event string          `json:"event"`
			Data  json.RawMessage `json:"data"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &n); err != nil || n.Event == "" {
			continue // subscribe responses, keepalives, other noise
		}
		switch n.Event {
		case "pane.scroll_changed":
			// The client treats any pane whose output tail may have grown as
			// "output changed" and re-reads it. scroll_changed carries no
			// revision, so the client's revision guard simply stays inert and
			// its debounce collapses bursts.
			h.hub.broadcast(mustJSON(frame{Type: "event", Event: "pane.output_changed", Data: n.Data}))
		case "pane_updated":
			h.handlePaneUpdated(conn, n.Data)
		}
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("read herdr events: %w", err)
	}
	return fmt.Errorf("herdr events connection closed")
}

// handlePaneUpdated tracks pane_id discovered from pane_updated notifications
// and subscribes to scroll changes for panes we had not seen yet (a pane only
// starts relaying output after its explicit per-pane subscription). Requires
// the live conn: incremental subscriptions must go out on the same socket.
func (h *herdrSubscriber) handlePaneUpdated(conn net.Conn, data json.RawMessage) {
	var env struct {
		Pane struct {
			PaneID string `json:"pane_id"`
		} `json:"pane"`
	}
	if err := json.Unmarshal(data, &env); err != nil || env.Pane.PaneID == "" {
		return
	}
	pid := env.Pane.PaneID
	h.mu.Lock()
	_, know := h.known[pid]
	if !know {
		h.known[pid] = true
	}
	h.mu.Unlock()
	if know {
		return
	}
	if err := h.writeSubs(conn, []any{map[string]any{"type": "pane.scroll_changed", "pane_id": pid}}); err != nil {
		log.Printf("herdr events: subscribe %s: %v", pid, err)
	}
}

// subscriptions lists the full set to (re)subscribe on a fresh connection.
func (h *herdrSubscriber) subscriptions() []any {
	h.mu.Lock()
	defer h.mu.Unlock()
	subs := []any{map[string]any{"type": "pane.updated"}}
	for pid := range h.known {
		subs = append(subs, map[string]any{"type": "pane.scroll_changed", "pane_id": pid})
	}
	return subs
}

func (h *herdrSubscriber) paneCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.known)
}

// writeSubs posts one events.subscribe request carrying all given
// subscriptions. The id is a constant string (the socket API rejects
// non-string request ids).
func (h *herdrSubscriber) writeSubs(conn net.Conn, subs []any) error {
	req := map[string]any{
		"jsonrpc": "2.0",
		"id":      "relay:events",
		"method":  "events.subscribe",
		"params":  map[string]any{"subscriptions": subs},
	}
	b, err := json.Marshal(req)
	if err != nil {
		return err
	}
	_, err = conn.Write(append(b, '\n'))
	return err
}