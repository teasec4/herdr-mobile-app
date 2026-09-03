# 06 — Work Plan, Phases, Open Questions

## Phases

### Phase 0 — Research and Design (closed)

- [x] Studied herdr 0.8.0: socket API (`herdr api schema`, protocol 19),
      JSON-RPC CLI output, plugin events.
- [x] Broke down the plugin mechanism (manifest, install/link, `HERDR_BIN_PATH`).
- [x] References: `0cv/herdr-mobile-relay` (transports, gateway, event),
      `persiyanov/herdr-reviewr` (manifest), moshi (SSH approach).
- [x] Docs 01–08 written (draft, refining together).

### Phase 1 — MVP "working and simple" — ✅ closed (LAN; B1 not verified)

1. [x] **Relay (Go, `cmd/relay`)**: `lan`/`tailscale`/`funnel`/`gateway` modes;
   reads `herdr api snapshot`, serves `GET /api/snapshot`,
   `POST agents/<id>/keys|prompt`, WS channel, auth token, `GET /pair`
   (available modes + ready URLs).
2. [x] **"Scan-and-works" onboarding**: the relay generates a token, the plugin's
   wizard pane prints a QR (`herdrelay://pair?...`, auto-detect of mode A→B1→B2),
   the app scans and connects.
3. [x] **Flutter app** (`client/`): onboarding QR scan / link paste,
   agent list, details-terminal (text), prompt/keys input.
4. [x] **herdr plugin**: `herdr-plugin.toml` (build + event + "show QR"
   action), relay launched via launchd.
5. [~] **End-to-end test**: phone at home over LAN (mode A) — passed live
   (statuses, output, prompt). Via tailnet from outside (B1) — **not verified**.
6. [ ] **Gateway (Go, `cmd/gateway`) + Docker deployment** — mode C. Not part of
   the MVP.

MVP readiness criterion: from the phone (at home over LAN or via tailnet from
outside) you can see agent statuses and write to the terminal
(`send-keys`/`prompt`).
**Reached over LAN (live, from the phone); tailnet (B1) still needs to be verified.**

### Phase 2 — Convenience

- [x] `pane.agent_status_changed` event → instant updates (no polling).
- [x] **B-lite: live terminal output** — the relay keeps a herdr socket
  subscription (`events.subscribe` on `pane.updated` + `pane.scroll_changed`),
  forwards to clients as `pane.output_changed`; the client re-reads output with
  debounce. Not a PTY stream, but "almost live" (see
  [03-relay](03-relay.md) and [01-architecture](01-architecture.md)).
- [~] ANSI colors and dark theme — done with a custom SGR parser
  (`client/lib/widgets/ansi_terminal.dart`); `flutter_xterm` and true
  scrollback — ahead.
- [x] Local notifications when blocked (v1: background only,
  `NotificationService`, tap → opens agent; see 05 — Flutter).
- [ ] `tailscale funnel` (B2) as an option for phones without Tailscale.
- [ ] Auto-switching / mode hint based on network availability.

### Phase 3 — Hardening (optional)

- End-to-end encryption phone↔relay (the gateway becomes truly blind), token
  rotation.
- Real push via FCM/APNs (gateway → push when blocked).
- Multiple machines/workspaces, history, answers to agents' structured questions
  (Codex/Claude Code approve-flow).
- Relay's direct JSON-RPC into the herdr socket instead of subprocess: events
  already go this way (socket subscription), requests remain.

## Open Questions (Decisions, ADR-lite)

| # | question | options | recommendation |
| --- | --- | --- | --- |
| 1 | Default transport | LAN / Tailscale (B1+B2) / Gateway (C) | ✅ closed: MVP = A + B1 (LAN works live; B1 not verified) |
| 2 | Relay launch | launchd service / plugin `[[startup]]` | ✅ closed: launchd service |
| 3 | Relay–herdr link | subprocess CLI / direct JSON-RPC | hybrid: requests — subprocess (v1), events — already via socket-RPC (subscription) |
| 4 | VPS region | Japan / closer to home | closer to home network (terminal latency) |
| 5 | E2E encryption | now / phase 3 | phase 3 (v1 — TLS + trusted private VPS) |
| 6 | Phone terminal | text + ANSI strip / `flutter_xterm` | v1 = custom SGR parser (`ansi_terminal.dart`, dark theme, softWrap); v2 xterm |
| 7 | Push | local / FCM | v1 local (not yet implemented), v3 FCM |
| 8 | Monorepo | yes / separate repos | monorepo: `cmd/{relay,gateway}`, `client/`, `plugin/` |
| 9 | B2 (Tailscale Funnel) | available on plan / no | verify during implementation; B2 does not block MVP (A+B1 is enough) |

## Deliberately Out of Scope

- Full 0cv transports (WebRTC P2P, Cloudflare tunnel, community gateway) —
  LAN/Tailscale is enough for us, the gateway is optional.
- SSH as a transport — not used: we need structured statuses + a terminal over
  WS with a token, not PTY access to the machine (see
  [01-architecture](01-architecture.md)).
- Multi-user support, a public marketplace, web version (PWA) — not what a
  personal tool is about.
- Laptop sleep issue: the relay does not wake a sleeping laptop.