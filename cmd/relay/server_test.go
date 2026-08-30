package main

import (
	"bufio"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gorilla/websocket"

	"herdrelay/internal/domain"
	"herdrelay/internal/infrastructure/netdetect"
	"herdrelay/internal/service"
	httpTransport "herdrelay/internal/transport/http"
	"herdrelay/internal/transport/ws"
)

// stubAgentRepo is a fake agent repository (no herdr subprocess needed).
type stubAgentRepo struct{}

func (stubAgentRepo) Snapshot() (*domain.Snapshot, error) {
	return &domain.Snapshot{
		Workspaces: []domain.Workspace{{WorkspaceID: "wF", Label: "herdr_relay", AgentStatus: "working", PaneCount: 1}},
		Panes: []domain.Pane{{PaneID: "wF:p5", WorkspaceID: "wF", TabID: "wF:t1", Agent: "codex", AgentStatus: "working"}},
		Agents:     []domain.Agent{{Agent: "codex", AgentStatus: "working", PaneID: "wF:p5"}},
	}, nil
}
func (stubAgentRepo) ReadOutput(target string, lines int, format string) (string, error) { return "hello\nworld\n", nil }
func (stubAgentRepo) SendKeys(target string, keys []string) error                         { return nil }
func (stubAgentRepo) SendPrompt(target, text string) error                                { return nil }
func (stubAgentRepo) StartAgent(name, kind, paneID string) error                          { return nil }
func (stubAgentRepo) CreateWorkspace(label, cwd string) (string, string, error)           { return "w9", "test-ws", nil }

// stubEventRepo is a fake event repository.
type stubEventRepo struct{}

func (stubEventRepo) Subscribe(events chan<- domain.Event) error { return nil }
func (stubEventRepo) Close() error                               { return nil }

// stubDetector simulates a machine with LAN + Tailscale + Funnel available.
type stubDetector struct{}

func (stubDetector) LANIP() string { return "192.168.1.5" }
func (stubDetector) Tailscale() *netdetect.TailscaleInfo {
	return &netdetect.TailscaleInfo{DNSName: "mac.tailnet.ts.net"}
}
func (stubDetector) TailscaleReachable(host, port string) bool { return true }
func (stubDetector) FunnelEnabled() bool                        { return true }

// testServer wires the relay exactly like main.go and serves it via httptest.
func testServer(t *testing.T, token string) *httptest.Server {
	t.Helper()
	agentService := service.NewAgentService(stubAgentRepo{})
	eventService := service.NewEventService(stubEventRepo{})
	identity := domain.Identity{RelayID: "relay-0123456789abcdef", Name: "test-host"}
	pairing := service.NewPairingService(stubDetector{}, identity, "lan", "8375", "", token)
	hub := ws.NewHub()

	// main.go wiring: forward broadcast events to the WS hub
	events := eventService.Subscribe()
	go func() {
		for event := range events {
			hub.BroadcastEvent(event)
		}
	}()

	httpHandler := httpTransport.NewHandler(agentService, eventService, pairing)
	wsHandler := ws.NewHandler(hub, agentService, eventService)
	ts := httptest.NewServer(buildMux(token, httpHandler, wsHandler))
	t.Cleanup(ts.Close)
	return ts
}

func wsConn(t *testing.T, ts *httptest.Server, token string) *websocket.Conn {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws?token=" + token
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn
}

func TestAuth(t *testing.T) {
	ts := testServer(t, "secret-token")

	resp, err := http.Get(ts.URL + "/api/snapshot")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 without token, got %d", resp.StatusCode)
	}

	resp, err = http.Get(ts.URL + "/api/snapshot?token=secret-token")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 with token, got %d", resp.StatusCode)
	}
}

func TestSnapshotAPI(t *testing.T) {
	ts := testServer(t, "secret-token")
	req, _ := http.NewRequest(http.MethodGet, ts.URL+"/api/snapshot", nil)
	req.Header.Set("Authorization", "Bearer secret-token")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	var snap domain.Snapshot
	if err := json.NewDecoder(resp.Body).Decode(&snap); err != nil {
		t.Fatal(err)
	}
	if len(snap.Agents) != 1 || snap.Agents[0].PaneID != "wF:p5" {
		t.Fatalf("unexpected snapshot: %+v", snap.Agents)
	}
}

func TestWSRequestResponse(t *testing.T) {
	ts := testServer(t, "secret-token")
	conn := wsConn(t, ts, "secret-token")

	// ping -> pong
	if err := conn.WriteMessage(websocket.TextMessage, []byte(`{"type":"ping"}`)); err != nil {
		t.Fatal(err)
	}
	_, raw, err := conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	var pong ws.Frame
	if err := json.Unmarshal(raw, &pong); err != nil || pong.Type != "pong" {
		t.Fatalf("expected pong, got %s", raw)
	}

	// request agents.snapshot -> response with the same id
	if err := conn.WriteMessage(websocket.TextMessage, []byte(`{"type":"request","id":7,"method":"agents.snapshot","params":{}}`)); err != nil {
		t.Fatal(err)
	}
	_, raw, err = conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	var resp ws.Frame
	if err := json.Unmarshal(raw, &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Type != "response" || resp.ID != float64(7) {
		t.Fatalf("unexpected response: %s", raw)
	}
	if resp.OK == nil || !*resp.OK {
		t.Fatalf("expected ok=true: %s", raw)
	}
}

// TestHerdrEventBroadcast verifies a raw HERDR_PLUGIN_EVENT_JSON payload from a
// herdr hook is normalized to pane.agent_status_changed and reaches the WS client.
func TestHerdrEventBroadcast(t *testing.T) {
	ts := testServer(t, "secret-token")
	conn := wsConn(t, ts, "secret-token")

	body := strings.NewReader(`{"data":{"pane_id":"wF:p5","agent":"codex","agent_status":"blocked","cwd":"/tmp/x"}}`)
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/events/herdr?token=secret-token", body)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()

	_, raw, err := conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	var ev ws.Frame
	if err := json.Unmarshal(raw, &ev); err != nil {
		t.Fatal(err)
	}
	if ev.Type != "event" || ev.Event != "pane.agent_status_changed" {
		t.Fatalf("unexpected event: %s", raw)
	}
	data, ok := ev.Data.(map[string]any)
	if !ok || data["agent_status"] != "blocked" {
		t.Fatalf("unexpected data: %v", ev.Data)
	}
}

func TestPairEndpoint(t *testing.T) {
	ts := testServer(t, "secret-token")
	req, _ := http.NewRequest(http.MethodGet, ts.URL+"/pair", nil)
	req.Header.Set("Authorization", "Bearer secret-token")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	var info domain.PairInfo
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		t.Fatal(err)
	}
	if info.Primary != "lan" {
		t.Fatalf("expected primary=lan, got %q", info.Primary)
	}
	lan, ok := info.URLs["lan"]
	if !ok || !lan.Available {
		t.Fatalf("expected available lan mode, got %+v", info.URLs)
	}
	if !strings.HasPrefix(lan.Link, "herdrelay://pair?") || !strings.Contains(lan.Link, "mode=lan") || !strings.Contains(lan.Link, "token=secret-token") {
		t.Fatalf("unexpected link: %s", lan.Link)
	}
	if info.UniversalQR == "" || strings.Contains(info.UniversalQR, "mode=") {
		t.Fatalf("expected a mode-less universal QR link, got %q", info.UniversalQR)
	}
	if !strings.Contains(lan.Link, "relay_id=relay-0123456789abcdef") || !strings.Contains(lan.Link, "name=test-host") {
		t.Fatalf("expected relay identity in link, got %s", lan.Link)
	}
	if !strings.Contains(info.UniversalQR, "relay_id=relay-0123456789abcdef") {
		t.Fatalf("expected relay_id in universal QR, got %q", info.UniversalQR)
	}
	if info.RelayID != "relay-0123456789abcdef" {
		t.Fatalf("expected relay_id relay-0123456789abcdef, got %q", info.RelayID)
	}
	if info.Name != "test-host" {
		t.Fatalf("expected name test-host, got %q", info.Name)
	}
}

func TestFetchPairInfo(t *testing.T) {
	ts := testServer(t, "secret-token")
	info, err := fetchPairInfo(ts.URL, "secret-token")
	if err != nil {
		t.Fatal(err)
	}
	if info.Primary != "lan" {
		t.Fatalf("expected primary=lan, got %q", info.Primary)
	}
	lan, ok := info.URLs["lan"]
	if !ok || !lan.Available {
		t.Fatalf("expected available lan mode, got %+v", info.URLs)
	}
	if !strings.Contains(lan.Link, "relay_id=relay-0123456789abcdef") {
		t.Fatalf("expected relay_id in link, got %s", lan.Link)
	}
	if info.Name != "test-host" {
		t.Fatalf("expected name test-host, got %q", info.Name)
	}

	// Wrong token must produce an error, not a decoded PairInfo.
	if _, err := fetchPairInfo(ts.URL, "wrong-token"); err == nil {
		t.Fatal("expected error with wrong token")
	}
}

func TestLoadIdentityCreatesFile(t *testing.T) {
	dir := t.TempDir()
	cfg := Config{IdentityFile: dir + "/sub/herdrelay.id"}

	id1, err := loadIdentity(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if len(id1.RelayID) != 32 {
		t.Fatalf("expected 32-hex relay_id, got %d chars (%q)", len(id1.RelayID), id1.RelayID)
	}
	if id1.Name == "" {
		t.Fatal("expected non-empty name")
	}
	id2, err := loadIdentity(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if id1.RelayID != id2.RelayID {
		t.Fatal("relay_id should be stable across runs")
	}
	if id2.Name == "" {
		t.Fatal("expected name to be refreshed from host")
	}
}

func TestLoadTokenCreatesFile(t *testing.T) {
	dir := t.TempDir()
	cfg := Config{TokenFile: dir + "/sub/tok"}

	tok1, err := loadToken(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if len(tok1) != 64 {
		t.Fatalf("expected 64-hex token, got %d chars", len(tok1))
	}
	tok2, err := loadToken(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if tok1 != tok2 {
		t.Fatal("token should be stable across runs")
	}

	cfg.Token = "from-env"
	tok3, err := loadToken(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if tok3 != "from-env" {
		t.Fatal("env token should win over file")
	}
}

func TestVerifyTokenConstantTime(t *testing.T) {
	// Verify that wrong tokens are rejected (functional test)
	req := httptest.NewRequest("GET", "/test", nil)

	// No token
	if verifyToken(req, "secret") {
		t.Fatal("expected false with no token")
	}

	// Wrong Bearer token
	req.Header.Set("Authorization", "Bearer wrong")
	if verifyToken(req, "secret") {
		t.Fatal("expected false with wrong Bearer token")
	}

	// Correct Bearer token
	req.Header.Set("Authorization", "Bearer secret")
	if !verifyToken(req, "secret") {
		t.Fatal("expected true with correct Bearer token")
	}

	// Wrong query token
	req.Header.Del("Authorization")
	req2 := httptest.NewRequest("GET", "/test?token=wrong", nil)
	if verifyToken(req2, "secret") {
		t.Fatal("expected false with wrong query token")
	}

	// Correct query token
	req3 := httptest.NewRequest("GET", "/test?token=secret", nil)
	if !verifyToken(req3, "secret") {
		t.Fatal("expected true with correct query token")
	}
}

func TestLoadTokenRaceCondition(t *testing.T) {
	// Test that concurrent loadToken calls produce the same token
	dir := t.TempDir()
	cfg := Config{TokenFile: dir + "/tok"}

	const numGoroutines = 5
	tokens := make(chan string, numGoroutines)
	errs := make(chan error, numGoroutines)

	for i := 0; i < numGoroutines; i++ {
		go func() {
			tok, err := loadToken(cfg)
			if err != nil {
				errs <- err
				return
			}
			tokens <- tok
		}()
	}

	// Collect all results
	var results []string
	for i := 0; i < numGoroutines; i++ {
		select {
		case tok := <-tokens:
			results = append(results, tok)
		case err := <-errs:
			t.Fatal(err)
		}
	}

	// All goroutines should get the same token
	if len(results) != numGoroutines {
		t.Fatalf("expected %d results, got %d", numGoroutines, len(results))
	}
	first := results[0]
	for i, tok := range results {
		if tok != first {
			t.Fatalf("token mismatch at index %d: %s != %s", i, tok, first)
		}
	}
}

func TestLoadIdentityRaceCondition(t *testing.T) {
	// Test that concurrent loadIdentity calls produce the same relay_id
	dir := t.TempDir()
	cfg := Config{IdentityFile: dir + "/id"}

	const numGoroutines = 5
	identities := make(chan domain.Identity, numGoroutines)
	errs := make(chan error, numGoroutines)

	for i := 0; i < numGoroutines; i++ {
		go func() {
			id, err := loadIdentity(cfg)
			if err != nil {
				errs <- err
				return
			}
			identities <- id
		}()
	}

	// Collect all results
	var results []domain.Identity
	for i := 0; i < numGoroutines; i++ {
		select {
		case id := <-identities:
			results = append(results, id)
		case err := <-errs:
			t.Fatal(err)
		}
	}

	// All goroutines should get the same relay_id
	if len(results) != numGoroutines {
		t.Fatalf("expected %d results, got %d", numGoroutines, len(results))
	}
	first := results[0]
	for i, id := range results {
		if id.RelayID != first.RelayID {
			t.Fatalf("relay_id mismatch at index %d: %s != %s", i, id.RelayID, first.RelayID)
		}
	}
}

// TestRPCEndpoint verifies the HTTP fallback dispatch: POST /api/rpc accepts a
// relay request frame and answers with the same response frame the WS handler
// would send.
func TestRPCEndpoint(t *testing.T) {
	ts := testServer(t, "secret")
	defer ts.Close()

	post := func(body string) *http.Response {
		t.Helper()
		req, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/rpc", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer secret")
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("rpc request failed: %v", err)
		}
		return res
	}

	t.Run("unknown method returns error frame", func(t *testing.T) {
		res := post(`{"type":"request","id":7,"method":"nope","params":{}}`)
		defer res.Body.Close()
		var frame struct {
			Type  string `json:"type"`
			ID    int    `json:"id"`
			OK    *bool  `json:"ok"`
			Error *struct {
				Code    string `json:"code"`
				Message string `json:"message"`
			} `json:"error"`
		}
		if err := json.NewDecoder(res.Body).Decode(&frame); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if frame.Type != "response" || frame.ID != 7 {
			t.Fatalf("unexpected envelope: %+v", frame)
		}
		if frame.OK != nil || frame.Error == nil || frame.Error.Code != "unknown_method" {
			t.Fatalf("expected unknown_method error frame, got %+v", frame)
		}
	})

	t.Run("agents.snapshot returns ok frame with agents", func(t *testing.T) {
		res := post(`{"type":"request","id":8,"method":"agents.snapshot","params":{}}`)
		defer res.Body.Close()
		var frame struct {
			Type   string `json:"type"`
			ID     int    `json:"id"`
			OK     bool   `json:"ok"`
			Result struct {
				Agents []domain.Agent `json:"agents"`
			} `json:"result"`
		}
		if err := json.NewDecoder(res.Body).Decode(&frame); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if !frame.OK || len(frame.Result.Agents) != 1 || frame.Result.Agents[0].Agent != "codex" {
			t.Fatalf("unexpected snapshot frame: %+v", frame)
		}
	})

	t.Run("rejects malformed frames", func(t *testing.T) {
		res := post(`not json`)
		defer res.Body.Close()
		if res.StatusCode != http.StatusBadRequest {
			t.Fatalf("expected 400, got %d", res.StatusCode)
		}
	})
}

// TestEventStreamSSE verifies the SSE fallback: events broadcast into the
// event service are streamed as `data: <frame>` lines.
func TestEventStreamSSE(t *testing.T) {
	agentService := service.NewAgentService(stubAgentRepo{})
	eventService := service.NewEventService(stubEventRepo{})
	identity := domain.Identity{RelayID: "relay-0123456789abcdef", Name: "test-host"}
	pairing := service.NewPairingService(stubDetector{}, identity, "lan", "8375", "", "secret")
	hub := ws.NewHub()
	httpHandler := httpTransport.NewHandler(agentService, eventService, pairing)
	wsHandler := ws.NewHandler(hub, agentService, eventService)
	ts := httptest.NewServer(buildMux("secret", httpHandler, wsHandler))
	defer ts.Close()

	req, _ := http.NewRequest(http.MethodGet, ts.URL+"/api/events/stream", nil)
	req.Header.Set("Authorization", "Bearer secret")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("sse connect: %v", err)
	}
	defer res.Body.Close()
	if ct := res.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/event-stream") {
		t.Fatalf("unexpected content-type %q", ct)
	}

	eventService.Broadcast(domain.AgentStatusChangedEvent{PaneID: "p1", AgentStatus: "blocked"})

	line, err := bufio.NewReader(res.Body).ReadString('\n')
	if err != nil {
		t.Fatalf("read sse line: %v", err)
	}
	if !strings.HasPrefix(line, "data: ") {
		t.Fatalf("expected 'data: ' line, got %q", line)
	}
	var frame struct {
		Type  string                          `json:"type"`
		Event string                          `json:"event"`
		Data  domain.AgentStatusChangedEvent  `json:"data"`
	}
	if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &frame); err != nil {
		t.Fatalf("decode sse payload: %v", err)
	}
	if frame.Type != "event" || frame.Event != "pane.agent_status_changed" {
		t.Fatalf("unexpected sse frame: %+v", frame)
	}
	if frame.Data.PaneID != "p1" || frame.Data.AgentStatus != "blocked" {
		t.Fatalf("unexpected event data: %+v", frame.Data)
	}
}

// TestSpacesAPI covers the spaces-protocol methods: session.snapshot,
// agent.start and workspace.create over the HTTP /api/rpc fallback.
func TestSpacesAPI(t *testing.T) {
	ts := testServer(t, "secret")
	defer ts.Close()

	post := func(body string) *http.Response {
		t.Helper()
		req, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/rpc", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer secret")
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("rpc request failed: %v", err)
		}
		return res
	}

	// session.snapshot returns the full hierarchy.
	t.Run("session.snapshot returns workspaces/panes/agents", func(t *testing.T) {
		res := post(`{"type":"request","id":1,"method":"session.snapshot","params":{}}`)
		defer res.Body.Close()
		var frame struct {
			Type string `json:"type"`
			OK   bool   `json:"ok"`
			Result struct {
				Workspaces []domain.Workspace `json:"workspaces"`
				Panes      []domain.Pane      `json:"panes"`
				Agents     []domain.Agent     `json:"agents"`
			} `json:"result"`
		}
		if err := json.NewDecoder(res.Body).Decode(&frame); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if !frame.OK || len(frame.Result.Workspaces) != 1 || frame.Result.Workspaces[0].Label != "herdr_relay" {
			t.Fatalf("unexpected session.snapshot: %+v", frame.Result)
		}
		if len(frame.Result.Panes) != 1 || len(frame.Result.Agents) != 1 {
			t.Fatalf("expected 1 pane and 1 agent, got %+v", frame.Result)
		}
	})

	// agent.start launches an agent into a pane.
	t.Run("agent.start returns ok", func(t *testing.T) {
		res := post(`{"type":"request","id":2,"method":"agent.start","params":{"name":"codex","kind":"codex","pane_id":"wF:p5"}}`)
		defer res.Body.Close()
		var frame struct {
			Type   string `json:"type"`
			OK     bool   `json:"ok"`
			Result map[string]bool `json:"result"`
		}
		if err := json.NewDecoder(res.Body).Decode(&frame); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if !frame.OK || frame.Result["ok"] != true {
			t.Fatalf("unexpected agent.start: %+v", frame)
		}
	})

	// agent.start with empty kind is rejected.
	t.Run("agent.start rejects empty kind", func(t *testing.T) {
		res := post(`{"type":"request","id":3,"method":"agent.start","params":{"name":"x","pane_id":"wF:p5"}}`)
		defer res.Body.Close()
		var frame struct {
			Type  string `json:"type"`
			Error *struct{ Code string `json:"code"` } `json:"error"`
		}
		if err := json.NewDecoder(res.Body).Decode(&frame); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if frame.Error == nil || frame.Error.Code != "herdr_error" {
			t.Fatalf("expected herdr_error, got %+v", frame)
		}
	})

	// workspace.create returns the new id and label.
	t.Run("workspace.create returns id/label", func(t *testing.T) {
		res := post(`{"type":"request","id":4,"method":"workspace.create","params":{"label":"mobile"}}`)
		defer res.Body.Close()
		var frame struct {
			Type   string `json:"type"`
			OK     bool   `json:"ok"`
			Result struct {
				WorkspaceID string `json:"workspace_id"`
				Label       string `json:"label"`
			} `json:"result"`
		}
		if err := json.NewDecoder(res.Body).Decode(&frame); err != nil {
			t.Fatalf("decode: %v", err)
		}
		if !frame.OK || frame.Result.WorkspaceID != "w9" || frame.Result.Label != "test-ws" {
			t.Fatalf("unexpected workspace.create: %+v", frame)
		}
	})
}
