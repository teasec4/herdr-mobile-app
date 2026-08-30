package herdr

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"herdrelay/internal/domain"
)

// unixSockPath returns a short unix-socket path for tests. macOS limits unix
// socket paths to ~104 bytes, and t.TempDir() embeds the (long) test name, so
// build a short-named dir under the system temp dir instead.
func unixSockPath(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "hdr")
	if err != nil {
		t.Fatalf("temp dir: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return filepath.Join(dir, "s.sock")
}

// fakeHerdrSocket is a minimal scripted herdr unix-socket server.
//
// Every accepted connection is served by handle(): it waits for the
// events.subscribe request (recording the raw request), answers with a
// response frame (which the repository skips — no "event" field), then writes
// the connection's scripted notifications, one JSON object per line, paced by
// [pace] between lines.
type fakeHerdrSocket struct {
	t    *testing.T
	ln   net.Listener
	pace time.Duration
	// Scripted notifications per connection, in connection order. Each
	// connection is served once; extra connections get no notifications.
	conns chan []string
	// Raw events.subscribe requests, in connection order.
	subs chan string
}

func startFakeHerdr(t *testing.T, pace time.Duration, perConn ...[]string) *fakeHerdrSocket {
	t.Helper()
	ln, err := net.Listen("unix", unixSockPath(t))
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	f := &fakeHerdrSocket{
		t:     t,
		ln:    ln,
		pace:  pace,
		conns: make(chan []string, len(perConn)),
		subs:  make(chan string, 16),
	}
	for _, c := range perConn {
		f.conns <- c
	}
	go f.acceptLoop()
	t.Cleanup(func() { ln.Close() })
	return f
}

func (f *fakeHerdrSocket) acceptLoop() {
	for {
		conn, err := f.ln.Accept()
		if err != nil {
			return
		}
		go f.handle(conn)
	}
}

func (f *fakeHerdrSocket) handle(conn net.Conn) {
	defer conn.Close()
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	var notifications []string
	select {
	case notifications = <-f.conns:
	default:
	}

	subscribed := false
	for scanner.Scan() {
		line := scanner.Text()
		var req struct {
			Method string `json:"method"`
		}
		if err := json.Unmarshal([]byte(line), &req); err != nil || req.Method != "events.subscribe" {
			continue
		}
		f.subs <- line
		if subscribed {
			continue
		}
		subscribed = true
		// Response frame: the repository skips frames without an "event" field.
		conn.Write([]byte(`{"jsonrpc":"2.0","id":"sub-0","result":{"status":"subscription_started"}}` + "\n"))
		for _, n := range notifications {
			conn.Write([]byte(n + "\n"))
			if f.pace > 0 {
				time.Sleep(f.pace)
			}
		}
	}
}

// collectEvents drains the repository event channel until count events arrive
// or the timeout elapses, then closes the repository and waits for Subscribe
// to return.
func collectEvents(t *testing.T, repo *SocketEventRepository, events chan domain.Event, count int) []domain.Event {
	t.Helper()
	got := make([]domain.Event, 0, count)
	timeout := time.After(6 * time.Second)
	for len(got) < count {
		select {
		case e := <-events:
			got = append(got, e)
		case <-timeout:
			t.Fatalf("timeout waiting for %d events, got %d: %#v", count, len(got), got)
		}
	}
	return got
}

// TestSocketEventRepositoryNormalizesAndForwardsRevision drives the full
// pipeline: pane_updated (underscore, nested PaneInfo) is normalized and its
// revision tracked; pane.scroll_changed is debounced per pane and forwarded as
// pane.output_changed with the revision only when it strictly increased.
func TestSocketEventRepositoryNormalizesAndForwardsRevision(t *testing.T) {
	// Connection 1: a pane_updated for a NEW pane -> the repository restarts
	// the connection with the full subscription set.
	// Connection 2: the pane is known; scrolls pace slower than the debounce.
	fake := startFakeHerdr(t, 550*time.Millisecond,
		[]string{`{"event":"pane_updated","data":{"pane":{"pane_id":"wH:p3","revision":7,"agent_status":"working"}}}`},
		[]string{
			`{"event":"pane_updated","data":{"pane":{"pane_id":"wH:p3","revision":7}}}`,
			`{"event":"pane.scroll_changed","data":{"pane_id":"wH:p3"}}`,
			`{"event":"pane_updated","data":{"pane":{"pane_id":"wH:p3","revision":7}}}`,
			`{"event":"pane.scroll_changed","data":{"pane_id":"wH:p3"}}`,
			`{"event":"pane_updated","data":{"pane":{"pane_id":"wH:p3","revision":8}}}`,
			`{"event":"pane.scroll_changed","data":{"pane_id":"wH:p3"}}`,
		},
	)

	repo := NewSocketEventRepository(fake.ln.Addr().String())
	events := make(chan domain.Event, 16)
	done := make(chan struct{})
	go func() {
		repo.Subscribe(events)
		close(done)
	}()

	// 1) first event: pane.updated normalized (underscore -> dot) with pane_id
	//    extracted (from connection 1, which restarts the subscription).
	got := collectEvents(t, repo, events, 7)
	pu, ok := got[0].(domain.PaneUpdatedEvent)
	if !ok || pu.PaneID != "wH:p3" {
		t.Fatalf("expected pane.updated for wH:p3, got %#v", got[0])
	}
	// The rest of the script also carries pane.updated notifications; filter
	// them out to check the output_changed sequence.
	ocs := make([]domain.OutputChangedEvent, 0, 3)
	for _, e := range got[1:] {
		if oc, ok := e.(domain.OutputChangedEvent); ok {
			ocs = append(ocs, oc)
		}
	}
	if len(ocs) != 3 {
		t.Fatalf("expected 3 output_changed events, got %d: %#v", len(ocs), got[1:])
	}
	// 2) first scroll after the restart -> output_changed with the tracked rev.
	if ocs[0].PaneID != "wH:p3" || ocs[0].Revision != 7 {
		t.Fatalf("expected output_changed rev 7, got %#v", ocs[0])
	}
	// 3) pane.updated reports the same revision -> the next scroll is forwarded
	//    WITHOUT a revision (a stale revision would make the client's guard
	//    wrongly skip a real output change).
	if ocs[1].PaneID != "wH:p3" || ocs[1].Revision != 0 {
		t.Fatalf("expected output_changed without revision, got %#v", ocs[1])
	}
	// 4) revision grows to 8 -> the next scroll carries it.
	if ocs[2].PaneID != "wH:p3" || ocs[2].Revision != 8 {
		t.Fatalf("expected output_changed rev 8, got %#v", ocs[2])
	}

	repo.Close()
	<-done
}

// TestSocketEventRepositoryDebounce checks that scroll_changed bursts within
// the debounce window collapse into a single output_changed.
func TestSocketEventRepositoryDebounce(t *testing.T) {
	fake := startFakeHerdr(t, 0,
		[]string{`{"event":"pane_updated","data":{"pane_id":"wH:p3"}}`},
		[]string{
			`{"event":"pane.scroll_changed","data":{"pane_id":"wH:p3"}}`,
			`{"event":"pane.scroll_changed","data":{"pane_id":"wH:p3"}}`, // dropped (debounce)
			`{"event":"pane.scroll_changed","data":{"pane_id":"wH:p3"}}`, // dropped (debounce)
		},
	)

	repo := NewSocketEventRepository(fake.ln.Addr().String())
	events := make(chan domain.Event, 16)
	done := make(chan struct{})
	go func() {
		repo.Subscribe(events)
		close(done)
	}()

	// pane.updated, then exactly ONE output_changed despite three scrolls.
	got := collectEvents(t, repo, events, 2)
	oc, ok := got[1].(domain.OutputChangedEvent)
	if !ok || oc.PaneID != "wH:p3" {
		t.Fatalf("expected a single output_changed, got %#v", got[1:])
	}

	repo.Close()
	<-done
}

// TestSocketEventRepositoryStatusFieldsAndRestart verifies that a new pane
// restarts the connection with the full subscription set and that status
// events keep herdr's extra fields (agent, display_agent, workspace_id).
func TestSocketEventRepositoryStatusFieldsAndRestart(t *testing.T) {
	fake := startFakeHerdr(t, 0,
		// Connection 1: flat pane_updated for a pane we do not know yet.
		[]string{`{"event":"pane_updated","data":{"pane_id":"wH:p3"}}`},
		// Connection 2: status event with the full herdr payload.
		[]string{`{"event":"pane.agent_status_changed","data":{"pane_id":"wH:p3","agent":"codex","agent_status":"blocked","display_agent":"codex","workspace_id":"wF"}}`},
	)

	repo := NewSocketEventRepository(fake.ln.Addr().String())
	events := make(chan domain.Event, 16)
	done := make(chan struct{})
	go func() {
		repo.Subscribe(events)
		close(done)
	}()

	// First event: the new pane's pane.updated.
	got := collectEvents(t, repo, events, 2)
	pu, ok := got[0].(domain.PaneUpdatedEvent)
	if !ok || pu.PaneID != "wH:p3" {
		t.Fatalf("expected pane.updated for wH:p3, got %#v", got[0])
	}

	// The restart reconnects and subscribes the new pane (both scoped events).
	timeout := time.After(6 * time.Second)
	var secondSub string
	for i := 0; i < 2; i++ {
		select {
		case s := <-fake.subs:
			if strings.Contains(s, `"wH:p3"`) {
				secondSub = s
			}
		case <-timeout:
			t.Fatal("timeout waiting for resubscribe")
		}
	}
	if !strings.Contains(secondSub, `"pane.scroll_changed"`) ||
		!strings.Contains(secondSub, `"pane.agent_status_changed"`) {
		t.Fatalf("resubscribe missing scoped subscriptions: %s", secondSub)
	}

	// Status event keeps herdr's extra fields.
	as, ok := got[1].(domain.AgentStatusChangedEvent)
	if !ok || as.PaneID != "wH:p3" || as.AgentStatus != "blocked" {
		t.Fatalf("expected status event for wH:p3 blocked, got %#v", got[1])
	}
	if as.Agent != "codex" || as.DisplayAgent != "codex" || as.WorkspaceID != "wF" {
		t.Fatalf("status event lost herdr fields: %#v", as)
	}

	repo.Close()
	<-done
}
