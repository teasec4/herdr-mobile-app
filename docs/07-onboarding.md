# 07 — Onboarding: "point at the QR and it works"

## Problem

For an open-source project, requiring users to "spin up a VPS, configure a
domain, TLS, and a gateway" is an insurmountable barrier. The goal is:

1. Install the plugin on the laptop (`herdr plugin install ...`).
2. Open the "Herdr Mobile: Setup" pane.
3. Point the phone at the QR code.
4. Done.

No VPS, no sign-up, no typing addresses by hand. A VPS stays an option for
those who genuinely need it.

**Status: LAN onboarding is verified live** — the relay prints a QR, the phone
scans it (with the system camera or the built-in scanner), the app opens and
connects (mode A, home network). Tailscale (B1) and funnel (B2) have not been
tested on a device yet.

## Model: the relay generates the QR, the phone scans it

- On first start the relay generates a pairing token and detects the available
  connection modes.
- The plugin's "show QR" action/pane asks the relay for `GET /pair` and draws
  the QR inside the herdr pane.
- The QR is a single custom-scheme link. The phone scans it (system camera or
  the scanner built into the app) → the app opens, saves the config, connects
  over WS. Scanning again = "switch mode"; the profile remembers the addresses
  of **all** relay modes and can switch offline (see "Connection profiles"
  below).

## Pair link URL scheme

`herdrelay://pair?mode=<mode>&token=<T>&...`

| mode | QR content | when |
| --- | --- | --- |
| `lan` | `herdrelay://pair?mode=lan&host=192.168.1.100&port=8375&relay_id=R&name=macbook&token=T` | phone on the same Wi-Fi as the laptop |
| `tailscale` (B1) | `herdrelay://pair?mode=tailscale&host=<your-machine>.<tailnet>.ts.net&port=8375&relay_id=R&name=macbook&token=T` | phone in the same tailnet |
| `funnel` (B2) | `herdrelay://pair?mode=funnel&host=<your-machine>.<tailnet>.ts.net&relay_id=R&name=macbook&token=T` | phone does not need Tailscale (public HTTPS) |
| `gateway` (C) | `herdrelay://pair?mode=gateway&url=wss://gw.example.com/ws&relay_id=R&name=macbook&token=T` | VPS gateway (optional) |

`relay_id` and `name` identify the relay (see below).

### Relay identity (relay_id)

Every pair link carries a stable `relay_id` (32 hex, generated on the relay's
first start, stored in `~/.config/herdr/herdrelay.id`) and a human-readable
`name` (the hostname). The client uses `relay_id` to recognize the same relay
across sessions or when it moves to another machine, and shows `name` in the
list of saved connections. See your own `relay_id`/`name` with:
`herdrelay status`.

### Connection profiles (several machines/modes)

The client stores several pair profiles (switching with `Switch` / adding with
`Add` / deleting with `Forget`):

- **Add** — a new QR adds a profile without erasing the previous ones.
- **Switch** — choose between saved profiles: handy when changing networks
  (`lan` at home → `tailscale` on the road → `funnel`/`gateway` from the
  internet) or when working with several computers.
- **Forget** — deletes a profile.

The app parses the link, stores the base URL + token in `shared_preferences`
and connects. If the host resolves to an unreachable address it shows an error
and offers to "look at another QR" (for example, switch from `lan` to
`tailscale` when the network changes).

### Mode = endpoint (the profile remembers all relay addresses)

One relay is reachable at several addresses (LAN IP, tailnet name, funnel URL).
A profile (`PairConfig`) keeps them in `endpoints: {mode → host:port}` — see
`docs/05-flutter-app.md` → mode badge:

- **Seeding**: the pair link writes the endpoint of its own mode; legacy
  profiles (without `endpoints`) get it automatically on load.
- **Enrichment**: every successful `GET /pair` appends the addresses of all
  modes to the profile (`withEndpoints`); switching uses `connectVia` (the
  other modes' addresses are not lost).
- **Offline switching**: if the current mode is unreachable (for example,
  Tailscale is off at home), the picker shows "Saved modes for this relay" — a
  choice of saved endpoints without the network; manual entry as a fallback
  (the host follows the mode, the token comes from the profile).

## Why a custom scheme instead of an http link

- An app will not open an http link to a LAN IP or a MagicDNS name
  automatically: "universal links" / App Links require an HTTPS domain with an
  AASA file on it, which does not work on a local network/Tailscale.
- A custom scheme (`herdrelay://`) opens the app always and everywhere, with no
  public domain. This is the standard mechanism on iOS (Info.plist
  `CFBundleURLTypes`) and Android (intent-filter).

## Mode auto-detection (wizard in the relay/plugin)

On `GET /pair` the relay returns only the modes that are actually available:

- **A (lan):** the LAN IP via `ipconfig getifaddr en0` (macOS) or
  `hostname -I` (Linux). Always available.
- **B1 (tailscale):** if `tailscale status` shows a live tailnet — take the
  `DNSName` from `tailscale status --json` (the machine's MagicDNS name). The
  port is open in the tailnet automatically (WireGuard), nothing to configure.
- **B2 (funnel):** a single command `tailscale funnel 8375`; enabled at the
  user's choice in the wizard pane (not by default — the address is public).
  After that the QR carries `https://<your-machine>.<tailnet>.ts.net`.
- **C (gateway):** only if `HERDRELAY_GATEWAY_URL` is set in the relay config.

The wizard pane in herdr shows a large QR for the selected mode plus mode
selection buttons (the default is the first available: `lan` → `tailscale` →
`funnel` → `gateway`). The same screen has "show/reset token" (rotation if the
QR was exposed).

## Health check: `herdrelay status`

`herdrelay status` prints the mode, the address, the relay identity (`relay_id`
and `name`), config paths and the live state:

- if the relay is running — the `primary` mode, the list of all available modes
  with URLs and the hint `herdrelay pair --qr`;
- if it is not running — "Status: NOT RUNNING" and how to start the service;
- exit code 0 = the relay is running, 1 = not (handy for scripts and checks).

## Changing the mode

Switch the mode without rebuilding the binary — the plugin action
"Herdr Mobile: configure mode", or manually:
`bash plugin/configure.sh <mode> [gateway_url]` (`lan | tailscale | funnel | gateway`).
The script rewrites the launchd config (`HERDRELAY_MODE`, for `gateway` —
`HERDRELAY_GATEWAY_URL`) and restarts the service via launchctl; choosing
`funnel` tries to enable `tailscale funnel 8375`. After switching modes, update
the QR on the phone (`herdrelay pair --qr`) — rescanning switches the mode of
the existing profile.

## Flow for an OSS user (no VPS)

1. `herdr plugin install <owner>/<repo>/plugin` → `[[build]]` builds/downloads
   the relay, installs the launchd service, the relay creates the token.
2. In herdr: "Herdr Mobile: Setup" pane → the QR is visible (the mode is chosen by
   auto-detect, usually `lan`).
3. Point the phone at it → the app opens and connects. Done.
4. Left home → switch the mode to `tailscale` in the app/on the laptop (or
   `funnel` if the phone has no Tailscale) → scan the new QR.

In short, for "personal" use and for most users **Tailscale on the laptop**
(it is free, personal plan) + the Tailscale app on the phone is enough. No VPS
needed at all.

## QR security

- The QR carries the pairing token — it is a secret. Show it in the pane on
  request (an action), not in logs. The token is rotated by the "reset token"
  action.
- The `funnel` (public) and `gateway` modes require the token and check it on
  every request/connect.
- In `lan`/`tailscale` modes the traffic is not TLS (inside a trusted
  network/WireGuard); if you want to secure it too — use `funnel` or `gateway`
  (those are HTTPS/WSS).

## What's next

- v1 (done): QR + custom scheme + wizard pane; verified over LAN from a phone.
- v2+: if the phone sees a network where the current mode does not resolve —
  offer to "show the QR again" (push/notification) or auto-switch based on the
  network.
