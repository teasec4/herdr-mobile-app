#!/bin/sh
# Хук herdr [[events]]: форвардит pane.agent_status_changed в локальный релей,
# тот пушит событие на подключённый телефон. Вызывается самим herdr (не руками).
#
# herdr передаёт событие через env HERDR_PLUGIN_EVENT_JSON, формат {"data":{...}}.
# Имя события хук не получает — оно фиксировано манифестом (pane.agent_status_changed),
# релей подставляет его сам на /api/events/herdr.
set -eu

RAW="${HERDR_PLUGIN_EVENT_JSON:-}"
[ -n "$RAW" ] || exit 0

TOKEN_FILE="${HERDR_RELAY_TOKEN_FILE:-$HOME/.config/herdr/herdrelay.token}"
[ -f "$TOKEN_FILE" ] || exit 0

PORT="${HERDRELAY_PORT:-8375}"

curl -sf -o /dev/null \
  -X POST "http://127.0.0.1:${PORT}/api/events/herdr" \
  -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
  -H "Content-Type: application/json" \
  --data-binary "$RAW" \
  || exit 0
