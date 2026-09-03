# 05 — Flutter app (`client/`)

Mobile client for iOS/Android. Works in all transports: LAN, Tailscale (mode
B1 — the phone needs Tailscale), Tailscale Funnel (B2 — public HTTPS, the
phone does not need Tailscale). The client is built in layers:
`core/transport` + `core/protocol` + `core/connection` + a thin
`services/relay_client_impl.dart` (the result of the refactoring,
[09 — Plan](09-refactoring-plan.md), phases 0–5).

## Layers and dependencies

```
┌─ pages/widgets — UI works only through RelayClient and PairConfig
├─ services/relay_client.dart      RelayClient interface + RelayStatus (stable for UI)
├─ services/relay_client_impl.dart assembles: Transport + RequestResponseManager + HttpHealth
├─ core/protocol  Frame (sealed), RequestResponseManager, RelayException
├─ core/transport Transport (interface), WebSocketTransport, HttpTransport,
│                 ReconnectMixin, RetryPolicy, HttpHealth
├─ core/connection ConnectionManager (lifecycle), ModeService (modes /pair)
└─ models/ PairConfig · RelayAgent · RelayEvent (unchanged)
```

| package | purpose |
| --- | --- |
| `web_socket_channel` | WebSocket channel to the relay (`WebSocketTransport`) |
| `http` | HTTP fallback (`HttpTransport`: `/api/rpc` + SSE), `HttpHealth`, `/pair` modes |
| `get_it` | DI: `RelayClient`, `AgentRepository`, `ConfigStore`, `ModeService`, `ConnectionManager` |
| `shared_preferences` | stores pair profiles + offline cache of the last snapshot |
| `app_links` | deep link via the custom scheme `herdrelay://` |
| `mobile_scanner` | scanning the pair QR link |
| `flutter_local_notifications` | local "agent blocked" notifications (Android 8+ channel, iOS/macOS/desktop) |

## Screens

1. **PairPage — onboarding.** Scan the QR (`mobile_scanner`) or manually paste
   the `herdrelay://pair?...` link; the link is validated (token ≥ 16
   characters, no characters that break the query). Errors — via a toast
   (`ToastService`), success — move to the main screen.
   - **Universal QR**: if `mode` is passed in the link, the mode is selected
     right away; otherwise a dialog to choose the primary mode
     (`LAN`/`TAILSCALE`/`FUNNEL`) is shown.
   - **LAN-only warning**: when pairing over LAN, `LanOnlyWarningDialog` is
     shown with a tip to enable Tailscale (mode `TAILSCALE`).

2. **HomePage — agent list** (main).
   - agent card: name, status (`idle/working/blocked/done/unknown`), cwd;
     blocked — on top and highlighted ("needs my reply");
   - pull-to-refresh + live updates via WS events (events are debounced by
     300 ms so a burst of events does not trigger N snapshot requests);
   - **offline cache**: the last successful snapshot is cached in
     `shared_preferences` (`AgentRepository`); when the relay is unavailable,
     the cached list is shown;
   - in the AppBar — **clickable mode badge** (`LAN`/`TAILSCALE`): tapping
     opens `ModePickerSheet` — choosing a mode means choosing the relay's
     **endpoint** (`PairConfig.endpoints`, `models/pair_config.dart`). Three
     paths: (1) modes from `/pair` — when the relay is reachable; (2) **saved
     endpoints** of the profile — offline switching (e.g. Tailscale is off at
     home, but the LAN IP is already remembered from a previous pair/`/pair`);
     (3) manual input (mode + host + port, token from the profile; the host
     follows the selected mode — the address of another mode is never
     substituted). Each successful `/pair` appends the addresses of all modes
     to the profile; switching does not lose the other addresses. Next to it —
     live connection status (online/connecting/offline);
   - "⋮" menu: **Connection…** (connection screen), **Add device…**,
     **Forget device**, **Help**.

3. **ConnectionPage — the "Connection" screen** (everything about how we are
   connected):
   - device card: name, `host:port`, mode, ws address, profile id;
   - live status + **Test** button (healthz + snapshot: "OK · N agent(s) ·
     Xms");
   - **Connection mode**: modes from `/pair` (lan/tailscale/funnel), switching
     connects via the saved endpoint of the mode (offline — from the profile);
     a profile with only the LAN mode shows a warning icon and a tip about
     Tailscale (`widgets/lan_only_warning_dialog.dart`);
   - **Switch mode manually**: manual host/port input with a live `/healthz`
     check ("Reachable…"/"Not reachable") — works even when the relay is
     unavailable (`widgets/manual_mode_dialog.dart`);
   - **Saved devices**: all saved profiles — switch/delete;
   - **Pair**: paste the link + "Forget this device" (with confirmation).

4. **AgentPage — the agent terminal.**
   - output: a monospace dark terminal, auto-scroll, live updates via
     `pane.output_changed` with a ~400 ms debounce, ANSI — via its own SGR
     parser (`widgets/ansi_terminal.dart`);
   - input line: prompt (`agent.prompt`); quick keys Esc/Ctrl-C
     (`agent.keys`); command history; action buttons from the output.

## Transport

- **WebSocketTransport** — raw strings, no protocol knowledge. Reconnect with
  `RetryPolicy` (default `ExponentialBackoff`: 1, 2, 4, … up to 30 s; formula
  and limit — `core/transport/retry_policy.dart`). Duplicate protection: a
  single timer, `cancelOnError`, a single `onDone/onError` handler.
- **Keepalive** (default 20 s ping / 10 s pong window): detects "half-dead"
  connections (mobile NAT silently drops the socket) and reconnects.
- **Lifecycle** — `core/connection/connection_manager.dart`
  (`WidgetsBindingObserver`): `paused`/`hidden` → `transport.pause()`,
  `resumed` → `transport.resume()` (saves battery; iOS freezes sockets ~30 s
  in the background).
- **HttpTransport** — HTTP fallback (Phase 5): `send()` POSTs the request
  frame to `/api/rpc`, events — an SSE stream `/api/events/stream`; the same
  reconnect/backoff. Enabled in `service_locator` via the
  `transportMode: 'ws'|'http'` parameter.
- **HttpHealth** — `/healthz`, up to 3 attempts with a short backoff.
- **ConnectionFallbackManager** — automatic mode switching on a disconnect:
  tries the profile's saved endpoints (tailscale → lan → funnel), reports via
  a SnackBar "Relay unreachable — switched to …" and reconnects (`main.dart`).

## Protocol

- `core/protocol/relay_protocol.dart` — `sealed Frame`:
  `Request/Response/Event/Ping/Pong`, strict `Frame.parse` (garbage →
  `ProtocolException`).
- `core/protocol/request_response_manager.dart` — id→completer, 15 s timeout,
  on disconnect all pending complete with an error, auto ping-pong, cold-start
  wait up to 8 s before `not_connected`.
- `RelayException`/`RelayError`/`ProtocolException` — `core/protocol/`;
  `services/relay_client.dart` re-exports them so the UI/tests keep importing
  from a single place.

## Events

`pane.agent_status_changed` (key **`agent_status`** — the client reads exactly
this), `pane.updated`, `pane.output_changed` (`pane.scroll_changed` has no
`revision` — debounce happens on the client). Agent statuses:
`idle/working/blocked/done/unknown` (docs/10-herdr-api.md §6.2).

## Local notifications (blocked)

`NotificationService` (`services/notification_service.dart`) watches
`AgentStatusChanged` and, when an agent transitions to `blocked` **while the
app is not in the foreground** (background/locked screen), shows a local
notification — one per pane until it leaves `blocked` (dedup by `pane_id`).
Controlled by `AppSettings.notificationsEnabled` (toggle in the ⋮ menu →
"Notifications…"); enabling it requests the OS permission. Tapping a
notification opens the agent page (including a cold start from the
notification). Platform layer — `NotificationApi`/`LocalNotificationsApi`
(`services/notification_api.dart`) built on `flutter_local_notifications`
(Android channel `blocked_agents`, `high`).

Limitations: on iOS a socket in the background lives ~30 s, then reconnect is
paused — long background sessions are covered only by push (see roadmap); on
Android the window is longer. On desktop the window is always in the
foreground → notifications are not shown.

## Errors and their display

- `ToastService` maps protocol errors to understandable text: `not_connected` →
  "check the network", `timeout` → "try again", `unauthorized` → "re-scan the
  QR".
- `ModeService` (`/pair` modes) — up to 3 attempts with backoff, 5 s timeout;
  401/403 — immediately, without retries; clear messages ("Cannot reach
  relay…", "Relay did not respond in time…"); in `ModePickerSheet` — the
  loading/error+Retry/list states.
- The pair link is validated on entry (token ≥ 16 characters, no `& # ?` or
  whitespace).

## Tests (241)

- **unit**: `test/core/protocol/` (parse/encode, matching, timeout, fail-on-
  disconnect), `test/core/transport/` (reconnect, keepalive, pause/resume,
  HttpTransport against a dart:io mock, HttpHealth, RetryPolicy),
  `test/core/connection/` (lifecycle, ModeService with retries/limits).
- **integration**: `test/services/relay_client_impl_test.dart` —
  `RelayClientImpl` + `FakeTransport`.
- **widget**: `home_page_test`, `connection_page_test`, `pair_page_test`,
  `agent_page_test`.
- **fakes**: `FakeRelayClient`, `FakeTransport`, `FakeWebSocketChannel`.

`flutter analyze` — 0 warnings/errors.

## Deliberately NOT in v1

- Workspaces/worktrees/diffs.
- Replies to structured agent approve-flows: "reply" = text/keys into the
  terminal (covers most cases).
- Push notifications (FCM/APNs) — planned (see [06 — Roadmap](06-roadmap.md));
  local blocked-agent notifications exist (see the Local notifications section
  above).
- `flutter_xterm` instead of the custom ANSI parser — a v2 plan.

## Security and known risks

- The pair token is stored in `shared_preferences` and passed as `?token=` in
  the WS query; logging only via `PairConfig.toJsonSafe()` (token masked).
- Certificate pinning for funnel mode is deliberately not implemented (the
  risk is documented): funnel goes through Tailscale Funnel with Let's
  Encrypt; pinning requires a platform implementation and complicates rotation
  — revisit before public distribution.
- Validation of incoming pair links (see PairPage).