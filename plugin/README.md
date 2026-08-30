# HerdRelay plugin (`herdrelay.events`)

A [herdr](https://herdr.dev) plugin that connects herdr on your laptop to your
phone through a separate Go process — the **relay** (`cmd/relay/`). The plugin
is a thin wrapper: the relay lives on its own as a system service (launchd),
and the plugin handles three things: instant events, QR-based phone pairing,
and relay installation.

## How the plugin talks to herdr

A herdr plugin is **just a directory with a `herdr-plugin.toml` manifest and
scripts**. There is no SDK: herdr registers the manifest and runs its commands
as plain processes. Inside the commands we call `herdr ...` through the
`HERDR_BIN_PATH` env var (points at the running herdr binary).

The manifest registers four entry points (see `herdr-plugin.toml`):

| Section | Script | When herdr calls it |
| --- | --- | --- |
| `[[build]]` | `install.sh` | on `herdr plugin install` (not on `link`) |
| `[[events]]` | `on-event.sh` | whenever a local agent changes status |
| `[[actions]]` | `open-pane.sh setup` | from the herdr menu / hotkey: "Show QR" |
| `[[panes]]` | `setup-menu.sh` | when the `setup` pane opens (zoomed in herdr's terminal) |

### Events: agent status -> phone

Whenever a local agent changes status, herdr fires the
`pane.agent_status_changed` event. The data reaches the `on-event.sh` hook via
env **`HERDR_PLUGIN_EVENT_JSON`** (format `{"data":{...}}` — the event name is
not passed, it is fixed by the manifest). The hook forwards the raw JSON to the
relay over local HTTP, and the relay pushes it to every connected WS client —
the phone:

```
herdr: agent changed status
  └─> [[events]] pane.agent_status_changed
        └─> on-event.sh        (env HERDR_PLUGIN_EVENT_JSON)
              └─> POST http://127.0.0.1:8375/api/events/herdr
                    (Authorization: Bearer <token from ~/.config/herdr/herdrelay.token>)
                    └─> relay (Go) ──WS──> Flutter app on the phone
```

So blocked/finished states appear instantly instead of via polling. If the
relay is not running or the token is missing, the hook exits quietly (code 0)
so it does not spam the herdr log.

### QR pairing: phone -> pair

The "Show QR" action (`show-pair-link`) opens the `setup` pane: `open-pane.sh`
calls `herdr plugin pane open --entrypoint setup`, herdr opens a zoomed pane,
and `setup-menu.sh` prints the relay status and a QR code with the pairing
link. The relay generates the QR itself (`herdrelay pair --qr`, ANSI
half-blocks straight into the terminal):

```
herdr menu: "HerdRelay: show phone link / QR"
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
herdr plugin link /Users/yg_kovalev/go/herdr_relay/plugin
bash plugin/install.sh                  # build the relay + launchd service

# from GitHub:
herdr plugin install yg_kovalev/herdr_relay/plugin

# checks:
herdr plugin list
herdr plugin action list --plugin herdrelay.events
herdr plugin log list --plugin herdrelay.events
```

The token used for event forwarding lives in
`~/.config/herdr/herdrelay.token` (the same one the relay puts into the QR
pairing link). Override with env `HERDR_RELAY_TOKEN_FILE`.

## Files

| File | Role |
| --- | --- |
| `herdr-plugin.toml` | manifest: registers build/events/actions/panes |
| `install.sh` | `[[build]]`: build the relay + install the launchd service |
| `on-event.sh` | `[[events]]`: forward `pane.agent_status_changed` to the relay |
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

The phone reconnects as-is: the pairing link/token do not change on redeploy.

Deep dive into the plugin model, the manifest, and installing into herdr — see
[docs/02-herdr-integration.md](../docs/02-herdr-integration.md).