# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.3.x   | :white_check_mark: |
| < 0.3   | :x:                |

## Reporting a Vulnerability

If you discover a security vulnerability in Herdr Mobile, please report it responsibly:

### Preferred Method: GitHub Security Advisories

Use GitHub's private vulnerability reporting:

https://github.com/teasec4/herdr-mobile-app/security/advisories/new

This allows us to discuss and fix the issue privately before public disclosure.

### Alternative: Email

If you prefer, you can email security concerns to the maintainer. Please include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if you have one)

### What to Expect

- **Initial Response**: Within 48 hours
- **Status Update**: Within 7 days
- **Fix Timeline**: Depends on severity
  - Critical: Patch within 7 days
  - High: Patch within 30 days
  - Medium/Low: Next scheduled release

### What NOT to Do

- **Do not** open a public GitHub issue for security vulnerabilities
- **Do not** disclose the vulnerability publicly until we've released a fix
- **Do not** exploit the vulnerability beyond what's necessary to demonstrate it

## Security Considerations

### Token Security

Herdr Mobile uses cryptographically secure tokens for authentication:
- Tokens are generated using Go's `crypto/rand`
- Tokens are stored locally at `~/.config/herdr/herdrelay.token`
- Never share your token or QR code publicly

### Network Security

- **LAN mode**: Unencrypted WebSocket (use only on trusted networks)
- **Tailscale mode**: End-to-end encrypted via Tailscale
- **Funnel mode**: HTTPS via Tailscale Funnel
- **Gateway mode**: WSS (encrypted WebSocket)

**Recommendation**: Use Tailscale mode for remote access to ensure encryption.

### Best Practices

1. **Rotate tokens regularly** if you suspect compromise:
   ```bash
   rm ~/.config/herdr/herdrelay.token
   launchctl kickstart -k gui/$(id -u)/com.herdrelay.relay
   ```

2. **Don't share QR codes** in screenshots or public channels

3. **Use Tailscale** when accessing from outside your home network

4. **Keep dependencies updated**: Run `go mod tidy` and `flutter pub upgrade` regularly

5. **Review logs** for suspicious connection attempts:
   ```bash
   tail -f ~/.local/state/herdrelay/relay.log
   ```

## Scope

This security policy applies to:
- Herdr Mobile relay server (Go)
- Herdr Mobile mobile app (Flutter)
- Herdr Mobile herdr plugin

For security issues in herdr itself, please report to the [herdr project](https://herdr.dev).

## Acknowledgments

We appreciate responsible disclosure and will acknowledge security researchers who help improve Herdr Mobile's security (with their permission).

---

Thank you for helping keep Herdr Mobile secure!
