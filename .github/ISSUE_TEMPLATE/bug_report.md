---
name: Bug report
about: Report a bug or unexpected behavior
title: '[BUG] '
labels: bug
assignees: ''
---

## Bug Description
A clear and concise description of what the bug is.

## Steps to Reproduce
1. Go to '...'
2. Run command '...'
3. Scan QR code '...'
4. See error

## Expected Behavior
What you expected to happen.

## Actual Behavior
What actually happened.

## Environment
- **OS**: [e.g., macOS 14.5, Ubuntu 22.04]
- **herdr version**: [run `herdr --version`]
- **Relay version**: [check plugin/bin/herdrelay or releases]
- **Connection mode**: [LAN / Tailscale / Funnel / Gateway]
- **Mobile OS**: [e.g., iOS 17.5 / Android 14]

## Logs

### Relay logs
```
# Paste output from:
# tail -50 ~/.local/state/herdrelay/relay.err.log
```

### Plugin logs
```
# Paste output from:
# herdr plugin log list --plugin herdrelay.events
```

### Mobile app logs
```
# If applicable, paste any error messages from the app
```

## Additional Context
Add any other context about the problem here. Screenshots are helpful for UI issues.
