import 'package:flutter/material.dart';

import '../controllers/modes_controller.dart';
import '../core/connection/mode_service.dart';
import '../core/service_locator.dart';
import '../models/pair_config.dart';
import '../utils/toast_service.dart';
import 'mode_icons.dart';

/// Bottom sheet that fetches the relay's available connection modes and lets
/// the user switch. Handles loading / error (with Retry) / empty states —
/// the relay request goes through [ModesController] (wrapping [ModeService],
/// which retries transient failures before this UI ever shows an error).
class ModePickerSheet extends StatefulWidget {
  const ModePickerSheet({
    super.key,
    required this.config,
    required this.modesController,
    required this.onSelected,
  });

  /// The currently active pair (used to build the /pair request).
  final PairConfig config;

  /// Injectable for tests; defaults to the global [ModesController].
  final ModesController? modesController;

  /// Called with the new [PairConfig] (parsed from the mode's link) when the
  /// user picks a mode; the parent saves it and reconnects.
  final Future<void> Function(PairConfig config) onSelected;

  @override
  State<ModePickerSheet> createState() => _ModePickerSheetState();
}

class _ModePickerSheetState extends State<ModePickerSheet> {
  late final ModesController _modesController =
      widget.modesController ?? getIt<ModesController>();
  bool _switching = false;

  /// Manual-connection form: lets the user switch modes even when the relay
  /// is unreachable (e.g. Tailscale is off at home and /pair cannot be
  /// fetched). The token is taken from the active profile — no relay round
  /// trip needed. The host field follows the selected mode (prefilled from the
  /// profile's stored endpoint for that mode, never another mode's host).
  String _manualMode = 'lan';
  late final TextEditingController _hostController =
      TextEditingController(text: widget.config.endpointFor(_manualMode)?.host ?? '');
  late final TextEditingController _portController =
      TextEditingController(text: '${widget.config.endpointFor(_manualMode)?.port ?? widget.config.port}');

  String get _hostHint => switch (_manualMode) {
        'lan' => '192.168.1.5',
        'tailscale' => 'mac.tailnet.ts.net',
        'funnel' => 'relay.tailnet.ts.net',
        _ => 'relay address',
      };

  @override
  void initState() {
    super.initState();
    _modesController.addListener(_onModesChanged);
    _load();
  }

  @override
  void dispose() {
    _modesController.removeListener(_onModesChanged);
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  void _onModesChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load({bool force = false}) async {
    await _modesController.load(widget.config, force: force);
  }

  /// Switches to a fetched mode, merging every advertised endpoint into the
  /// profile (LAN IP + tailnet name + funnel) so later offline switches work.
  Future<void> _pick(RelayModeInfo mode) async {
    if (_switching) return;
    setState(() => _switching = true);
    try {
      final config = _modesController.switchMode(widget.config, mode);
      Navigator.of(context).pop();
      await widget.onSelected(config);
    } on FormatException {
      if (mounted) {
        setState(() => _switching = false);
        ToastService.showError(context, 'Invalid mode link from relay');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _switching = false);
        ToastService.showError(context, e);
      }
    }
  }

  /// Switches to a stored endpoint (offline quick-switch: no /pair needed).
  Future<void> _pickEndpoint(String mode, RelayEndpoint endpoint) async {
    if (_switching) return;
    setState(() => _switching = true);
    try {
      final config = widget.config.connectVia(mode, endpoint);
      Navigator.of(context).pop();
      await widget.onSelected(config);
    } catch (e) {
      if (mounted) {
        setState(() => _switching = false);
        ToastService.showError(context, e);
      }
    }
  }

  /// Builds a config from the manual form (host/port/mode + the saved token)
  /// and switches — works while the relay is completely unreachable.
  Future<void> _connectManual() async {
    if (_switching) return;
    final host = _hostController.text.trim();
    final portRaw = _portController.text.trim();
    if (host.isEmpty) {
      ToastService.showError(
          context, 'Enter the relay host (e.g. ${_hostHint})');
      return;
    }
    final port = int.tryParse(portRaw) ?? PairConfig.defaultPort;
    if (port <= 0 || port > 65535) {
      ToastService.showError(context, 'Invalid port: $portRaw');
      return;
    }
    setState(() => _switching = true);
    try {
      final config = widget.config
          .withEndpoints({_manualMode: RelayEndpoint(host: host, port: port)})
          .connectVia(_manualMode, RelayEndpoint(host: host, port: port));
      Navigator.of(context).pop();
      await widget.onSelected(config);
    } catch (e) {
      if (mounted) {
        setState(() => _switching = false);
        ToastService.showError(context, e);
      }
    }
  }

  void _onManualModeChanged(String mode) {
    setState(() => _manualMode = mode);
    // Host follows the selected mode: stored endpoint for it, or empty with a
    // hint — never carry another mode's host over.
    final ep = widget.config.endpointFor(mode);
    _hostController.text = ep?.host ?? '';
    _portController.text = '${ep?.port ?? widget.config.port}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = _modesController.state;
    final loading = state.isLoading;
    final error = state.errorOrNull;
    final modes = state.dataOrNull ?? const <RelayModeInfo>[];
    return SafeArea(
      // Scrollable: with the saved-modes + manual sections the sheet can
      // exceed the bottom-sheet height on small screens.
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Text('Connection mode', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  if (loading || error != null)
                    TextButton(
                      onPressed: loading ? null : () => _load(force: true),
                      child: const Text('Retry'),
                    ),
                ],
              ),
            ),
            if (loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline,
                        color: theme.colorScheme.error),
                    const SizedBox(width: 8),
                    Expanded(child: Text('$error')),
                  ],
                ),
              )
            else if (modes.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text(
                  'No modes available — relay unreachable?',
                  style: theme.textTheme.bodySmall,
                ),
              )
            else
              for (final mode in modes)
                RadioListTile<String>(
                  dense: true,
                  title: Text(mode.mode),
                  subtitle: Text('${mode.description}\n${mode.url}'),
                  value: mode.mode,
                  groupValue: widget.config.mode,
                  onChanged: _switching ? null : (_) => _pick(mode),
                ),
            // Offline quick-switch: /pair failed, but the profile remembers
            // endpoints for this relay — switch without any network.
            if (error != null && widget.config.endpoints.isNotEmpty) ...[
              const Divider(height: 16),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text('Saved modes for this relay',
                    style: theme.textTheme.labelLarge),
              ),
              for (final entry in widget.config.endpoints.entries)
                ListTile(
                  dense: true,
                  leading: Icon(
                    modeIcon(entry.key),
                    size: 18,
                  ),
                  title: Text(entry.key),
                  subtitle: Text(entry.value.toString()),
                  trailing: entry.key == widget.config.mode
                      ? const Icon(Icons.check, size: 16)
                      : null,
                  onTap: _switching
                      ? null
                      : () => _pickEndpoint(entry.key, entry.value),
                ),
            ],
            // Manual fallback — shown even while /pair is loading, so an
            // unreachable relay (e.g. Tailscale off at home) never blocks the
            // user from switching modes by hand.
            const Divider(height: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Relay unreachable? Connect manually',
                      style: theme.textTheme.labelLarge),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      DropdownButton<String>(
                        value: _manualMode,
                        items: [
                          for (final m in PairConfig.knownModes)
                            DropdownMenuItem(
                                value: m, child: Text(modeLabel(m))),
                        ],
                        onChanged: _switching
                            ? null
                            : (v) => _onManualModeChanged(v ?? 'lan'),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _hostController,
                          enabled: !_switching,
                          decoration: InputDecoration(
                            labelText: 'Host',
                            hintText: _hostHint,
                            isDense: true,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 88,
                        child: TextField(
                          controller: _portController,
                          enabled: !_switching,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Port',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonalIcon(
                      onPressed: _switching ? null : _connectManual,
                      icon: const Icon(Icons.link, size: 16),
                      label: const Text('Connect'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
