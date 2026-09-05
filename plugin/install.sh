#!/usr/bin/env bash
# Herdr Mobile plugin [[build]] step.
#
# What it does: obtains the relay binary (downloads the prebuilt release
# artifact for this platform/version, falling back to `go build` when the
# release is unavailable), then installs a launchd autostart service (macOS).
# The relay is a separate system service, not a herdr process, so it survives
# herdr restarts.
#
# When it runs: `herdr plugin install` invokes this script after confirmation.
# `herdr plugin link` does NOT run build — for local development run it by hand:
#   bash plugin/install.sh
#
# Binary source precedence:
#   1. Release artifact:  GitHub Release v<manifest version>, downloaded as
#      herdrelay-<ver>-<os>-<arch>.tar.gz and verified against its .sha256 —
#      no Go toolchain required on the host.
#   2. Source build:      fallback `go build` from the repo root (needs `go`);
#      used before the first tagged release, for unreleased versions, or when
#      HERDRELAY_FORCE_BUILD=1.
#
# Side effects:
#   - ~/.local/bin/herdrelay                            built relay binary (stable path)
#   - ~/Library/LaunchAgents/com.herdrelay.relay.plist   launchd service
#   - ${XDG_STATE_HOME:-$HOME/.local/state}/herdrelay/   service logs
#
# Why ~/.local/bin and not plugin/bin: herdr runs [[build]] from a temporary
# checkout and moves it to its managed location afterwards (and replaces it on
# reinstall), so a launchd plist must never point inside the plugin root.
# Override the binary location with HERDRELAY_BIN.
#
# Environment:
#   HERDRELAY_BIN             absolute relay binary path (default ~/.local/bin/herdrelay)
#   HERDRELAY_FORCE_BUILD     1 to skip the release download and always `go build`
#   HERDRELAY_RELEASE_BASE_URL override the release download base URL (testing)
#   HERDRELAY_MODE            lan | tailscale | funnel | gateway (default: lan)
#   HERDRELAY_GATEWAY_URL     required only for mode=gateway
#   HERDRELAY_PORT            port used by the healthz check (default 8375)
#   XDG_STATE_HOME            log dir base (default ~/.local/state)
#   HERDR_BIN                 absolute herdr binary (default: from PATH)
set -euo pipefail

# Plugin root = the script's directory (HERDR_PLUGIN_ROOT may not be set during
# [[build]], same as in the persiyanov/herdr-reviewr reference).
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
source "$ROOT/relay-lib.sh"

BIN="$(relay_bin_path)"
BIN_DIR="$(dirname "$BIN")"
LOG_DIR="$(relay_log_dir)"
PORT="${HERDRELAY_PORT:-8375}"
MODE="${HERDRELAY_MODE:-lan}"
GW="${HERDRELAY_GATEWAY_URL:-}"

log() { echo "Herdr Mobile: $*"; }
log_err() { echo "Herdr Mobile: $*" >&2; }

# herdr lives in a user-local dir that launchd's minimal PATH does not include,
# so resolve its absolute path here and hand it to the relay via env.
HERDR_BIN="${HERDR_BIN:-$(command -v herdr || true)}"
if [ -z "$HERDR_BIN" ]; then
    log_err "warning: herdr not found in PATH — the relay will still run,"
    log_err "but herdr-socket integration (event subscription) will be unavailable."
    log_err "install herdr, then re-run install.sh to enable it."
fi

mkdir -p "$BIN_DIR"

# --- obtain the binary ------------------------------------------------------

target=""
case "$(uname -s):$(uname -m)" in
    Darwin:arm64 | Darwin:aarch64) target="darwin-arm64" ;;
    Darwin:x86_64 | Darwin:amd64)  target="darwin-amd64" ;;
    Linux:arm64 | Linux:aarch64)   target="linux-arm64" ;;
    Linux:x86_64 | Linux:amd64)    target="linux-amd64" ;;
    *) log_err "unsupported platform $(uname -s)/$(uname -m) — falling back to source build" ;;
esac

version="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)"/\1/p' "$ROOT/herdr-plugin.toml" | head -1)"

downloaded=0
if [ -n "$target" ] && [ "${HERDRELAY_FORCE_BUILD:-0}" != "1" ] && [ -n "$version" ]; then
    base="${HERDRELAY_RELEASE_BASE_URL:-https://github.com/teasec4/herdr-mobile-app/releases/download/v$version}"
    archive="herdrelay-${version}-${target}.tar.gz"
    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/herdrelay-install.XXXXXX")"
    trap 'rm -rf "$tmp_dir"' EXIT
    if curl -fsSL --retry 3 --connect-timeout 10 -o "$tmp_dir/$archive" "$base/$archive" \
        && curl -fsSL --retry 3 --connect-timeout 10 -o "$tmp_dir/$archive.sha256" "$base/$archive.sha256"; then
        # Verify sha256 (shasum on macOS/BSD, sha256sum on Linux, openssl fallback).
        want="$(awk '{print $1}' "$tmp_dir/$archive.sha256")"
        got=""
        if command -v shasum >/dev/null 2>&1; then
            got="$(shasum -a 256 "$tmp_dir/$archive" | awk '{print $1}')"
        elif command -v sha256sum >/dev/null 2>&1; then
            got="$(sha256sum "$tmp_dir/$archive" | awk '{print $1}')"
        elif command -v openssl >/dev/null 2>&1; then
            got="$(openssl dgst -sha256 "$tmp_dir/$archive" | awk '{print $NF}')"
        else
            log_err "no sha256 tool found (shasum/sha256sum/openssl) — refusing unsigned download"
        fi
        if [ -n "$want" ] && [ "$want" = "$got" ]; then
            log "downloading herdrelay v$version ($target)..."
            tar -xzf "$tmp_dir/$archive" -C "$tmp_dir"
            mv "$tmp_dir/herdrelay" "$BIN"
            chmod 0755 "$BIN"
            downloaded=1
            log "installed release binary v$version to $BIN"
        else
            log_err "sha256 mismatch for $archive (want $want, got $got) — falling back to source build"
        fi
    else
        log_err "release v$version not published yet for $target — falling back to source build"
    fi
    rm -rf "$tmp_dir"
    trap - EXIT
fi

if [ "$downloaded" -ne 1 ]; then
    if command -v go >/dev/null 2>&1; then
        log "building relay binary from source ($BIN)..."
        ( cd "$REPO_ROOT" && go build -o "$BIN" ./cmd/relay )
    else
        log_err "no release artifact and no Go toolchain — cannot build the relay."
        log_err "install Go and re-run install.sh, or run it once a v$version release exists."
        exit 1
    fi
fi

# --- launchd service --------------------------------------------------------

log "installing launchd service (mode=$MODE)..."
write_relay_plist "$MODE" "$HERDR_BIN" "$GW"

log "service installed. Checking relay..."
up=0
for _ in $(seq 1 10); do
    if curl -s -m 2 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
        up=1
        break
    fi
    # The plist is written with RunAtLoad, but a plain `load` is unreliable on
    # modern macOS — actively start the job if it did not come up on its own.
    launchctl kickstart "gui/$(id -u)/com.herdrelay.relay" >/dev/null 2>&1 || true
    sleep 1
done
if [ "$up" -ne 1 ]; then
    log_err "relay did not come up on :${PORT} within ~10s"
    log_err "check $LOG_DIR/relay.err.log for errors."
    log_err "re-run 'bash plugin/install.sh', or start the service with:"
    log_err "  launchctl kickstart -k gui/$(id -u)/com.herdrelay.relay"
    exit 1
fi
log "relay is running on :${PORT}"
