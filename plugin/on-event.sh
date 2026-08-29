#!/bin/sh
# herdr [[events]] hook: pane.agent_status_changed -> relay -> phone.
#
# Invoked by herdr itself (not by hand) whenever any local agent changes
# status. Pipeline: herdr -> on-event.sh -> POST 127.0.0.1:8375/api/events/herdr
# -> the relay pushes the event to every connected WS client (the phone).
# This makes blocked/finished visible instantly, with no polling.
#
# herdr hook contract:
#   - the event arrives via env HERDR_PLUGIN_EVENT_JSON, format {"data":{...}};
#   - the event name is NOT passed in env — it is fixed by the manifest
#     ([[events]] on = "pane.agent_status_changed"), the relay fills it in
#     itself at /api/events/herdr;
#   - the manifest command runs as-is (no shell) — we call sh explicitly.
#
# Failure is intentionally silent: the relay may not be running (user never
# ran install.sh) or the token may be missing — the hook exits 0 quietly so it
# does not spam the plugin log. Losing this event is not critical: the phone
# re-reads the snapshot when it next opens the app.
set -eu

# Raw event JSON from herdr; nothing to do without it.
RAW="${HERDR_PLUGIN_EVENT_JSON:-}"
[ -n "$RAW" ] || exit 0

# Token to authenticate against the relay — the same one the relay puts into
# the pairing QR link (written next to the herdr config on install). Without
# the token the relay would answer 401.
TOKEN_FILE="${HERDR_RELAY_TOKEN_FILE:-$HOME/.config/herdr/herdrelay.token}"
[ -f "$TOKEN_FILE" ] || exit 0

PORT="${HERDRELAY_PORT:-8375}"

# -sf: -s quiet mode, -f do not treat 4xx/5xx as curl errors — we care about
# not crashing the hook, not about delivery; any failure is swallowed (|| exit 0).
curl -sf -o /dev/null \
  -X POST "http://127.0.0.1:${PORT}/api/events/herdr" \
  -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
  -H "Content-Type: application/json" \
  --data-binary "$RAW" \
  || exit 0
