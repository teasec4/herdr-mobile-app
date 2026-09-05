#!/usr/bin/env bash
# Herdr Mobile plugin [[build]] step.
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
#   - ~/.local/bin/herdrelay                            built relay binary (stable path)
#   - ~/Library/LaunchAgents/com.herdrelay.relay.plist   launchd service
#   - ${XDG_STATE_HOME:-$HOME/.local/state}/herdrelay/   service logs
#
# Why ~/.local/bin and not plugin/bin: herdr runs [[build]] from a temporary
# checkout and moves it to its managed location afterwards (and replaces it on
# reinstall), so a launchd plist must never point inside the plugin root.
# Override the binary location with HERDRELAY_BIN.
#
# Environment:
#   HERDRELAY_BIN         absolute relay binary path (default ~/.local/bin/herdrelay)
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
source "$ROOT/relay-lib.sh"

BIN="$(relay_bin_path)"
BIN_DIR="$(dirname "$BIN")"
LOG_DIR="$(relay_log_dir)"
PORT="${HERDRELAY_PORT:-8375}"
MODE="${HERDRELAY_MODE:-lan}"
GW="${HERDRELAY_GATEWAY_URL:-}"
# herdr lives in a user-local dir that launchd's minimal PATH does not include,
# so resolve its absolute path here and hand it to the relay via env.
HERDR_BIN="${HERDR_BIN:-$(command -v herdr || true)}"
if [ -z "$HERDR_BIN" ]; then
    echo "Herdr Mobile: warning: herdr not found in PATH — the relay will still run," >&2
    echo "Herdr Mobile: but herdr-socket integration (event subscription) will be unavailable." >&2
    echo "Herdr Mobile: install herdr, then re-run install.sh to enable it." >&2
fi

echo "Herdr Mobile: building relay binary ($BIN)..."
mkdir -p "$BIN_DIR"
( cd "$REPO_ROOT" && go build -o "$BIN" ./cmd/relay )

echo "Herdr Mobile: installing launchd service (mode=$MODE)..."
write_relay_plist "$MODE" "$HERDR_BIN" "$GW"

echo "Herdr Mobile: service installed. Checking relay..."
up=0
for _ in $(seq 1 10); do
    if curl -s -m 2 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
        up=1
        break
    fi
    # The plist is written with RunAtLoad, but a plain `load` is unreliable on
    # modern macOS — actively start the job if it did not come up on its own.
    launchctl kickstart "gui/$(id -u)/com.herdrelay.relay" >/dev/null 2>&1 || true
    sleep 1
done
if [ "$up" -ne 1 ]; then
    echo "Herdr Mobile: relay did not come up on :${PORT} within ~10s" >&2
    echo "Herdr Mobile: check $LOG_DIR/relay.err.log for errors." >&2
    echo "Herdr Mobile: re-run 'bash plugin/install.sh', or start the service with:" >&2
    echo "Herdr Mobile:   launchctl kickstart -k gui/$(id -u)/com.herdrelay.relay" >&2
    exit 1
fi
echo "Herdr Mobile: relay is running on :${PORT}"
