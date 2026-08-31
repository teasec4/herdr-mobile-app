import 'package:flutter/material.dart';

import '../core/service_locator.dart';
import '../services/app_settings.dart';
import '../services/notification_api.dart';

/// Notifications settings: toggle for "agent blocked" alerts shown while the
/// app is in the background. Enabling requests OS permission on demand.
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  late bool _enabled = getIt<AppSettings>().notificationsEnabled;

  Future<void> _setEnabled(bool value) async {
    getIt<AppSettings>().setNotificationsEnabled(value);
    if (value) {
      // Ask the OS again so the user can grant permission from here.
      await getIt<NotificationApi>().requestPermission();
    }
    setState(() => _enabled = value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SwitchListTile(
              title: const Text('Blocked agent alerts'),
              subtitle: const Text(
                'Show a notification when an agent needs your response '
                'while the app is in the background',
              ),
              value: _enabled,
              onChanged: _setEnabled,
            ),
            const SizedBox(height: 8),
            Text(
              'Notifications are shown only when the app is not on screen '
              '(backgrounded or the phone is locked). Tapping one opens the '
              'agent.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
