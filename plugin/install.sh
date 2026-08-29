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
# Environment: HERDRELAY_PORT (port, default 8375), XDG_STATE_HOME (log dir).
set -euo pipefail

# Plugin root = the script's directory (HERDR_PLUGIN_ROOT may not be set during
# [[build]], same as in the persiyanov/herdr-reviewr reference).
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
BIN_DIR="$ROOT/bin"
PLIST="$HOME/Library/LaunchAgents/com.herdrelay.relay.plist"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdrelay"
PORT="${HERDRELAY_PORT:-8375}"
# herdr lives in a user-local dir that launchd's minimal PATH does not include,
# so resolve its absolute path here and hand it to the relay via env.
HERDR_BIN="${HERDR_BIN:-$(command -v herdr || true)}"

echo "HerdRelay: building relay binary..."
( cd "$REPO_ROOT" && go build -o "$BIN_DIR/herdrelay" ./cmd/relay )

mkdir -p "$LOG_DIR"

echo "HerdRelay: installing launchd service..."
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.herdrelay.relay</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN_DIR/herdrelay</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/relay.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/relay.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HERDRELAY_MODE</key>
    <string>lan</string>
    <key>HERDRELAY_HERDR_BIN</key>
    <string>$HERDR_BIN</string>
  </dict>
</dict>
</plist>
EOF

# (Re)start the service: unload the old one (if any), load the new one.
launchctl unload "$PLIST" >/dev/null 2>&1 || true
launchctl load "$PLIST"

echo "HerdRelay: service installed. Checking relay..."
sleep 1
if curl -s -m 2 "http://127.0.0.1:${PORT}/healthz" >/dev/null; then
    echo "HerdRelay: relay is running on :${PORT}"
else
    echo "HerdRelay: relay not answering yet — see $LOG_DIR/relay.err.log"
fi
