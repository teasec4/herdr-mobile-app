# 01 — Architecture

## Context: what herdr already has

Herdr 0.8.0 (installed locally, `~/.local/bin/herdr`) is not just a TUI.
Behind it runs a headless server that listens on a **unix socket**
`~/.config/herdr/herdr.sock` (macOS) over JSON-RPC, protocol 19.

Key facts (verified locally):

- The CLI is a thin JSON-RPC client over the socket: `herdr api snapshot`,
  `herdr agent list` return ready-made JSON `{"id":..., "result":{...}}`.
- Agent management: `agent list/get/read/send-keys/prompt/attach/start/wait`.
- Agent statuses: `idle / working / blocked / done / unknown`.
- Machine contract: `herdr api schema` dumps the full JSON schema
  (the same file in the herdr repo: `docs/next/api/herdr-api.schema.json`).
- Events for push notifications: the herdr plugin can subscribe to
  `pane.agent_status_changed` (see [02](02-herdr-integration.md)).
- The socket itself supports **output events** (`events.subscribe`), which the
  plugin hook mechanism does not — this is what the live terminal is built on
  (B-lite, see [03-relay](03-relay.md)).

Conclusion: **herdr already knows how to do everything needed for remote
control**. Our job is a thin translator between the herdr socket and the phone.

## Components

```
   MODE A — LAN: phone on the same network as the laptop, no Tailscale or VPS
   phone ──ws://192.168.x.x:8375──► cmd/relay ──JSON-RPC──► herdr.sock

   MODE B — Tailscale (laptop already in a tailnet)
   B1 tailnet: phone ──ws://<machine>.ts.net:8375──► cmd/relay
               (phone also in the tailnet; direct port over WireGuard)
   B2 funnel:  phone ──https://<machine>.ts.net──► tailscale funnel ──► cmd/relay
               (phone does not need Tailscale, public address on 443)

   MODE C — Gateway on a VPS (option, for access without Tailscale at all)
   phone ──wss──► cmd/gateway (Docker + Caddy TLS) ◄──wss── cmd/relay ──► herdr.sock
   both ends (phone and relay) — outbound connections, NAT does not interfere
```

- **Go relay** — the only process on the laptop that can talk to the herdr
  socket. It exposes a WS/HTTP API for the phone on the selected interface (LAN /
  tailnet) and/or connects to the gateway itself via an outbound connection
  (mode C).
- **Gateway** — a separate process (Go, Docker) on a VPS, **optional** (mode
  C). Both ends (phone and relay) connect to it via **outbound** connections,
  so the laptop needs no open port, and NAT/firewalls are not an obstacle.
- **Flutter app** — the client: agent list, terminal, input, statuses.
- **herdr plugin** — a thin wrapper: registers the
  `pane.agent_status_changed` event (instant broadcast of blocked/finished),
  the "show pairing QR/link" actions, and starts the relay. Live output is
  **not a hook**: herdr hooks cannot handle output events
  (`pane.updated` → unknown event), so live output goes through the relay's own
  socket subscription (`pane.output_changed`).

## Transport: three modes — one QR

The same relay, the same protocol; only the address that goes into the pairing
QR link changes (details — [07 — Onboarding](07-onboarding.md)).

| mode | address in QR | when | infrastructure |
| --- | --- | --- | --- |
| **A. LAN** | `ws://<lan-ip>:8375` | phone and laptop on the same Wi-Fi | none |
| **B1. Tailscale (tailnet)** | `ws://<machine>.<tailnet>.ts.net:8375` | phone in the same tailnet (Tailscale on the phone) | Tailscale on the laptop only |
| **B2. Tailscale Funnel** | `https://<machine>.<tailnet>.ts.net` | phone does not need Tailscale; public address | `tailscale funnel 8375` |
| **C. Gateway (VPS)** | `wss://gw.example.com/ws` | access without Tailscale at all, from any network | VPS + Docker |

- **A + B1 = MVP.** They cover the personal "left home" scenario: phone with
  Tailscale, laptop with Tailscale — a direct WireGuard connection, zero
  infrastructure, low latency. A is verified live; B1 is not yet.
- **B2** — a bonus for cases where the phone has no Tailscale (public HTTPS
  on 443, token required).
- **C** — an option for advanced users: access without Tailscale entirely,
  with the possibility of FCM push from the cloud. Not part of the MVP.

**Decision 1 (revised):** the gateway used to be the "primary" transport —
now it is an **option** (mode C). The primary path: A at home, B1 from outside.
The VPS region (if needed) — closer to the laptop's home network to reduce
live-terminal latency.

## Why not SSH

Intuitively, "controlling a terminal from a phone" = SSH, but it is a different
tool for a different task:

- SSH requires a running `sshd` on the laptop, a real account and key/password,
  and an open port (or forwarding) — extra attack surface and administration.
- SSH gives only a live PTY. We need **structured** statuses
  (blocked/working/done), an agent list, workspaces, and output slices — SSH
  cannot provide these; a layer over the herdr API is needed. Our relay is that
  layer.
- The relay covers both needs over a single WS channel with a token from the
  QR: a live terminal (output slices + `send-keys`/`prompt`) and structured
  data. Cheaper and safer than SSH: one "token ↔ laptop" pair, without
  accounts, keys, and open ports.
- moshi uses SSH because it is a universal way to open a terminal on an
  arbitrary machine. For us, the terminal is not an end in itself — the goal is
  controlling herdr agents. If we want the feel of a real PTY (Esc sequences,
  full-screen TUI) — we stream `herdr agent attach`/PTY over the same WS;
  that is not SSH.

## Protocol: JSON over WebSocket

One persistent WS channel phone↔relay (through the gateway or directly). Frames
are a JSON envelope:

```jsonc
// request from the client
{"type":"request","id":1,"method":"agents.list","params":{}}
// relay response
{"type":"response","id":1,"ok":true,"result":{"agents":[...]}}
// error
{"type":"response","id":1,"ok":false,"error":{"code":"...","message":"..."}}
// event from the relay (push-like)
{"type":"event","event":"agent_status_changed","data":{...}}
// heartbeat
{"type":"ping"}
```

v1 methods (a thin slice of what herdr has):

| method | what it does | under the hood |
| --- | --- | --- |
| `agents.snapshot` | the full agent list + statuses + workspaces | `herdr api snapshot` |
| `agent.output` | a slice of terminal output (text/ansi, N lines) | `herdr agent read` |
| `agent.keys` | send keys (Esc, Ctrl-C, text) | `herdr agent send-keys` |
| `agent.prompt` | send a prompt | `herdr agent prompt` |
| `ping` | keepalive | — |

Events (from the relay): `agent_status_changed` (from/to), `agents.changed`
(structure changed), `pane.output_changed` (live output — data
`{pane_id, workspace_id}`, the client re-reads `agent.output`). Snapshot
polling every 1–2 s remains as a fallback if an event does not arrive.

## "Live terminal" data flow

- The relay keeps a socket subscription to herdr (`events.subscribe`:
  `pane.updated` + `pane.scroll_changed`), see [03-relay](03-relay.md). On
  scroll change, the relay sends the client the `pane.output_changed` event;
  the client re-reads `agent.output` (the last N lines slice) with a ~400 ms
  debounce and renders with auto-scroll. This is "live-like", but not a
  sub-100ms PTY like moshi over SSH.
- Fallback: a periodic re-snapshot/re-read every 1–2 s if an event does not
  arrive.
- Control: `agent.keys` / `agent.prompt` are sent instantly.

## Security (v1)

- Token authorization on the relay and (in mode C) on the gateway — the
  pairing secret.
- The pairing link (URL + token) is a secret; the QR is shown in the herdr
  pane only on request, and the token is rotated.
- The relay listens **only on the required interface**: in A — on the LAN IP,
  in B1 — on `tailscale0`, in B2/C — on `127.0.0.1` (the funnel/gateway faces
  outward). Public modes (B2, C) are unavailable without a token.
- TLS: B2 (the funnel itself provides HTTPS on 443) and C (phone↔gateway and
  relay↔gateway — WSS). In A/B1 traffic goes within a trusted network/WireGuard.
  In v1 the gateway is trusted (own VPS); end-to-end E2E encryption is phase 3.
