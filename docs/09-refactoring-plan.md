# 09 — Refactoring Plan: Modular Client Architecture + Logic Defects

> Status: **implementation complete (Phases 0–4, defects D1–D9)** — branch `refactor/modular-architecture`
> Scope: Flutter client only (`client/`). The Go server is not changed.
> Related documents: [01 — Architecture](01-architecture.md), [05 — Flutter app](05-flutter-app.md), [08 — Execution plan](08-execution-plan.md), [10 — herdr API](10-herdr-api.md).

> **Two plans in one:** (A) moving the client architecture to layers (§1–§8);
> (B) logic fixes found while reconciling the code against [10 — herdr API](10-herdr-api.md) (§1.4).
> Fixes (B) require no architectural changes and are done at the start of the relevant phases.

## 0. Implementation status

| Phase | Status | Commit |
| --- | --- | --- |
| Server fixes D2–D6, D9 | ✅ | `f724b1a` |
| Phase 0 — baseline tests + D1/D8 | ✅ | `965b7f9` |
| Phase 1 — Transport | ✅ | `5357948` (+ keepalive D7 in `dc106ca`~) |
| Phase 2 — Protocol | ✅ | `13d94c2` |
| Phase 3 — Client on layers | ✅ | `402072c` |
| Phase 4 — Connection Manager | ✅ | `dc106ca` |
| Phase 5 — HTTP fallback (RPC + SSE) | ✅ | server `36149fa`, client `2e4bdb1` |
| Module READMEs (contracts) | ✅ | — |

Result: `WsRelayClient` (362 lines) removed; replaced by `core/transport` +
`core/protocol` + `core/connection` + `services/relay_client_impl.dart`
(128 tests green, `dart analyze` — 0 warnings/errors).

**Live verification (herdr 0.8.0, protocol 19):** new relay on `:18375` —
`/healthz` ✓, `/api/snapshot` (3 real agents) ✓, `/api/rpc`
(ok-frame + error-frame `unknown_method`) ✓, `/api/events/stream` (SSE
holds) ✓, `/pair` ✓, WS `connect → ping→pong → snapshot→response` ✓.
Fix D2 confirmed live: snapshot goes through `HERDR_SOCKET_PATH`.

## 1. Context and motivation

### 1.1 Current state (verified against the code)

`WsRelayClient` (`client/lib/services/relay_client.dart`) — **362 lines**, a monolith that mixes all layers:

| Responsibility | Where in the code today |
| --- | --- |
| WebSocket lifecycle | `_connect()`, `_onDisconnect()`, `_channel` |
| Reconnect with exponential backoff | `_scheduleReconnect()`, `_attempt`, `_reconnectTimer` (1, 2, 4, … up to 30 s) |
| Protocol framing (JSON) | `_onMessage()`, `_sendFrame()` — jsonDecode/encode |
| Request-response matching | `_request()`, `_pending`, `_nextId`, 15 s timeout |
| Event broadcasting | `_events` (StreamController), mapping to `RelayEvent` |
| Ping/pong | `_onMessage()` → `case 'ping'` → `{'type': 'pong'}` |
| HTTP healthz | `healthz()` — 3 attempts with backoff |
| Status management | `status` (ValueNotifier), `lastError` |
| Reconnect pause/resume | `pauseReconnect()`, `resumeReconnect()` (for lifecycle) |

### 1.2 Why refactor

1. **Testability.** There is not a single test for `WsRelayClient` (it is absent from `client/test/`). The network cannot be substituted, and behavior (reconnect, timeout, failPending) is not verified.
2. **Extensibility.** HTTP endpoints already exist on the server (`internal/transport/http/handler.go`: `output`/`keys`/`prompt`) — HTTP fallback makes sense, but there is no way to hook into a monolith.
3. **Reuse.** Reconnect logic is needed by any transport (WS, HTTP long-poll, and in the future gRPC/WebRTC).
4. **Parallel work.** Two people cannot touch one 362-line file at the same time.

### 1.3 What we do NOT rewrite (already good)

- **The `RelayClient` interface** — already separated from the implementation and stable: `status`, `events`, `snapshot`, `output`, `keys`, `prompt`, `healthz`, `pauseReconnect`, `resumeReconnect`, `close`. The UI works through it. **We do not change the signatures** — otherwise pages and tests will break.
- **Lifecycle** — `_HerdRelayAppState` in `client/lib/main.dart` already observes `AppLifecycleState` and calls `pauseReconnect`/`resumeReconnect`. Phase 4 = moving this logic into `ConnectionManager`, not building it from scratch.
- **DI** — `setupRelayServices(config, {clientFactory})` in `client/lib/core/service_locator.dart` already supports injecting a fake (used in widget tests).
- **`FakeRelayClient`** (`client/test/fakes/fake_relay_client.dart`) — a ready-made top-level fake.
- **Offline cache** in `AgentRepository` (last_snapshot in SharedPreferences) — must not break when rebuilding the client.
- **Models** (`RelayAgent`, `RelayEvent`, `PairConfig`) — not touched.

### 1.4 Logic defects found while reconciling with docs/10-herdr-api.md (plan "B")

Reconciling the client and relay code against the herdr API reference (0.8.0, protocol 19) revealed
mismatches. They are fixed **before or at the start of** the relevant phase, independently
of the architectural migration.

| # | Priority | Where | Defect | Evidence | Fix | Status |
|---|---|---|---|---|---|---|
| **D1** | 🔴 Critical | `client/lib/models/relay_event.dart` | `pane.agent_status_changed` is parsed via `data['status']`, but the server sends `agent_status` → real-time status is **always `unknown`** (agent_page updates status from the event) | `internal/domain/event.go` — `AgentStatusChangedEvent` with json tag `agent_status`; docs/10 §5.3 (data example) | `data?['agent_status'] ?? data?['status']` | ✅ |
| **D2** | 🔴 Critical | `internal/infrastructure/herdr/cli_repository.go:30` | `HERDR_SOCKET` is sent to the subprocess, but the CLI **ignores** this variable (only `HERDR_SOCKET_PATH` works) → all herdr operations go to the default socket, named session is broken | docs/10 §3.1, pitfall №10 (verified live) | send `HERDR_SOCKET_PATH`; `cmd/relay/config.go` — read `HERDR_SOCKET_PATH` (fallback to `HERDR_SOCKET`) | ✅ |
| **D3** | 🟠 Important | `internal/infrastructure/herdr/socket_event_repository.go` | No `pane.agent_status_changed` subscription → agent statuses arrive only via the plugin hook; without an installed plugin there are no live statuses | docs/10 §5.2 (scoped subscription exists), §8 (statuses currently = hook) | add a per-pane `pane.agent_status_changed` subscription + mapping in `domain.ParseEvent` | ✅ |
| **D4** | 🟠 Important | client `agent_page.dart` + server | `pane.scroll_changed` does not carry `revision` (always 0) → the client debounces 400 ms, but every tick = WS request = subprocess herdr CLI; with active output — extra load | docs/10 pitfall №5; `agent_page.dart:102-115` | server-side `scroll_changed` debounce (per-pane, ≥500 ms) in `socket_event_repository` | ✅ |
| **D5** | 🟡 Medium | `cmd/relay/router.go:29` | The `/api/events/pane.updated` route is dead: the `pane.updated` hook cannot be registered (the linker rejects it as an unknown event) | docs/10 pitfall №1 | remove the route (or mark it deprecated) | ✅ |
| **D6** | 🟡 Medium | relay→client | Snapshot does not contain `display_agent` (herdr provides it) → the displayed agent name is lost on the phone | docs/10 §6.1 (PaneInfo.display_agent); `client/lib/models/relay_agent.dart:51` | add `DisplayAgent` to `domain.Agent` and pass it through to `RelayAgent` | ✅ (server; client already read `display_agent`) |
| **D7** | 🟡 Medium | client | No keepalive: nobody initiates ping (client and server only respond) → a dead WS connection (NAT/phone sleep) is not detected until the first request | `relay_client.dart` (`case 'ping'` — response only); `ws/handler.go` | periodic ping in Transport (Phase 1) | ✅ (`WebSocketTransport` keepalive, 20 s / pong 10 s) |
| **D8** | 🟢 Low | `client/lib/models/relay_agent.dart:23` | The comment about statuses is outdated ("done, running, waiting, error") — herdr 0.8.0: `idle/working/blocked/done/unknown` | docs/10 §6.2 | fix the docs | ✅ |
| **D9** | 🟢 Low | `socket_event_repository.go:216` | `"jsonrpc":"2.0"` in subscribe — an extra field (absent from the herdr schema; harmless) | docs/10 §3.2 | remove when fixing D3 | ✅ |

**Phase binding:** D1, D8 → Phase 0 (baseline test "event → status" must be red before the fix, green after); D2, D5, D6 → server fixes, done as the first commit (independent of the refactoring); D3, D4, D9 → server improvements, done with them; D7 → Phase 1 (keepalive in `Transport`).

## 2. Target architecture: layered cake

```
┌─────────────────────────────────────────────────────────────┐
│ UI (pages/widgets) — works only with RelayClient            │
├─────────────────────────────────────────────────────────────┤
│ Client Layer    RelayClientImpl  — typed API, events,       │
│                 RelayStatus mapping, delegates to protocol  │
├─────────────────────────────────────────────────────────────┤
│ Protocol Layer  RequestResponseManager + Frame              │
│                 — JSON <-> Frame, id->completer, ping/pong  │
├─────────────────────────────────────────────────────────────┤
│ Transport Layer WebSocketTransport — bytes/strings, status,  │
│                 reconnect with backoff, pause/resume        │
├─────────────────────────────────────────────────────────────┤
│ Connection      ConnectionManager + RetryPolicy             │
│ (orchestration) — app lifecycle, fallback, retry policies   │
└─────────────────────────────────────────────────────────────┘
```

**Boundary rule:** dependency arrows go only downward. Transport knows nothing about JSON and requests. Protocol knows nothing about WebSocket and lifecycle. Client knows nothing about reconnect timers. Connection knows about all of them, but knows nothing about the domain (agents, events).

### 2.1 Transport Layer — `lib/core/transport/`

Responsible for: opening a connection, sending/receiving raw strings, auto-reconnect, status.

```dart
enum ConnectionStatus { disconnected, connecting, connected }

abstract class Transport {
  Stream<String> get messages;                    // raw text frames
  ValueNotifier<ConnectionStatus> get status;      // for UI and protocol
  String? get lastError;

  Future<void> connect(Uri uri);
  void send(String data);
  void pause();    // pause the reconnect loop (background)
  void resume();   // resume (foreground)
  Future<void> close();
}
```

Contract decisions (see §4):
- **`String`, not `Uint8List`** — WS text frames, the protocol is JSON strings. Binary is not needed.
- **`pause()`/`resume()`** — on the transport (not on the client): reconnect pause is a property of the connection.
- **Reconnect** — `ReconnectMixin`/`RetryPolicy` inside the transport: 1, 2, 4, … up to 30 s (keep the current behavior), plus duplicate protection (single timer, `cancelOnError`, `_closed`).
- **`HttpHealth`** — a small class for HTTP `healthz` (3 attempts with backoff, as currently in `WsRelayClient.healthz()`).

### 2.2 Protocol Layer — `lib/core/protocol/`

Responsible for: JSON <-> Frame, request-response matching, ping/pong, protocol errors.

```dart
sealed class Frame {
  factory Frame.parse(String json);   // throws ProtocolException on garbage
  String encode();
}

class RequestFrame  extends Frame { int id; String method; Map<String, dynamic> params; }
class ResponseFrame extends Frame { int id; bool ok; Map<String, dynamic>? result; RelayError? error; }
class EventFrame    extends Frame { String event; Map<String, dynamic>? data; }
class PingFrame     extends Frame {}
class PongFrame     extends Frame {}
```

```dart
class RequestResponseManager {
  RequestResponseManager(this.transport);   // listens to transport.messages and transport.status
  Future<Map<String, dynamic>> request(String method, Map<String, dynamic> params); // timeout 15 s
  // on disconnected: all pending complete with RelayException('disconnected', ...)
  // on PingFrame: automatically sends PongFrame — the client knows nothing about ping
}
```

- **`_waitForConnected`** (the current logic "give the WS a moment on cold start, then not_connected") — lives here: `request()` waits up to 8 s when `connecting`, and immediately throws `RelayException('not_connected', lastError)` when `disconnected`.
- **`_failPending`** — also here: subscription to `transport.status`; transitioning to `disconnected` completes all pending with an error.

### 2.3 Client Layer — `lib/services/relay_client_impl.dart`

`RelayClientImpl implements RelayClient` — the only new top-level code:

- `snapshot/output/keys/prompt` — typed wrappers over `RequestResponseManager` (JSON → `RelayAgent` mapping and back; `RelayClient` signatures do not change).
- `events` — listens to `transport.messages`, parses `EventFrame`, broadcasts into `RelayEvent` (broadcast controller).
- `status` — maps `ConnectionStatus` → `RelayStatus` (`ValueNotifier<RelayStatus>` — the public UI contract).
- `healthz` — delegates to `HttpHealth`.
- `pauseReconnect`/`resumeReconnect` — delegate to `transport.pause()/resume()` (interface signature preserved so `main.dart` is untouched until Phase 4).
- `close` — closes the transport, events, pending.

### 2.4 Connection Layer — `lib/core/connection/`

```dart
class ConnectionManager with WidgetsBindingObserver {
  ConnectionManager(this.transport, this.retryPolicy);
  // didChangeAppLifecycleState: paused/hidden -> transport.pause(); resumed -> transport.resume()
  // (logic moves here from main.dart)
  // optional (Phase 5): WS fails > 3 times -> switch to HttpTransport
}

abstract class RetryPolicy {
  bool shouldRetry(int attempt, Object error);
  Duration nextDelay(int attempt);
}
class ExponentialBackoff implements RetryPolicy { ... }  // 1..30 s
class FixedDelay      implements RetryPolicy { ... }
```

## 3. What already exists and what we create (deltas by file)

| File | Status |
| --- | --- |
| `services/relay_client.dart` (interface + RelayStatus + RelayException) | stays; re-export `RelayException` from protocol for test/UI compatibility |
| `services/relay_client.dart` (WsRelayClient) | after Phase 3 marked `@Deprecated` and moved to `_legacy/` (rollback plan), removed in Phase 4 |
| `core/transport/transport.dart`, `websocket_transport.dart`, `reconnect_mixin.dart`, `http_health.dart` | new (Phase 1) |
| `core/protocol/relay_protocol.dart`, `request_response_manager.dart`, `relay_exception.dart` | new (Phase 2) |
| `core/connection/connection_manager.dart`, `retry_policy.dart` | new (Phase 4) |
| `services/relay_client_impl.dart` | new (Phase 3) |
| `core/service_locator.dart` | updated: assembles the graph transport → rpc → client → repo (+ ConnectionManager) |
| `main.dart` | simplified: lifecycle moves to ConnectionManager (Phase 4) |

## 4. Decisions (ADR — approved)

> All 7 decisions approved on 30.08. When a layer contract changes — update this
> section and mark the change (date, reason).

| # | Question | Decision (approved) | Rationale |
| --- | --- | --- | --- |
| 1 | `Stream<String>` or `Stream<Uint8List>` in Transport | **`String`** | WS text frames; the protocol is JSON strings. Binary — if needed, we will add a separate method |
| 2 | Where `healthz()` lives | **A separate `HttpHealth` in transport**, the client delegates | It is network, but not protocol and not domain; the `RelayClient.healthz()` signature does not change |
| 3 | Where `RelayStatus` / `RelayException` live | `RelayStatus` — in `services/relay_client.dart` (public UI API); `RelayException` — in `core/protocol/`, re-exported from `services/relay_client.dart` | UI and tests import them from `services/relay_client.dart` — we do not want to break imports |
| 4 | pause/resume | On **Transport** (`pause()/resume()`), not on the client | Reconnect pause is a property of the connection; the client delegates (interface signatures preserved) |
| 5 | `_waitForConnected` and `_failPending` | Both — in **RequestResponseManager** | This is request-response semantics: wait/fail requests based on transport status |
| 6 | Ping/pong | **Auto-reply to `PingFrame` inside RequestResponseManager** | The manager already listens to all frames; the client knows nothing about ping |
| 7 | HTTP fallback | **Deferred to Phase 5** (behind a feature flag) | The server already supports HTTP (output/keys/prompt); we need to verify events over HTTP (long-poll/SSE) in `internal/transport/http/` |

## 5. Plan by phases

### Phase 0 — Baseline (2–3 days, before the refactoring branch)

**Goal:** pin the current behavior with tests that must stay green after each phase.

1. Create branch `refactor/modular-architecture` from the current state.
2. Write `client/test/services/relay_client_test.dart` against the **existing** `WsRelayClient`, using a replaceable `WebSocketChannel` (hand-rolled fake on `StreamController` — no mockito, it is not in the dependencies):
   - request → response matching (ok and error)
   - event → `RelayEvent` (with `name`/`data`), including `pane.agent_status_changed`
   - ping → pong
   - 15 s timeout → `RelayException('timeout', ...)`
   - reconnect: simulated disconnect → new connect, backoff 1/2/4 s (fake clock not needed — we verify the fact of reconnection)
   - `pauseReconnect` → no reconnect attempts; `resumeReconnect` → reconnect
   - pending requests complete with an error on disconnect
   - `not_connected` when requesting without a connection
3. `flutter analyze` and `flutter test` — green.

**Definition of done:** client behavior is covered by tests; these tests do not change when rebuilding on layers (only the instantiation method changes).

### Phase 1 — Transport (week 1)

1. `core/transport/transport.dart` — the interface (contract from §2.1).
2. `core/transport/reconnect_mixin.dart` — reconnect loop with backoff (moved from `_scheduleReconnect`), `pause()/resume()`, duplicate protection.
3. `core/transport/websocket_transport.dart` — `WebSocketChannel.connect`, move `_connect/_onDisconnect`; **without** JSON, without requests/events, without healthz.
4. `core/transport/http_health.dart` — move `healthz()` (3 attempts, backoff 200/400 ms).
5. Tests: `test/core/transport/websocket_transport_test.dart` (reconnect on simulated disconnects, send/receive, pause/resume, status transitions) + `http_health_test.dart`.

**Definition of done:** `WebSocketTransport` reconnects on its own, but knows nothing about JSON/requests/events. The old `WsRelayClient` still works in parallel (the app is not switched over).

### Phase 2 — Protocol (week 2)

1. `core/protocol/relay_exception.dart` — `RelayException` (+ `RelayError`), `ProtocolException`.
2. `core/protocol/relay_protocol.dart` — `sealed class Frame` + parser (exact mapping of the real protocol from `cmd/relay/ws.go`: `type`, `id`, `ok`, `result`, `error`, `event`, `data`, `ping`).
3. `core/protocol/request_response_manager.dart` — `request()`, 15 s timeout, failPending on disconnected, auto ping-pong, wait-for-connected.
4. Tests: `relay_protocol_test.dart` (parse/encode of all frames, garbage → ProtocolException), `request_response_manager_test.dart` (fake transport: matching, timeout, failPending, ping/pong).

**Definition of done:** Protocol parses any relay JSON and matches requests/responses without a network stack.

### Phase 3 — Client on new layers (week 3)

1. `core/transport/fake_transport.dart` (test/fakes) — following the plan template, with `simulateMessage`/`sentMessages`.
2. `services/relay_client_impl.dart` — `RelayClientImpl` on Transport + RequestResponseManager (§2.3).
3. Switch `service_locator.dart` to the new assembly; the old `WsRelayClient` → `@Deprecated`, moved to `lib/_legacy/`.
4. Tests: `relay_client_impl_test.dart` with FakeTransport (scenario from the plan: snapshot over a simulated response); **Phase 0 baseline tests are switched to `RelayClientImpl` and remain green**.

**Definition of done:** UI works as before; each layer is tested independently; `WsRelayClient` in `_legacy/` is available for rollback.

### Phase 4 — Connection Manager (week 4)

1. `core/transport/retry_policy.dart` — interface + `ExponentialBackoff`, `FixedDelay` (move the 1..30 s formula; lives in transport so there is no transport → connection dependency).
2. `core/connection/connection_manager.dart` — lifecycle from `main.dart` (`WidgetsBindingObserver` → `transport.pause()/resume()`), wiring up RetryPolicy.
3. `main.dart` — remove `WidgetsBindingObserver`; `service_locator.dart` registers `ConnectionManager` alongside client/repo.
4. Remove `_legacy/WsRelayClient`.
5. Tests: `connection_manager_test.dart` (paused/hidden → pause, resumed → resume; disposal without observer leak), `retry_policy_test.dart` (in `test/core/transport/`).

**Definition of done:** the app pauses reconnect in the background and resumes in the foreground on its own (behavior from main.dart preserved, now testable). Battery drain closed.

### Phase 5 — HTTP fallback (optional, future)

1. Audit `internal/transport/http/handler.go`: which methods exist, whether events exist (long-poll/SSE) — if not, fallback is request-only first, events stay on WS.
2. `core/transport/http_transport.dart` — `implements Transport` (HTTP long-polling for `messages`).
3. Switch in `ConnectionManager`: WS fails > 3 times → HTTP, behind a feature flag.

**Definition of done:** switching transports does not change Protocol/Client/UI.

## 6. Test strategy (vertical slices)

```
            ╱ E2E (1–2) — app_integration_test: test relay + UI
           ╱ Integration (5–10) — RelayClientImpl + FakeTransport
          ╱ Unit (50–100) — protocol, transport, retry, manager
```

| Layer | Test | Fake |
| --- | --- | --- |
| Protocol | `relay_protocol_test.dart` — parse/encode, garbage | — |
| RPC | `request_response_manager_test.dart` — matching, timeout, failPending | `FakeTransport` |
| Transport | `websocket_transport_test.dart` — reconnect, pause/resume | fake `WebSocketChannel` |
| Connection | `connection_manager_test.dart`, `retry_policy_test.dart` | fake transport |
| Client | `relay_client_impl_test.dart` — typed API | `FakeTransport` |
| Baseline | `relay_client_test.dart` (Phase 0) — runs against WsRelayClient, then RelayClientImpl | fake `WebSocketChannel` |
| Widget | existing `home_page_test.dart`, `agent_page_test.dart` | existing `FakeRelayClient` |

Tooling: `package:test`/`flutter_test`; mockito/mocktail **are not added** — hand-rolled fakes on `StreamController` are enough and faster.

## 7. Final directory structure

```
client/lib/
├── core/
│   ├── transport/
│   │   ├── transport.dart              # interface + ConnectionStatus
│   │   ├── websocket_transport.dart
│   │   ├── reconnect_mixin.dart        # backoff + pause/resume
│   │   ├── retry_policy.dart           # ExponentialBackoff/FixedDelay
│   │   ├── http_health.dart            # healthz (3 attempts)
│   │   └── http_transport.dart         # Phase 5 (future fallback)
│   ├── protocol/
│   │   ├── relay_protocol.dart         # sealed Frame + parser
│   │   ├── request_response_manager.dart
│   │   └── relay_exception.dart
│   ├── connection/
│   │   └── connection_manager.dart     # lifecycle (from main.dart)
│   └── service_locator.dart
├── models/                             # unchanged
├── services/
│   ├── relay_client.dart               # interface + RelayStatus (unchanged for UI)
│   └── relay_client_impl.dart          # new layered implementation
├── repositories/                       # unchanged (keep the offline cache!)
├── pages/ · widgets/                   # unchanged
└── _legacy/                            # temporarily: WsRelayClient (rollback), removed in Phase 4

client/test/
├── core/
│   ├── transport/  (websocket_transport_test, http_health_test, retry_policy_test)
│   ├── protocol/   (relay_protocol_test, request_response_manager_test)
│   └── connection/ (connection_manager_test)
├── services/       (relay_client_impl_test, relay_client_test ← baseline)
└── fakes/          (fake_transport.dart, fake_relay_client.dart ← existing)
```

## 8. Working rules

1. **Feature-driven boundaries.** A new feature touches one layer: HTTP fallback → transport only; offline mode → `CachingTransport` wrapper; metrics → decorator around `RequestResponseManager`.
2. **Contract-first.** First the layer interface → tests against it → implementation → integration. A new transport (WebRTC) = the same tests as WS.
3. **Vertical slice testing** — the pyramid from §6; one E2E.
4. **Incremental migration.** We do not rewrite everything at once: Phase 0 pins the behavior, Phases 1–2 work in parallel with the old code, `_legacy/` provides rollback until Phase 4.
5. **Documentation as contracts.** Each module has a `README.md`: Purpose / Dependencies / API / Examples / Testing (template — §9).

## 9. Module README template

```markdown
# Transport Layer

## Purpose
Raw network connectivity: connect, send, receive, reconnect.

## Dependencies
- `dart:async` (Stream, Future) · `web_socket_channel`

## API
```dart
abstract class Transport { /* ... */ }
```

## Usage
final transport = WebSocketTransport(uri);
await transport.connect(uri);
transport.messages.listen((msg) => print('Got: $msg'));
transport.send('{"type":"ping"}');

## Testing
final transport = FakeTransport();
transport.simulateMessage('{"type":"pong"}');
expect(transport.sentMessages, contains('{"type":"ping"}'));
```

## 10. Progress metrics

Modularity works when:
1. **Test isolation** — tests of one layer run without the rest.
2. **Swap implementations** — `WebSocketTransport` → `HttpTransport` without changing Client.
3. **Parallel development** — Transport and Protocol can be built independently.
4. **Incremental rollout** — a new transport is enabled via a feature flag.

Verifiable: `flutter test test/core` (without widget tests) — green; replacing the transport in `service_locator.dart` in one line.

## 11. Checklist

**Before starting:**
- [x] Approve §4 decisions (record the ADR) — **done 30.08**
- [x] Create branch `refactor/modular-architecture`
- [x] Server fixes D2/D3/D4/D5/D6/D9 (independent of the refactoring)
- [x] Phase 0: baseline tests on `WsRelayClient` (behavior reference), red test for D1 before the fix
- [ ] `flutter analyze` + `flutter test` green on baseline

**During:**
- [x] Each layer: unit tests + README
- [x] Baseline tests green after each phase
- [x] The `RelayClient` interface does not change (UI untouched)

**After:**
- [ ] Code review focused on boundaries (no cross-layer dependencies)
- [x] `_legacy/WsRelayClient` removed
- [ ] Benchmark: reconnect time, request latency

## 12. Risks

| Risk | Mitigation |
| --- | --- |
| "Parallel run" in the mobile app is hard (no metrics from users) | We replace it with baseline tests: behavior is pinned by tests, not by production observation |
| Losing reconnect invariants (single timer, cancelOnError, duplicate disconnects) | Move `_scheduleReconnect/_onDisconnect` as-is, cover with Phase 0–1 tests |
| Changing the pair: getIt singletons and observers not released | `ConnectionManager.dispose()` removes the observer; `teardownRelayServices` closes the transport |
| Broken `AgentRepository` offline cache | We do not touch the repository; cover with a "relay offline" scenario in `relay_client_impl_test` |
| iOS suspend ~30 s — reconnect pause lost on migration | `pause()/resume()` move to the transport, lifecycle — into ConnectionManager (Phase 4) |

## 13. Open questions

1. Do we need HTTP fallback now (Phase 5) or just the `http_transport.dart` skeleton?
2. Should we add metrics/logging as a decorator in this iteration?
3. Should `_legacy` be moved to a separate branch instead of `lib/_legacy/` in the main one?
