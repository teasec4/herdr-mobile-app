# herdrelay

![Go](https://img.shields.io/badge/Go-1.26-00ADD8?logo=go&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-3.12-0175C2?logo=dart&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-3.44-02569B?logo=flutter&logoColor=white)
![Platforms](https://img.shields.io/badge/Platforms-iOS%20%7C%20Android%20%7C%20macOS%20%7C%20Linux%20%7C%20Windows-blue)
![Transport](https://img.shields.io/badge/Transport-WebSocket-8e44ad)
![Status](https://img.shields.io/badge/Status-backend%20done%20%7C%20client%20in%20dev-yellow)

A personal relay for managing [herdr](https://herdr.dev) — a terminal workspace
manager for AI coding agents — from your phone.

Run agents on your laptop, leave the house, and from your phone watch what the
agents are doing: read terminal output, send prompts and key presses, and
answer `blocked` states.

## Stack

| Part | Tech | Lives in |
| --- | --- | --- |
| Mobile client | Flutter (iOS/Android) | `client/` |
| Relay on the laptop | Go (module `herdrelay`) | `cmd/relay/` |
| Gateway (VPS, **optional**) | Go + Docker | `cmd/gateway/`, `deploy/` |
| herdr integration | plugin `herdr-plugin.toml` | `plugin/` |
| Docs | Markdown | `docs/` |

One QR-based onboarding ("point and it works") supports three transport modes:
**A. LAN** (same network), **B. Tailscale** (direct tailnet / public Funnel),
**C. Gateway** on a VPS (optional). SSH is not used as a transport (details in
[01-architecture](docs/01-architecture.md)).

## Documentation

- [01 — Architecture](docs/01-architecture.md) — components, the three transports, the protocol.
- [02 — herdr integration (plugin)](docs/02-herdr-integration.md) — how the plugin hooks into herdr: manifest, events, install/link.
- [03 — Relay (Go)](docs/03-relay.md) — herdr socket API, the WS API, auth.
- [04 — Gateway (VPS + Docker)](docs/04-gateway.md) — blind relay, VPS deployment (mode C).
- [05 — Flutter app](docs/05-flutter-app.md) — screens, packages, notifications.
- [06 — Roadmap & open questions](docs/06-roadmap.md) — phases, out of scope, ADRs.
- [07 — "Scan the QR" onboarding](docs/07-onboarding.md) — pair URL scheme, modes, OSS flow.
- [08 — Execution plan](docs/08-execution-plan.md) — loops, checkpoints, verification.

## Status

Backend (Go relay + herdr plugin) is working end-to-end. The Flutter client has
the core screens implemented — pair via QR, agent list, terminal details — with
unit and widget tests green; the end-to-end gate on a real phone is still
ahead. See the [roadmap](docs/06-roadmap.md) and the
[execution plan](docs/08-execution-plan.md).
