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

  @override
  void initState() {
    super.initState();
    _load();
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
          ],
        ),
      ),
    );
  }
}
