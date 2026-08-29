import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../models/pair_config.dart';
import '../utils/toast_service.dart';

/// Onboarding: scan a QR with the relay pair link or paste a link manually.
class PairPage extends StatefulWidget {
  const PairPage({super.key, required this.onPaired});

  /// Called with a valid pair; the parent saves it and switches the screen.
  final Future<void> Function(PairConfig config) onPaired;

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
      final config = PairConfig.fromLink(link);
      await widget.onPaired(config);
    } on FormatException catch (e) {
      if (mounted) ToastService.showError(context, e.message);
    } catch (e) {
      if (mounted) ToastService.showError(context, 'Connection error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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