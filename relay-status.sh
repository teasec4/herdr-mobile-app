#!/bin/bash
# relay-status.sh - диагностика и управление HerdRelay

set -e

COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

TOKEN_FILE="${HOME}/.config/herdr/herdrelay.token"
RELAY_PORT=8375

# Получить токен
get_token() {
  if [[ -f "$TOKEN_FILE" ]]; then
    cat "$TOKEN_FILE" | tr -d '\n'
  else
    echo ""
  fi
}

# Проверить процесс relay
check_process() {
  echo -e "${COLOR_BLUE}━━━ Процесс relay ━━━${COLOR_RESET}"
  if pgrep -fl herdrelay >/dev/null 2>&1; then
    echo -e "${COLOR_GREEN}✓ Запущен${COLOR_RESET}"
    ps aux | grep herdrelay | grep -v grep | awk '{print "  PID:", $2, "CPU:", $3"%", "MEM:", $4"%", "Uptime:", $10}'

    # Версия бинарника (по дате модификации)
    BINARY="$(dirname "$0")/plugin/bin/herdrelay"
    if [[ -f "$BINARY" ]]; then
      MOD_TIME=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$BINARY" 2>/dev/null || stat -c "%y" "$BINARY" 2>/dev/null | cut -d. -f1)
      echo "  Бинарник: $MOD_TIME"
    fi
  else
    echo -e "${COLOR_RED}✗ Не запущен${COLOR_RESET}"
    return 1
  fi
}

# Проверить порт
check_port() {
  echo -e "\n${COLOR_BLUE}━━━ Сеть ━━━${COLOR_RESET}"
  if lsof -nP -iTCP:$RELAY_PORT -sTCP:LISTEN >/dev/null 2>&1; then
    echo -e "${COLOR_GREEN}✓ Слушает порт $RELAY_PORT${COLOR_RESET}"
    lsof -nP -iTCP:$RELAY_PORT -sTCP:LISTEN | tail -n +2 | awk '{print "  Адрес:", $9}'
  else
    echo -e "${COLOR_RED}✗ Порт $RELAY_PORT не слушается${COLOR_RESET}"
    return 1
  fi
}

# Проверить API
check_api() {
  echo -e "\n${COLOR_BLUE}━━━ API ━━━${COLOR_RESET}"
  TOKEN=$(get_token)
  if [[ -z "$TOKEN" ]]; then
    echo -e "${COLOR_RED}✗ Токен не найден${COLOR_RESET}"
    return 1
  fi

  RESPONSE=$(curl -s -w "\n%{http_code}" -H "Authorization: Bearer $TOKEN" "http://localhost:$RELAY_PORT/api/snapshot" 2>/dev/null || echo "000")
  HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
  BODY=$(echo "$RESPONSE" | sed '$d')

  if [[ "$HTTP_CODE" == "200" ]]; then
    echo -e "${COLOR_GREEN}✓ API отвечает (HTTP $HTTP_CODE)${COLOR_RESET}"
    AGENT_COUNT=$(echo "$BODY" | jq -r '.agents | length' 2>/dev/null || echo "?")
    echo "  Агентов: $AGENT_COUNT"
    echo "$BODY" | jq -r '.agents[] | "  - \(.agent) (\(.agent_status)) @ \(.cwd | split("/") | last)"' 2>/dev/null || true
  else
    echo -e "${COLOR_RED}✗ API не отвечает (HTTP $HTTP_CODE)${COLOR_RESET}"
    return 1
  fi
}

# Проверить плагин herdr
check_plugin() {
  echo -e "\n${COLOR_BLUE}━━━ Плагин herdr ━━━${COLOR_RESET}"
  if ! command -v herdr >/dev/null 2>&1; then
    echo -e "${COLOR_YELLOW}⚠ herdr не найден в PATH${COLOR_RESET}"
    return 1
  fi

  PLUGIN_STATUS=$(herdr plugin list 2>/dev/null | grep -A2 "herdrelay.events" || echo "")
  if [[ -n "$PLUGIN_STATUS" ]]; then
    if echo "$PLUGIN_STATUS" | grep -q "enabled"; then
      echo -e "${COLOR_GREEN}✓ Установлен и включен${COLOR_RESET}"
    else
      echo -e "${COLOR_YELLOW}⚠ Установлен но выключен${COLOR_RESET}"
    fi
    echo "$PLUGIN_STATUS" | head -3 | sed 's/^/  /'
  else
    echo -e "${COLOR_RED}✗ Не установлен${COLOR_RESET}"
    return 1
  fi
}

# Показать токен и QR
show_token() {
  echo -e "\n${COLOR_BLUE}━━━ Токен доступа ━━━${COLOR_RESET}"
  TOKEN=$(get_token)
  if [[ -n "$TOKEN" ]]; then
    echo "  Токен: ${TOKEN:0:16}...${TOKEN: -8}"
    echo "  Файл: $TOKEN_FILE"
  else
    echo -e "${COLOR_RED}✗ Токен не найден${COLOR_RESET}"
  fi
}

# Перезапустить relay (через launchd)
restart_relay() {
  echo -e "${COLOR_YELLOW}Перезапуск relay...${COLOR_RESET}"

  PLIST="$HOME/Library/LaunchAgents/com.herdrelay.relay.plist"

  # Попробовать через launchctl kickstart (macOS) — перезапускает сервис с новой сборкой
  if [[ -f "$PLIST" ]]; then
    if launchctl kickstart -k "gui/$(id -u)/com.herdrelay.relay" >/dev/null 2>&1; then
      echo -e "${COLOR_GREEN}✓ Перезапущен через launchctl kickstart${COLOR_RESET}"
    else
      # Старый launchctl / не-GUI сессия: unload + load
      launchctl unload "$PLIST" 2>/dev/null || true
      sleep 1
      launchctl load "$PLIST"
      echo -e "${COLOR_GREEN}✓ Перезапущен через launchctl load${COLOR_RESET}"
    fi
  else
    # plist нет — убить процесс напрямую (он должен автоматически перезапуститься)
    if pkill -9 herdrelay 2>/dev/null; then
      echo -e "${COLOR_GREEN}✓ Процесс остановлен${COLOR_RESET}"
      sleep 2
      if pgrep herdrelay >/dev/null; then
        echo -e "${COLOR_GREEN}✓ Процесс перезапустился автоматически${COLOR_RESET}"
      else
        echo -e "${COLOR_YELLOW}⚠ Процесс не перезапустился. Запустите вручную.${COLOR_RESET}"
      fi
    else
      echo -e "${COLOR_YELLOW}⚠ Процесс не был запущен${COLOR_RESET}"
    fi
  fi
}

# Обновить всё: собрать relay, перезапустить сервис, перелинковать плагин
update_relay() {
  echo -e "${COLOR_YELLOW}Обновление relay и плагина...${COLOR_RESET}"
  cd "$(dirname "$0")"
  if bash plugin/redeploy.sh; then
    echo -e "${COLOR_GREEN}✓ Обновление завершено${COLOR_RESET}"
  else
    echo -e "${COLOR_RED}✗ Обновление не удалось — см. вывод выше${COLOR_RESET}"
    return 1
  fi
}

# Проверить, не устарел ли бинарник относительно исходников
check_staleness() {
  BINARY="$(dirname "$0")/plugin/bin/herdrelay"
  [[ -f "$BINARY" ]] || return 0
  ROOT="$(cd "$(dirname "$0")" && pwd)"

  # Реально входящие в сборку .go-файлы (компилируются в бинарник)
  SRC_FILES=""
  if command -v go >/dev/null 2>&1; then
    SRC_FILES=$(cd "$ROOT" && go list -deps -compiled -f '{{range .CompiledGoFiles}}{{.}}{{"\n"}}{{end}}' ./cmd/relay 2>/dev/null | grep "^$ROOT/" || true)
  fi
  if [[ -z "$SRC_FILES" ]]; then
    # Fallback: широкая выборка по дереву исходников
    SRC_FILES=$(find "$ROOT/cmd/relay" "$ROOT/internal" -name '*.go' -type f 2>/dev/null)
  fi
  [[ -z "$SRC_FILES" ]] && return 0

  BIN_MTIME=$(stat -f "%m" "$BINARY" 2>/dev/null || echo 0)

  # Найти исходники новее бинарника
  FRESH=()
  while IFS= read -r f; do
    M=$(stat -f "%m" "$f" 2>/dev/null || echo 0)
    if (( M > BIN_MTIME )); then
      FRESH+=("$f")
    fi
  done <<< "$SRC_FILES"

  if (( ${#FRESH[@]} > 0 )); then
    echo -e "${COLOR_YELLOW}⚠ Бинарник устарел: исходники новее сборки. Выполните: $(basename "$0") update${COLOR_RESET}"
    FMT=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$BINARY" 2>/dev/null)
    echo "    Бинарник собран: $FMT"
    for f in "${FRESH[@]}"; do
      echo "    новее: $f"
    done
  fi
}

# Показать логи
show_logs() {
  echo -e "${COLOR_BLUE}━━━ Логи relay (последние 20 строк) ━━━${COLOR_RESET}"
  LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdrelay"
  LOG_FILE="$LOG_DIR/relay.err.log"
  if [[ -f "$LOG_FILE" ]]; then
    tail -20 "$LOG_FILE"
    if [[ -s "$LOG_DIR/relay.log" ]]; then
      echo ""
      echo "--- relay.log (stdout) ---"
      tail -20 "$LOG_DIR/relay.log"
    fi
  else
    echo -e "${COLOR_YELLOW}⚠ Лог-файл не найден: $LOG_FILE${COLOR_RESET}"
  fi
}

# Полный статус
status() {
  check_process && check_port && check_api && check_plugin && show_token
  check_staleness
  echo ""
}

# Помощь
usage() {
  cat <<EOF
Использование: $(basename "$0") [команда]

Команды:
  status          Полный статус relay и плагина (по умолчанию)
  update          Собрать relay, перезапустить и перелинковать плагин (после любых изменений)
  rebuild         То же, что update
  restart         Перезапустить relay
  logs            Показать последние логи
  token           Показать токен доступа
  api             Проверить только API
  help            Эта справка

Примеры:
  $(basename "$0")                # показать статус
  $(basename "$0") update         # обновить всё после изменений в Go/плагине
  $(basename "$0") restart        # перезапустить без пересборки
  $(basename "$0") logs           # посмотреть логи

EOF
}

# Главная логика
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
    show_logs
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
    echo -e "${COLOR_RED}Неизвестная команда: $1${COLOR_RESET}\n"
    usage
    exit 1
    ;;
esac
