import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/connection/mode_service.dart';
import '../core/service_locator.dart';
import '../models/pair_config.dart';
import '../utils/toast_service.dart';
import '../widgets/lan_only_warning_dialog.dart';

/// Onboarding: scan a QR with the relay pair link or paste a link manually.
class PairPage extends StatefulWidget {
  const PairPage({super.key, required this.onPaired, this.modesFetcher});

  /// Called with a valid pair; the parent saves it and switches the screen.
  final Future<void> Function(PairConfig config) onPaired;

  /// Injectable for tests; defaults to [ModeService.fetch] (with retries).
  /// Used for universal QR links (no `mode` param) to learn all modes.
  final Future<List<RelayModeInfo>> Function(PairConfig config)? modesFetcher;

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  final MobileScannerController _scanner = MobileScannerController();
  final TextEditingController _linkController = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _scanner.dispose();
    _linkController.dispose();
    super.dispose();
  }

  Future<void> _connect(String link) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      var config = PairConfig.fromLink(link);

      // Universal QR (no `mode` param): ask the relay for all its modes and
      // let the user pick a primary; every endpoint is saved so switching
      // modes later never needs a new scan (AUTO_MODE_SWITCHING_PLAN, Phase 4).
      if (!Uri.tryParse(link)!.queryParameters.containsKey('mode')) {
        final enriched = await _enrichFromModes(config);
        if (enriched == null || !mounted) return; // user cancelled the choice
        config = enriched;
      }

      // LAN-only pair: warn that the relay is unreachable away from home
      // (AUTO_MODE_SWITCHING_PLAN, Phase 1.1).
      if (config.endpoints.length == 1 && config.mode == 'lan') {
        final proceed = await showLanOnlyWarning(context);
        if (!proceed || !mounted) return;
      }

      await widget.onPaired(config);
    } on FormatException catch (e) {
      if (mounted) ToastService.showError(context, e.message);
    } catch (e) {
      if (mounted) ToastService.showError(context, 'Connection error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Fetches the relay's modes and asks which to use as the primary connection.
  /// Returns the enriched config, or `null` when the user cancels the choice.
  /// A fetch failure never blocks pairing — it shows a toast and falls back to
  /// the bare LAN config from the link.
  Future<PairConfig?> _enrichFromModes(PairConfig config) async {
    List<RelayModeInfo> modes;
    try {
      modes = await (widget.modesFetcher ?? getIt<ModeService>().fetch)(config);
    } catch (e) {
      if (mounted) {
        ToastService.showError(
            context, e is ModeFetchException ? e.message : e.toString());
      }
      return config;
    }
    if (!mounted) return null;
    if (modes.isEmpty) return config; // nothing to choose — keep the link default

    final selected = await _showModeSelectionDialog(modes);
    if (selected == null || !mounted) return null;

    return config
        .withEndpoints({
          for (final m in modes) m.mode: RelayEndpoint.fromUrl(m.url),
        })
        .connectVia(selected.mode, RelayEndpoint.fromUrl(selected.url));
  }

  Future<RelayModeInfo?> _showModeSelectionDialog(
      List<RelayModeInfo> modes) {
    return showDialog<RelayModeInfo>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select connection mode'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'The relay is reachable through several networks. '
              'Pick the one to use now — the others are saved too.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final mode in modes)
              ListTile(
                dense: true,
                leading: Icon(
                  switch (mode.mode) {
                    'lan' => Icons.wifi,
                    'tailscale' => Icons.lan,
                    'funnel' => Icons.public,
                    _ => Icons.link,
                  },
                ),
                title: Text(mode.mode),
                subtitle: Text(
                  mode.description.isEmpty ? mode.url : mode.description,
                ),
                onTap: () => Navigator.of(context).pop(mode),
              ),
          ],
        ),
      ),
    );
  }

  void _onDetect(BarcodeCapture capture) {
    final code = capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue;
    if (code == null) return;
    _scanner.stop();
    _connect(code);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to relay')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'Scan the QR code the relay shows on the computer '
              '(command `relay pair --qr`), or paste the link manually.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            _buildScannerCard(theme),
            const SizedBox(height: 24),
            TextField(
              controller: _linkController,
              decoration: const InputDecoration(
                labelText: 'Pair link',
                hintText: 'herdrelay://pair?host=...&token=...',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
              onSubmitted: _connect,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () => _connect(_linkController.text.trim()),
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link),
              label: const Text('Connect'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScannerCard(ThemeData theme) {
    return Container(
      height: 240,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: MobileScanner(
        controller: _scanner,
        onDetect: _onDetect,
        errorBuilder: (context, error) => Center(
          child: Text(
            'Camera unavailable (${error.errorCode.name}). '
            'Paste the link manually.',
            style: const TextStyle(color: Colors.white),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}