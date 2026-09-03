# Herdr Mobile plugin (`herdrelay.events`)

A [herdr](https://herdr.dev) plugin that connects herdr on your laptop to your
phone through a separate Go process — the **relay** (`cmd/relay/`). The plugin
is a thin wrapper: the relay lives on its own as a system service (launchd),
and the plugin handles QR-based phone pairing and relay installation. Live
agent statuses and terminal output are NOT delivered through a plugin hook —
the relay subscribes to herdr's unix socket directly (`events.subscribe`,
`internal/infrastructure/herdr/socket_event_repository.go`), so the plugin
has no `[[events]]` entry point (a hook used to duplicate socket-delivered
statuses; see `docs/12-fix-plan.md` A1).

## How the plugin talks to herdr

A herdr plugin is **just a directory with a `herdr-plugin.toml` manifest and
scripts**. There is no SDK: herdr registers the manifest and runs its commands
as plain processes. Inside the commands we call `herdr ...` through the
`HERDR_BIN_PATH` env var (points at the running herdr binary).

The manifest registers three entry points (see `herdr-plugin.toml`):

| Section | Script | When herdr calls it |
| --- | --- | --- |
| `[[build]]` | `install.sh` | on `herdr plugin install` (not on `link`) |
| `[[actions]]` | `open-pane.sh setup` | from the herdr menu / hotkey: "Show QR" |
| `[[panes]]` | `setup-menu.sh` | when the `setup` pane opens (zoomed in herdr's terminal) |

### QR pairing: phone -> pair

The "Show QR" action (`show-pair-link`) opens the `setup` pane: `open-pane.sh`
calls `herdr plugin pane open --entrypoint setup`, herdr opens a zoomed pane,
and `setup-menu.sh` prints the relay status and a QR code with the pairing
link. The relay generates the QR itself (`herdrelay pair --qr`, ANSI
half-blocks straight into the terminal):

```
herdr menu: "Herdr Mobile: show phone link / QR"
  └─> open-pane.sh setup
        └─> herdr plugin pane open --entrypoint setup --placement zoomed
              └─> setup-menu.sh
                    ├─> curl 127.0.0.1:8375/healthz        (relay status)
                    └─> herdrelay pair --qr                 (QR herdrelay://pair?...)
                          └─> phone scans the QR and connects over WS
```

### Relay installation

`install.sh` builds the Go relay from the repo root into `bin/herdrelay` and
installs the launchd service `com.herdrelay.relay` (RunAtLoad + KeepAlive,
port 8375 by default). The relay is a **system service**, not a herdr process:
it survives herdr restarts.

## Install and link

```bash
# local development (herdr does not run build on link):
herdr plugin link ~/herdr-relay/plugin
bash plugin/install.sh                  # build the relay + launchd service

# from GitHub:
herdr plugin install teasec4/herdr-mobile-app/plugin

# checks:
herdr plugin list
herdr plugin action list --plugin herdrelay.events
herdr plugin log list --plugin herdrelay.events
```

The token used for event forwarding lives in
`~/.config/herdr/herdrelay.token` (the same one the relay puts into the QR
pairing link). Override with env `HERDRELAY_TOKEN_FILE`.

## Files

| File | Role |
| --- | --- |
| `herdr-plugin.toml` | manifest: registers build/actions/panes (no `[[events]]`) |
| `install.sh` | `[[build]]`: build the relay + install the launchd service |
| `open-pane.sh` | `[[actions]]`: open a plugin pane by id |
| `setup-menu.sh` | `[[panes]]`: pane with relay status and the pairing QR |
| `redeploy.sh` | dev loop: rebuild relay + restart service + re-link plugin |
| `bin/herdrelay` | built Go relay (artifact of `install.sh`) |

## Redeploy after code changes

After changing Go code, hook scripts, or `herdr-plugin.toml`, apply everything
with one command (rebuilds the relay, restarts the launchd service, re-links
the plugin so herdr re-reads the manifest/scripts, then health-checks):

```bash
bash plugin/redeploy.sh
# → building relay binary...
# → restarting launchd service (com.herdrelay.relay)...
# → re-linking herdr plugin (herdrelay.events)...
# ✓ relay is up on :8375
# ✓ /api/rpc agents.snapshot ok
```

Recommended entry point from the repo root (same engine, plus a status summary,
and a staleness check that warns when the binary is older than the sources):

```bash
./relay-status.sh update
```

The phone reconnects as-is: the pairing link/token do not change on redeploy.

Deep dive into the plugin model, the manifest, and installing into herdr — see
[docs/02-herdr-integration.md](../docs/02-herdr-integration.md).