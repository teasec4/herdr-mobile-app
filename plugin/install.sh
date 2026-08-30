#!/usr/bin/env bash
# HerdRelay plugin [[build]] step.
#
# What it does: builds the Go relay from the repo root into the plugin's bin/
# and installs a launchd autostart service (macOS). The relay is a separate
# system service, not a herdr process, so it survives herdr restarts.
#
# When it runs: `herdr plugin install` invokes this script after confirmation.
# `herdr plugin link` does NOT run build — for local development run it by hand:
#   bash plugin/install.sh
#
# Side effects:
#   - bin/herdrelay                                    built relay binary
#   - ~/Library/LaunchAgents/com.herdrelay.relay.plist   launchd service
#   - ${XDG_STATE_HOME:-$HOME/.local/state}/herdrelay/   service logs
#
# Environment:
#   HERDRELAY_MODE        lan | tailscale | funnel | gateway (default: lan)
#   HERDRELAY_GATEWAY_URL required only for mode=gateway
#   HERDRELAY_PORT        port used by the healthz check (default 8375)
#   XDG_STATE_HOME        log dir base (default ~/.local/state)
#   HERDR_BIN             absolute herdr binary (default: from PATH)
set -euo pipefail

# Plugin root = the script's directory (HERDR_PLUGIN_ROOT may not be set during
# [[build]], same as in the persiyanov/herdr-reviewr reference).
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
BIN_DIR="$ROOT/bin"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdrelay"
PORT="${HERDRELAY_PORT:-8375}"
MODE="${HERDRELAY_MODE:-lan}"
GW="${HERDRELAY_GATEWAY_URL:-}"
# herdr lives in a user-local dir that launchd's minimal PATH does not include,
# so resolve its absolute path here and hand it to the relay via env.
HERDR_BIN="${HERDR_BIN:-$(command -v herdr || true)}"

source "$ROOT/relay-lib.sh"

echo "HerdRelay: building relay binary..."
( cd "$REPO_ROOT" && go build -o "$BIN_DIR/herdrelay" ./cmd/relay )

echo "HerdRelay: installing launchd service (mode=$MODE)..."
write_relay_plist "$MODE" "$HERDR_BIN" "$GW"

echo "HerdRelay: service installed. Checking relay..."
sleep 1
if curl -s -m 2 "http://127.0.0.1:${PORT}/healthz" >/dev/null; then
    echo "HerdRelay: relay is running on :${PORT}"
else
    echo "HerdRelay: relay not answering yet — see $LOG_DIR/relay.err.log"
fi
