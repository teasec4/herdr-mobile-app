# Installation Guide

## Prerequisites

- **macOS/Linux**: Working installation
- **[herdr](https://herdr.dev)**: Version 0.8.0 or higher
- **Go**: Version 1.26+ (for building from source)
- **Flutter**: Version 3.44+ (for building mobile app from source)

## Quick Install (Recommended)

### Step 1: Install the Plugin

```bash
herdr plugin install teasec4/herdr-mobile-app/plugin
```

This command will:
- Download the plugin
- Build the relay binary
- Install and start the relay as a system service (launchd on macOS)
- Generate a pairing token

### Step 2: Get the QR Code

In herdr, open the pairing screen:

```bash
herdr plugin action invoke show-pair-link --plugin herdrelay.events
```

Or use the menu: **Herdr Mobile → Show phone link / QR**

### Step 3: Install Mobile App

**Android:**
- Download the APK from the [Releases](https://github.com/teasec4/herdr-mobile-app/releases) page
- Install on your phone
- Grant necessary permissions

**iOS:**
- Coming soon (requires TestFlight or App Store)

### Step 4: Connect

1. Open the mobile app
2. Tap "Scan QR code" or use your camera app
3. Point at the QR code from Step 2
4. The app will connect automatically

Done! You can now manage herdr agents from your phone.

## Connection Modes

The relay automatically detects available connection modes:

### Mode A: LAN (Local Network)
- **When**: Phone and laptop on the same WiFi
- **Setup**: Automatic (default mode)
- **URL format**: `http://192.168.x.x:8375`

### Mode B1: Tailscale (Direct)
- **When**: Both devices in the same Tailscale network
- **Setup**: Install [Tailscale](https://tailscale.com) on both devices
- **URL format**: `http://machine.tailnet.ts.net:8375`
- **Benefit**: Works anywhere, no public exposure

### Mode B2: Tailscale Funnel (Public HTTPS)
- **When**: Phone doesn't have Tailscale
- **Setup**: Run `tailscale funnel 8375` on laptop
- **URL format**: `https://machine.tailnet.ts.net`
- **Note**: Creates a public HTTPS endpoint

### Mode C: Gateway (Optional VPS)
- **When**: Maximum security or corporate firewall bypass
- **Setup**: Deploy gateway (see [docs/04-gateway.md](docs/04-gateway.md))
- **URL format**: `wss://your-gateway.com/ws`

## Best Practices for Remote Access

### Setup Checklist

**Before first pairing:**

1. Install Tailscale on the laptop: `brew install tailscale && sudo tailscale up`
2. Install the Tailscale app on the phone
3. Restart the relay: `bash plugin/redeploy.sh`
4. Scan the QR code — all modes are saved automatically

**Switching networks:**

- At home: **LAN** (fastest)
- Away: **Tailscale** (automatic fallback)
- Without Tailscale: **Funnel** (public HTTPS)

### Troubleshooting

**Problem: "Can't connect when away from home"**

Solution:

1. Open the Connection page → "Switch mode manually"
2. Select "Tailscale"
3. Enter your relay hostname (e.g., `mac.tailnet.ts.net`)
4. Connect

**Problem: "Only LAN mode available"**

This means Tailscale wasn't running during QR generation.

Solution:

1. On the laptop: `sudo tailscale up`
2. Restart the relay: `bash plugin/redeploy.sh`
3. On the phone: open the Connection page → "Refresh modes"
4. Select the Tailscale mode

## Configuration

### Change Connection Mode

```bash
# Switch to Tailscale mode
bash plugin/configure.sh tailscale

# Switch to Funnel mode
bash plugin/configure.sh funnel

# Back to LAN
bash plugin/configure.sh lan
```

After changing modes, scan the new QR code in the app.

### Check Status

```bash
# Via relay command (from the repo root)
./plugin/bin/herdrelay status

# Via health check
curl http://127.0.0.1:8375/healthz
```

### View Logs

```bash
# Relay logs
tail -f ~/.local/state/herdrelay/relay.log
tail -f ~/.local/state/herdrelay/relay.err.log

# Plugin logs
herdr plugin log list --plugin herdrelay.events
```

## Troubleshooting

### Relay Not Starting

```bash
# Check if service is loaded
launchctl list | grep herdrelay

# Restart the service
launchctl kickstart -k gui/$(id -u)/com.herdrelay.relay

# Check logs
cat ~/.local/state/herdrelay/relay.err.log
```

### Phone Can't Connect

1. **LAN mode**: Verify both devices on same WiFi
2. **Tailscale mode**: Check `tailscale status` on both devices
3. **Firewall**: Ensure port 8375 is not blocked
4. **Token**: Rescan QR if connection fails (token may have changed)

### Reset Pairing Token

```bash
# Regenerate token and show new QR (from the repo root)
./plugin/bin/herdrelay pair --qr
```

## Building from Source

### Relay Binary

```bash
git clone https://github.com/teasec4/herdr-mobile-app.git
cd herdr_relay
go build -o plugin/bin/herdrelay ./cmd/relay
bash plugin/install.sh
```

### Mobile App

```bash
cd client
flutter pub get
flutter test  # Run 259 tests

# Android
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk

# iOS
flutter build ios --release
```

## Uninstall

```bash
# Stop and remove service (macOS)
launchctl bootout gui/$(id -u)/com.herdrelay.relay
rm ~/Library/LaunchAgents/com.herdrelay.relay.plist

# Remove plugin
herdr plugin uninstall herdrelay.events

# Remove data (optional)
rm -rf ~/.config/herdr/herdrelay.*
rm -rf ~/.local/state/herdrelay
```

## Next Steps

- Read [Architecture Overview](docs/01-architecture.md)
- Learn about [QR Onboarding](docs/07-onboarding.md)
- Check the [Roadmap](docs/06-roadmap.md)

## Getting Help

- **Issues**: [GitHub Issues](https://github.com/teasec4/herdr-mobile-app/issues)
- **Discussions**: [GitHub Discussions](https://github.com/teasec4/herdr-mobile-app/discussions)
- **herdr Community**: [herdr.dev](https://herdr.dev)
