# 03 — Relay (Go, `cmd/relay`)

The single process on the laptop that understands the herdr socket and serves
it to the phone. It already has go.mod (`module herdrelay`, Go 1.26.1).

## Responsibilities

1. Talk to herdr (socket `~/.config/herdr/herdr.sock` by default, path visible
   in `herdr status`; configurable via env `HERDR_SOCKET`/config).
2. Serve the phone: WS channel (via the gateway or directly) + HTTP fallback.
3. Receive herdr events and fan them out to connected clients:
   - agent statuses and live terminal output — via the relay's direct socket
     subscription (`events.subscribe`: `pane.agent_status_changed` +
     `pane.scroll_changed`, see `socket_event_repository.go`);
4. Authenticate clients (pair bearer token).

## Talking to herdr: two options

### V1 — via the CLI (simple and version-stable)

The entire herdr CLI emits structured JSON. The relay just `exec`s it:

```go
// agent list and statuses
herdr api snapshot
// terminal output slice (last N lines, text or ansi)
herdr agent read <target> --lines 200 --format text
// send keys
herdr agent send-keys <target> Esc
// send a prompt
herdr agent prompt <target> "продолжай"
```

Call it via `$HERDR_BIN_PATH ?? "herdr"`, as the plugin documentation
instructs. Plus: nothing breaks on herdr updates, the code is trivial.
Minus: process-spawn overhead (negligible for our traffic).

### V2 — direct JSON-RPC into the socket

Full JSON-schema is available (`herdr api schema`). We write a small RPC
client on the unix socket, method `agent.read` and the like. Faster, no
process spawning, streaming potential. We'll do it once v1 works, sparingly.

**Partially done:** live event streaming already works through this same socket
(`events.subscribe`, see "Handling herdr events" below). What remains is moving
the `agent.read / send-keys / prompt` requests from the CLI to the socket —
low priority, process-spawn overhead is negligible in our traffic.

**Open fact for implementation:** the exact `target` format for `agent read /
send-keys / prompt` — a stable agent id (from the snapshot: `pane_id`,
`terminal_id`, or name). Agents with identical names (two `kimi`s) exist in a
live snapshot, so the name is not unique — we take `pane_id`. To be verified
at the v1 stage.

## WS/HTTP API for the phone

- WS endpoint `/ws` — the main channel (JSON envelope from
  [01-architecture](01-architecture.md)).
- HTTP endpoints (handy for debugging/curl and for a simple client):
  - `GET /api/snapshot` — agents + statuses (JSON).
  - `GET /api/agents/<id>/output?lines=N&format=text|ansi` — responds with
    **plain text** (slice of the last N lines, `Content-Type: text/plain`);
    the endpoint does not return the output revision — the client gets it from
    the RPC `agent.output`/`pane.output` and from `pane.output_changed` events
    (WS/SSE), strictly increasing, and uses it to dedupe live updates.
  - `POST /api/agents/<id>/keys` `{"keys":["Esc"]}`.
  - `POST /api/agents/<id>/prompt` `{"text":"..."}`.
- `GET /healthz`.

Connection modes (matching the pair QR scheme from
[07 — Onboarding](07-onboarding.md)):

- **lan**: the relay listens on `:8375` on the LAN interface (concrete LAN-IP).
  The phone is on the same network. No infrastructure at all.
- **tailscale** (B1): the relay listens on `:8375` on the tailnet interface
  (`tailscale0`), the phone in the tailnet connects directly to
  `ws://<machine>.<tailnet>.ts.net:8375`. `tailscale serve` is not needed for
  this — the port is already reachable over WireGuard in the tailnet.
- **funnel** (B2): the relay listens on `127.0.0.1:8375`, facing outward via
  `tailscale funnel 8375` (public HTTPS on 443, the phone does not need
  Tailscale). Token is mandatory.
- **gateway** (C): the relay has no inbound port; it keeps an outbound WS
  connection to the gateway (URL+token in the config) and waits for the gateway
  to deliver the phone channel.

## Config (v1, no dependencies)

Flags/env:

```text
HERDRELAY_MODE=lan|tailscale|funnel|gateway  # default lan
HERDRELAY_LISTEN=127.0.0.1:8375              # for lan — LAN-IP, for
                                             # tailscale — tailscale0,
                                             # for funnel — 127.0.0.1
HERDRELAY_GATEWAY_URL=wss://gw.example.com/ws  # gateway only
HERDRELAY_TOKEN=<pair token>                  # generated on first start
HERDR_SOCKET=~/.config/herdr/herdr.sock
```

The pair token is generated on first start. `GET /pair` returns the available
modes with ready URLs (autodetect: LAN-IP, MagicDNS name, funnel address,
gateway from env) — see [07 — Onboarding](07-onboarding.md). The plugin prints
a QR in the herdr pane, the phone scans it. In `funnel` mode the relay invokes
`tailscale funnel <port>`; in `lan`/`tailscale` the port is available without
`serve`.

The client caches the `/pair` response in the pair profile (`PairConfig.endpoints`: the
address of each mode) — when the relay is unreachable (for example, tailscale
off at home), mode switching works from the saved addresses without the network
(see [05 — Flutter](05-flutter-app.md) → mode badge).

## What we take from the snapshot

`herdr api snapshot` returns in a single call:

- `agents[]`: `agent` (name, e.g. `codex`, `kimi`), `agent_status`
  (`idle|working|blocked|done`), `cwd`, `focused`, `pane_id`, `tab_id`,
  `terminal_id`, `terminal_title`, `workspace_id`.
- workspaces, tabs — for v2.

The app renders: name, status (blocked on top), workspace, `terminal_title`.

## Authentication

- Gateway mode: the gateway verifies the token when the relay connects; the
  relay passes the token and `relay_id`, the gateway only sends legitimate
  channels.
- Direct mode: bearer token on all endpoints.
- Invariant: no write method without a valid token.

## Handling herdr events

The relay has **one** event channel — a subscription over the herdr unix
socket (`events.subscribe`, `SocketEventRepository`). The plugin hook
(`on-event.sh` → `POST /api/events/herdr`) **was removed**: it duplicated the
statuses the socket already provides (`pane.agent_status_changed` by pane_id),
and every status change was broadcast to the client twice — see
[12-fix-plan.md](12-fix-plan.md) A1.

### Statuses and live output: socket subscription (relay → herdr)

herdr hooks do not support output events (`pane.updated`,
`pane.output_changed`, `pane.scroll_changed` — all rejected by the linker as
unknown event, verified by brute force on herdr 0.8.0). So the live
status/output is pulled by the relay directly over the herdr unix socket
(`~/.config/herdr/herdr.sock`) via the JSON-RPC subscription
`events.subscribe`:

- **`pane.updated`** (global) — learn about new panes; new pane_ids are
  delivered on reconnection with the full set of subscriptions (a second
  subscribe on a live connection kills it, herdr 0.8.0).
- **`pane.scroll_changed`** (one per pane_id) — fires when the pane's
  scrollable output changes.
- **`pane.agent_status_changed`** (one per pane_id) — agent status change.

Implementation — `internal/infrastructure/herdr/socket_event_repository.go`
(`SocketEventRepository`): keeps the connection with backoff reconnect 2s→30s,
survives herdr restarts, on start seeds pane_ids from the snapshot. The received
`pane.scroll_changed` is forwarded by the relay to clients as
`{"type":"event","event":"pane.output_changed","data":{...}}` — the client
re-reads the agent output by matching `pane_id`. The event carries no revision
(gotcha №5), so the relay attaches to `output_changed` the last known
`revision` from `pane.updated` (**strictly increasing only** — a stale revision
would make the client guard skip the live update); bursts are collapsed by
debounce on the client (400ms) and on the relay (500ms per pane).

Server output is cached (`internal/service/output_cache.go`, `AgentService`):
TTL 60 s, composite key `(paneID, lines, format)` — the `text/200` and
`ansi/500` variants do not overlap. The cache is invalidated on `pane.updated`,
`pane.output_changed` and `agent_status_changed` events (`EventService`), so
after a live update the client is guaranteed fresh output rather than a cached
one. `agent.output` / `pane.output` responses carry `revision` along with the
text (the last known revision, tracked from events): the client (Phase 2)
passes it as `knownRevision`, and if its cache is already at that revision —
the RPC for the repeated output is not made (dedup of burst events and
repeated renders).

Socket format (verified live): newline-delimited JSON-RPC 2.0, request id must
be a string. Request:

```json
{"jsonrpc":"2.0","id":"relay:events","method":"events.subscribe",
 "params":{"subscriptions":[{"type":"pane.updated"},
                            {"type":"pane.scroll_changed","pane_id":"wH:p3"},
                            {"type":"pane.agent_status_changed","pane_id":"wH:p3"}]}}
```

Notifications are flat: `{"event":"pane.scroll_changed","data":{...}}`,
`{"event":"pane.agent_status_changed","data":{...}}` and
`{"event":"pane_updated","data":{"pane":{...}}}`.

Subscription log is in `relay.err.log`: `herdr socket: connected to ... (N pane subscriptions)`.

## Running

macOS: launchd unit (`plist`), systemd for Linux — see
[04-gateway](04-gateway.md) for environments and [06-roadmap](06-roadmap.md).
Binary install/update — via the plugin's `[[build]]` (in `$HERDR_PLUGIN_ROOT/bin`).
