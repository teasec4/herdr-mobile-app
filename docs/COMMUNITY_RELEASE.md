# Community Release Guide

This document outlines best practices for releasing Herdr Mobile to the community.

## 📦 What Makes a Good Open Source Release?

1. **Clear value proposition** — Users understand in 30 seconds what this does
2. **Easy installation** — Works in 3 commands or less
3. **Good documentation** — README, install guide, troubleshooting
4. **Working examples** — Screenshots, demo, or video
5. **Active maintenance** — Respond to issues within 1-2 days initially
6. **Welcoming community** — Friendly to beginners and contributors

## 🎯 Release Strategy

### Phase 1: Soft Launch (Private Beta)
- Share with 5-10 trusted users
- Gather feedback on installation process
- Fix critical bugs
- Iterate on documentation
- Duration: 1-2 weeks

### Phase 2: Community Preview
- Post in herdr community/Discord/Slack
- Limited announcement (no HackerNews yet)
- Monitor closely, fix issues quickly
- Gather feature requests
- Duration: 2-4 weeks

### Phase 3: Public Launch
- Announce on HackerNews, Reddit, Twitter
- Write blog post or tutorial
- Create demo video
- Submit to awesome-lists
- Duration: Ongoing

## 📢 Where to Announce

### Tier 1 (Core audience)
- [ ] herdr community channels
- [ ] herdr GitHub Discussions
- [ ] Personal social media

### Tier 2 (Developer community)
- [ ] Hacker News (Show HN)
- [ ] Reddit: r/golang, r/FlutterDev, r/commandline
- [ ] Dev.to or Medium blog post
- [ ] Twitter/X with hashtags #herdr #golang #flutter

### Tier 3 (Broader reach)
- [ ] Product Hunt
- [ ] Awesome lists (awesome-go, awesome-flutter)
- [ ] Newsletter mentions (Golang Weekly, etc.)

## 🎨 Marketing Materials

### Screenshots to Include
1. QR code in terminal (pairing flow)
2. Mobile app home screen with agent list
3. Terminal output view on phone
4. Connection mode picker
5. Send prompt interface

### Demo Video (2-3 minutes)
1. Show herdr running on laptop
2. Install plugin with one command
3. Show QR code
4. Scan with phone
5. Interact with agents from phone
6. Walk away from computer while agents work

### Key Messaging
- **Problem**: Can't monitor long-running AI agents when away from laptop
- **Solution**: Control herdr from phone via secure relay
- **Unique**: No VPS needed, QR-based setup, works over Tailscale
- **Audience**: Developers using herdr for AI-assisted coding

## 📝 Launch Announcement Template

```markdown
# Show HN: Control herdr AI agents from your phone

Hi HN! I built Herdr Mobile — a mobile companion for herdr (a terminal workspace manager for AI coding agents).

**The problem**: When running long AI agent tasks, I wanted to check progress without being tied to my laptop.

**The solution**: Herdr Mobile connects your phone to your laptop via a lightweight Go relay. Install a herdr plugin, scan a QR code, and you're connected.

**Key features**:
- Real-time agent status and terminal output
- Send prompts from phone
- Works over LAN or Tailscale (no VPS needed)
- QR-based pairing (30 seconds to set up)
- Native mobile app (Flutter)

**Tech stack**: Go (relay), Flutter (mobile), herdr plugin system

**How it works**: The relay subscribes to herdr's event stream and forwards everything over WebSocket to your phone. Three connection modes: LAN (same WiFi), Tailscale (anywhere), or public HTTPS (Funnel).

Try it: [GitHub link]
Android APK: [Release link]

Open to feedback! This is my first Flutter app and first herdr plugin.
```

## 🤝 Community Engagement

### Respond to Issues Quickly
- First week: Respond within 24 hours
- First month: Respond within 48 hours
- Be friendly and helpful even to "dumb" questions
- Thank people for bug reports

### Encourage Contributors
- Label issues as "good first issue"
- Be specific about what help you need
- Review PRs within 1-2 days
- Thank contributors in release notes

### Build in Public
- Share progress updates
- Explain design decisions
- Ask for feedback on features
- Show roadmap transparently

## 🔧 Post-Launch Maintenance

### Monitor These Metrics
- GitHub stars/watches
- Download counts (releases)
- Issue open/close rate
- PR activity
- Community engagement

### Plan for Common Issues
- Installation failures (missing dependencies)
- Connection problems (firewall, network)
- Platform-specific bugs (macOS vs Linux)
- Mobile app crashes (permission issues)

### Iterative Improvements
- Release bug fixes weekly (v0.1.1, v0.1.2)
- Release features monthly (v0.2.0, v0.3.0)
- Keep CHANGELOG updated
- Celebrate milestones (100 stars, 1000 downloads)

## 🎁 Going the Extra Mile

### Optional but Impactful
- [ ] Create a landing page (simple GitHub Pages)
- [ ] Make a 30-second demo GIF for README
- [ ] Write integration tests
- [ ] Set up codecov for test coverage
- [ ] Add badges to README (tests passing, coverage, version)
- [ ] Create Docker image for relay (future)
- [ ] Publish to plugin registry when herdr has one

### Build Community
- [ ] Create Discord or Slack channel
- [ ] Start GitHub Discussions
- [ ] Write monthly progress updates
- [ ] Feature user success stories
- [ ] Create swag (stickers!) for contributors

## ⚠️ What to Avoid

❌ **Don't over-promise**: Be honest about limitations
❌ **Don't disappear**: Maintain momentum after launch
❌ **Don't ignore feedback**: Even negative feedback is valuable
❌ **Don't rush features**: Quality > speed for early releases
❌ **Don't forget mobile**: iOS is half your audience (eventually)

## ✅ Success Criteria

A successful launch means:
- 50+ GitHub stars in first week
- 100+ downloads/installs
- 5+ positive comments/feedback
- 0 critical bugs reported
- 2+ potential contributors interested
- Featured in at least one newsletter/blog

## 🚀 Ready to Launch?

Use the [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md) to ensure everything is ready.

Good luck! 🎉
