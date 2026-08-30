#!/usr/bin/env bash
# HerdRelay: переключение режима подключения (lan / tailscale / funnel / gateway).
#
# Интерактивное меню, либо неинтерактивно:
#   bash plugin/configure.sh <mode> [gateway_url]
#
# Что делает: переписывает launchd plist с новым HERDRELAY_MODE и перезапускает
# службу через launchctl. НЕ пересобирает бинарник (в отличие от install.sh).
#
# Режимы (docs/03-relay.md):
#   lan       локальная сеть (по умолчанию)
#   tailscale VPN-сеть Tailscale, удалённый доступ без проброса портов
#   funnel    публичный URL через tailscale funnel, доступ из интернета
#   gateway   подключение через центральный шлюз (нужен HERDRELAY_GATEWAY_URL)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/relay-lib.sh"

# herdr lives in a user-local dir that launchd's minimal PATH does not include.
HERDR_BIN="${HERDR_BIN:-$(command -v herdr || true)}"

current_mode() {
    local plist
    plist="$(relay_plist_path)"
    if [[ -f "$plist" ]]; then
        grep -A1 '<key>HERDRELAY_MODE</key>' "$plist" \
            | sed -nE 's/.*<string>([^<]*)<\/string>.*/\1/p' | head -1
    fi
}

current_gw() {
    local plist
    plist="$(relay_plist_path)"
    if [[ -f "$plist" ]]; then
        grep -A1 '<key>HERDRELAY_GATEWAY_URL</key>' "$plist" \
            | sed -nE 's/.*<string>([^<]*)<\/string>.*/\1/p' | head -1
    fi
}

apply_mode() {
    local mode="$1" gw="${2:-}"
    case "$mode" in
        lan|tailscale|funnel|gateway) ;;
        *)
            echo "HerdRelay: неизвестный режим '$mode' (lan|tailscale|funnel|gateway)" >&2
            return 1
            ;;
    esac
    if [[ "$mode" == "gateway" && -z "$gw" ]]; then
        echo "HerdRelay: для режима gateway нужен URL шлюза (HERDRELAY_GATEWAY_URL)" >&2
        return 1
    fi
    if [[ "$mode" == "funnel" ]]; then
        if command -v tailscale >/dev/null 2>&1; then
            echo "HerdRelay: включаю tailscale funnel :8375..."
            tailscale funnel 8375 \
                || echo "HerdRelay: не удалось включить funnel — сделайте вручную: tailscale funnel 8375" >&2
        else
            echo "HerdRelay: tailscale не найден в PATH — включите funnel вручную: tailscale funnel 8375" >&2
        fi
    fi
    write_relay_plist "$mode" "$HERDR_BIN" "$gw"
    echo "HerdRelay: режим изменён на '$mode'."
    echo "Проверка: herdrelay status ; QR для телефона: herdrelay pair --qr"
}

# Non-interactive: configure.sh <mode> [gateway_url]
if [[ -n "${1:-}" ]]; then
    apply_mode "$1" "${2:-}"
    exit $?
fi

# Interactive menu requires a tty; otherwise hint at the arg form.
if [[ ! -t 0 ]]; then
    echo "HerdRelay: нет интерактивного ввода — укажите режим аргументом:" >&2
    echo "  bash plugin/configure.sh lan|tailscale|funnel|gateway [URL]" >&2
    exit 1
fi

CUR="$(current_mode)"; CUR="${CUR:-lan}"

echo "HerdRelay: выбор режима подключения"
echo ""
echo "Текущий режим: $CUR"
echo ""
echo "  1) lan        — локальная сеть (по умолчанию)"
echo "  2) tailscale  — VPN-сеть Tailscale (удалённо, без проброса портов)"
echo "  3) funnel     — публичный URL через tailscale funnel (доступ из интернета)"
echo "  4) gateway    — подключение через центральный шлюз (HERDRELAY_GATEWAY_URL)"
echo "  Enter — оставить '$CUR'"
echo ""
read -rp "Выберите [1-4 / Enter]: " choice

case "$choice" in
    "") apply_mode "$CUR" "$(current_gw)" ;;
    1)  apply_mode "lan" ;;
    2)  apply_mode "tailscale" ;;
    3)  apply_mode "funnel" ;;
    4)
        read -rp "URL шлюза (HERDRELAY_GATEWAY_URL): " gwu
        if [[ -z "$gwu" ]]; then
            echo "HerdRelay: URL обязателен для режима gateway" >&2
            exit 1
        fi
        apply_mode "gateway" "$gwu"
        ;;
    *)
        echo "HerdRelay: неверный выбор ($choice)" >&2
        exit 1
        ;;
esac
