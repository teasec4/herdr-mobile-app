#!/usr/bin/env bash
# Shared helpers for Herdr Mobile plugin scripts (install.sh, configure.sh).
# Source this file — it is not meant to be executed directly:
#   source "$(dirname "$0")/relay-lib.sh"
#
# Provides:
#   relay_plist_path                          -> launchd plist path
#   relay_log_dir                             -> service log directory
#   write_relay_plist MODE HERDR_BIN [GW_URL]
#       Writes the launchd plist with the given mode / herdr binary / optional
#       gateway URL, then (re)loads the service via launchctl (macOS only).
set -euo pipefail

# Directory of this library file (stable even when sourced from another script).
RELAY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

relay_plist_path() {
    echo "$HOME/Library/LaunchAgents/com.herdrelay.relay.plist"
}

# Stable location of the relay binary, independent of the plugin directory.
#
# herdr runs [[build]] (install.sh) from a temporary checkout that it moves to
# its final managed location afterwards, and it replaces that checkout on
# reinstall — so a launchd plist must never point inside the plugin root. The
# binary therefore lives under ~/.local/bin (override with HERDRELAY_BIN).
relay_bin_path() {
    echo "${HERDRELAY_BIN:-${XDG_BIN_HOME:-$HOME/.local/bin}/herdrelay}"
}

relay_log_dir() {
    echo "${XDG_STATE_HOME:-$HOME/.local/state}/herdrelay"
}

# write_relay_plist MODE HERDR_BIN [GATEWAY_URL]
# MODE: lan | tailscale | funnel | gateway (see docs/03-relay.md)
# HERDR_BIN: absolute path to the herdr binary (launchd has a minimal PATH).
# GATEWAY_URL: required only for mode=gateway, omitted otherwise.
write_relay_plist() {
    local mode="$1"
    local herdr_bin="$2"
    local gateway_url="${3:-}"
    local relay_bin="$(relay_bin_path)"
    local plist log_dir gw_block

    plist="$(relay_plist_path)"
    log_dir="$(relay_log_dir)"
    mkdir -p "$log_dir"

    gw_block=""
    if [[ -n "$gateway_url" ]]; then
        gw_block="    <key>HERDRELAY_GATEWAY_URL</key>
    <string>$gateway_url</string>"
    fi

    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.herdrelay.relay</string>
  <key>ProgramArguments</key>
  <array>
    <string>$relay_bin</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$log_dir/relay.log</string>
  <key>StandardErrorPath</key>
  <string>$log_dir/relay.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HERDRELAY_MODE</key>
    <string>$mode</string>
    <key>HERDRELAY_HERDR_BIN</key>
    <string>$herdr_bin</string>
$gw_block  </dict>
</dict>
</plist>
EOF

    if command -v launchctl >/dev/null 2>&1; then
        local target="gui/$(id -u)/com.herdrelay.relay"
        # Unload any previous instance, then load the new plist. `launchctl load`
        # alone does not reliably honor RunAtLoad on modern macOS (the job ends up
        # loaded but not running), so kickstart the job afterwards.
        launchctl bootout "$target" >/dev/null 2>&1 || true
        launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 || \
            launchctl load "$plist" >/dev/null 2>&1 || true
        launchctl kickstart -k "$target" >/dev/null 2>&1 || \
            launchctl start com.herdrelay.relay >/dev/null 2>&1 || true
    else
        echo "Herdr Mobile: launchctl not found — plist written, service reload skipped"
    fi
}
