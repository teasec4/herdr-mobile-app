# 08 — Execution Plan (loops, gates, checks)

> **Historical document.** The phased plan (including the client refactoring
> phases and the `WsRelayClient`/`provider` layers mentioned below) has been
> completed — the current client architecture is described in
> [05 — Flutter App](05-flutter-app.md), the refactoring progress and outcome
> in [09 — Refactoring Plan](09-refactoring-plan.md).

This document turns the architecture (01–07) into a step-by-step work plan.
The project is built in **loops** — complete iterations you can launch and try
out.

## Ground rules

- Each loop = **a complete piece of work** + **a gate** — a list of checks
  that must pass.
- **Gate red → don't move on**: fix the loop until the checks turn green.
- Checks are run with the commands in the loop's "checks" section.
- Between loops there is a shared feedback loop: write → run → check →
  fix/commit → take the next loop. Everything runs on the laptop (relay) and
  on the phone/simulator (client).
- Relay/plugin/client loops can proceed in parallel, but loop gates pass in
  layer order: relay → plugin → client → end-to-end.
- "Verified facts" grow as work progresses — a store of what has been
  confirmed live and can be relied on without re-checking.

## Verified facts (confirmed at the start, expands as work progresses)

- herdr 0.8.0, socket `~/.config/herdr/herdr.sock`, protocol 19.
- The agent target for `read/send-keys/prompt` is **`pane_id`** (the name is
  non-unique: two `kimi` in the snapshot). Verified live:
  `herdr agent read wG:p1 --lines 5 --format text` returns the terminal text;
  `--format ansi` — with ANSI codes.
- `herdr agent send-keys <TARGET> <KEY>...` (keys are separate arguments,
  `esc` is the canonical name for Esc).
- `herdr agent prompt <TARGET> <TEXT> [--wait] [--until STATUS]`.
- `herdr api snapshot` / `agent list` return a JSON envelope
  `{"id":..., "result":{...}}`.
- Plugin event hook: herdr passes the event via the env var
  **`HERDR_PLUGIN_EVENT_JSON`** in the form `{"data":{...}}` (pane_id, tab_id,
  tab_label, workspace_id, agent_status, agent, display_agent, cwd, ...). The
  event name does not arrive in the env — the plugin manifest fixes it
  (`pane.agent_status_changed`), and the relay substitutes the canonical name
  itself.
- `pane.agent_status_changed` confirmed live: after `herdr plugin link`,
  events really fired on agent status changes (`herdr plugin log list`
  → status=succeeded, exit_code=0), and the WS client received the event with
  full `data` — E2E, not an emulation.
- **herdr hooks CANNOT deliver terminal output events**: `pane.updated`,
  `pane.output_changed`, `pane.scroll_changed` → "unknown event" (verified by
  brute force on 0.8.0). Live output via the plugin is impossible — only via
  the socket.
- **Socket subscription (B-lite)**: the herdr unix socket is
  newline-delimited JSON-RPC 2.0, request id is a string. The
  `events.subscribe` request carries the `subscriptions` field. Incoming
  notifications are flat: `{"event":"pane.scroll_changed","data":{pane_id,
  scroll:{max_offset_from_bottom, offset_from_bottom, viewport_rows},
  workspace_id}}` and `{"event":"pane_updated","data":{"pane":{...}}}`.
- Relay token: `~/.config/herdr/herdrelay.token` (0600, 64 hex); env
  `HERDRELAY_TOKEN` takes precedence. Default port 8375 (env `HERDRELAY_PORT`).
- With `herdr plugin link` (unlike `install`), herdr does **not** run
  `[[build]]` — locally the relay is installed manually:
  `bash plugin/install.sh`.

## Relay loops (Go, `cmd/relay`)

### L0. Scaffold: config, token, HTTP, `/healthz` — ✅ implemented

- `main.go` — startup, env config, `loadOrCreateToken`.
- HTTP server: `/healthz`, auth middleware (Bearer) on everything except `/healthz`.
- Token: generated on first run (32 bytes hex), stored in
  `~/.config/herdr/herdrelay.token` (0600), env `HERDRELAY_TOKEN` takes precedence.

L0 checks (all passed):
```bash
go build ./... && go vet ./...
./bin/relay &                          # token printed/created
curl -s localhost:8375/healthz         # {"ok":true}
curl -s -i localhost:8375/api/snapshot # 401 without token
```

### L1. herdr v1: snapshot + read/keys/prompt over HTTP — ✅ implemented

- `herdr.go` — thin CLI wrapper (subprocess), `AgentAPI` interface.
- `GET /api/snapshot` → agents+statuses; `GET /api/agents/{pane_id}/output`;
  `POST /api/agents/{pane_id}/keys`; `POST /api/agents/{pane_id}/prompt`.

L1 checks (all passed):
```bash
curl -s -H "Authorization: Bearer $T" localhost:8375/api/snapshot  # live agents
curl -s -H "Authorization: Bearer $T" \
  "localhost:8375/api/agents/<pane_id>/output?lines=20"            # terminal text
# compare with: herdr agent read <pane_id> --lines 20 --format text
```

### L2. WS channel + events — ✅ implemented

- `ws.go` — client hub, JSON envelope (request/response/event/ping/pong),
  methods `agents.snapshot`, `agent.output`, `agent.keys`, `agent.prompt`.
- `POST /api/events` (auth) `{"event":"...","data":{...}}` → broadcast to all
  WS clients (manual emulation and for tests).
- `POST /api/events/herdr` (auth) — a separate entry point for the plugin:
  accepts the raw `HERDR_PLUGIN_EVENT_JSON` (`{"data":{...}}`) and broadcasts
  it under the canonical name `pane.agent_status_changed`.

L2 checks (all passed):
```bash
go test ./cmd/relay/ -run WS             # unit: request/response envelope, ping/pong
go test ./cmd/relay/ -run HerdrEvent     # unit: POST /api/events/herdr → WS clients
# emulate an event: curl -X POST -H "Authorization: Bearer $T" \
#   localhost:8375/api/events -d '{"event":"agent_status_changed","data":{}}'
# the WS client receives {"type":"event",...}
```

### L3. Pairs and modes: `/pair`, LAN/Tailscale auto-detection — ✅ implemented

- `pair.go` — detects available modes: LAN IP (`ipconfig getifaddr en0` /
  `hostname -I`), tailnet (`tailscale status --json` → MagicDNS name), funnel
  (if enabled), gateway (from env).
- `GET /pair` → `{primary, urls:{mode→{url, link}}, token}`. The QR is
  rendered by the plugin/client.
- The `herdrelay pair [--qr]` subcommand — prints the mode / WS URL / link;
  `--qr` draws an ANSI QR (qrterminal, half blocks) right into the herdr
  terminal.

L3 checks (all passed):
```bash
curl -s -H "Authorization: Bearer $T" localhost:8375/pair
# in the response: lan (192.168.x.x:8375) and tailscale (macbook-pro.tail….ts.net:8375),
# if the tailnet is up
plugin/bin/herdrelay pair --qr        # ANSI-QR printed to stdout
```

### L5. B-lite: live output via socket subscription — ✅ implemented

- `herdrevents.go` — subscriber to the herdr unix socket: `events.subscribe`
  with `pane.updated` (globally) + `pane.scroll_changed` (per pane_id).
- Seed snapshot: on startup we take `herdr api snapshot` (seedKnown) to
  subscribe to already-existing panes; new panes are subscribed incrementally
  via `pane_updated`.
- Reconnect with backoff 2s → 30s; on a scroll change the relay forwards the
  `pane.output_changed` event to clients (data: `{pane_id, workspace_id}`).
- Started from `main.go`; isolated from the HTTP API.

L5 checks:
```bash
go build ./... && go vet ./... && go test ./...  # green
launchctl print gui/$(id -u)/com.herdrelay.relay  # relay alive, subscriber started
# live test: type in the agent terminal → the client updates the output via
# pane.output_changed (debounce ~400ms)
```

## herdr plugin loops (`plugin/`)

### L4. Plugin: manifest, QR pane, on-event, launchd — ✅ implemented

- `herdr-plugin.toml` (id `herdrelay.events`):
  - `[[build]]` → `install.sh` (relay build + launchd);
  - `[[events]]` on `pane.agent_status_changed` → `on-event.sh`;
  - `[[actions]]` `show-pair-link` → `open-pane.sh setup`;
  - `[[panes]]` `setup` (placement zoomed) → `setup-menu.sh`.
- `on-event.sh` — reads `HERDR_PLUGIN_EVENT_JSON`, `curl -X POST
  http://127.0.0.1:8375/api/events/herdr` with the Bearer token from
  `~/.config/herdr/herdrelay.token`; on any error `exit 0` (don't disturb herdr).
- `install.sh` — `go build` of the relay from the repo root into
  `bin/herdrelay`, installs the launchd unit `com.herdrelay.relay`
  (RunAtLoad + KeepAlive, logs in
  `${XDG_STATE_HOME:-$HOME/.local/state}/herdrelay/`, env
  `HERDRELAY_MODE=lan`), healthz check.
- `setup-menu.sh` — relay status + `bin/herdrelay pair --qr` + instructions.
- `open-pane.sh` — `herdr plugin pane open --plugin herdrelay.events
  --entrypoint setup --placement zoomed --focus`.

L4 checks (all passed):
```bash
bash plugin/install.sh              # built bin/herdrelay, launchd, "relay is running on :8375"
launchctl print gui/$(id -u)/com.herdrelay.relay   # state=running, pid, log paths
herdr plugin link ~/herdr-relay/plugin
herdr plugin list                   # herdrelay.events (HerdRelay) enabled [local:...]
herdr plugin action list --plugin herdrelay.events # show-pair-link
# live events (not an emulation): change the agent status →
#   herdr plugin log list --plugin herdrelay.events → status=succeeded, exit_code=0
#   the connected WS client receives pane.agent_status_changed with full data
```
The QR pane in the live TUI is checked by hand (it opens a zoomed pane, we
don't do it uninvited): `herdr plugin action invoke show-pair-link --plugin
herdrelay.events`.

## Flutter client loops (`client/`)

### C1. Scaffold + onboarding — ✅ implemented (QR scan verified on a phone over LAN)

- Custom scheme `herdrelay://` (Info.plist / intent-filter), link scan/paste,
  config saving, WS connection, healthz check.
- Implemented: `PairConfig` (link parsing/validation, wsUri/healthUri),
  `ConfigStore` (SharedPreferences), `PairPage` (mobile_scanner + manual
  input), deep link in `main.dart` (app_links), `RelayClient` — an abstract
  contract for the UI, WS-backed implementation `WsRelayClient`
  (auto-reconnect with backoff, request/response, events, ping/pong); the
  client is created at the app level (`main.dart`) and handed to the whole
  tree via `provider` (`Provider<RelayClient>.value` — a single WS channel
  for the list and details, also visible to push routes); in tests it is
  replaced by the `FakeRelayClient` fake through the same `Provider.value`.

C1 checks:
```bash
cd client && flutter analyze && flutter test   # green (53 tests)
cd client && flutter run                # on a phone on the same network — verified over LAN
# point at the QR (L4) -> the app opened and connected
```

### C2. Agent list — ✅ code

- Snapshot + updates on events (`pane.agent_status_changed` → re-snapshot),
  **blocked on top** (`RelayAgent.sorted` ordering + card highlighting),
  pull-to-refresh.

### C3. Terminal details — ✅ code

- `AgentPage`: terminal output (`agent.output`, monospaced dark terminal,
  auto-scroll, **live updates on `pane.output_changed` with a ~400 ms
  debounce**), input line (`agent.prompt`), quick keys Esc and Ctrl-C
  (`agent.keys`). A single shared WS client for the list and details.
- ANSI colors — via our own SGR parser in `widgets/ansi_terminal.dart`
  (TextSpan, dark theme, softWrap); the whole app's dark theme lives in
  `main.dart`.
- Covered by widget tests (`test/agent_page_test.dart`, `test/home_page_test.dart`,
  `test/fakes/fake_relay_client.dart`): output rendering, prompt sending,
  keys, status updates on events, blocked-on-top ordering, navigation to
  details, error screen.

### C4. End-to-end MVP gate (phone) — ✅ LAN, [ ] B1

C4 checks (all by hand from the phone):
1. [x] At home over LAN (mode A): scan QR → list → output → prompt → I see the answer.
2. [ ] From outside via tailnet (B1): the same.
3. [x] The blocked agent is highlighted on top; the answer to it arrives in under 2 s.

## Polish and hardening (after MVP)

- `flutter_xterm`/real scrollback, local notifications, funnel (B2).
- Gateway (C) + Docker deployment (`cmd/gateway`, `deploy/`).
- E2E encryption, FCM push, token rotation, multiple workspaces.

## Final MVP gate

- [x] `go build ./... && go vet ./... && go test ./...` — green.
- [x] `flutter analyze` — no errors, **53** unit tests green.
- [~] LAN (A) from the phone — ✅ verified live; tailnet (B1) from outside — not checked.
- [x] Blocked events arrive instantly (plugin, not an emulation).
- [x] Docs updated to match the actual behavior.