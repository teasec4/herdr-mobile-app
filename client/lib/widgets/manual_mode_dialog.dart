import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/pair_config.dart';
import 'mode_icons.dart';

/// Manual connection dialog: enter a custom host/port for any mode and test
/// whether the relay answers before committing (AUTO_MODE_SWITCHING_PLAN,
/// Phase 3). Use this when automatic mode switching cannot pick an endpoint.
///
/// Returns the resulting [PairConfig] on Connect, `null` on cancel.
Future<PairConfig?> showManualModeDialog(
  BuildContext context, {
  required PairConfig config,
  http.Client? httpClient,
}) {
  return showDialog<PairConfig>(
    context: context,
    builder: (_) => _ManualModeDialog(config: config, httpClient: httpClient),
  );
}

class _ManualModeDialog extends StatefulWidget {
  const _ManualModeDialog({required this.config, this.httpClient});

  final PairConfig config;
  final http.Client? httpClient;

  @override
  State<_ManualModeDialog> createState() => _ManualModeDialogState();
}

class _ManualModeDialogState extends State<_ManualModeDialog> {
  late final TextEditingController _hostController =
      TextEditingController(text: widget.config.host);
  late final TextEditingController _portController =
      TextEditingController(text: '${widget.config.port}');
  late String _mode = widget.config.mode;
  bool _checking = false;
  bool? _reachable;
  String? _checkResult;

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  int get _port =>
      int.tryParse(_portController.text.trim()) ?? PairConfig.defaultPort;

  /// Probes the relay's /healthz over the same scheme the mode uses (http for
  /// lan/tailscale, https for funnel). Any HTTP answer counts as reachable —
  /// the point is that the host/port resolves and the relay is up.
  Future<void> _checkReachability() async {
    final host = _hostController.text.trim();
    if (host.isEmpty) {
      setState(() {
        _reachable = false;
        _checkResult = 'Enter a host first';
      });
      return;
    }
    setState(() {
      _checking = true;
      _reachable = null;
      _checkResult = null;
    });
    final probe = widget.config.connectVia(_mode, RelayEndpoint(host: host, port: _port));
    final client = widget.httpClient ?? http.Client();
    try {
      final res = await client.get(probe.healthUri).timeout(
            const Duration(seconds: 3),
          );
      if (!mounted) return;
      setState(() {
        _reachable = true;
        _checkResult = 'Reachable (HTTP ${res.statusCode})';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _reachable = false;
        _checkResult = 'Not reachable — $e';
      });
    } finally {
      if (widget.httpClient == null) client.close();
      if (mounted) setState(() => _checking = false);
    }
  }

  void _connect() {
    final config = widget.config.connectVia(
      _mode,
      RelayEndpoint(host: _hostController.text.trim(), port: _port),
    );
    Navigator.of(context).pop(config);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Manual Connection'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Use this when automatic mode switching doesn’t work.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _mode,
              decoration: const InputDecoration(
                labelText: 'Mode',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final m in PairConfig.knownModes)
                  DropdownMenuItem(value: m, child: Text(modeLabel(m))),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  _mode = v;
                  _reachable = null;
                  _checkResult = null;
                });
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _hostController,
              decoration: InputDecoration(
                labelText: 'Host',
                hintText: 'e.g. mac.tailnet.ts.net',
                border: const OutlineInputBorder(),
                suffixIcon: switch (_reachable) {
                  true => const Icon(Icons.check_circle, color: Colors.green),
                  false => const Icon(Icons.error, color: Colors.red),
                  null => null,
                },
              ),
              onChanged: (_) => setState(() {
                _reachable = null;
                _checkResult = null;
              }),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _portController,
              decoration: const InputDecoration(
                labelText: 'Port',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              onChanged: (_) => setState(() {
                _reachable = null;
                _checkResult = null;
              }),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _checking ? null : _checkReachability,
                  icon: _checking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: const Text('Test connection'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _checkResult == null
                      ? const SizedBox.shrink()
                      : Text(
                          _checkResult!,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: _reachable == true
                                    ? Colors.green
                                    : Colors.red,
                              ),
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _connect,
          child: const Text('Connect'),
        ),
      ],
    );
  }
}
