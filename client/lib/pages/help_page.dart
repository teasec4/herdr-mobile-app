import 'package:flutter/material.dart';

/// Help & troubleshooting: what to do when the relay is unreachable and what
/// each connection mode means (docs/AUTO_MODE_SWITCHING_PLAN.md, Phase 5.1).
class HelpPage extends StatelessWidget {
  const HelpPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Help')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Connection issues', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _qaCard(
              theme,
              question: 'Can’t connect when away from home?',
              answer:
                  'The relay is probably reachable only on your local WiFi '
                  '(LAN mode). Install Tailscale on the relay machine and on '
                  'this device, then re-scan the QR code — all reachable modes '
                  'are saved automatically, and the app switches to Tailscale '
                  'when LAN goes dark.',
            ),
            const SizedBox(height: 24),
            Text('Connection modes', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _modeCard(
              theme,
              icon: Icons.wifi,
              title: 'LAN',
              body:
                  'Direct connection on the same WiFi / local network. Fastest, '
                  'but stops working when either device leaves home.',
            ),
            const SizedBox(height: 8),
            _modeCard(
              theme,
              icon: Icons.lan,
              title: 'Tailscale',
              body:
                  'Secure tunnel that works from anywhere. Both devices need the '
                  'Tailscale app and must be on the same tailnet.',
            ),
            const SizedBox(height: 8),
            _modeCard(
              theme,
              icon: Icons.public,
              title: 'Funnel',
              body:
                  'Public HTTPS URL exposed through Tailscale — reachable from '
                  'anywhere without Tailscale installed. Relay must enable '
                  'funnel (`tailscale funnel 8375`).',
            ),
          ],
        ),
      ),
    );
  }

  Widget _qaCard(ThemeData theme,
      {required String question, required String answer}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Q: $question',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text('A: $answer', style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  Widget _modeCard(ThemeData theme,
      {required IconData icon, required String title, required String body}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(body, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
