# Contributing to HerdRelay

Thank you for your interest in contributing to HerdRelay! This document provides guidelines and instructions for contributing.

## Getting Started

### Development Setup

1. **Clone the repository**
   ```bash
   git clone https://github.com/yg_kovalev/herdr_relay.git
   cd herdr_relay
   ```

2. **Install dependencies**
   - Go 1.26+
   - Flutter 3.44+ (for mobile development)
   - herdr 0.8.0+

3. **Local development workflow**
   ```bash
   # Link plugin for development
   herdr plugin link "$PWD/plugin"
   
   # Build and install relay service
   bash plugin/install.sh
   
   # After making changes, redeploy
   bash plugin/redeploy.sh
   ```

### Project Structure

```
cmd/relay/     - Relay server entry point
internal/      - Go business logic (domain, service, infrastructure)
plugin/        - herdr plugin integration (scripts, manifest)
client/        - Flutter mobile app
docs/          - Architecture and design documentation
```

## How to Contribute

### Reporting Issues

- **Bug reports**: Include steps to reproduce, expected vs actual behavior, logs
- **Feature requests**: Describe the use case and why it would be valuable
- **Questions**: Use GitHub Discussions for general questions

### Submitting Changes

1. **Fork the repository**

2. **Create a feature branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

3. **Make your changes**
   - Follow existing code style
   - Add tests for new functionality
   - Update documentation as needed

4. **Test your changes**
   ```bash
   # Go tests
   go test ./...
   
   # Flutter tests
   cd client && flutter test
   
   # Integration test
   bash plugin/redeploy.sh
   # Test QR pairing and connection from phone
   ```

5. **Commit with clear messages**
   ```bash
   git commit -m "feat(relay): add connection timeout configuration"
   ```
   
   Use conventional commit prefixes:
   - `feat:` - New feature
   - `fix:` - Bug fix
   - `docs:` - Documentation changes
   - `refactor:` - Code refactoring
   - `test:` - Test additions/changes
   - `chore:` - Build/tooling changes

6. **Push and create a Pull Request**
   ```bash
   git push origin feature/your-feature-name
   ```

### Pull Request Guidelines

- **Title**: Clear, concise description of the change
- **Description**: 
  - What problem does this solve?
  - How does it solve it?
  - Any breaking changes?
  - Screenshots (for UI changes)
- **Tests**: All tests must pass
- **Documentation**: Update relevant docs
- **Small PRs**: Prefer focused changes over large rewrites

## Development Guidelines

### Go Code

- Follow [Effective Go](https://golang.org/doc/effective_go.html)
- Use `gofmt` for formatting
- Layered architecture: `domain` → `service` → `infrastructure`
- Avoid global state
- Handle errors explicitly

### Flutter Code

- Follow [Dart Style Guide](https://dart.dev/guides/language/effective-dart/style)
- Use `dart format` for formatting
- Layered architecture: see `client/ARCHITECTURE.md`
- Widget tests for UI components
- Unit tests for business logic

### Plugin Scripts

- POSIX-compliant shell (`#!/usr/bin/env bash`)
- Set `set -euo pipefail`
- Clear error messages
- Test on macOS and Linux

### Documentation

- Write in Markdown
- Use clear headings and structure
- Include code examples where helpful
- Update CHANGELOG.md for user-facing changes

## Testing

### Manual Testing Checklist

Before submitting a PR that affects core functionality:

- [ ] QR code generation works
- [ ] Phone can scan and connect
- [ ] Agent list updates in real-time
- [ ] Terminal output streams correctly
- [ ] Can send prompts from phone
- [ ] Reconnection works after network interruption
- [ ] Mode switching (LAN ↔ Tailscale) works
- [ ] Service survives herdr restart

### Automated Tests

```bash
# Run all Go tests
go test ./... -v

# Run Flutter tests
cd client
flutter test

# Run specific test file
flutter test test/core/transport/websocket_transport_test.dart
```

## Architecture Decisions

For significant changes:

1. Open an issue first to discuss the approach
2. Reference relevant architecture docs (`docs/01-architecture.md`, etc.)
3. Consider backward compatibility
4. Think about cross-platform support (macOS/Linux, iOS/Android)

## Code Review Process

- Maintainers will review PRs as time permits
- Be open to feedback and iteration
- Address review comments or explain why you disagree
- Once approved, maintainer will merge

## Release Process

(For maintainers)

1. Update `CHANGELOG.md` with release notes
2. Tag the release: `git tag v0.x.0`
3. Push tag: `git push origin v0.x.0`
4. GitHub Actions builds and publishes:
   - Go relay binary
   - Android APK
   - iOS build (when available)
5. Create GitHub Release with notes and attachments

## Community

- Be respectful and constructive
- Help others when you can
- Share your use cases and ideas
- No question is too simple

## License

By contributing, you agree that your contributions will be licensed under the same license as the project (see LICENSE file).

## Questions?

Open a [Discussion](https://github.com/yg_kovalev/herdr_relay/discussions) or reach out in the herdr community.

Thank you for contributing! 🚀
