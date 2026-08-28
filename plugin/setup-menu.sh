#!/usr/bin/env bash
# Пейн «HerdRelay: Setup» — статус релея и ссылка/QR для телефона.
# Открывается экшеном show-pair-link (или: herdr plugin pane open --plugin
# herdrelay.events --entrypoint setup).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/bin/herdrelay"
PORT="${HERDRELAY_PORT:-8375}"

echo "== HerdRelay: status =="
if curl -s -m 2 "http://127.0.0.1:${PORT}/healthz" >/dev/null; then
    echo "relay: running on :${PORT}"
    echo
    echo "== Phone link / QR (сканируй в приложении HerdRelay) =="
    if [ -x "$BIN" ]; then
        "$BIN" pair --qr
    else
        echo "relay binary missing: run 'bash $ROOT/install.sh'" >&2
    fi
else
    echo "relay: NOT running"
    echo "Start it: launchctl start com.herdrelay.relay   (or 'bash $ROOT/install.sh')"
fi

echo
echo "This pane closes by itself."
sleep 15
