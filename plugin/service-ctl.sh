#!/usr/bin/env bash
# Control the Herdr Mobile relay launchd service (macOS).
#
# Usage:
#   bash plugin/service-ctl.sh start|stop|restart|uninstall
#
# Registered as herdr [[actions]] so the user can manage the relay service
# from herdr (e.g. after `herdr plugin install`):
#   herdr plugin action invoke herdrelay.events.restart
#
# uninstall removes the launchd service and plist but KEEPS the pairing state
# (~/.config/herdr/herdrelay.token + herdrelay.id), so a later install
# reconnects the phone without scanning a new QR.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/relay-lib.sh"

PLIST="$(relay_plist_path)"
LOG_DIR="$(relay_log_dir)"
PORT="${HERDRELAY_PORT:-8375}"
TARGET="gui/$(id -u)/com.herdrelay.relay"

CMD="${1:-}"
case "$CMD" in
    start | stop | restart | uninstall) ;;
    *)
        echo "usage: $0 start|stop|restart|uninstall" >&2
        exit 2
        ;;
esac

log() { echo "Herdr Mobile: $*"; }
log_err() { echo "Herdr Mobile: $*" >&2; }

wait_health() {
    for _ in $(seq 1 10); do
        if curl -s -m 2 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

service_start() {
    # Load if not loaded, then start regardless of RunAtLoad.
    launchctl print "$TARGET" >/dev/null 2>&1 \
        || launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 \
        || launchctl load "$PLIST" >/dev/null 2>&1 || true
    launchctl kickstart "$TARGET" >/dev/null 2>&1 \
        || launchctl start com.herdrelay.relay >/dev/null 2>&1 || true
    if wait_health; then
        log "relay is running on :${PORT}"
    else
        log_err "relay did not answer on :${PORT} — see $LOG_DIR/relay.err.log"
        return 1
    fi
}

service_stop() {
    launchctl bootout "$TARGET" >/dev/null 2>&1 \
        || launchctl unload "$PLIST" >/dev/null 2>&1 || true
    log "relay service stopped (plist kept; start again with: bash plugin/service-ctl.sh start)"
}

service_restart() {
    service_stop
    service_start
}

service_uninstall() {
    launchctl bootout "$TARGET" >/dev/null 2>&1 \
        || launchctl unload "$PLIST" >/dev/null 2>&1 || true
    rm -f "$PLIST"
    log "relay service uninstalled ($PLIST removed)."
    log "pairing state is KEPT:"
    log "  - $HOME/.config/herdr/herdrelay.token"
    log "  - $HOME/.config/herdr/herdrelay.id"
    log "re-run 'bash plugin/install.sh' (or the herdr plugin build) to reinstall without re-pairing."
}

case "$CMD" in
    start)      service_start ;;
    stop)       service_stop ;;
    restart)    service_restart ;;
    uninstall)  service_uninstall ;;
esac
