import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/app_session_controller.dart';
import '../controllers/modes_controller.dart';
import '../core/connection/mode_service.dart';
import '../core/service_locator.dart';
import '../models/pair_config.dart';
import '../services/config_store.dart';
import '../services/relay_client.dart';
import '../utils/toast_service.dart';
import '../widgets/manual_mode_dialog.dart';
import '../widgets/mode_icons.dart';

/// Connection screen: the active pair, live status, connection test,
/// available modes from the relay, saved devices, and pair-link entry —
/// everything about "how am I connected" in one place.
///
/// Replaces the scattered popup-menu UX (docs/09-refactoring-plan.md,
/// follow-up): status/mode/error were previously invisible.
class ConnectionPage extends StatefulWidget {
  const ConnectionPage({
    super.key,
    required this.config,
    required this.onSwitch,
    required this.onForgetActive,
    required this.onLink,
    this.modesController,
  });

  /// The currently active pair.
  final PairConfig config;

  /// Switch to another profile / mode (parent saves it and reconnects).
  final Future<void> Function(PairConfig config) onSwitch;

  /// Forget the active device and return to the scanner.
  final Future<void> Function() onForgetActive;

  /// Apply a pasted pair link (`herdrelay://pair?...`).
  final Future<void> Function(String link) onLink;

  /// Injectable for tests; defaults to the global [ModesController].
  final ModesController? modesController;

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> {
  final TextEditingController _linkController = TextEditingController();
  RelayClient? _client;
  List<PairConfig> _profiles = const [];
  String? _activeKey;
  late final ModesController _modesController =
      widget.modesController ?? getIt<ModesController>();
  /// Root session: when a config switch recreates the relay services, the
  /// cached [_client] becomes a reference to a disposed object, so the status
  /// listener is re-bound to the fresh client (see [_attachClient]).
  late final AppSessionController _session = getIt<AppSessionController>();
  bool _checking = false;
  bool _checkOk = false;
  String? _checkResult;
  bool _connectingLink = false;
  int _checkGeneration = 0;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
    _attachClient();
    _modesController.addListener(_onModesChanged);
    _reloadProfiles();
    _loadModes();
  }

  @override
  void dispose() {
    _client?.status.removeListener(_onStatus);
    _session.removeListener(_onSessionChanged);
    _modesController.removeListener(_onModesChanged);
    _linkController.dispose();
    super.dispose();
  }

  /// (Re)binds the status listener to the current relay client. Called at open
  /// and again whenever [_onSessionChanged] fires: a config switch tears down
  /// the old client and registers a fresh one, and the old reference must not
  /// be listened to anymore.
  void _attachClient() {
    _client?.status.removeListener(_onStatus);
    _client = _session.liveClient;
    _client?.status.addListener(_onStatus);
  }

  void _onSessionChanged() {
    if (!mounted) return;
    _attachClient();
    setState(() {});
  }

  void _onStatus() {
    if (mounted) setState(() {});
  }

  void _onModesChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _reloadProfiles() async {
    final store = getIt<ConfigStore>();
    final profiles = await store.loadProfiles();
    final active = await store.loadActive();
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _activeKey = active?.profileKey;
    });
  }

  Future<void> _loadModes({bool force = false}) async {
    await _modesController.load(widget.config, force: force);
    if (!mounted) return;
    final error = _modesController.state.errorOrNull;
    if (error != null) ToastService.showError(context, error);
  }

  Future<void> _checkConnection() async {
    final client = _client;
    if (client == null) return;
    // Guard against overlapping tests (double-tap / retry): a stale response
    // must not overwrite a fresher one.
    final gen = ++_checkGeneration;
    setState(() {
      _checking = true;
      _checkResult = null;
    });
    try {
      final sw = Stopwatch()..start();
      final healthy = await client.healthz();
      final ms = sw.elapsedMilliseconds;
      if (!mounted || gen != _checkGeneration) return;
      if (!healthy) {
        setState(() {
          _checkOk = false;
          _checkResult = 'Relay not reachable (healthz failed)';
        });
        return;
      }
      final agents = await client.snapshot();
      if (!mounted || gen != _checkGeneration) return;
      setState(() {
        _checkOk = true;
        _checkResult = 'OK · ${agents.length} agent(s) · ${ms}ms';
      });
    } catch (e) {
      if (!mounted || gen != _checkGeneration) return;
      setState(() {
        _checkOk = false;
        _checkResult = '$e';
      });
    } finally {
      if (mounted && gen == _checkGeneration) setState(() => _checking = false);
    }
  }

  Future<void> _switchMode(RelayModeInfo mode) async {
    try {
      // Merge every advertised endpoint into the profile so switching modes
      // never forgets the others (LAN IP + tailnet name + funnel).
      final config = _modesController.switchMode(widget.config, mode);
      await widget.onSwitch(config);
      if (mounted) {
        ToastService.showSuccess(context, 'Switched to ${mode.mode}');
      }
    } catch (e) {
      if (mounted) ToastService.showError(context, e);
    }
  }

  /// Switches to a stored endpoint (offline quick-switch: no /pair needed).
  /// Shown when the relay is unreachable but the profile remembers endpoints
  /// for this relay — e.g. Tailscale on the phone but the LAN /pair is not
  /// reachable, exactly the case where the switch is needed.
  Future<void> _switchToLocalMode(String mode) async {
    final cfg = widget.config.viaStoredEndpoint(mode);
    if (cfg == null) return;
    try {
      await widget.onSwitch(cfg);
      if (mounted) {
        ToastService.showSuccess(context, 'Switched to $mode');
      }
    } catch (e) {
      if (mounted) ToastService.showError(context, e);
    }
  }

  /// Opens the manual-mode dialog (custom host/port with live availability
  /// check) and applies the resulting config (AUTO_MODE_SWITCHING_PLAN, Phase 3).
  Future<void> _openManualMode() async {
    final cfg = await showManualModeDialog(context, config: widget.config);
    if (cfg == null) return;
    await widget.onSwitch(cfg);
  }

  Future<void> _switchProfile(PairConfig config) async {
    await widget.onSwitch(config);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _forgetProfile(PairConfig config) async {
    await getIt<ConfigStore>().forget(config.profileKey);
    await _reloadProfiles();
  }

  Future<void> _applyLink(String link) async {
    if (_connectingLink) return;
    setState(() => _connectingLink = true);
    try {
      await widget.onLink(link);
      if (mounted) {
        ToastService.showSuccess(context, 'Pair saved');
        Navigator.of(context).pop();
      }
    } on FormatException catch (e) {
      if (mounted) ToastService.showError(context, e.message);
    } catch (e) {
      if (mounted) ToastService.showError(context, e);
    } finally {
      if (mounted) setState(() => _connectingLink = false);
    }
  }

  Future<void> _confirmForgetActive() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget this device?'),
        content: Text(
          '${widget.config.displayName} (${widget.config.host}:${widget.config.port}) '
          'will be removed and the app returns to the scanner.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.onForgetActive();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Connection')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _deviceCard(theme),
            const SizedBox(height: 16),
            _statusCard(theme),
            const SizedBox(height: 16),
            _modesCard(theme),
            const SizedBox(height: 16),
            _devicesCard(theme),
            const SizedBox(height: 16),
            _pairCard(theme),
          ],
        ),
      ),
    );
  }

  Widget _deviceCard(ThemeData theme) {
    final c = widget.config;
    // LAN-only profile: the badge + hint warn that the relay is unreachable
    // away from home (AUTO_MODE_SWITCHING_PLAN, Phase 1.2).
    final lanOnly = c.isLanOnly;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Device', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.computer, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(c.displayName,
                      style: theme.textTheme.titleMedium),
                ),
                Chip(label: Text(c.mode)),
                if (lanOnly)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Tooltip(
                      message: 'Only reachable on local WiFi',
                      child: Icon(Icons.warning_amber,
                          color: Colors.orange, size: 20),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text('${c.host}:${c.port}',
                style: theme.textTheme.bodyMedium),
            if (lanOnly) ...[
              const SizedBox(height: 8),
              Text(
                'Tip: enable Tailscale on both devices for remote access',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.orange),
              ),
            ],
            const SizedBox(height: 8),
            SelectableText(
              c.wsUri.toString(),
              style: theme.textTheme.bodySmall!
                  .copyWith(fontFamily: 'monospace', color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 4),
            Text('id: ${c.profileKey}',
                style: theme.textTheme.bodySmall!
                    .copyWith(color: theme.colorScheme.outline)),
          ],
        ),
      ),
    );
  }

  Widget _statusCard(ThemeData theme) {
    final client = _client;
    final status = client?.status.value;
    final (label, color, icon) = switch (status) {
      RelayStatus.connected => ('Connected', Colors.green, Icons.check_circle),
      RelayStatus.connecting => ('Connecting…', Colors.orange, Icons.sync),
      null => ('No client', Colors.grey, Icons.help_outline),
      _ => ('Disconnected', Colors.red, Icons.error_outline),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Connection status', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 8),
                Text(label, style: theme.textTheme.titleMedium),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: _checking ? null : _checkConnection,
                  icon: _checking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow),
                  label: const Text('Test'),
                ),
              ],
            ),
            if (_checkResult != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    _checkOk ? Icons.check : Icons.close,
                    size: 16,
                    color: _checkOk ? Colors.green : Colors.red,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(_checkResult!,
                        style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _modesCard(ThemeData theme) {
    final state = _modesController.state;
    final modes = state.dataOrNull ?? const <RelayModeInfo>[];
    final saved = widget.config.endpoints;
    // Spinner only while /pair is actually loading AND nothing usable is on
    // screen yet: with saved endpoints we can offer an offline switch straight
    // away instead of blocking on a ~16 s retry window.
    final showSpinner = state.isLoading && modes.isEmpty && saved.isEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Connection mode', style: theme.textTheme.labelLarge),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh modes',
                  onPressed: () => _loadModes(force: true),
                ),
              ],
            ),
            if (showSpinner)
              const Padding(
                padding: EdgeInsets.all(8),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (modes.isNotEmpty)
              for (final mode in modes)
                RadioListTile<String>(
                  dense: true,
                  title: Text(mode.mode),
                  subtitle: Text('${mode.description}\n${mode.url}'),
                  value: mode.mode,
                  groupValue: widget.config.mode,
                  onChanged: (_) => _switchMode(mode),
                )
            else if (saved.isNotEmpty)
              // Offline quick-switch: /pair failed, but the profile remembers
              // endpoints for this relay — switch without any network.
              ...[
                Text('Saved modes for this relay',
                    style: theme.textTheme.bodySmall),
                const SizedBox(height: 4),
                for (final entry in saved.entries)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      modeIcon(entry.key),
                      size: 18,
                    ),
                    title: Text(entry.key),
                    subtitle: Text(entry.value.toString()),
                    trailing: entry.key == widget.config.mode
                        ? const Icon(Icons.check, size: 16)
                        : null,
                    onTap: () => _switchToLocalMode(entry.key),
                  ),
              ]
            else
              Text('No modes available — relay unreachable?',
                  style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: _openManualMode,
              icon: const Icon(Icons.tune),
              label: const Text('Switch mode manually'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _devicesCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Saved devices', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            if (_profiles.isEmpty)
              Text('No saved devices yet', style: theme.textTheme.bodySmall)
            else
              for (final p in _profiles)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    p.profileKey == _activeKey
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: p.profileKey == _activeKey
                        ? theme.colorScheme.primary
                        : null,
                  ),
                  title: Text(p.displayName),
                  subtitle: Text('${p.mode} · ${p.host}:${p.port}'),
                  onTap: p.profileKey == _activeKey
                      ? null
                      : () => _switchProfile(p),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Forget',
                    onPressed: () => _forgetProfile(p),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _pairCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Pair / add device', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            TextField(
              controller: _linkController,
              decoration: const InputDecoration(
                labelText: 'Pair link',
                hintText: 'herdrelay://pair?host=...&token=...',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              keyboardType: TextInputType.url,
              onSubmitted: (link) => _applyLink(link.trim()),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _connectingLink
                      ? null
                      : () => _applyLink(_linkController.text.trim()),
                  icon: const Icon(Icons.link),
                  label: const Text('Connect'),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _confirmForgetActive,
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  icon: const Icon(Icons.delete),
                  label: const Text('Forget this device'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
