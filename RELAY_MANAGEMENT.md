# Herdr Mobile: Management and Diagnostics

## Quick Status Check

```bash
./relay-status.sh
```

Shows:
- ✓/✗ Relay process is running (PID, CPU/memory usage, binary build time)
- ✓/✗ Port 8375 is listening
- ✓/✗ API responds (number of agents, their statuses)
- ✓/✗ herdr plugin is installed and enabled
- Access token (first/last characters)

## Commands

### Status (default)
```bash
./relay-status.sh status
./relay-status.sh          # the same thing
```

### Update after Changes — the Main Mode

```bash
./relay-status.sh update
```

One command does everything:
1. Builds the relay binary (`~/.local/bin/herdrelay`) from the Go code;
2. Restarts the launchd service `com.herdrelay.relay` so the new build gets picked up;
3. Relinks the herdr plugin `herdrelay.events` — the manifest and hook scripts are re-read;
4. Checks health: `/healthz` and `agents.snapshot`.

Run it **after any changes**: Go code (`cmd/relay/*.go`), plugin (`plugin/*.sh`, `plugin/herdr-plugin.toml`).

`rebuild` — the same thing (alias).

The status itself will tell you: if the sources are newer than the built binary, `status` will show a yellow warning "binary is outdated".

**Just restart** (without rebuilding):
```bash
./relay-status.sh restart
```

### Logs
```bash
./relay-status.sh logs
```
Shows the last 20 lines from `~/.local/state/herdrelay/relay.err.log`

### Trim Logs
```bash
./relay-status.sh logs --trim
```
Clears `relay.err.log` and `relay.log`. Safe to run on the fly: the process writes with `O_APPEND`, so writing simply continues from the beginning of the file. Useful when the log has grown large (for example after diagnostics or when the reconnect loop left junk behind).

### Token
```bash
./relay-status.sh token
```
Shows the access token (needed to connect the Flutter client)

### API-Only Check
```bash
./relay-status.sh api
```

## Manual Commands

### Check the Process
```bash
ps aux | grep herdrelay | grep -v grep
```

### Check the Port
```bash
lsof -nP -iTCP:8375 -sTCP:LISTEN
```

### Check the API Directly
```bash
curl -H "Authorization: Bearer $(cat ~/.config/herdr/herdrelay.token)" \
  http://localhost:8375/api/snapshot | jq '.'
```

### Check the herdr Plugin
```bash
herdr plugin list | grep -A2 herdrelay
```

### Rebuild Manually
```bash
bash plugin/install.sh
```

### Restart via launchd (macOS)
```bash
launchctl unload ~/Library/LaunchAgents/com.herdrelay.relay.plist
launchctl load ~/Library/LaunchAgents/com.herdrelay.relay.plist
```

### Or Kill the Process (it restarts automatically)
```bash
pkill herdrelay
```

## Configuration

### Port
Relay runs on port **8375** (not 8787!)

Configured via:
- The `HERDRELAY_LISTEN` env variable
- Or in `cmd/relay/config.go` (default `:8375`)

### Token
Stored in `~/.config/herdr/herdrelay.token`
- Generated automatically on first launch
- 64 hex characters (32 bytes of random)

### Modes
```bash
export HERDRELAY_MODE=lan        # default (listens on :8375)
export HERDRELAY_MODE=funnel     # 127.0.0.1:8375
export HERDRELAY_MODE=tailscale  # :8375
export HERDRELAY_MODE=gateway    # requires HERDRELAY_GATEWAY_URL
```

## Troubleshooting

### Relay Does Not Start
1. Check the logs: `./relay-status.sh logs`
2. Check that port 8375 is free: `lsof -nP -iTCP:8375`
3. Rebuild: `./relay-status.sh rebuild`

### API Does Not Respond
1. Check the token: `cat ~/.config/herdr/herdrelay.token`
2. Check the port: `./relay-status.sh` (should show "Listening on port 8375")
3. Check the firewall (if connecting from a phone)

### Plugin Does Not Work
1. Check the status: `herdr plugin list | grep herdrelay`
2. If not installed: `herdr plugin link ~/herdr-relay/plugin`
3. If disabled: `herdr plugin enable herdrelay.events`

### Flutter Client Does Not Connect
1. Make sure you use the correct port: **8375**
2. Check the token in the client (must match `~/.config/herdr/herdrelay.token`)
3. Make sure the computer and phone are on the same network
4. Check the computer's IP address: `ifconfig | grep "inet " | grep -v 127.0.0.1`

### relay.err.log Grows Very Fast (a couple of lines per second)
Symptom: the log contains lines one after another
`herdr socket: connected to ... (N pane subscriptions)` and
`herdr socket: connection closed, reconnecting` — once per second, endlessly.

Cause (fixed): relay kept a pane_id in its subscriptions that no longer exists
(the tab/pane was closed, or the pane_id changed on pane.moved). herdr answers
such a subscription with a JSON-RPC error `pane_not_found` and closes the
connection; previously relay ignored the error frame, saw a "clean EOF" and
reconnected with the same dead pane_id — an endless loop.

What to do now:
1. Check whether the problem is back: `./relay-status.sh logs` — it should be
   quiet (a few lines per minute, not per second).
2. If the log has already grown: `./relay-status.sh logs --trim`.
3. If the loop repeats: `./relay-status.sh update` (rebuild + restart) and
   look at `docs/10-herdr-api.md` — subscribing to a dead pane_id.

## Workflow After Changes

### Changed Go Code (cmd/relay/\*.go) or Plugin (plugin/\*.sh, plugin/\*.toml)
```bash
./relay-status.sh update
```

### Changed the Flutter Client (client/\*)
```bash
cd client
flutter run
```

### Want to Verify Everything Works
```bash
./relay-status.sh
```
All checkmarks should be green ✓

## Files and Paths

```
~/herdr-relay/
├── cmd/relay/              # Go code for the relay server
│   ├── main.go
│   ├── server.go
│   ├── httpapi.go
│   └── ...
├── plugin/                 # Plugin for herdr
│   ├── herdr-plugin.toml   # Plugin manifest
│   ├── install.sh          # Build and install
│   ├── setup-menu.sh       # Setup menu
│   ├── relay-lib.sh        # Shared helpers (paths, plist)
│   └── ...  (binary installs to ~/.local/bin/herdrelay)
├── client/                 # Flutter client
│   └── lib/
├── relay-status.sh         # This script
└── RELAY_MANAGEMENT.md     # This documentation

~/.config/herdr/
├── herdrelay.token         # Access token
├── herdr.sock              # Unix socket herdr
└── plugins/
    └── config/
        └── herdrelay.events/

~/Library/LaunchAgents/
└── com.herdrelay.relay.plist   # launchd config (macOS)

~/.local/state/herdrelay/
├── relay.log                   # Relay logs (stdout)
└── relay.err.log               # Relay logs (stderr, main)
```
