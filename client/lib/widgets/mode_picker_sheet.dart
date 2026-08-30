import 'package:flutter/material.dart';

import '../core/connection/mode_service.dart';
import '../models/pair_config.dart';
import '../utils/toast_service.dart';

/// Bottom sheet that fetches the relay's available connection modes and lets
/// the user switch. Handles loading / error (with Retry) / empty states —
/// the relay request goes through [ModeService] so transient failures are
/// retried before this UI ever shows an error.
class ModePickerSheet extends StatefulWidget {
  const ModePickerSheet({
    super.key,
    required this.config,
    required this.fetcher,
    required this.onSelected,
  });

  /// The currently active pair (used to build the /pair request).
  final PairConfig config;

  /// Fetches available modes; defaults to [ModeService.fetch].
  final Future<List<RelayModeInfo>> Function(PairConfig config) fetcher;

  /// Called with the new [PairConfig] (parsed from the mode's link) when the
  /// user picks a mode; the parent saves it and reconnects.
  final Future<void> Function(PairConfig config) onSelected;

  @override
  State<ModePickerSheet> createState() => _ModePickerSheetState();
}

class _ModePickerSheetState extends State<ModePickerSheet> {
  bool _loading = true;
  Object? _error;
  List<RelayModeInfo> _modes = const [];
  bool _switching = false;

  /// Manual-connection form: lets the user switch modes even when the relay
  /// is unreachable (e.g. Tailscale is off at home and /pair cannot be
  /// fetched). The token is taken from the active profile — no relay round
  /// trip needed.
  String _manualMode = 'lan';
  late final TextEditingController _hostController =
      TextEditingController(text: widget.config.host);
  late final TextEditingController _portController =
      TextEditingController(text: '${widget.config.port}');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final modes = await widget.fetcher(widget.config);
      if (!mounted) return;
      setState(() {
        _modes = modes;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _pick(RelayModeInfo mode) async {
    if (_switching) return;
    setState(() => _switching = true);
    try {
      final config = PairConfig.fromLink(mode.link);
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

  /// Builds a config from the manual form (host/port/mode + the saved token)
  /// and switches — works while the relay is completely unreachable.
  Future<void> _connectManual() async {
    if (_switching) return;
    final host = _hostController.text.trim();
    final portRaw = _portController.text.trim();
    if (host.isEmpty) {
      ToastService.showError(context, 'Enter the relay host (e.g. 192.168.1.5)');
      return;
    }
    final port = int.tryParse(portRaw) ?? PairConfig.defaultPort;
    if (port <= 0 || port > 65535) {
      ToastService.showError(context, 'Invalid port: $portRaw');
      return;
    }
    setState(() => _switching = true);
    try {
      final config = PairConfig(
        host: host,
        port: port,
        mode: _manualMode,
        token: widget.config.token,
        relayId: widget.config.relayId,
        name: widget.config.name,
      );
      Navigator.of(context).pop();
      await widget.onSelected(config);
    } catch (e) {
      if (mounted) {
        setState(() => _switching = false);
        ToastService.showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
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
                  if (_loading || _error != null)
                    TextButton(
                      onPressed: _loading ? null : _load,
                      child: const Text('Retry'),
                    ),
                ],
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline,
                        color: theme.colorScheme.error),
                    const SizedBox(width: 8),
                    Expanded(child: Text('$_error')),
                  ],
                ),
              )
            else if (_modes.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text(
                  'No modes available — relay unreachable?',
                  style: theme.textTheme.bodySmall,
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final mode in _modes)
                      RadioListTile<String>(
                        dense: true,
                        title: Text(mode.mode),
                        subtitle: Text('${mode.description}\n${mode.url}'),
                        value: mode.mode,
                        groupValue: widget.config.mode,
                        onChanged: _switching ? null : (_) => _pick(mode),
                      ),
                  ],
                ),
              ),
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
                        items: const [
                          DropdownMenuItem(value: 'lan', child: Text('LAN')),
                          DropdownMenuItem(
                              value: 'tailscale', child: Text('Tailscale')),
                          DropdownMenuItem(
                              value: 'funnel', child: Text('Funnel')),
                        ],
                        onChanged: _switching
                            ? null
                            : (v) => setState(() => _manualMode = v ?? 'lan'),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _hostController,
                          enabled: !_switching,
                          decoration: const InputDecoration(
                            labelText: 'Host',
                            hintText: '192.168.1.5',
                            isDense: true,
                            border: OutlineInputBorder(),
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
