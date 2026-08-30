# Pre-Release Checklist

Use this checklist before publishing a new release to the community.

## 📋 Documentation

- [ ] README.md is clear and inviting for new users
- [ ] INSTALL.md has step-by-step installation instructions
- [ ] CONTRIBUTING.md explains how to contribute
- [ ] All docs in `docs/` are up-to-date
- [ ] LICENSE file is present (MIT)
- [ ] CHANGELOG.md is updated with version notes

## 🧪 Testing

- [ ] All Go tests pass: `go test ./...`
- [ ] All Flutter tests pass: `cd client && flutter test`
- [ ] Manual QR pairing works (LAN mode)
- [ ] Mobile app connects successfully
- [ ] Agent list displays correctly
- [ ] Terminal output streams work
- [ ] Prompts can be sent from phone
- [ ] Reconnection works after network interruption
- [ ] Service survives herdr restart

## 🏗️ Build & Release

- [ ] Go relay builds on macOS: `GOOS=darwin go build ./cmd/relay`
- [ ] Go relay builds on Linux: `GOOS=linux go build ./cmd/relay`
- [ ] Android APK builds: `cd client && flutter build apk --release`
- [ ] iOS build compiles (if applicable): `flutter build ios --release`
- [ ] Binary size is reasonable (< 20MB for relay)
- [ ] APK size is reasonable (< 30MB)

## 🔧 Configuration

- [ ] Default configuration works out of the box
- [ ] Plugin install script (`plugin/install.sh`) works
- [ ] Redeploy script (`plugin/redeploy.sh`) works
- [ ] Quick start script (`quick-start.sh`) is tested
- [ ] Service configuration (launchd) works correctly
- [ ] Port 8375 is not conflicting with common services

## 🔐 Security

- [ ] No hardcoded secrets or tokens in code
- [ ] Token generation is cryptographically secure
- [ ] QR codes don't expose more than necessary
- [ ] Connection modes properly validate tokens
- [ ] Logs don't leak sensitive information
- [ ] Dependencies are up-to-date (no known vulnerabilities)

## 📱 Mobile App

- [ ] App manifest (AndroidManifest.xml) has correct permissions
- [ ] Custom URL scheme (`herdrelay://`) is registered
- [ ] App icon is present and looks good
- [ ] Splash screen works
- [ ] All required permissions are requested
- [ ] App doesn't crash on network errors
- [ ] Connection screen shows clear status

## 🌐 GitHub Repository

- [ ] Repository is public (when ready to release)
- [ ] Clear repository description and topics
- [ ] Issues are enabled
- [ ] Discussions are enabled (optional but recommended)
- [ ] GitHub Actions workflows are configured
- [ ] Branch protection rules set for `main` (optional)
- [ ] Issue templates are in place (bug report, feature request)
- [ ] `.gitignore` excludes build artifacts and secrets

## 📢 Release Process

- [ ] Version number follows semver (e.g., v0.1.0)
- [ ] Git tag created: `git tag v0.1.0`
- [ ] Tag pushed: `git push origin v0.1.0`
- [ ] GitHub Release created with notes
- [ ] Release includes all binaries (macOS, Linux, Android)
- [ ] Release notes are clear and helpful
- [ ] Download links are tested

## 🎯 Post-Release

- [ ] Announce in herdr community (if applicable)
- [ ] Monitor initial issues and feedback
- [ ] Be responsive to first users' questions
- [ ] Update README badges if needed
- [ ] Consider creating a demo video or GIF
- [ ] Write a blog post or tutorial (optional)

## 🚨 Known Issues to Document

Document any known limitations or issues:

- [ ] List supported herdr versions
- [ ] List tested platforms (macOS 14+, Ubuntu 22+, etc.)
- [ ] List tested mobile OS versions (iOS 15+, Android 10+)
- [ ] Document any network requirements (firewall rules, etc.)
- [ ] Note any features still in development

---

## First Release Checklist (v0.1.0)

For the very first public release, also ensure:

- [ ] Repository has a clear "About" section
- [ ] At least 3-5 GitHub topics for discoverability
- [ ] Screenshot or demo GIF in README
- [ ] Clear value proposition in first paragraph
- [ ] Links to herdr project and community
- [ ] Social preview image configured (optional)
- [ ] Star the herdr repository (show support!)

## Testing with Fresh Users

Before announcing widely:

- [ ] Test installation on a clean machine
- [ ] Have 1-2 people try the quick-start guide
- [ ] Verify instructions work for non-experts
- [ ] Check that error messages are helpful
- [ ] Ensure troubleshooting guide covers common issues

---

**Ready to release?** Make sure at least 90% of items are checked!
