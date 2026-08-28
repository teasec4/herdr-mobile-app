#!/usr/bin/env bash
# Обёртка [[actions]]: открывает пейн плагина по id (аналог open-plugin-pane.sh
# из herdr-mobile-relay, но без лишних опций).
set -euo pipefail

ENTRYPOINT="${1:-}"
[ -n "$ENTRYPOINT" ] || { echo "usage: $0 <pane-id>" >&2; exit 2; }

PLUGIN_ID="${HERDR_PLUGIN_ID:-herdrelay.events}"
HERDR="${HERDR_BIN_PATH:-herdr}"

exec "$HERDR" plugin pane open \
  --plugin "$PLUGIN_ID" \
  --entrypoint "$ENTRYPOINT" \
  --placement zoomed \
  --focus