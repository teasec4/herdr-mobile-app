#!/usr/bin/env bash
# HerdRelay: switch the connection mode (lan / tailscale / funnel / gateway).
#
# Interactive menu, or non-interactively:
#   bash plugin/configure.sh <mode> [gateway_url]
#
# What it does: rewrites the launchd plist with a new HERDRELAY_MODE and
# restarts the service via launchctl. Does NOT rebuild the binary (unlike
# install.sh).
#
# Modes (docs/03-relay.md):
#   lan       local network (default)
#   tailscale Tailscale VPN, remote access without port forwarding
#   funnel    public URL via tailscale funnel, internet access
#   gateway   connection through the central gateway (requires HERDRELAY_GATEWAY_URL)
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
            echo "HerdRelay: unknown mode '$mode' (lan|tailscale|funnel|gateway)" >&2
            return 1
            ;;
    esac
    if [[ "$mode" == "gateway" && -z "$gw" ]]; then
        echo "HerdRelay: gateway mode requires a gateway URL (HERDRELAY_GATEWAY_URL)" >&2
        return 1
    fi
    if [[ "$mode" == "funnel" ]]; then
        if command -v tailscale >/dev/null 2>&1; then
            echo "HerdRelay: enabling tailscale funnel :8375..."
            tailscale funnel 8375 \
                || echo "HerdRelay: failed to enable funnel — run it manually: tailscale funnel 8375" >&2
        else
            echo "HerdRelay: tailscale not found in PATH — enable funnel manually: tailscale funnel 8375" >&2
        fi
    fi
    write_relay_plist "$mode" "$HERDR_BIN" "$gw"
    echo "HerdRelay: mode changed to '$mode'."
    echo "Check: herdrelay status ; phone QR: herdrelay pair --qr"
}

# Non-interactive: configure.sh <mode> [gateway_url]
if [[ -n "${1:-}" ]]; then
    apply_mode "$1" "${2:-}"
    exit $?
fi

# Interactive menu requires a tty; otherwise hint at the arg form.
if [[ ! -t 0 ]]; then
    echo "HerdRelay: no interactive input — pass the mode as an argument:" >&2
    echo "  bash plugin/configure.sh lan|tailscale|funnel|gateway [URL]" >&2
    exit 1
fi

CUR="$(current_mode)"; CUR="${CUR:-lan}"

echo "HerdRelay: connection mode"
echo ""
echo "Current mode: $CUR"
echo ""
echo "  1) lan        — local network (default)"
echo "  2) tailscale  — Tailscale VPN (remote, no port forwarding)"
echo "  3) funnel     — public URL via tailscale funnel (internet access)"
echo "  4) gateway    — connect through the central gateway (HERDRELAY_GATEWAY_URL)"
echo "  Enter — keep '$CUR'"
echo ""
read -rp "Choose [1-4 / Enter]: " choice

case "$choice" in
    "") apply_mode "$CUR" "$(current_gw)" ;;
    1)  apply_mode "lan" ;;
    2)  apply_mode "tailscale" ;;
    3)  apply_mode "funnel" ;;
    4)
        read -rp "Gateway URL (HERDRELAY_GATEWAY_URL): " gwu
        if [[ -z "$gwu" ]]; then
            echo "HerdRelay: a URL is required for gateway mode" >&2
            exit 1
        fi
        apply_mode "gateway" "$gwu"
        ;;
    *)
        echo "HerdRelay: invalid choice ($choice)" >&2
        exit 1
        ;;
esac