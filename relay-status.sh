#!/bin/bash
# relay-status.sh - Herdr Mobile diagnostics and management

set -e

COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

TOKEN_FILE="${HERDRELAY_TOKEN_FILE:-$HOME/.config/herdr/herdrelay.token}"
RELAY_PORT=8375

# Get the relay token
get_token() {
  if [[ -f "$TOKEN_FILE" ]]; then
    cat "$TOKEN_FILE" | tr -d '\n'
  else
    echo ""
  fi
}

# Check the relay process
check_process() {
  echo -e "${COLOR_BLUE}━━━ Relay process ━━━${COLOR_RESET}"
  if pgrep -fl herdrelay >/dev/null 2>&1; then
    echo -e "${COLOR_GREEN}✓ Running${COLOR_RESET}"
    ps aux | grep herdrelay | grep -v grep | awk '{print "  PID:", $2, "CPU:", $3"%", "MEM:", $4"%", "Uptime:", $10}'

    # Binary version (by modification date)
    BINARY="$(dirname "$0")/plugin/bin/herdrelay"
    if [[ -f "$BINARY" ]]; then
      MOD_TIME=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$BINARY" 2>/dev/null || stat -c "%y" "$BINARY" 2>/dev/null | cut -d. -f1)
      echo "  Binary: $MOD_TIME"
    fi
  else
    echo -e "${COLOR_RED}✗ Not running${COLOR_RESET}"
    return 1
  fi
}

# Check the port
check_port() {
  echo -e "\n${COLOR_BLUE}━━━ Network ━━━${COLOR_RESET}"
  if lsof -nP -iTCP:$RELAY_PORT -sTCP:LISTEN >/dev/null 2>&1; then
    echo -e "${COLOR_GREEN}✓ Listening on port $RELAY_PORT${COLOR_RESET}"
    lsof -nP -iTCP:$RELAY_PORT -sTCP:LISTEN | tail -n +2 | awk '{print "  Address:", $9}'
  else
    echo -e "${COLOR_RED}✗ Port $RELAY_PORT not listening${COLOR_RESET}"
    return 1
  fi
}

# Check the API
check_api() {
  echo -e "\n${COLOR_BLUE}━━━ API ━━━${COLOR_RESET}"
  TOKEN=$(get_token)
  if [[ -z "$TOKEN" ]]; then
    echo -e "${COLOR_RED}✗ Token not found${COLOR_RESET}"
    return 1
  fi

  RESPONSE=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $TOKEN" "http://localhost:$RELAY_PORT/api/snapshot" 2>/dev/null || echo "000")
  HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  if [[ "$HTTP_CODE" == "200" ]]; then
    echo -e "${COLOR_GREEN}✓ API responding (HTTP $HTTP_CODE)${COLOR_RESET}"
    AGENT_COUNT=$(echo "$BODY" | jq -r '.agents | length' 2>/dev/null || echo "?")
    echo "  Agents: $AGENT_COUNT"
    echo "$BODY" | jq -r '.agents[] | "  - \(.agent) (\(.agent_status)) @ \(.cwd | split("/") | last)"' 2>/dev/null || true
  else
    echo -e "${COLOR_RED}✗ API not responding (HTTP $HTTP_CODE)${COLOR_RESET}"
    return 1
  fi
}

# Check the herdr plugin
check_plugin() {
  echo -e "\n${COLOR_BLUE}━━━ herdr plugin ━━━${COLOR_RESET}"
  if ! command -v herdr >/dev/null 2>&1; then
    echo -e "${COLOR_YELLOW}⚠ herdr not found in PATH${COLOR_RESET}"
    return 1
  fi

  PLUGIN_STATUS=$(herdr plugin list 2>/dev/null | grep -A2 "herdrelay.events" || echo "")
  if [[ -n "$PLUGIN_STATUS" ]]; then
    if echo "$PLUGIN_STATUS" | grep -q "enabled"; then
      echo -e "${COLOR_GREEN}✓ Installed and enabled${COLOR_RESET}"
    else
      echo -e "${COLOR_YELLOW}⚠ Installed but disabled${COLOR_RESET}"
    fi
    echo "$PLUGIN_STATUS" | head -3 | sed 's/^/  /'
  else
    echo -e "${COLOR_RED}✗ Not installed${COLOR_RESET}"
    return 1
  fi
}

# Show token and file path
show_token() {
  echo -e "\n${COLOR_BLUE}━━━ Access token ━━━${COLOR_RESET}"
  TOKEN=$(get_token)
  if [[ -n "$TOKEN" ]]; then
    echo "  Token: ${TOKEN:0:16}...${TOKEN: -8}"
    echo "  File: $TOKEN_FILE"
  else
    echo -e "${COLOR_RED}✗ Token not found${COLOR_RESET}"
  fi
}

# Restart the relay (via launchd)
restart_relay() {
  echo -e "${COLOR_YELLOW}Restarting relay...${COLOR_RESET}"

  PLIST="$HOME/Library/LaunchAgents/com.herdrelay.relay.plist"

  # Try launchctl kickstart (macOS) — restarts the service with the new build
  if [[ -f "$PLIST" ]]; then
    if launchctl kickstart -k "gui/$(id -u)/com.herdrelay.relay" >/dev/null 2>&1; then
      echo -e "${COLOR_GREEN}✓ Restarted via launchctl kickstart${COLOR_RESET}"
    else
      # Older launchctl / non-GUI session: unload + load
      launchctl unload "$PLIST" 2>/dev/null || true
      sleep 1
      launchctl load "$PLIST"
      echo -e "${COLOR_GREEN}✓ Restarted via launchctl load${COLOR_RESET}"
    fi
  else
    # No plist — kill the process directly (KeepAlive should restart it)
    if pkill -9 herdrelay 2>/dev/null; then
      echo -e "${COLOR_GREEN}✓ Process stopped${COLOR_RESET}"
      sleep 2
      if pgrep herdrelay >/dev/null; then
        echo -e "${COLOR_GREEN}✓ Process restarted automatically${COLOR_RESET}"
      else
        echo -e "${COLOR_YELLOW}⚠ Process did not restart. Start it manually: launchctl start com.herdrelay.relay${COLOR_RESET}"
      fi
    else
      echo -e "${COLOR_YELLOW}⚠ Process was not running${COLOR_RESET}"
    fi
  fi
}

# Update everything: build the relay, restart the service, re-link the plugin
update_relay() {
  echo -e "${COLOR_YELLOW}Updating relay and plugin...${COLOR_RESET}"
  cd "$(dirname "$0")"
  if bash plugin/redeploy.sh; then
    echo -e "${COLOR_GREEN}✓ Update complete${COLOR_RESET}"
  else
    echo -e "${COLOR_RED}✗ Update failed — see output above${COLOR_RESET}"
    return 1
  fi
}

# Check whether the binary is stale relative to the sources
check_staleness() {
  BINARY="$(dirname "$0")/plugin/bin/herdrelay"
  [[ -f "$BINARY" ]] || return 0
  ROOT="$(cd "$(dirname "$0")" && pwd)"

  # .go files actually compiled into the binary
  SRC_FILES=""
  if command -v go >/dev/null 2>&1; then
    SRC_FILES=$(cd "$ROOT" && go list -deps -compiled -f '{{range .CompiledGoFiles}}{{.}}{{"\n"}}{{end}}' ./cmd/relay 2>/dev/null | grep "^$ROOT/" || true)
  fi
  if [[ -z "$SRC_FILES" ]]; then
    # Fallback: broad selection across the source tree
    SRC_FILES=$(find "$ROOT/cmd/relay" "$ROOT/internal" -name '*.go' -type f 2>/dev/null)
  fi
  [[ -z "$SRC_FILES" ]] && return 0

  BIN_MTIME=$(stat -f "%m" "$BINARY" 2>/dev/null || echo 0)

  # Find sources newer than the binary
  FRESH=()
  while IFS= read -r f; do
    M=$(stat -f "%m" "$f" 2>/dev/null || echo 0)
    if (( M > BIN_MTIME )); then
      FRESH+=("$f")
    fi
  done <<< "$SRC_FILES"

  if (( ${#FRESH[@]} > 0 )); then
    echo -e "${COLOR_YELLOW}⚠ Binary is stale: sources are newer than the build. Run: $(basename "$0") update${COLOR_RESET}"
    FMT=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$BINARY" 2>/dev/null)
    echo "    Binary built: $FMT"
    for f in "${FRESH[@]}"; do
      echo "    newer: $f"
    done
  fi
}

# Show logs
show_logs() {
  LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdrelay"
  LOG_FILE="$LOG_DIR/relay.err.log"
  if [[ -f "$LOG_FILE" ]]; then
    echo -e "${COLOR_BLUE}━━━ Relay logs (last 20 lines) ━━━${COLOR_RESET}"
    tail -20 "$LOG_FILE"
    if [[ -s "$LOG_DIR/relay.log" ]]; then
      echo ""
      echo "--- relay.log (stdout) ---"
      tail -20 "$LOG_DIR/relay.log"
    fi
  else
    echo -e "${COLOR_YELLOW}⚠ Log file not found: $LOG_FILE${COLOR_RESET}"
  fi
}

# Truncate logs to zero (manual rotation). Safe: the process writes with
# O_APPEND (verified), so the file is simply zeroed and writes continue
# from the start.
trim_logs() {
  LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdrelay"
  for f in "$LOG_DIR/relay.err.log" "$LOG_DIR/relay.log"; do
    if [[ -f "$f" ]]; then
      SIZE=$(stat -f "%z" "$f" 2>/dev/null || echo 0)
      : > "$f"
      echo -e "${COLOR_GREEN}✓ Truncated: $f${COLOR_RESET} (was $SIZE bytes)"
    fi
  done
}

# Full status
status() {
  check_process && check_port && check_api && check_plugin && show_token
  check_staleness
  echo ""
}

# Help
usage() {
  cat <<EOF
Usage: $(basename "$0") [command]

Commands:
  status          Full relay and plugin status (default)
  update          Build the relay, restart, and re-link the plugin (after any changes)
  rebuild         Same as update
  restart         Restart the relay
  logs            Show recent logs
  logs --trim     Truncate logs to zero (manual rotation)
  token           Show the access token
  api             Check only the API
  help            This help

Examples:
  $(basename "$0")                # show status
  $(basename "$0") update         # update everything after Go/plugin changes
  $(basename "$0") restart        # restart without rebuilding
  $(basename "$0") logs           # view logs

EOF
}

# Main dispatch
case "${1:-status}" in
  status)
    status
    ;;
  restart)
    restart_relay
    echo ""
    sleep 2
    status
    ;;
  update|rebuild)
    update_relay
    echo ""
    sleep 2
    status
    ;;
  logs)
    if [[ "$2" == "--trim" ]]; then
      trim_logs
    else
      show_logs
    fi
    ;;
  token)
    show_token
    echo ""
    ;;
  api)
    check_api
    echo ""
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    echo -e "${COLOR_RED}Unknown command: $1${COLOR_RESET}\n"
    usage
    exit 1
    ;;
esac