import 'package:flutter/material.dart';

import '../controllers/modes_controller.dart';
import '../core/service_locator.dart';
import '../models/pair_config.dart';
import '../repositories/agent_repository.dart';
import '../services/app_settings.dart';
import '../services/notification_api.dart';
import '../services/relay_client.dart';
import '../widgets/mode_picker_sheet.dart';
import 'help_page.dart';

/// Settings tab: connection (status, one-tap offline mode switching from the
/// saved endpoints, /pair mode picker, link to the Connection screen),
/// notifications, terminal preferences and help — the single home for app
/// settings, replacing the ⋮ menu entries.
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.config,
    required this.onModeSelected,
    required this.onRequestSwitch,
    this.modesController,
  });

  final PairConfig config;

  /// Switch the connection mode (saved endpoint or one picked from /pair).
  final Future<void> Function(PairConfig config) onModeSelected;

  /// Open the Connection screen (switch profile, pair, forget).
  final Future<void> Function() onRequestSwitch;

  /// Injectable for tests; defaults to the global [ModesController].
  final ModesController? modesController;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final AgentRepository _repository;
  late final AppSettings _settings;

  @override
  void initState() {
    super.initState();
    _repository = getIt<AgentRepository>();
    _settings = getIt<AppSettings>();
  }

  /// Immediate offline switch: the mode is a saved endpoint of the current
  /// config, so no /pair round-trip is needed (same path as ConnectionPage).
  Future<void> _switchToLocalMode(String mode) async {
    final config = widget.config.viaStoredEndpoint(mode);
    if (config == null) return;
    await widget.onModeSelected(config);
  }

  /// Online picker: loads the modes the relay advertises over /pair (with
  /// loading/error states handled inside the sheet).
  Future<void> _openModePicker() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => ModePickerSheet(
        config: widget.config,
        modesController: widget.modesController ?? getIt<ModesController>(),
        onSelected: widget.onModeSelected,
      ),
    );
  }

  void _openHelp() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const HelpPage()),
    );
  }

  Future<void> _setNotificationsEnabled(bool value) async {
    _settings.setNotificationsEnabled(value);
    if (value) {
      // Ask the OS again so the user can grant permission from here.
      await getIt<NotificationApi>().requestPermission();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.config;
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _header(context, 'Connection'),
            ValueListenableBuilder<RelayStatus>(
              valueListenable: _repository.status,
              builder: (context, status, _) {
                final connected = status == RelayStatus.connected;
                return ListTile(
                  leading: Icon(
                    connected
                        ? Icons.cloud_done
                        : status == RelayStatus.connecting
                            ? Icons.cloud_sync
                            : Icons.cloud_off,
                    color: connected
                        ? Colors.green
                        : status == RelayStatus.connecting
                            ? Colors.orange
                            : Colors.grey,
                  ),
                  title: Text('${c.mode} · ${c.host}:${c.port}'),
                  subtitle: Text(_statusLabel(status)),
                );
              },
            ),
            // Offline mode switch: saved endpoints of this config, shown even
            // when /pair is unreachable (away from the local network, e.g. a
            // Tailscale fallback).
            if (c.endpoints.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final mode in c.endpoints.keys)
                      ChoiceChip(
                        label: Text(mode),
                        selected: mode == c.mode,
                        onSelected: (_) => _switchToLocalMode(mode),
                      ),
                  ],
                ),
              ),
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('More modes…'),
              subtitle: const Text('Modes the relay advertises over /pair'),
              onTap: _openModePicker,
            ),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Connection settings…'),
              subtitle: const Text(
                'Switch profile, pair a device, forget this relay',
              ),
              onTap: widget.onRequestSwitch,
            ),
            const Divider(),
            _header(context, 'Notifications'),
            SwitchListTile(
              title: const Text('Blocked agent alerts'),
              subtitle: const Text(
                'Show a notification when an agent needs your response while '
                'the app is in the background',
              ),
              value: _settings.notificationsEnabled,
              onChanged: _setNotificationsEnabled,
            ),
            const Divider(),
            _header(context, 'Terminal'),
            ListTile(
              title: const Text('Terminal font size'),
              subtitle: Text(
                'Default size for agent output '
                '(${_settings.terminalFontSize.round()} pt)',
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Slider(
                value: _settings.terminalFontSize,
                min: AppSettings.kMinFontSize,
                max: AppSettings.kMaxFontSize,
                divisions:
                    (AppSettings.kMaxFontSize - AppSettings.kMinFontSize)
                        .round(),
                label: '${_settings.terminalFontSize.round()}',
                onChanged: _settings.setTerminalFontSize,
              ),
            ),
            SwitchListTile(
              title: const Text('Auto-follow terminal output'),
              subtitle: const Text(
                'Keep the terminal scrolled to the bottom as new output arrives',
              ),
              value: _settings.autoScrollFollow,
              onChanged: _settings.setAutoScrollFollow,
            ),
            const Divider(),
            _header(context, 'About'),
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: const Text('Help & troubleshooting'),
              onTap: _openHelp,
            ),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }

  String _statusLabel(RelayStatus status) => switch (status) {
        RelayStatus.connected => 'online',
        RelayStatus.connecting => 'connecting…',
        RelayStatus.disconnected => 'offline',
      };

  Widget _header(BuildContext context, String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}