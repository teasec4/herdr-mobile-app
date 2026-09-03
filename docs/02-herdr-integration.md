# 02 — Integration with herdr: how the plugin is wired up

This document answers the question "how the plugin is registered with herdr".
Everything below is verified against the official herdr documentation
(`docs/.../plugins.mdx`, `cli-reference`) and against live examples:
`persiyanov/herdr-reviewr` and `0cv/herdr-mobile-relay`. Items marked
"verified live" were confirmed on a real herdr 0.8.0 while developing this
relay (loop L4).

## Plugin model (in short)

A herdr plugin is **just a directory with a `herdr-plugin.toml` manifest and
commands**. There is no SDK or special language: a plugin can be a Bash script,
a JS application, a Rust/Go/Python binary, anything the machine can execute.
The entire herdr CLI is the plugin API: inside its commands the plugin calls
`herdr ...` through the `HERDR_BIN_PATH` environment variable (it points to the
running herdr binary, portable between the unix socket and the named pipe).
Those who want to can send raw JSON-RPC straight into the socket.

The herdr core is written in Rust and behaves as a "host": it owns installation,
manifest validation, hotkeys, terminal panes, events, and the socket. The plugin
owns its own logic, dependencies, and state.

## The `herdr-plugin.toml` manifest

Required fields: `id`, `name`, `version`, `min_herdr_version`.
Optional: `platforms`, `description`.

Hook sections we care about:

| section | purpose |
| --- | --- |
| `[[build]]` | commands at install time (download a binary, build, `npm ci`) |
| `[[startup]]` | commands when herdr starts (autostart) |
| `[[actions]]` | actions in the herdr menu, can be bound to a hotkey in `config.toml` |
| `[[events]]` | reactions to herdr events (e.g. `pane.agent_status_changed`) |
| `[[panes]]` | herdr-managed terminal panes (setup menu, QR) |
| `[[link_handlers]]` | link handlers (not needed for us) |

Example from the herdr documentation:

```toml
id = "example.layout"
name = "Layout"
version = "0.1.0"
min_herdr_version = "0.7.0"
platforms = ["linux", "macos"]

[[events]]
on = "worktree.created"
command = ["herdr", "workspace", "list"]

[[panes]]
id = "board"
title = "Project board"
placement = "overlay"
command = ["herdr-board"]
```

`command` is an argv array, no shell involved (if you need a shell — run it
yourself).

## Installation and linking

```bash
# from GitHub (shorthand owner/repo[/subdir]):
herdr plugin install teasec4/herdr-mobile-app/plugin
# locally during development:
herdr plugin link ~/herdr-relay/plugin
# check/manage:
herdr plugin list
herdr plugin action list --plugin herdrelay.events
herdr plugin log list --plugin herdrelay.events
```

Installing from GitHub: herdr clones the repo into
`~/.config/herdr/plugins/github/<id>-<hash>/`, shows a preview (in the
interactive terminal), runs `[[build]]`, and registers the plugin.
Reinstalling replaces the checkout. `herdr plugin install` only understands
GitHub shorthand. Installed and linked plugins are global to the user and
available in all herdr sessions.

**Verified live:** `herdr plugin link` worked, `herdrelay.events` shows up in
`herdr plugin list` as `enabled [local:...]`. On linking (unlike `install`)
herdr **does not run** `[[build]]` — locally the relay is installed manually:
`bash plugin/install.sh` (details in "Running the relay").

## What we actually need from the plugin

The relay itself is a **separate Go process**, it does not live inside herdr.
The plugin is needed as a thin wrapper for two things:

1. **Pairing.** The "show QR" action (`show-pair-link`) and the `setup` pane —
   convenient to scan once from the phone instead of typing URL + token by hand.
   QR = custom-scheme link `herdrelay://pair?...` with automatic mode detection
   (LAN / Tailscale / gateway); the URL comes from the relay's `GET /pair` — see
   [07 — Onboarding](07-onboarding.md). The QR is rendered by the
   `herdrelay pair --qr` subcommand (ANSI half-blocks straight into the herdr
   terminal).

2. **Installing/starting the relay.** `[[build]]` → `install.sh` builds the Go
   relay into `bin/herdrelay` and installs the launchd service (see "Running
   the relay").

**Live status and output — NOT through the plugin (statuses used to go through
a hook, now socket only).** The herdr hook system has no event for terminal
output: `pane.updated`, `pane.output_changed`, `pane.scroll_changed` are
rejected by the linker as unknown events (verified by brute force on herdr
0.8.0). Statuses used to be duplicated: via the `on-event.sh` hook
(`POST /api/events/herdr`) **and** via a socket subscription. The socket is
self-sufficient (`events.subscribe` includes `pane.agent_status_changed` per
pane_id), so the hook and the `/api/events/*` HTTP routes were removed — one
status change = one event to the client (see `docs/12-fix-plan.md` A1).
Implementation: `internal/infrastructure/herdr/socket_event_repository.go` and
[03-relay.md](03-relay.md) → "Handling herdr events". The plugin does not
participate in this scheme at all.

The implemented manifest (`plugin/herdr-plugin.toml`):

```toml
id = "herdrelay.events"
name = "Herdr Mobile"
version = "0.1.0"
description = "Remote control for Herdr: monitor and check agents from your phone over LAN/Tailscale"
platforms = ["macos", "linux"]

# build the Go relay into bin/ and install the launchd service (macOS)
[[build]]
command = ["bash", "install.sh"]

# no [[events]] hook: the relay receives statuses and live output directly over
# herdr's unix socket (events.subscribe) — see "Live status and output" below.

# "Show QR" — opens the setup pane with the pairing link/QR
[[actions]]
id = "show-pair-link"
title = "Herdr Mobile: show phone link / QR"
command = ["bash", "open-pane.sh", "setup"]

[[panes]]
id = "setup"
title = "Herdr Mobile: Setup"
placement = "zoomed"
command = ["bash", "setup-menu.sh"]
```

On `id`: dots are allowed inside a plugin id (`herdrelay.events`), but not
inside action/pane ids; herdr qualifies them as `plugin.id.action`.

## Running the relay: plugin vs. service

There were two approaches (Decision 2). **Closed: A was chosen — the relay is
a system service.**

- **A. Relay = system service** (launchd on macOS / systemd on Linux).
  The plugin is only for events, QR, and installation. Lifecycle management is
  predictable, the relay survives herdr restarts. ← **implemented:**
  `install.sh` builds `bin/herdrelay` and installs
  `~/Library/LaunchAgents/com.herdrelay.relay.plist` (RunAtLoad + KeepAlive,
  logs in `${XDG_STATE_HOME:-$HOME/.local/state}/herdrelay/`, env
  `HERDRELAY_MODE=lan`), default port 8375 (env `HERDRELAY_PORT`).
- **B. Relay = `[[startup]]` hook** of the plugin, starts together with herdr.
  Simpler to install (one `plugin install`), but the lifecycle is tied to herdr
  — rejected.

Service check (verified live):
```bash
launchctl print gui/$(id -u)/com.herdrelay.relay  # state=running, pid, log paths
curl -s localhost:8375/healthz                    # {"ok":true}
```

## herdr events: what was verified live

- **`pane.agent_status_changed`** — agent status change. It reaches the relay
  over the unix socket (`events.subscribe` with a per-pane subscription), not
  through a plugin hook (the hook was removed — it duplicated the socket, see
  `docs/12-fix-plan.md` A1). Confirmed on a real herdr 0.8.0: the WS client
  received the event with full `data` (pane_id, agent_status, agent,
  display_agent, workspace_id, title).
- `worktree.created` — a reviewer case, not needed for us.

Status and output events come only through the socket, not through a hook. The
linker rejects all output event names (`pane.updated`, `pane.output_changed`,
`pane.scroll_changed`): `herdr plugin link` → warning "unknown event". Verified
on herdr 0.8.0. Live status/output works via the relay's JSON-RPC subscription
over the unix socket: `events.subscribe` with `pane.updated` (global),
`pane.scroll_changed` and `pane.agent_status_changed` per pane_id;
notifications arrive as `{"event":"pane.scroll_changed","data":{...}}` (data:
pane_id, scroll.max_offset_from_bottom, offset_from_bottom, viewport_rows),
`{"event":"pane.agent_status_changed","data":{...}}` and
`{"event":"pane_updated","data":{"pane":{...}}}`. The request/response format
and the socket dialect are in [03-relay.md](03-relay.md) → "Handling herdr
events".

Previously statuses also came via a plugin hook (`on-event.sh` → `POST
/api/events/herdr`, env contract `HERDR_PLUGIN_EVENT_JSON`), which produced two
events per single change. The hook and the `/api/events/*` routes were removed —
the socket is self-sufficient (`pane_updated` on subscription lists existing
panes).

The full list of available events is refined against the herdr schema/docs
during implementation (in `docs/next/.../plugins.mdx` and `cli-reference`).

## Links

- The official plugin documentation lives here:
  `<herdr repo>/docs/next/website/src/content/docs/plugins.mdx`.
- `herdr api schema` — the full socket contract (the same thing in the herdr
  repo: `docs/next/api/herdr-api.schema.json`).
- References: `persiyanov/herdr-reviewr` (Rust plugin, manifest with build/panes/
  actions/events), `0cv/herdr-mobile-relay` (Go plugin + event + service).
