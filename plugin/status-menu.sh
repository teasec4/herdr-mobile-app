#!/usr/bin/env bash
# "Herdr Mobile: Status" pane — relay status summary + recent logs (no QR).
#
# Invoked by herdr when the status pane opens ([[panes]] entrypoint "status",
# opened via the herdrelay.events.status action). Prints process/health/plist
# state and the tail of the service log, then closes by itself.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/relay-lib.sh"

BIN="$(relay_bin_path)"
PLIST="$(relay_plist_path)"
LOG_DIR="$(relay_log_dir)"
PORT="${HERDRELAY_PORT:-8375}"

echo "== Herdr Mobile: relay status =="

# Health / process
if curl -s -m 2 "http://127.0.0.1:${PORT}/healthz" >/dev/null; then
    echo "relay:    running on :${PORT}"
else
    echo "relay:    NOT running"
fi
if pgrep -fl herdrelay >/dev/null 2>&1; then
    ps aux | grep '[h]erdrelay' | awk '{print "pid:      " $2}'
fi

# Binary
if [ -x "$BIN" ]; then
    echo "binary:   $BIN"
else
    echo "binary:   MISSING ($BIN) — run 'bash $ROOT/install.sh'"
fi

# Service mode from the plist
if [ -f "$PLIST" ]; then
    mode="$(grep -A1 '<key>HERDRELAY_MODE</key>' "$PLIST" \
        | sed -nE 's/.*<string>([^<]*)<\/string>.*/\1/p' | head -1)"
    echo "mode:     ${mode:-lan}"
    echo "plist:    $PLIST"
else
    echo "plist:    MISSING — run 'bash $ROOT/install.sh'"
fi

# Recent errors
if [ -f "$LOG_DIR/relay.err.log" ]; then
    echo
    echo "== recent log (relay.err.log) =="
    tail -15 "$LOG_DIR/relay.err.log"
fi

echo
echo "Control from herdr: actions restart / stop / start / uninstall-service"
echo "This pane closes by itself."
sleep 10
