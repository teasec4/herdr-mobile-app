package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
)

// stubHerdr — фейк AgentAPI для тестов (herdr subprocess не нужен).
type stubHerdr struct{}

func (stubHerdr) Snapshot() (*Snapshot, error) {
	return &Snapshot{Agents: []Agent{{Agent: "codex", AgentStatus: "working", PaneID: "wF:p5"}}}, nil
}
func (stubHerdr) Read(target string, lines int, format string) (string, error) { return "hello\nworld\n", nil }
func (stubHerdr) Keys(target string, keys []string) error                      { return nil }
func (stubHerdr) Prompt(target, text string) error                             { return nil }

func testServer(t *testing.T, token string) *httptest.Server {
	t.Helper()
	srv := newServer(Config{Mode: "lan", Listen: ":8375"}, token, stubHerdr{})
	ts := httptest.NewServer(srv.routes())
	t.Cleanup(ts.Close)
	return ts
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

	var snap Snapshot
	if err := json.NewDecoder(resp.Body).Decode(&snap); err != nil {
		t.Fatal(err)
	}
	if len(snap.Agents) != 1 || snap.Agents[0].PaneID != "wF:p5" {
		t.Fatalf("unexpected snapshot: %+v", snap.Agents)
	}
}

func TestWSRequestResponse(t *testing.T) {
	ts := testServer(t, "secret-token")
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws?token=secret-token"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	// ping -> pong
	if err := conn.WriteMessage(websocket.TextMessage, []byte(`{"type":"ping"}`)); err != nil {
		t.Fatal(err)
	}
	_, raw, err := conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	var pong frame
	if err := json.Unmarshal(raw, &pong); err != nil || pong.Type != "pong" {
		t.Fatalf("expected pong, got %s", raw)
	}

	// request agents.snapshot -> response с тем же id
	if err := conn.WriteMessage(websocket.TextMessage, []byte(`{"type":"request","id":7,"method":"agents.snapshot","params":{}}`)); err != nil {
		t.Fatal(err)
	}
	_, raw, err = conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	var resp frame
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

func TestEventBroadcast(t *testing.T) {
	ts := testServer(t, "secret-token")
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws?token=secret-token"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	// эмуляция события плагина
	body := strings.NewReader(`{"event":"agent_status_changed","data":{"agent":"codex","status":"blocked"}}`)
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/events?token=secret-token", body)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()

	_, raw, err := conn.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	var ev frame
	if err := json.Unmarshal(raw, &ev); err != nil {
		t.Fatal(err)
	}
	if ev.Type != "event" || ev.Event != "agent_status_changed" {
		t.Fatalf("unexpected event: %s", raw)
	}
}

// TestHerdrEventBroadcast — сырой HERDR_PLUGIN_EVENT_JSON с хука herdr
// нормализуется в pane.agent_status_changed и доходит до WS-клиента.
func TestHerdrEventBroadcast(t *testing.T) {
	ts := testServer(t, "secret-token")
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws?token=secret-token"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

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
	var ev frame
	if err := json.Unmarshal(raw, &ev); err != nil {
		t.Fatal(err)
	}
	if ev.Type != "event" || ev.Event != "pane.agent_status_changed" {
		t.Fatalf("unexpected event: %s", raw)
	}
	// data должен быть валидным JSON-объектом с agent_status
	data, ok := ev.Data.(map[string]any)
	if !ok || data["agent_status"] != "blocked" {
		t.Fatalf("unexpected data: %v", ev.Data)
	}
}

func TestPairLink(t *testing.T) {
	l := pairLink("lan", map[string]string{"host": "192.168.1.5", "port": "8375"}, "abc")
	if !strings.HasPrefix(l, "herdrelay://pair?") || !strings.Contains(l, "mode=lan") || !strings.Contains(l, "token=abc") {
		t.Fatalf("unexpected link: %s", l)
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