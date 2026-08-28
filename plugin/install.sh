#!/usr/bin/env bash
# herdr [[build]]-шаг плагина HerdRelay: собирает Go-релей из корня репо
# в bin/ плагина и ставит launchd-сервис автозапуска (macOS).
#
# При `herdr plugin install` вызывается после подтверждения; при `herdr plugin
# link` build пропускается herdr'ом — для локальной разработки запускать вручную:
#   bash plugin/install.sh
set -euo pipefail

# Корень плагина = каталог скрипта (на момент [[build]] env HERDR_PLUGIN_ROOT
# может не передаваться, как в persiyanov/herdr-reviewr).
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
BIN_DIR="$ROOT/bin"
PLIST="$HOME/Library/LaunchAgents/com.herdrelay.relay.plist"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdrelay"
PORT="${HERDRELAY_PORT:-8375}"

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
  </dict>
</dict>
</plist>
EOF

# Перезапуск сервиса: unload старого (если был), load нового.
launchctl unload "$PLIST" >/dev/null 2>&1 || true
launchctl load "$PLIST"

echo "HerdRelay: service installed. Checking relay..."
sleep 1
if curl -s -m 2 "http://127.0.0.1:${PORT}/healthz" >/dev/null; then
    echo "HerdRelay: relay is running on :${PORT}"
else
    echo "HerdRelay: relay not answering yet — see $LOG_DIR/relay.err.log"
fi
