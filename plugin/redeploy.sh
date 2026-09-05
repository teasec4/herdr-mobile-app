#!/usr/bin/env bash
# Rebuild + restart the relay and re-link the herdr plugin — one command for
# the dev loop after changing Go code, plugin hook scripts, or the manifest.
#
# Usage: bash plugin/redeploy.sh
#
# What it does:
#   1. builds the relay binary into ~/.local/bin/herdrelay (stable path — the
#      launchd service must not point inside the plugin directory)
#   2. restarts the launchd service (com.herdrelay.relay) so the new binary
#      is picked up (KeepAlive=true would restart on crash, not on rebuild)
#   3. re-links the herdr plugin (herdr re-reads herdr-plugin.toml and the
#      hook scripts — the same effect as a fresh `herdr plugin link`)
#   4. health-checks the relay: /healthz then /api/rpc agents.snapshot
#
# Environment (same as install.sh):
#   HERDRELAY_BIN       absolute relay binary path (default ~/.local/bin/herdrelay)
#   HERDRELAY_PORT      port for the health checks (default 8375)
#   HERDRELAY_PLUGIN_ID plugin id to re-link (default herdrelay.events)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
source "$ROOT/relay-lib.sh"
BIN="$(relay_bin_path)"
BIN_DIR="$(dirname "$BIN")"
LOG_DIR="$(relay_log_dir)"
PORT="${HERDRELAY_PORT:-8375}"
PLUGIN_ID="${HERDRELAY_PLUGIN_ID:-herdrelay.events}"
PLIST="$(relay_plist_path)"

# 1. Build ---------------------------------------------------------------
echo "→ building relay binary..."
mkdir -p "$BIN_DIR"
( cd "$REPO_ROOT" && go build -o "$BIN" ./cmd/relay )

# 2. Restart the launchd service ------------------------------------------
echo "→ restarting launchd service (com.herdrelay.relay)..."
if ! launchctl kickstart -k "gui/$(id -u)/com.herdrelay.relay" >/dev/null 2>&1; then
    # Older launchctl / non-GUI session: fall back to unload+load.
    launchctl unload "$PLIST" >/dev/null 2>&1 || true
    launchctl load "$PLIST"
fi

# 3. Re-link the herdr plugin ----------------------------------------------
if command -v herdr >/dev/null 2>&1; then
    echo "→ re-linking herdr plugin ($PLUGIN_ID)..."
    herdr plugin unlink "$PLUGIN_ID" >/dev/null 2>&1 || true
    herdr plugin link "$ROOT"
else
    echo "⚠ herdr not found in PATH — plugin re-link skipped"
fi

# 4. Health checks ----------------------------------------------------------
echo "→ waiting for the relay..."
up=0
for _ in $(seq 1 10); do
    if curl -s -m 2 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
        up=1
        break
    fi
    sleep 1
done
if [ "$up" -ne 1 ]; then
    echo "✗ relay not answering on :${PORT} — see $LOG_DIR/relay.err.log"
    exit 1
fi
echo "✓ relay is up on :${PORT}"

TOKEN_FILE="${HERDRELAY_TOKEN_FILE:-$HOME/.config/herdr/herdrelay.token}"
if [ -f "$TOKEN_FILE" ]; then
    TOKEN="$(cat "$TOKEN_FILE")"
    if curl -s -m 5 -X POST "http://127.0.0.1:${PORT}/api/rpc?token=${TOKEN}" \
        -H 'Content-Type: application/json' \
        -d '{"type":"request","id":1,"method":"agents.snapshot","params":{}}' \
        | grep -q '"ok":true'; then
        echo "✓ /api/rpc agents.snapshot ok"
    else
        echo "⚠ /api/rpc check failed — relay is up but the RPC path may be broken"
    fi
fi

echo
echo "done. The phone can reconnect as-is (pairing link/token unchanged)."
