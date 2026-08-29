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

  # Попробовать через launchd (macOS)
  if [[ -f ~/Library/LaunchAgents/com.herdr.relay.plist ]]; then
    launchctl unload ~/Library/LaunchAgents/com.herdr.relay.plist 2>/dev/null || true
    sleep 1
    launchctl load ~/Library/LaunchAgents/com.herdr.relay.plist
    echo -e "${COLOR_GREEN}✓ Перезапущен через launchd${COLOR_RESET}"
  else
    # Убить процесс напрямую (он должен автоматически перезапуститься)
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

# Пересобрать relay
rebuild_relay() {
  echo -e "${COLOR_YELLOW}Пересборка relay...${COLOR_RESET}"
  cd "$(dirname "$0")"
  bash plugin/install.sh
  echo -e "${COLOR_GREEN}✓ Relay пересобран${COLOR_RESET}"
}

# Показать логи
show_logs() {
  echo -e "${COLOR_BLUE}━━━ Логи relay (последние 20 строк) ━━━${COLOR_RESET}"
  LOG_FILE="${HOME}/Library/Logs/herdrelay.log"
  if [[ -f "$LOG_FILE" ]]; then
    tail -20 "$LOG_FILE"
  else
    echo -e "${COLOR_YELLOW}⚠ Лог-файл не найден: $LOG_FILE${COLOR_RESET}"
  fi
}

# Полный статус
status() {
  check_process && check_port && check_api && check_plugin && show_token
  echo ""
}

# Помощь
usage() {
  cat <<EOF
Использование: $(basename "$0") [команда]

Команды:
  status          Полный статус relay и плагина (по умолчанию)
  restart         Перезапустить relay
  rebuild         Пересобрать и перезапустить relay
  logs            Показать последние логи
  token           Показать токен доступа
  api             Проверить только API
  help            Эта справка

Примеры:
  $(basename "$0")                # показать статус
  $(basename "$0") rebuild        # пересобрать после изменений в Go коде
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
  rebuild)
    rebuild_relay
    echo ""
    restart_relay
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
