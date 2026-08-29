#!/usr/bin/env bash
# herdr [[actions]] wrapper: opens a plugin pane by id.
#
# Invoked by herdr from a menu / hotkey (the show-pair-link action) with the
# pane id as the argument (e.g. "setup"). To open the pane in the active herdr
# session we call herdr itself: herdr plugin pane open.
#
# The herdr call goes through the named binary HERDR_BIN_PATH — herdr injects
# it into hooks/actions so the command reaches the running session (unix
# socket) rather than an arbitrary process from PATH.
set -euo pipefail

# Pane id to open (we register one: setup).
ENTRYPOINT="${1:-}"
[ -n "$ENTRYPOINT" ] || { echo "usage: $0 <pane-id>" >&2; exit 2; }

# The plugin id that owns the pane (inherited from the manifest; can be
# overridden via env HERDR_PLUGIN_ID).
PLUGIN_ID="${HERDR_PLUGIN_ID:-herdrelay.events}"
HERDR="${HERDR_BIN_PATH:-herdr}"

exec "$HERDR" plugin pane open \
  --plugin "$PLUGIN_ID" \
  --entrypoint "$ENTRYPOINT" \
  --placement zoomed \
  --focus