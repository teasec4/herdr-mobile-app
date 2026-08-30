# 📱 HerdRelay

![Go](https://img.shields.io/badge/Go-1.26-00ADD8?logo=go&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-3.12-0175C2?logo=dart&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-3.44-02569B?logo=flutter&logoColor=white)
![Platforms](https://img.shields.io/badge/Platforms-iOS%20%7C%20Android%20%7C%20macOS%20%7C%20Linux%20%7C%20Windows-blue)
![Transport](https://img.shields.io/badge/Transport-WebSocket%20%7C%20HTTP--RPC--8e44ad)
![Status](https://img.shields.io/badge/Status-working-brightgreen)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> Control [herdr](https://herdr.dev) AI agents from your phone. Start agents on your laptop, leave the house, and monitor everything remotely: read terminal output, send prompts, manage workspaces.

**Perfect for**: Running long tasks, monitoring agent progress on the go, responding to blocked states from anywhere.

## ✨ Features

- 📱 **Native mobile app** (Flutter) for iOS and Android
- 🔄 **Real-time updates** via WebSocket or HTTP fallback
- 🔐 **QR-based pairing** — scan once, connect instantly
- 🌐 **Multiple connection modes with auto-fallback**: LAN, Tailscale, or public HTTPS — switches automatically when one goes unreachable
- 📊 **Full agent control**: View output, send prompts, manage workspaces
- 🔌 **Seamless integration** with herdr as a plugin
- 🧪 **Well tested**: 240+ tests across client and server

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
plugin/        herdr plugin: QR pairing pane, install/redeploy (no event
               hook — statuses/output come via the relay's socket subscription)
client/        Flutter app: layered Transport/Protocol/Connection core
docs/          architecture, herdr API reference, refactoring plan, etc.
```

## 🚀 Quick Start

### One-line install:

```bash
curl -fsSL https://raw.githubusercontent.com/yg_kovalev/herdr_relay/main/quick-start.sh | bash
```

Or manual installation:

```bash
# 1. Install the plugin
herdr plugin install yg_kovalev/herdr_relay/plugin

# 2. Show QR code for pairing
herdr plugin action invoke show-pair-link --plugin herdrelay.events

# 3. Download mobile app (Android APK from Releases)
# 4. Scan QR code with the app
```

**That's it!** Your phone is now connected.

For detailed instructions, see **[INSTALL.md](INSTALL.md)**.

## 📲 Mobile App

**Android**: Download the latest APK from [Releases](https://github.com/yg_kovalev/herdr_relay/releases)

**iOS**: Coming soon (TestFlight beta available on request)

### Build from source:

```bash
cd client
flutter pub get
flutter test          # 241 unit/widget tests
flutter build apk --release
```

The client uses a layered architecture (see [05 — Flutter app](docs/05-flutter-app.md)):
- `core/transport` — WebSocket + HTTP fallback, reconnect/keepalive
- `core/protocol` — frames, request-response
- `core/connection` — lifecycle, mode service, auto-fallback manager
- `services/relay_client_impl.dart` — typed client for UI

## 🔌 Connection Modes

HerdRelay automatically detects available connection modes:

| Mode | When to use | Setup required |
|------|-------------|----------------|
| **LAN** | Same WiFi network | None (automatic) |
| **Tailscale** | Anywhere with Tailscale | Install Tailscale on both devices |
| **Funnel** | No Tailscale on phone | Run `tailscale funnel 8375` on laptop |
| **Gateway** (optional) | VPS for max security | Deploy gateway (see docs) |

Switch modes anytime:
```bash
bash plugin/configure.sh tailscale  # or lan, funnel, gateway
```

## 📚 Documentation

**Getting Started:**
- **[INSTALL.md](INSTALL.md)** — Detailed installation and setup guide
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — How to contribute to the project
- [07 — QR Onboarding](docs/07-onboarding.md) — How pairing works

**Architecture & Design:**
- [01 — Architecture](docs/01-architecture.md) — Components, transports, wire protocol
- [02 — herdr Integration](docs/02-herdr-integration.md) — Plugin manifest and events
- [03 — Relay (Go)](docs/03-relay.md) — Server implementation and API
- [05 — Flutter App](docs/05-flutter-app.md) — Client architecture and tests

**Advanced:**
- [04 — Gateway (VPS)](docs/04-gateway.md) — Optional VPS mode
- [06 — Roadmap](docs/06-roadmap.md) — Future plans
- [10 — herdr API Reference](docs/10-herdr-api.md) — herdr 0.8.0 integration contract

## 🛠️ Development

```bash
# Clone repository
git clone https://github.com/yg_kovalev/herdr_relay.git
cd herdr_relay

# Link plugin for development
herdr plugin link "$PWD/plugin"
bash plugin/install.sh

# After making changes, redeploy
bash plugin/redeploy.sh

# Run tests
go test ./...                    # Go tests
cd client && flutter test        # Flutter tests (241 tests)
```

See **[CONTRIBUTING.md](CONTRIBUTING.md)** for detailed development guidelines.

## ❓ Troubleshooting

**Relay not starting?**
```bash
# Check service status
launchctl list | grep herdrelay

# View logs
tail -f ~/.local/state/herdrelay/relay.err.log
```

**Phone can't connect?**
- Verify both devices on same network (LAN mode)
- Check firewall isn't blocking port 8375
- Try rescanning the QR code

For more help, see [INSTALL.md](INSTALL.md#troubleshooting) or open an [issue](https://github.com/yg_kovalev/herdr_relay/issues).

## 🌐 Best Practices for Remote Access

### Setup Checklist

**Before first pairing:**

1. Install Tailscale on the laptop: `brew install tailscale && sudo tailscale up`
2. Install the Tailscale app on the phone
3. Restart the relay: `bash plugin/redeploy.sh`
4. Scan the QR code — all modes are saved automatically

**Switching networks:**

- At home: **LAN** (fastest)
- Away: **Tailscale** (automatic fallback)
- Without Tailscale: **Funnel** (public HTTPS)

### Troubleshooting

**Problem: "Can't connect when away from home"**

Solution:

1. Open the Connection page → "Switch mode manually"
2. Select "Tailscale"
3. Enter your relay hostname (e.g., `mac.tailnet.ts.net`)
4. Connect

**Problem: "Only LAN mode available"**

This means Tailscale wasn't running during QR generation.

Solution:

1. On the laptop: `sudo tailscale up`
2. Restart the relay: `bash plugin/redeploy.sh`
3. On the phone: open the Connection page → "Refresh modes"
4. Select the Tailscale mode

## 🤝 Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for:
- Development setup
- Code style guidelines  
- Testing requirements
- Pull request process

## 📄 License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for details.

## 🙏 Acknowledgments

- [herdr](https://herdr.dev) — Terminal workspace manager for AI agents
- [Tailscale](https://tailscale.com) — Zero-config VPN for remote access
- Flutter community for excellent mobile framework

## 📊 Status

✅ **Production ready** for LAN and Tailscale modes  
✅ End-to-end tested against herdr 0.8.0 (protocol 19)  
✅ All tests passing (Go + Flutter)

**Current features:**
- Real-time agent status and terminal output
- Send prompts and keypresses from phone
- QR-based pairing with multiple profiles
- Auto-reconnection and connection testing
- Automatic fallback between connection modes (tailscale → lan → funnel)
- Manual mode with live reachability check
- Universal QR — one code offers every available mode
- HTTP RPC/SSE fallback for restrictive networks

---

**Questions?** Open a [Discussion](https://github.com/yg_kovalev/herdr_relay/discussions) or check [existing issues](https://github.com/yg_kovalev/herdr_relay/issues).
