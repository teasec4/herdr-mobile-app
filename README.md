# herdrelay

![Go](https://img.shields.io/badge/Go-1.26-00ADD8?logo=go&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-3.12-0175C2?logo=dart&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-3.44-02569B?logo=flutter&logoColor=white)
![Platforms](https://img.shields.io/badge/Platforms-iOS%20%7C%20Android%20%7C%20macOS%20%7C%20Linux%20%7C%20Windows-blue)
![Transport](https://img.shields.io/badge/Transport-WebSocket%20%7C%20HTTP--RPC--8e44ad)
![Status](https://img.shields.io/badge/Status-working-brightgreen)

A personal relay for managing [herdr](https://herdr.dev) — a terminal workspace
manager for AI coding agents — from your phone.

Run agents on your laptop, leave the house, and from your phone watch what the
agents are doing: read terminal output, send prompts and key presses, and
answer `blocked` states.

## Stack

| Part | Tech | Lives in |
| --- | --- | --- |
| Mobile client | Flutter (iOS/Android) | `client/` |
| Relay on the laptop | Go (module `herdrelay`) | `cmd/relay/`, `internal/` |
| herdr integration | plugin `herdrelay.events` | `plugin/` |
| Docs | Markdown | `docs/` |

One QR-based onboarding supports **LAN** (same network), **Tailscale**
(direct tailnet — no port forwarding), and **Tailscale Funnel** (public HTTPS,
no Tailscale on the phone). A VPS gateway (mode C) is an optional future path.
SSH is not used as a transport (details in
[01-architecture](docs/01-architecture.md)).

## Repository layout

```
cmd/relay/     relay binary: /ws, /api/rpc, /api/events/stream (SSE), /pair,
               /healthz; `relay pair [--qr]`, `relay status` subcommands
internal/      Go layers: domain, service, infrastructure (herdr CLI + socket
               events, netdetect), transport (ws, http)
plugin/        herdr plugin: event hook, QR pairing pane, install/redeploy
client/        Flutter app: layered Transport/Protocol/Connection core
docs/          architecture, herdr API reference, refactoring plan, etc.
```

## Quick start (laptop)

```bash
# 1. Install the plugin (builds the Go relay + launchd service):
herdr plugin link "$PWD/plugin"        # local dev (no build)
bash plugin/install.sh                 # build relay + install launchd service

# 2. After changing Go code / plugin scripts / manifest, redeploy everything:
bash plugin/redeploy.sh                # build → restart service → re-link plugin → health check

# 3. Show the pairing QR for the phone:
herdr plugin action invoke show-pair-link --plugin herdrelay.events
```

The relay listens on `:8375` (`HERDRELAY_MODE=lan|tailscale|funnel`, see
`plugin/relay-lib.sh` and [03 — Relay](docs/03-relay.md)). The phone pairs by
scanning the QR or pasting the `herdrelay://pair?...` link; the app then picks
the connection mode (LAN / Tailscale) via the mode badge on the home screen.

## Mobile client

```bash
cd client
flutter test          # 148 unit/widget tests
flutter build apk --release
```

The client is layered (see [05 — Flutter app](docs/05-flutter-app.md)):
`core/transport` (WebSocket + HTTP fallback, reconnect/keepalive),
`core/protocol` (frames, request-response), `core/connection` (lifecycle,
mode service), `services/relay_client_impl.dart` (typed client for the UI).

## Documentation

- [01 — Architecture](docs/01-architecture.md) — components, transports, the wire protocol.
- [02 — herdr integration (plugin)](docs/02-herdr-integration.md) — manifest, events, install/link.
- [03 — Relay (Go)](docs/03-relay.md) — herdr socket API, the relay API, auth.
- [04 — Gateway (VPS + Docker)](docs/04-gateway.md) — optional mode C (future path).
- [05 — Flutter app](docs/05-flutter-app.md) — screens, layered core, tests.
- [06 — Roadmap & open questions](docs/06-roadmap.md).
- [07 — "Scan the QR" onboarding](docs/07-onboarding.md) — pair URL scheme, modes.
- [08 — Execution plan](docs/08-execution-plan.md).
- [09 — Refactoring plan](docs/09-refactoring-plan.md) — modular client architecture (Phases 0–5, all done).
- [10 — herdr API reference](docs/10-herdr-api.md) — the herdr 0.8.0 contract we integrate against.

## Status

End-to-end working over LAN and Tailscale against herdr 0.8.0 (protocol 19):
agent list with live status, terminal output, prompts/keys, QR pairing,
mode switching (lan/tailscale), HTTP RPC/SSE fallback endpoints on the relay,
and a Connection screen with connection testing. All client and server tests
green.
