import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/relay_agent.dart';
import '../services/relay_client.dart';
import '../widgets/ansi_terminal.dart';
import '../widgets/status_chip.dart';

/// Agent details: live terminal output, sending a prompt, quick keys.
///
/// The client comes from Provider — the same [RelayClient] as the list
/// (one WS channel for everything), so it is not closed on exit.
class AgentPage extends StatefulWidget {
  const AgentPage({super.key, required this.agent});

  /// Snapshot of the agent at open time; status is then updated from events.
  final RelayAgent agent;

  @override
  State<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends State<AgentPage> {
  late final RelayClient _client;
  late RelayAgent _agent;
  late final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  String _output = '';
  bool _loading = true;
  String? _error;
  bool _sending = false;

  /// Whether the view should follow new output; the user scrolling up turns
  /// it off so they can read, scrolling back to the bottom turns it on again.
  bool _stickToBottom = true;

  /// Debounce for live output updates: `pane.output_changed` events may arrive
  /// in bursts while an agent is streaming, so we wait until the stream settles
  /// before re-reading the tail.
  Timer? _outputDebounce;

  /// Last seen `revision` from a `pane.output_changed` event; older/equal
  /// revisions are ignored (out-of-order delivery safety).
  int? _lastRevision;

  @override
  void initState() {
    super.initState();
    _client = context.read<RelayClient>();
    _agent = widget.agent;
    _scroll.addListener(_onScroll);
    _client.events.listen(_onEvent);
    _refresh();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _scroll.dispose();
    _outputDebounce?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atBottom =
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 48;
    if (atBottom != _stickToBottom) {
      setState(() => _stickToBottom = atBottom);
    }
  }

  void _onEvent(RelayEvent event) {
    if (!mounted) return;
    // Live output change: re-read the tail on a debounce. The event carries
    // only {pane_id, revision} — no text — so we always pull the real output.
    if (event.name == 'pane.output_changed') {
      final data = event.data;
      if (data is! Map || data['pane_id'] != _agent.id) return;
      final rev = data['revision'];
      if (rev is int && _lastRevision != null && rev <= _lastRevision!) return;
      if (rev is int) _lastRevision = rev;
      _outputDebounce?.cancel();
      _outputDebounce =
          Timer(const Duration(milliseconds: 400), () => _refresh(silent: true));
      return;
    }
    if (event.name != 'pane.agent_status_changed') return;
    final data = event.data;
    if (data is Map && data['pane_id'] != _agent.id) return;
    setState(() {
      _agent = RelayAgent.fromJson(
        data is Map ? data.cast<String, dynamic>() : const {},
      );
    });
    _refresh();
  }

  /// Re-reads the agent output. In [silent] mode (live update after a
  /// `pane.output_changed` event) the spinner/error stay untouched and a
  /// failure is swallowed — the last good output remains on screen; the next
  /// event will retry.
  Future<void> _refresh({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final output = await _client.output(_agent.id, lines: 500, format: 'ansi');
      if (!mounted) return;
      setState(() {
        _output = output;
        _loading = false;
        _error = null;
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted || silent) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _scrollToBottom() {
    if (!_stickToBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await _client.prompt(_agent.id, text);
      _input.clear();
      // after sending, re-read the output: the agent has started working
      await _refresh();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendKeys(List<String> keys) async {
    try {
      await _client.keys(_agent.id, keys);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: Text(_agent.displayAgent, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            StatusChip(status: _agent.status),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _refresh(),
            tooltip: 'Обновить вывод',
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildOutput(theme)),
            _buildInputBar(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildOutput(ThemeData theme) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 40, color: theme.colorScheme.error),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              TextButton(onPressed: () => _refresh(), child: const Text('Повторить')),
            ],
          ),
        ),
      );
    }
    if (_loading && _output.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return AnsiTerminal(
      controller: _scroll,
      text: _output.isEmpty ? '(вывод пуст)' : _output,
    );
  }

  Widget _buildInputBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Quick keys: Esc and Ctrl-C are sent via agent.keys.
              IconButton(
                icon: const Icon(Icons.keyboard_tab, size: 20),
                onPressed: () => _sendKeys(const ['esc']),
                tooltip: 'Esc',
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                icon: const Icon(Icons.stop_circle_outlined, size: 20),
                onPressed: () => _sendKeys(const ['ctrl', 'c']),
                tooltip: 'Ctrl-C (прервать)',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  decoration: const InputDecoration(
                    hintText: 'Сообщение агенту…',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                onPressed: _sending ? null : _send,
                tooltip: 'Отправить',
              ),
            ],
          ),
        ],
      ),
    );
  }
}