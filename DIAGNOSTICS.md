# Agent Status Update Diagnostics

> ⚠ 30.08: this document describes a debug session on the old scheme. The
> plugin hook has since been removed — statuses now arrive only via the relay's
> socket subscription (`events.subscribe`), and the debug `print`s from
> HomePage/AgentPage have been removed (docs/12-fix-plan.md A1, G1). The
> items below about `on-event.sh` and `/api/events/herdr` are no longer valid.

## What was added

### 1. Logging at all levels

**herdr plugin (plugin/on-event.sh):**
- Logs all incoming events to `/tmp/herdr-relay-events.log`
- Format: `[2026-08-29 10:30:00] Event: {"data":{...}}`

**Relay server (cmd/relay/httpapi.go):**
- Logs event broadcasts with the number of connected clients
- Visible in relay logs: `/tmp/herdrelay.log` or `./relay-status.sh logs`

**Flutter client (client/lib/services/relay_client.dart):**
- Logs incoming WebSocket events: `[RelayClient] WS event: pane.agent_status_changed`

**HomePage (client/lib/pages/home_page.dart):**
- Logs event receipt: `[HomePage] Event received: ...`
- Logs refresh: `[HomePage] Fetching snapshot...`
- Logs results: `[HomePage] Got N agents: ...`

### 2. Race condition fix

A 150ms delay was added between receiving an event and calling snapshot, so that herdr has time to update its internal state:

```dart
if (event.name == 'pane.agent_status_changed' || event.name == 'pane.updated') {
  Future.delayed(const Duration(milliseconds: 150), () {
    if (mounted) _refresh();
  });
}
```

## How to use the diagnostics

### Run the Flutter app with logs

```bash
cd client
flutter run 2>&1 | grep -E '\[HomePage\]|\[RelayClient\]'
```

Or simply:
```bash
cd client
flutter run
```

And watch the console for log entries prefixed with `[HomePage]` and `[RelayClient]`.

### Check the herdr plugin logs

```bash
# Events from herdr
tail -f /tmp/herdr-relay-events.log

# Lines should appear when the agent status changes:
# [2026-08-29 10:30:15] Event: {"data":{"pane_id":"wH:p7","agent":"claude","agent_status":"blocked"}}
```

### Check the relay logs

```bash
# Current relay logs
tail -f /tmp/herdrelay.log

# Or via the utility
./relay-status.sh logs

# Lines should look like:
# [relay] Broadcasting event pane.agent_status_changed to 1 clients: {...}
```

### Full flow check

1. **Run Flutter with logs:**
   ```bash
   cd client && flutter run
   ```

2. **In another terminal, watch for events:**
   ```bash
   tail -f /tmp/herdr-relay-events.log
   ```

3. **Change the agent status** (e.g. run a command in the herdr agent)

4. **Check what happened:**
   - `/tmp/herdr-relay-events.log` - did the event arrive from herdr? ✓
   - `/tmp/herdrelay.log` - did the relay receive and broadcast it? ✓
   - Flutter console - `[RelayClient] WS event` - did the client receive it? ✓
   - Flutter console - `[HomePage] Event received` - did HomePage process it? ✓
   - Flutter console - `[HomePage] Fetching snapshot` - did it request an update? ✓
   - Flutter console - `[HomePage] Got N agents` - did it fetch the agents? ✓
   - Flutter console - `[HomePage] UI updated` - did it update the UI? ✓

## Typical problems

### The event does not arrive in /tmp/herdr-relay-events.log
**Cause:** herdr does not call the plugin  
**Solution:**
```bash
# Check that the plugin is enabled
herdr plugin list | grep herdrelay

# Check the herdr version (>= 0.7.5 required)
herdr --version

# Look at the herdr logs
tail -f ~/.local/state/herdr/logs/plugin_*.log
```

### The event is in the log, but the relay does not broadcast it
**Cause (old scheme):** token not found, relay not running, curl cannot send.
**Status:** the `/api/events/herdr` route has been **removed** (docs/12 A1) —
statuses must be checked via the relay's socket subscription (log `herdr socket: connected to ...`), not through the hook:
```bash
# Check the relay
./relay-status.sh

# Relay socket-subscription log (statuses/output)
tail -f ~/.local/state/herdrelay/relay.err.log | grep 'herdr socket'
```

### The relay broadcasts, but the client does not receive it
**Cause:** WebSocket is disconnected  
**Solution:** watch the Flutter console for reconnect logs, check that `status.value == RelayStatus.connected`

### The client receives, but the UI does not update
**Cause:** race condition (herdr has not updated its state yet) or setState is not called  
**Solution:** already fixed by the 150ms delay; watch the `[HomePage] UI updated` logs

## After diagnostics

Once the problem is found and fixed, you can turn off the DEBUG logs:

### Disable event logging in the plugin
```bash
# In plugin/on-event.sh, comment out the line:
# echo "[$(date '+%Y-%m-%d %H:%M:%S')] Event: $RAW" >> /tmp/herdr-relay-events.log
```

### Remove print() from Flutter
Delete or comment out `print()` in:
- `client/lib/services/relay_client.dart` (_onMessage)
- `client/lib/pages/home_page.dart` (_onEvent, _refresh)

### Remove the log from relay
Delete or comment out `log.Printf` in `cmd/relay/httpapi.go:137`

But keep the 150ms delay in _onEvent — it fixes the race condition!

## Verification checklist

- [ ] Relay is running (`./relay-status.sh`)
- [ ] Plugin is enabled (`herdr plugin list`)
- [ ] herdr >= 0.7.5 (`herdr --version`)
- [ ] Events are written to `/tmp/herdr-relay-events.log`
- [ ] Relay broadcasts events (`tail -f /tmp/herdrelay.log`)
- [ ] Flutter receives events (console `[RelayClient]`)
- [ ] HomePage processes events (console `[HomePage]`)
- [ ] UI updates after the snapshot