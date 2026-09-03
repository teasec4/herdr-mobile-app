# Tailscale Remote Access

The app supports three connection modes to the relay:

## 1. LAN (local network)
**When to use:** At home or in the office, when the phone and the computer are on the same Wi-Fi network.

**Setup:** No extra configuration — works automatically.

**Example link:**
```
herdrelay://pair?host=192.168.1.100&port=8375&mode=lan&token=...
```

## 2. Tailscale (VPN)
**When to use:** Remote access through the Tailscale VPN. A secure connection from anywhere in the world.

**Setup:**
1. Install Tailscale on the computer: https://tailscale.com/download
2. Install Tailscale on the phone from the App Store / Google Play
3. Sign in to the same account on both devices
4. Run Tailscale on both devices
5. The relay automatically detects Tailscale and offers this mode

**Example link:**
```
herdrelay://pair?host=<your-machine>.<tailnet>.ts.net&port=8375&mode=tailscale&token=...
```

**Advantages:**
- Works from anywhere (home, a cafe, another city)
- Encrypted connection
- No need to open ports on the router
- Free for personal use

## 3. Funnel (public HTTPS)
**When to use:** When you need public access or Tailscale is not available on the phone.

**Setup:**
1. Enable Tailscale Funnel on the computer:
   ```bash
   tailscale funnel --bg 8375
   ```
2. The relay automatically offers the funnel mode

**Example link:**
```
herdrelay://pair?host=<your-machine>.<tailnet>.ts.net&mode=funnel&token=...
```

**Important:**
- Uses HTTPS (secure connection)
- Does not require Tailscale on the phone
- The relay becomes publicly reachable (protected by the token)

## How to switch the mode

1. Open Settings in the app
2. Tap "Disconnect"
3. Scan the QR code again or paste a new link with a different mode

## Checking the available modes

On the computer run:
```bash
curl "http://localhost:8375/pair?token=$(cat ~/.config/herdr/herdrelay.token)" | python3 -m json.tool
```

You will see the list of available modes in the `urls` section.
