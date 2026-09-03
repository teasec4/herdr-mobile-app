# Problem: agent status is not updated on the main screen

> ⚠ 30.08: this document describes a debugging session on the old scheme. The plugin
> hook has been removed — statuses now arrive only via the relay's socket subscription
> (docs/12-fix-plan.md A1), and HomePage no longer takes a snapshot on every status
> event (it updates the list locally from the event).

## Event flow (how it should work)

1. **herdr** detects an agent status change
2. **herdr** sends `pane.agent_status_changed` over the unix socket (relay subscription `events.subscribe`)
3. **relay** forwards the event to clients over WebSocket (`pane.agent_status_changed`)
4. **Flutter client** receives the event over WebSocket
5. **HomePage** updates the agent tile locally from the event (no snapshot)
6. **AgentPage** updates the status locally from the event (no snapshot/read)

## Possible causes of failure

### 1. Plugin is not invoked by herdr
**Symptoms:** Events never reach the relay  
**Causes:**
- Plugin is disabled: `herdr plugin list` shows disabled
- herdr does not recognize the `pane.agent_status_changed` event (old herdr version < 0.7.5)
- Hook is not registered correctly in the manifest

**Verification:**
```bash
# Check that the plugin is enabled
herdr plugin list | grep herdrelay

# Check the herdr version (needs >= 0.7.5)
herdr --version

# View plugin logs
tail -f ~/.local/state/herdr/logs/plugin_*.log
```

**Relay diagnostics:**
```bash
# Add logging to on-event.sh (temporarily)
echo "Event received: $HERDR_PLUGIN_EVENT_JSON" >> /tmp/herdr-events.log
```

### 2. on-event.sh cannot send to the relay
**Symptoms:** Events are generated but never reach the relay  
**Causes:**
- Token file not found: `~/.config/herdr/herdrelay.token` is missing
- Relay is not running (port 8375 is not listening)
- Wrong port (default 8375, but it can be overridden)
- curl is not installed or not working

**Verification:**
```bash
# Does the token exist?
ls -la ~/.config/herdr/herdrelay.token

# Is the relay listening on the port?
lsof -nP -iTCP:8375 -sTCP:LISTEN

# Check manually
TOKEN=$(cat ~/.config/herdr/herdrelay.token)
curl -v -X POST "http://127.0.0.1:8375/api/events/herdr" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"data":{"pane_id":"test","agent_status":"blocked"}}'
```

**Fix:** on-event.sh silently ignores errors (`|| exit 0` on line 41), so you can temporarily remove it:
```bash
# Change lines 36-41 in plugin/on-event.sh to:
curl -v -X POST "http://127.0.0.1:${PORT}/api/events/herdr" \
  -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
  -H "Content-Type: application/json" \
  --data-binary "$RAW"
# This will surface errors in the herdr logs
```

### 3. Relay does not broadcast events
**Symptoms:** Events reach the relay but do not go out over WebSocket  
**Causes:**
- JSON parsing error in `handlePluginEvent` (lines 125-138 httpapi.go)
- Hub is empty (no connected clients) - normal, but events are lost
- Error writing to WebSocket (`c.write(b) != nil` at ws.go:89)

**Verification:**
```bash
# Add logging to cmd/relay/httpapi.go:137
log.Printf("Broadcasting event %s: %s", name, string(ev.Data))

# Rebuild
./relay-status.sh rebuild

# View logs
./relay-status.sh logs
```

### 4. WebSocket disconnected on the client
**Symptoms:** Events are broadcast but the client does not receive them  
**Causes:**
- WebSocket connection dropped (no reconnect)
- Events arrive, but the `_events` stream is closed
- Listener was removed (`_client.events.listen(_onEvent)` unsubscribed)

**Verification in Flutter:**
```dart
// Add a log in HomePage._onEvent:
void _onEvent(RelayEvent event) {
  print('Event received: ${event.name} - ${event.data}');
  if (event.name == 'pane.agent_status_changed' || event.name == 'pane.updated') {
    _refresh();
  }
}
```

**Typical problem:** `StreamController<RelayEvent>` is not broadcast, so only one listener works.

Check in `relay_client.dart`:
```dart
// Should be:
final StreamController<RelayEvent> _events = StreamController.broadcast();
```

### 5. _refresh() is called, but the UI is not updated
**Symptoms:** Events arrive, _refresh is called, but the list does not change  
**Causes:**
- `setState()` is not called inside `_refresh()` (present on lines 69-72 home_page.dart - OK)
- Agent is not in the list (is a filter cutting it out?)
- `RelayAgent.sorted()` returns stale data (cache?)
- `_client.snapshot()` returns stale data

**Verification:**
```dart
// Add a log in HomePage._refresh:
Future<void> _refresh() async {
  setState(() => _error = null);
  try {
    final agents = await _client.snapshot();
    print('Refreshed: ${agents.length} agents');
    for (var a in agents) {
      print('  ${a.id}: ${a.status}');
    }
    if (mounted) {
      setState(() {
        _agents = RelayAgent.sorted(agents);
        _loaded = true;
      });
    }
  } catch (e) {
    print('Refresh error: $e');
    if (mounted) setState(() => _error = '$e');
  }
}
```

### 6. Race condition: the event arrives before the snapshot
**Symptoms:** Sometimes it works, sometimes not  
**Causes:**
- The `pane.agent_status_changed` event arrives
- `_refresh()` calls `snapshot()` over HTTP
- But herdr has not updated its internal state yet
- snapshot returns the old status

**Fix:** Add a small delay before the refresh:
```dart
void _onEvent(RelayEvent event) {
  if (event.name == 'pane.agent_status_changed' || event.name == 'pane.updated') {
    // Give herdr time to update state before the snapshot
    Future.delayed(const Duration(milliseconds: 100), _refresh);
  }
}
```

### 7. Event arrives, but for a different pane_id
**Symptoms:** Events arrive, but not for the right agent  
**Causes:**
- herdr generates events for all panes, including non-agent ones
- The event is there, but `pane_id` does not match `agent.id`

**Verification:**
```dart
void _onEvent(RelayEvent event) {
  print('Event: ${event.name}');
  print('Data: ${event.data}');
  if (event.name == 'pane.agent_status_changed' || event.name == 'pane.updated') {
    _refresh();
  }
}
```

## Diagnostics recommendations

### Level 1: Quick check
```bash
# 1. Is the relay running?
./relay-status.sh

# 2. Is the plugin enabled?
herdr plugin list | grep herdrelay

# 3. Does the herdr version support the event?
herdr --version  # must be >= 0.7.5
```

### Level 2: Logging
Add logs at critical points:

1. **on-event.sh** - echo to /tmp/herdr-events.log
2. **httpapi.go:137** - log.Printf before broadcast
3. **home_page.dart:_onEvent** - print the event
4. **home_page.dart:_refresh** - print results

### Level 3: WebSocket monitoring
```bash
# Connect to the WebSocket and watch events
websocat "ws://localhost:8375/ws" \
  -H "Authorization: Bearer $(cat ~/.config/herdr/herdrelay.token)"

# Events like this should arrive:
# {"type":"event","event":"pane.agent_status_changed","data":{...}}
```

## Most likely causes

In order of decreasing probability:

1. **WebSocket disconnected** - the client lost the connection and does not reconnect
2. **Race condition** - snapshot returns stale data before herdr has updated
3. **on-event.sh cannot send** - token not found or the relay is not working
4. **Events are not for the right pane** - filtering is needed on the client

## Proposed fix

Add to HomePage:

```dart
void _onEvent(RelayEvent event) {
  if (!mounted) return;
  
  print('[HomePage] Event: ${event.name}'); // DEBUG
  
  if (event.name == 'pane.agent_status_changed' || event.name == 'pane.updated') {
    // Small delay so herdr has time to update state
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) _refresh();
    });
  }
}
```

And check that the StreamController is broadcast:
```dart
// In relay_client.dart
final StreamController<RelayEvent> _events = StreamController.broadcast();
```