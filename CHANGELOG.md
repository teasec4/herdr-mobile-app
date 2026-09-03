# Changelog

All notable changes to HerdRelay project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-08-30

### Added (terminal stream dedup, docs/14-terminal-stream-implementation-plan.md)

#### Go Relay Server (Phase 1 — output cache)
- `internal/service/output_cache.go`: TTL cache for agent output, composite key
  `(paneID, lines, format)` so `text/200` and `ansi/500` variants never
  cross-pollute; 60 s TTL, background cleanup goroutine, `Invalidate(paneID)`
  drops all cached variants of a pane
- `AgentService` now tracks the latest output `revision` from events
  (`lastKnownRevision`, monotonic guard) and returns it in
  `agent.output` / `pane.output` responses
- `EventService` invalidates the output cache on `pane.updated`,
  `pane.output_changed` and `agent_status_changed`; the socket repo keeps the
  revision in the data of `pane.updated` / `pane.output_changed` it forwards
  (strictly-increasing revision, so the client guard never skips a live update)
- New tests: `output_cache_test.go` (TTL, eviction, invalidation),
  `agent_service_test.go` (cache hit / invalidation / TTL via repo stub)

#### Flutter Client (Phase 2 — revision-aware cache)
- `RelayClient.output`/`paneOutput` return `AgentOutputResult` (text + revision)
- `AgentRepository` caches the latest output per agent and skips the RPC when
  the caller's `knownRevision` matches the cached revision (only request the
  live update, never re-fetch a stale view)
- `AgentPage` passes the event `revision` on live refresh, so a burst of
  `pane.output_changed` events collapses to a single RPC
- Full test suite green: 202 Flutter tests, `flutter analyze` no new issues

#### Flutter Client (settings + offline mode switching)
- **AppSettings** (`services/app_settings.dart`): typed layer over SharedPreferences
  (homeTabIndex, terminalFontSize 9–20 + A−/A+ buttons on AgentPage, autoScrollFollow,
  snapshot cache). HomePage restores the selected tab, AgentPage restores font size and
  auto-scroll.
- **Offline mode switching**: the picker only worked through `/pair` (an unreachable relay
  was a chicken-and-egg problem); saved profile endpoints + manual entry added (host follows
  the mode, token comes from the profile) — see below.
- **Mode = endpoint** (`PairConfig.endpoints`): the profile remembers addresses for every
  relay mode (LAN IP, tailnet name, funnel); a pair link seeds the endpoint, each `/pair`
  appends addresses, switching `connectVia` doesn't drop the others; offline switch from
  "Saved modes for this relay". The sheet is scrollable.
- Tests: endpoints round-trip/seed/legacy/connectVia/fromUrl, `/pair` selection with merge,
  offline switching, host follows the mode. Result: 225 Flutter tests, analyze 0 errors.

## [0.2.0] - 2026-08-30

### Changed (big refactor, docs/09-refactoring-plan.md)

#### Flutter Client — layered architecture
- Monolithic `WsRelayClient` (362 lines) replaced by four layers:
  - `core/transport` — `Transport` interface, `WebSocketTransport`
    (reconnect via `RetryPolicy`, keepalive 20 s/10 s, pause/resume),
    `HttpTransport` (HTTP RPC + SSE fallback), `HttpHealth`, `RetryPolicy`
  - `core/protocol` — `sealed Frame` (Request/Response/Event/Ping/Pong),
    `RequestResponseManager` (matching, 15 s timeout, fail-on-disconnect,
    auto ping→pong, cold-start wait), `RelayException`
  - `core/connection` — `ConnectionManager` (app lifecycle),
    `ModeService` (fetch /pair modes with retries/limits/clear errors)
  - `services/relay_client_impl.dart` — typed `RelayClient` on the layers
- New **Connection screen**: device card, live status, connection test
  (healthz + snapshot), mode switching, saved devices, pair link entry
- **Tappable mode badge** on the home screen: opens a mode picker
  (lan/tailscale/funnel from `/pair`) with loading/error+Retry states
- Pair link entry now gives explicit success/error feedback
- `get_it` DI (was `provider`), profiles stored in `shared_preferences`
- 148 tests, `flutter analyze` 0 warnings

#### Go Relay Server
- Clean-architecture split into `internal/` (domain/service/infrastructure/
  transport), `cmd/relay` keeps `pair`/`status` subcommands
- **HTTP fallback endpoints**: `POST /api/rpc` (relay request frame in,
  response frame out) and `GET /api/events/stream` (SSE) — HTTP twin of `/ws`
- Shared `service.Dispatch` used by both WS and HTTP transports
- Event socket repo: single `events.subscribe` per connection, per-pane
  `pane.agent_status_changed` subscription (statuses without the plugin hook),
  `scroll_changed` debounce (500 ms/pane)
- herdr CLI calls now use `HERDR_SOCKET_PATH` (was ignored `HERDR_SOCKET`)

#### herdr Plugin
- `redeploy.sh`: one command to rebuild the relay, restart the launchd
  service, re-link the plugin and health-check

### Fixed (herdr API cross-check, docs/10)
- `pane.agent_status_changed` read `agent_status` (was `status` → live status
  always `unknown`); baseline test was red before the fix
- Dead `/api/events/pane.updated` route removed; `display_agent` forwarded;
  `jsonrpc` field dropped from subscribe

## [0.1.0] - 2026-08-29

### Added

#### Flutter Client
- **Home Page**: list of all AI agents on the machine with real-time status updates
- **Agent Page**: interactive terminal for interacting with an agent
  - Live agent output with ANSI support (colors, formatting)
  - Sending prompts and commands
  - Ctrl-C to interrupt the agent
  - Smart interactive buttons (parse answer options from the output)
  - Command history with arrow-key navigation
- **Pair Page**: relay connection configuration (host, port, token)
- **Status indicators**: visual status chips (working, blocked, idle, done)
- **Provider-based DI**: RelayClient via Provider for shared state
- **Comprehensive tests**: 55 tests covering all the main scenarios

#### Go Relay Server
- **WebSocket API**: real-time two-way communication with clients
- **HTTP API**: REST endpoints for snapshot, agent output, prompt, keys
- **Event broadcasting**: push notifications on agent status changes
- **herdr integration**: interaction with the herdr CLI (agent list, read, prompt, send-keys)
- **Token authentication**: secure authentication via Bearer token
- **Multi-client support**: multiple clients working at the same time

#### herdr Plugin
- **Event forwarding**: automatic forwarding of events to the relay
  - `pane.agent_status_changed` - agent status change
  - `pane.output_changed` - output update
  - `pane.updated` - general pane changes
- **Auto-configuration**: automatic token generation on install
- **Plugin lifecycle**: setup-menu, on-event hooks

#### Utilities & Documentation
- **relay-status.sh**: relay management utility (status, rebuild, restart, logs)
- **Diagnostics tools**: logging at all levels (plugin → relay → client)
- **Documentation**:
  - `README.md` - general project description (EN)
  - `RELAY_MANAGEMENT.md` - managing the relay server
  - `DIAGNOSTICS.md` - diagnosing status updates
  - `DEBUG_STATUS_UPDATE.md` - detailed event debugging
  - `client/TERMINAL_UI.md` - interactive terminal buttons

### Features Details

#### Smart Interactive Buttons
The parser automatically recognizes answer options from the agent's output:
- **Inline options**: `(y/n)`, `[yes/no]`, `accept/reject`
- **Questions**: "Would you like to...?" → Yes/No buttons
- **Numbered lists**: `1. Option` → buttons with the option text
- **Filtering**: task lists (◻/◼) are not recognized as options

#### Real-time Status Updates
- Events from herdr are forwarded through the relay to Flutter
- 150ms delay between event and snapshot (race condition fix)
- Proper subscription cancellation on dispose (no memory leaks)

#### Terminal Features
- ANSI escape code rendering (colors, bold, italic)
- Auto-scroll to bottom (disabled when scrolling up)
- Debounced output updates (no UI overload during fast streaming)
- Command history with arrow-key navigation (↑/↓)

### Fixed
- **Ctrl-C**: fixed send format (`C-c` instead of `['ctrl', 'c']`)
- **Subscription leaks**: proper StreamSubscription cancellation in dispose
- **Race condition**: 150ms delay to sync herdr state
- **Parser false positives**: removed the keyword-search strategy

### Technical Stack
- **Frontend**: Flutter 3.24.3, Dart 3.5.3
- **Backend**: Go 1.23+
- **Integration**: herdr CLI, tmux, WebSocket
- **Testing**: flutter_test, widget tests, integration tests

### Known Limitations
- Local connection only (localhost or a LAN IP)
- Requires herdr >= 0.7.5
- macOS/Linux (Windows not tested)
- The interactive-button parser only works with text output

---

## [Unreleased]

### Added
- **Relay identity**: on first start the relay generates a stable `relay_id` (32 hex) and a host `name` (`~/.config/herdr/herdrelay.id`); `relay_id`/`name` added to the pair link and to the universal QR.
- **Client profiles**: the app stores several pair configurations (Switch / Add / Forget) — handy when changing networks, sessions or moving to another machine.
- **`herdrelay status`**: diagnostic subcommand — mode, address, identity, config paths and live state (exit 0 = relay is running).
- **Mode switch without rebuild**: `plugin/configure.sh` rewrites the launchd plist (`HERDRELAY_MODE`, `HERDRELAY_GATEWAY_URL`) and restarts the service; install.sh and the plist now read `HERDRELAY_MODE`/`HERDRELAY_GATEWAY_URL` from the environment.
- **Automatic mode switching** (docs/AUTO_MODE_SWITCHING_PLAN.md, Phase 2): `ConnectionFallbackManager` — on transport drop it tries the saved endpoints (tailscale → lan → funnel), SnackBar "Relay unreachable — switched to …"; integrated in `main.dart`, `websocket_transport.dart` now goes `disconnected` on connection errors.
- **Manual Mode** (Phase 3): "Switch mode manually" button in the Connection page, dialog with a live `/healthz` check — works even when the relay is unreachable (`widgets/manual_mode_dialog.dart`).
- **Universal QR** (Phase 4): a mode-less link pulls all modes through `ModeService` and offers a primary choice; LAN-only links show a "Limited connectivity detected" warning (`widgets/lan_only_warning_dialog.dart`).
- **Help page** (Phase 5): `pages/help_page.dart` — FAQ on Connection modes / remote access, "Help" item in the HomePage menu.
- **Documentation rebalance**: README/INSTALL — "Best Practices for Remote Access" section; plan checklist marked.

### Fixed (Flutter Client, reliability)
- **Reconnect without duplicates**: before a new connection the old subscription is cancelled, `onError`/`onDone` merged into a single handler with `cancelOnError: true`, re-scheduling reconnect is blocked. More than 1 active WS connection and lost request responses are excluded.
- **Lifecycle**: when the app goes to background the reconnect loop pauses; it resumes on return (saves battery, leaves no dangling pending requests).
- **ConfigStore race condition**: concurrent `saveProfile` calls are serialized (in-memory lock) — parallel deep links no longer lose profiles.
- **healthz retry**: up to 3 attempts with backoff instead of one — a single network failure no longer marks the relay offline.
- **List update debounce**: a burst of simultaneous events (e.g. batch start) triggers one snapshot instead of N parallel requests.
- **Offline agent cache**: the last successful snapshot is cached and shown when the relay is unreachable.
- **Clear errors**: protocol errors (`not_connected`/`timeout`/`unauthorized`) are mapped to human-readable text instead of a raw `toString()`.
- **Pair link validation**: token at least 16 characters and without characters that break a query string; `PairConfig.toJsonSafe()` masks the token in logs.

### Changed (event pipeline, dedup — docs/12-fix-plan.md A1-A3)
- **Single status channel**: the plugin hook (`on-event.sh` → `POST /api/events/herdr`) and the `/api/events/*` routes removed — statuses now only come from the socket subscription (`events.subscribe`, `pane.agent_status_changed`). One status change = one event to the client instead of two.
- **Agent page without extra requests**: the `pane.agent_status_changed` event updates the status locally (and name/workspace from the payload) — no re-snapshot or re-read of output; output is read only on `pane.output_changed` and manual refresh.
- **Status event extended**: `agent`, `display_agent`, `workspace_id`, `title` from the herdr payload now reach the client (`relay_event.dart`).
- **Revision revived**: the relay attaches the last known `revision` from `pane.updated` to `pane.output_changed` (strictly increasing only) — the client revision-guard starts working, a stale revision is not sent so a live update is never skipped.
- **AnsiTerminal memoization**: same text → same `SelectableText` instance (no ANSI re-parse or re-layout) — duplicate/status rebuilds no longer rebuild the terminal.
- **Pong no longer leaks into messages**: keepalive-pong is consumed by the transport, upper layers don't parse an empty frame.
- **Agent cache written only on list change** (not on every snapshot).
- **Interruptible socket reconnect loop**: `Close()` no longer waits for the backoff sleep (docs/12 B3).
- **Debug print removed** from `agent_page.dart` (and the event path of `home_page.dart`).

### Changed (view architecture: controllers instead of orchestration in State)
- **Lightweight ViewModels** (plain `ChangeNotifier` + `ListenableBuilder`, no framework): `AgentsController` (agent list: status deltas, debounce, reconnect catch-up, pause under AgentPage) and `SessionController` (session for the Spaces/Run tabs: one load instead of two, live status updates, reconnect catch-up, `freePaneFor`).
- **Triple reconnect-catch-up duplication removed** (`_wasDisconnected` used to live in home/run/spaces — now it lives in the two controllers).
- **Refresh races closed** (generation counter): a stale response no longer overwrites a fresh one — `AgentsController`, `SessionController`, `AgentPage._refresh`, `ConnectionPage._checkConnection`.
- **Lazy HomePage tabs**: Spaces/Agents/Run are built on first visit — no `getAgents()` and no double `session()` for invisible tabs at startup (covered by a test).
- **HomePage header no longer overflows** on narrow screens: the mode badge (TAILSCALE) and status are truncated, padding reduced; test at 320 px.
- **AnsiTerminalParser moved** to a separate file (`widgets/ansi_terminal_parser.dart`); list tiles wrapped in `RepaintBoundary`.
- **Dead `provider` dependency removed** from pubspec.

### Planned
- Remote API access (outside the local network)
- Multi-workspace support
- Theme settings (dark/light)
- Search over agent output
- Agent history export
- Push notifications for critical events

