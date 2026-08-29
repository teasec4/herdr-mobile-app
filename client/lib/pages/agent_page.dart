import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/relay_agent.dart';
import '../services/relay_client.dart';
import '../widgets/ansi_terminal.dart';
import '../widgets/status_chip.dart';

/// Quick key metadata: label, icon, and the key sequence to send.
class _QuickKey {
  const _QuickKey(this.label, this.icon, this.keys);
  final String label;
  final IconData icon;
  final List<String> keys;
}

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
  final FocusNode _inputFocusNode = FocusNode();

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

  /// Command history and navigation state.
  final List<String> _commandHistory = [];
  int? _historyIndex;
  String? _historyTemp;

  @override
  void initState() {
    super.initState();
    _client = context.read<RelayClient>();
    _agent = widget.agent;
    _scroll.addListener(_onScroll);
    _client.events.listen(_onEvent);
    _loadCommandHistory();
    _refresh();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _scroll.dispose();
    _inputFocusNode.dispose();
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

      // Add to command history (avoid duplicates)
      if (_commandHistory.isEmpty || _commandHistory.last != text) {
        _commandHistory.add(text);
        // Keep last 100 commands
        if (_commandHistory.length > 100) {
          _commandHistory.removeAt(0);
        }
        await _saveCommandHistory();
      }

      _input.clear();
      _clearHistoryNavigation();
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
          // Quick keys grouped by purpose
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // Interrupt group (red-ish)
              ..._buildQuickKeyGroup(
                'Прервать',
                [
                  _QuickKey('Ctrl-C', Icons.stop, ['ctrl', 'c']),
                  _QuickKey('Ctrl-Z', Icons.pause, ['ctrl', 'z']),
                ],
                Colors.red.shade100,
                Colors.red.shade700,
              ),
              // Navigation group (neutral)
              ..._buildQuickKeyGroup(
                'Навигация',
                [
                  _QuickKey('Esc', Icons.keyboard_tab, ['esc']),
                  _QuickKey('Ctrl-L', Icons.clear_all, ['ctrl', 'l']),
                ],
                Colors.grey.shade200,
                Colors.grey.shade800,
              ),
              // Input group (green-ish)
              ..._buildQuickKeyGroup(
                'Ввод',
                [
                  _QuickKey('Enter', Icons.keyboard_return, ['enter']),
                  _QuickKey('Ctrl-D', Icons.eject, ['ctrl', 'd']),
                ],
                Colors.green.shade100,
                Colors.green.shade700,
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Quick commands menu
          Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: _showQuickCommands,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.flash_on, size: 16),
                      SizedBox(width: 4),
                      Text('Быстрые команды'),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Text input with history navigation
          Row(
            children: [
              Expanded(
                child: KeyboardListener(
                  focusNode: _inputFocusNode,
                  onKeyEvent: _handleKeyEvent,
                  child: TextField(
                    controller: _input,
                    decoration: InputDecoration(
                      hintText: 'Сообщение агенту…',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      suffixIcon: (_historyIndex != null && _historyIndex! >= 0)
                          ? IconButton(
                              icon: const Icon(Icons.history, size: 18),
                              onPressed: _clearHistoryNavigation,
                              tooltip: 'Сбросить навигацию',
                            )
                          : null,
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                  ),
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

  // ─────────────────────────────────────────────────────────────────────
  // Command history
  // ─────────────────────────────────────────────────────────────────────

  Future<void> _loadCommandHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('command_history_${_agent.id}') ?? [];
    if (!mounted) return;
    setState(() {
      _commandHistory.clear();
      _commandHistory.addAll(history);
    });
  }

  Future<void> _saveCommandHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('command_history_${_agent.id}', _commandHistory);
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _navigateHistory(-1);
    } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _navigateHistory(1);
    }
  }

  void _navigateHistory(int direction) {
    if (_commandHistory.isEmpty) return;

    setState(() {
      if (_historyIndex == null) {
        // First navigation: save current input and start from the end
        _historyTemp = _input.text;
        _historyIndex = _commandHistory.length;
      }

      _historyIndex = (_historyIndex! + direction)
          .clamp(0, _commandHistory.length);

      if (_historyIndex == _commandHistory.length) {
        // Back to the original input
        _input.text = _historyTemp ?? '';
      } else {
        _input.text = _commandHistory[_historyIndex!];
      }

      // Move cursor to the end
      _input.selection = TextSelection.fromPosition(
        TextPosition(offset: _input.text.length),
      );
    });
  }

  void _clearHistoryNavigation() {
    // Only exit history mode; keep the current text (e.g. when the user taps
    // the reset icon while browsing history). _send clears the input itself.
    setState(() {
      _historyIndex = null;
      _historyTemp = null;
    });
  }

  // ─────────────────────────────────────────────────────────────────────
  // Quick keys and commands
  // ─────────────────────────────────────────────────────────────────────

  List<Widget> _buildQuickKeyGroup(
    String groupLabel,
    List<_QuickKey> keys,
    Color bgColor,
    Color fgColor,
  ) {
    return [
      Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Text(
          groupLabel,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Colors.grey.shade600,
          ),
        ),
      ),
      ...keys.map((key) => ActionChip(
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(key.icon, size: 16),
                const SizedBox(width: 4),
                Text(key.label, style: const TextStyle(fontSize: 12)),
              ],
            ),
            backgroundColor: bgColor,
            labelStyle: TextStyle(color: fgColor),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            visualDensity: VisualDensity.compact,
            onPressed: () => _sendKeys(key.keys),
          )),
    ];
  }

  void _showQuickCommands() {
    showModalBottomSheet(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Быстрые команды',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildCommandButton('status', Icons.info_outline),
                _buildCommandButton('continue', Icons.play_arrow),
                _buildCommandButton('skip', Icons.skip_next),
                _buildCommandButton('yes', Icons.check),
                _buildCommandButton('no', Icons.close),
                _buildCommandButton('help', Icons.help_outline),
                _buildCommandButton('quit', Icons.exit_to_app),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCommandButton(String command, IconData icon) {
    return OutlinedButton.icon(
      icon: Icon(icon, size: 18),
      label: Text(command),
      onPressed: () {
        Navigator.of(context).pop();
        _input.text = command;
        _send();
      },
    );
  }
}