# Fix plan: audit of the herdr ↔ relay ↔ client message flow

Status: **partially implemented (30.08)** — A1, A2, A3, B3 closed; remaining phases (B1–B2, B4–B5, C, D, E, F) queued.
Date: 2026-08-30
Basis: manual audit of the event/command flow (`pane.agent_status_changed` arrives via two paths,
the herdr CLI has no timeouts, broadcast is synchronous, retries have no give-up, etc.). Every item
below was verified against the code (file:line) at the time of writing.

---

## 0. Summary

- **All audit findings confirmed** (14 Go tests only in `cmd/relay`, on stubs; Flutter 148 tests).
- There are three critical issues: (1) duplicate `agent_status_changed` delivery (hook + socket), (2) the herdr CLI
  and the HTTP server without timeouts → a hung `herdr` blocks the request forever, (3) synchronous
  `Broadcast` → a slow client stalls the broadcast to everyone.
- The plan is split into phases A–F; A+B deliver the most value and should go first.

---

## 1. Verified findings (cross-checked against the code)

### 1.1 Duplication and workarounds

| # | Finding | Code evidence |
|---|---|---|
| D1 | **Duplicate `agent_status_changed` path**: plugin HTTP hook + socket subscription → every status change is broadcast to the client twice | `plugin/on-event.sh` → `router.go:23-25` → `internal/transport/http/handler.go:168-194` (`HandlePluginEvent` → `eventService.Broadcast`); socket: `internal/infrastructure/herdr/socket_event_repository.go:126` (`pane.agent_status_changed` subscription on the pane) |
| D2 | Duplicate route `/api/events/pane.agent_status_changed` — a dead copy of `/api/events/herdr` | `cmd/relay/router.go:26-28` |
| D3 | Slow-consumer: `Broadcast` writes synchronously to each client; `Client.Write` under a mutex blocks when the TCP buffer is full → a slow client stalls the broadcast to everyone | `internal/transport/ws/hub.go:44-58`, `:96-100` |
| D4 | Event field loss: `AgentStatusChangedEvent` carries only `pane_id`+`agent_status`; `agent`, `display_agent`, `workspace_id`, `tab_id`, `cwd`, `title` from the herdr payload are silently dropped | `internal/domain/event.go:12-15`; real payload — `docs/10-herdr-api.md:354` |
| D5 | Revision-guard is inert: `OutputChangedEvent.Revision` with `omitempty`, always 0 → the client-side guard never fires | `internal/domain/event.go:40-43`; `client/lib/pages/agent_page.dart:106-109` (`revision > 0` never) |
| D6 | Pong frame leaks into the client message stream (the upper layer ignores it, but it's sloppy) | `client/lib/core/transport/websocket_transport.dart:118-121` vs `client/lib/core/protocol/request_response_manager.dart:103` |
| D7 | `emitEvent` waits up to 5 s (`time.After`) when the channel is full → can slow down reading from the herdr socket | `socket_event_repository.go:198-210` |
| D8 | Internal channels: events 100 (`event_service.go:47`), listener 10 (`:74`); when the listener is full the event is dropped silently (`:99-113`, `default`) | `internal/service/event_service.go` |
| D9 | `errRestart` loop: each new pane = full restart of the socket connection (starting with N panes — N restarts) | `socket_event_repository.go:56-70,161-169` |
| D10 | Server-side snapshot is not cached: every request spawns a CLI subprocess | `cmd/relay/main.go:40-41` + `internal/infrastructure/herdr/cli_repository.go:47` |
| D11 | Minor cache bug: `RelayAgent.toJson` does not write `workspace_id` → the `last_snapshot` cache loses workspaceId | `client/lib/models/relay_agent.dart:67-73` |

### 1.2 Error handling

| # | Finding | Evidence |
|---|---|---|
| E1 | `HttpTransport.send` is fire-and-forget: on `status != 200` only `lastError` is set; `catchError` swallows network errors silently; the calling code waits the full 15 s | `client/lib/core/transport/http_transport.dart:131-153`; `request_response_manager.dart:62-68` |
| E2 | `getAgents()` catches any error and silently returns the cache; the UI does not show freshness (`lastCachedAt()`) | `client/lib/repositories/agent_repository.dart:27-37` |
| E3 | The server replies 502 to CLI errors without details (acceptable) | `internal/transport/http/handler.go:57,121,160` |
| E4 | Race on the client: `_channel?.sink.add` silently drops the request frame when a disconnect happens between the status check and the send → the request hangs until the timeout | `websocket_transport.dart:157`; `request_response_manager.dart:45-60` |
| E5 | No graceful shutdown: `eventService.Stop()` is never called, SIGTERM is not handled | `cmd/relay/main.go:15-68` |

### 1.3 Retries and timeouts

| # | Finding | Evidence |
|---|---|---|
| R1 | **herdr CLI without a timeout**: `exec.Command` with no context — a hung herdr = a request hanging forever (the most critical gap) | `cli_repository.go:28-42` |
| R2 | `http.Server` without `ReadHeaderTimeout/ReadTimeout/WriteTimeout/IdleTimeout` | `main.go:67` |
| R3 | `http.DefaultClient` without a timeout in `fetchPairInfo` | `cmd/relay/pairfetch.go:21` |
| R4 | `await ws.ready` without its own timeout | `websocket_transport.dart:104` |
| R5 | `shouldRetry` always returns true — even on an invalid token (401) the client retries forever; there is no distinction between "transient/permanent" | `client/lib/core/transport/retry_policy.dart:26,46` |
| R6 | Socket reconnect loop: `time.Sleep` at `:65/:76` is not interrupted by `Close()` (`:256-265`) — a "sleeping" loop on shutdown | `socket_event_repository.go:40-78` |

### 1.4 Security

| # | Finding | Evidence |
|---|---|---|
| S1 | `CheckOrigin: true` — any origin can open the WS (a deliberate trade-off for LAN) | `internal/transport/ws/handler.go:13-14` |
| S2 | The token is also accepted via `?token=` — it leaks in URLs/logs/proxies | `cmd/relay/router.go:59` |
| S3 | Read loop without read/write deadlines and without a message size limit | `ws/handler.go:48-64` |
| S4 | `handleFrame` — switch without `default`: unknown frame types are silently ignored | `ws/handler.go:67-80` |
| S5 | No POST body limit (`keys/prompt/events/herdr`) | `internal/transport/http/handler.go` |
| S6 | Good: `verifyToken` — `subtle.ConstantTimeCompare`; token file 0600 | `router.go:54-62`; tests `TestLoadTokenCreatesFile` |

### 1.5 Debug output in production

| # | Finding | Evidence |
|---|---|---|
| G1 | `print(...)` on every fetch/event | `home_page.dart:90,99,109-114,120,123`; `agent_page.dart:71,118,129,172,176` |
| G2 | The hook writes every event to `/tmp/herdr-relay-events.log` (marked "comment out in production", but enabled) | `plugin/on-event.sh:27` |

### 1.6 Tests

| # | Finding | Evidence |
|---|---|---|
| T1 | Go: 14 tests only in `cmd/relay/server_test.go`; all herdr integration is on stubs (`stubAgentRepo`/`stubEventRepo`/`stubDetector`); `internal/domain`, `internal/infrastructure/herdr`, `internal/service`, `internal/transport/*` — `[no test files]` | `go test ./...` |
| T2 | Flutter: 148 tests, transports/protocol/pages covered; dedup, duplicate delivery, CLI timeouts are not tested | `client/test/` |

---

## 2. Fix plan by phases

### Phase A — Data and duplicates (foundation; affects everything else)

#### A1. Single source for `agent_status_changed` = socket; remove the hook and the duplicate route — ✅ implemented
- **Problem**: D1, D2. Every status change is broadcast twice; the client makes redundant requests
  (3× snapshot + 2× read per change with an open agent page).
- **Solution**:
  - Remove the `[[events]]` block (`on = "pane.agent_status_changed"`) from `plugin/herdr-plugin.toml`;
    delete/empty `plugin/on-event.sh` (the socket is self-sufficient — comment
    `socket_event_repository.go:120`; `pane.updated` on subscription lists the existing panes).
  - Remove the duplicate route `router.go:26-28`; keep `/api/events/herdr` only if some
    HTTP source remains (currently there is none — it can be removed too if the hook is fully removed).
  - Update `docs/01-architecture.md`, `docs/02-herdr-integration.md`, `README.md`,
    `CHANGELOG.md` (hook mentions).
- **Tests**: T1 extension — a fake unix-socket (see F1) proves the status arrives exactly once.

#### A2. Extend `AgentStatusChangedEvent` with fields — ✅ implemented
- **Problem**: D4. The client cannot update the agent from the event (no `display_agent`, `cwd`,
  `workspace_id`, `tab_id`), so it makes a snapshot request.
- **Solution**: `internal/domain/event.go:12-15` — add `Agent, DisplayAgent, WorkspaceID, TabID,
  Cwd, Title` (payload: `docs/10-herdr-api.md:354`). On the client: `relay_event.dart` (field parsing),
  `agent_page.dart` — update `_agent` entirely from the event.
- **Tests**: unit tests for `domain.ParseEvent` (new `internal/domain/event_test.go`); client —
  `relay_event_test.dart` for field parsing.

#### A3. Remove the inert revision-guard — ✅ implemented (safe variant)
- **Problem**: D5. `pane.scroll_changed` does not carry `revision` (docs gotcha №5), the guard never
  fires; dedup protection is the debounce that already exists.
- **Solution**: remove `_lastRevision`/guard from `agent_page.dart:106-109` (and `revision` from
  `OutputChanged` parsing, unless a real source appears). Document in code.
- **Tests**: client agent-page tests do not break; a rationale comment.
- **Note (implementation 30.08)**: the guard was not removed but **revived** — the relay now attaches
  to `pane.output_changed` the last known `revision` from `pane.updated`, **strictly increasing only**
  (stale/equal revisions are not sent, so the guard does not miss a live update). The client-side guard
  now works; in the absence of a revision the client, as before, relies on the debounce.

### Phase B — Timeouts and hangs (the most dangerous)

#### B1. Timeout on the herdr CLI
- **Problem**: R1.
- **Solution**: `cli_repository.go:28-42` — `exec.CommandContext` with a timeout
  (default 10 s, env `HERDRELAY_CLI_TIMEOUT`, `cmd/relay/config.go`); on `context.DeadlineExceeded`
  — `DispatchError{Code: "timeout"}` (the client gets a fast, clear error instead of waiting forever).
- **Tests**: unit `cli_repository_test.go` — a fake `bin` script that sleeps longer than the timeout;
  verify `run` returns the error on time and does not hang.

#### B2. `http.Server` timeouts + graceful shutdown
- **Problem**: R2, E5.
- **Solution**: `main.go:67` — `http.Server{ReadHeaderTimeout: 5s, ReadTimeout: 30s, WriteTimeout: 30s,
  IdleTimeout: 60s}`; handle SIGTERM/SIGINT: `eventService.Stop()`, `server.Shutdown(ctx)`.
  (Separately: the socket repository's `Close()` must interrupt the `time.Sleep` in the reconnect loop — R6,
  see B3.)
- **Tests**: `server_test.go` — server start/stop with shutdown (without a real herdr).

#### B3. Interruptible socket reconnect loop — ✅ implemented
- **Problem**: R6. `time.Sleep` at `:65/:76` is not interrupted by `Close()`.
- **Solution**: replace `time.Sleep` with `select { case <-time.After(...): case <-r.stopCh: }`;
  `Close()` closes `stopCh` (with `sync.Once`).
- **Tests**: unit `socket_event_repository_test.go` — `Subscribe` + `Close` immediately: the loop
  finishes without a pause (does not hang for 2+ s).

#### B4. HTTP client timeout in pairfetch
- **Problem**: R3.
- **Solution**: `pairfetch.go:21` — `http.Client{Timeout: 5 * time.Second}` (or a shared client).

#### B5. Timeout on `ws.ready` + 401 detection
- **Problem**: R4 (+ linked with R5).
- **Solution**: `websocket_transport.dart:104` — `await ws.ready.timeout(...)`; classify the upgrade
  error (401/403) as "invalid token" (see D1 below).

### Phase C — Slow consumer

#### C1. Per-client queue in the WS-hub — ✅ implemented (queue 128, slow consumer is closed, broadcast does not block; hub_test)
- **Problem**: D3.
- **Solution**: `hub.go` — each `Client` gets a channel queue (e.g. 64) + a writer-goroutine;
  `Broadcast` enqueues non-blocking, on overflow — drop-oldest (or drop the new one +
  a counter in the log); a write error → close the client. Remove the blocking `Write` under a mutex from
  the hot path.
- **Tests**: unit `hub_test.go` (new) — a slow client (full queue) does not block
  `Broadcast` for others; drop-oldest works; the client is closed on a write error.

### Phase D — Client: retries, transport, UX

#### D1. Give-up on retries for unrecoverable errors
- **Problem**: R5. On an invalid token (401 on WS upgrade/SSE) the client retries forever
  and hangs in "connecting…".
- **Solution**: extend the contract — `RetryPolicy.shouldRetry(attempt, error)` gains a "fatal" flag
  (the transport marks 401/403), or a separate `isFatal(error)` method. `ExponentialBackoff`
  returns false for fatal. The UI (`connection_page.dart`/status) shows
  "invalid token — re-scan the QR" and stops the reconnect loop.
- **Tests**: `retry_policy_test.dart` — a fatal error → `shouldRetry == false`; transport tests — 401
  on SSE/upgrade does not schedule a reconnect.

#### D2. HTTP transport: timeout and error propagation
- **Problem**: E1.
- **Solution**: `http_transport.dart:131-153` — `_client.post(...).timeout(...)`; on an error/non-200
  put an **error frame into `_messages`** (not only `lastError`), so `RequestResponseManager`
  fails the request instantly with a clear `RelayException`. `send` stays `void` (contract),
  but the error is delivered to the protocol layer.
- **Tests**: `http_transport_test.dart` — timeout/network error/401 → an error frame arrives in
  `_messages`; `request_response_manager` fails the request immediately.

#### D3. Agent page: status debounce + no redundant snapshot — ✅ (in f7a701f)

**Extra (after the audit): reconnect catch-up** — HomePage/SpacesPage/RunPage re-read data on the disconnected→connected transition (events during the gap are lost): `_wasDisconnected` + refresh/`_load()`; the home_page_test "after reconnect the list is re-read" test.
- **Problem**: D1 (client side), E4.
- **Solution**: `agent_page.dart:117-131` — debounce refresh on `AgentStatusChanged` (300–400 ms,
  like output); after A2 the event carries `display_agent/cwd/workspace_id` → `_refreshAgentFromSnapshot()`
  is not needed on the event (keep it only for manual refresh). Close the E4 race: in
  `request_response_manager.request` — re-check connected after `send` (or make
  `send` return `bool`).
- **Tests**: `agent_page_test.dart` — a burst of status events → one refresh.

#### D4. Clean up debug output and cache-freshness UX
- **Problem**: G1, G2, E2.
- **Solution**: remove `print` from `home_page.dart`/`agent_page.dart`; `on-event.sh` (if it stays)
  — log only under an env flag. `home_page` — if the list comes from the cache, show
  "showing saved data from HH:MM" (via `AgentRepository.lastCachedAt()`); `getAgents()` —
  return a "from cache" flag. Fix D11 (`toJson` → `workspace_id`).
- **Tests**: `home_page_test.dart` — the freshness banner on cache; `agent_repository_test.dart` — the
  cache flag.

### Phase E — WS and HTTP security/hygiene

| Item | Solution | Files |
|---|---|---|
| S3 | `SetReadLimit` (~64 KB), `SetReadDeadline`/`SetWriteDeadline` + a pong handler (keepalive at the WS level) | `internal/transport/ws/handler.go` |
| S4 | `default` in `handleFrame`: log the unknown type; not silently | `internal/transport/ws/handler.go:67-80` |
| S5 | `http.MaxBytesReader` on POST endpoints (`keys/prompt/events/herdr/rpc`) | `internal/transport/http/handler.go` |
| S1/S2 | Keep as a deliberate trade-off (LAN); document it. Optional: `Origin` check via config; token only in `Authorization` for non-QR clients | `ws/handler.go:13-14`, `router.go:59` |

### Phase F — Tests (regression protection for phases A–C)

#### F1. Integration test with a fake herdr socket (Go)
- A fake unix-socket in the test: accepts `events.subscribe` (JSON-RPC), replies
  `subscription_started`, sends `pane_updated`, `pane.agent_status_changed`, `pane.scroll_changed`.
- Verifies: (A1) the status arrives exactly once (no duplicates), (B1) the CLI timeout, (C1) a slow consumer
  does not block, (B3) `Close()` interrupts the reconnect.
- Files: `internal/infrastructure/herdr/socket_event_repository_test.go`,
  `internal/service/event_service_test.go`, `internal/transport/ws/hub_test.go`.

#### F2. Client tests
- `retry_policy_test.dart` (D1), `http_transport_test.dart` (D2), `agent_page_test.dart` (D3),
  `home_page_test.dart` (D4).

---

## 3. Order and dependencies

```
Phase A (data/dupes) ──► Phase B (timeouts) ──► Phase C (slow consumer)
        │                       │
        └──► Phase D (client) ◄──┘        Phase E (security) — independent
                                             │
Phase F (tests) — written alongside A–C, final full run after E
```

- A1, A2, A3 — one PR (duplicate removal + fields + guard): delivers visible effect immediately.
- B1–B5 — one PR (all timeouts): critical for reliability.
- C1 — a separate PR (hub queue).
- D1–D4 — one PR (client retries/transport/UX).
- E — a separate PR (security).
- F1/F2 — with each PR, final full run.

## 4. Acceptance criteria

- `go test ./...` and `flutter test` green; `flutter analyze` 0 warnings.
- Live run: a change in agent status → exactly one event in the client (log/counter), one
  snapshot request per burst, the agent page updates from the event without a snapshot.
- A hung `herdr` (kill -STOP) → requests fail in ~10 s with a clear error, they do not hang forever.
- Invalid token → the client stops reconnecting and shows "invalid token" (not "connecting…").
- A slow client (network throttle) does not slow down the broadcast to the others.
- No debug prints or `/tmp/herdr-relay-events.log` in the relay/client logs.
