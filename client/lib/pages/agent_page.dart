import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/relay_agent.dart';
import '../services/relay_client.dart';
import '../utils/toast_service.dart';
import '../widgets/ansi_terminal.dart';
import '../widgets/status_chip.dart';

/// Quick key metadata: label, icon, and the key sequence to send.
class _SuggestedAction {
  const _SuggestedAction(this.label, this.response);
  final String label;
  final String response;
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
  StreamSubscription<RelayEvent>? _eventSubscription;
  late RelayAgent _agent;
  late final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();

  String _output = '';
  bool _loading = true;
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

  /// Suggested actions parsed from agent output.
  List<_SuggestedAction> _suggestedActions = [];

  @override
  void initState() {
    super.initState();
    _client = context.read<RelayClient>();
    _agent = widget.agent;
    _scroll.addListener(_onScroll);
    _eventSubscription = _client.events.listen(_onEvent);
    _loadCommandHistory();
    _refresh();
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
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
      setState(() => _loading = true);
    }
    try {
      final output = await _client.output(_agent.id, lines: 500, format: 'ansi');
      if (!mounted) return;
      setState(() {
        _output = output;
        _loading = false;
        _parseSuggestedActions(output);
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted || silent) return;
      setState(() {
        _loading = false;
      });
      ToastService.showError(context, e);
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
      if (mounted) ToastService.showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendKeys(List<String> keys) async {
    try {
      await _client.keys(_agent.id, keys);
    } catch (e) {
      if (mounted) ToastService.showError(context, e);
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
            tooltip: 'Refresh output',
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
    if (_loading && _output.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return AnsiTerminal(
      controller: _scroll,
      text: _output.isEmpty ? '(no output)' : _output,
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
          // Suggested actions (dynamic based on agent output)
          if (_suggestedActions.isNotEmpty) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _suggestedActions.map((action) {
                return FilledButton.tonal(
                  onPressed: () {
                    _input.text = action.response;
                    _send();
                  },
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: Colors.blue.shade100,
                    foregroundColor: Colors.blue.shade700,
                  ),
                  child: Text(action.label),
                );
              }).toList(),
            ),
            const SizedBox(height: 8),
          ],
          // Control: only Ctrl-C
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: () => _sendKeys(['C-c']),
                icon: const Icon(Icons.stop, size: 16),
                label: const Text('Ctrl-C'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: Colors.red.shade700,
                ),
              ),
              const Spacer(),
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
                      hintText: 'Message agent…',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      suffixIcon: (_historyIndex != null && _historyIndex! >= 0)
                          ? IconButton(
                              icon: const Icon(Icons.history, size: 18),
                              onPressed: _clearHistoryNavigation,
                              tooltip: 'Clear history',
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
                tooltip: 'Send',
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
  // Suggested actions parsing
  // ─────────────────────────────────────────────────────────────────────

  void _parseSuggestedActions(String output) {
    _suggestedActions = [];

    // Only suggest actions when agent is blocked
    if (_agent.status != 'blocked') return;

    // Parse only last 10 lines (agent prompts are at the end)
    final lines = output.split('\n');
    final recentLines = lines.length > 10 ? lines.sublist(lines.length - 10) : lines;

    // Find the last non-empty line before prompt markers (❯, >, ───)
    String? lastNonEmpty;
    for (int i = recentLines.length - 1; i >= 0; i--) {
      final stripped = recentLines[i].trim();
      // Skip empty lines and common prompt/decoration markers
      if (stripped.isEmpty ||
          stripped == '❯' ||
          stripped == '>' ||
          stripped.startsWith('─') ||
          stripped.startsWith('⏵')) {
        continue;
      }
      lastNonEmpty = stripped;
      break;
    }

    if (lastNonEmpty == null) return;

    // Strategy 1: Extract inline options from the last line
    // These are the most explicit - always trust them
    // Patterns: "(y/n)", "(yes/no)", "[y/n]", "accept/reject"
    final inlinePatterns = [
      RegExp(r'\(([^)]+)/([^)]+)\)'),           // (yes/no) or (y/n)
      RegExp(r'\[([^\]]+)/([^\]]+)\]'),         // [yes/no] or [y/n]
      RegExp(r'\b(\w+)\s*/\s*(\w+)\s*[?.]?\s*$'), // yes/no at end of line
    ];

    for (final pattern in inlinePatterns) {
      final match = pattern.firstMatch(lastNonEmpty);
      if (match != null && match.groupCount >= 2) {
        final opt1 = match.group(1)!.trim();
        final opt2 = match.group(2)!.trim();

        // Skip if options are too long (not real options)
        if (opt1.length <= 15 && opt2.length <= 15) {
          _suggestedActions.add(_SuggestedAction(_capitalize(opt1), opt1.toLowerCase()));
          _suggestedActions.add(_SuggestedAction(_capitalize(opt2), opt2.toLowerCase()));
          return;
        }
      }
    }

    // Strategy 2: Look for explicit questions - only if very clear
    final lastFewLines = recentLines.join('\n').toLowerCase();
    final hasExplicitQuestion = lastFewLines.contains(RegExp(r'\b(would you|do you want|should i|can i)\b'));

    // Only show yes/no if there's a question AND it ends with '?'
    if (hasExplicitQuestion && lastNonEmpty.trim().endsWith('?')) {
      _suggestedActions.add(const _SuggestedAction('Yes', 'yes'));
      _suggestedActions.add(const _SuggestedAction('No', 'no'));
      return;
    }

    // Strategy 3: Look for numbered options
    // "1. Option one"  "2. Option two"  or  "1) Option"
    final numberedPattern = RegExp(r'^\s*(\d+)[.)]\s+(.+)$', multiLine: true);
    final matches = numberedPattern.allMatches(recentLines.join('\n'));

    if (matches.length >= 2 && matches.length <= 6) {
      final options = <_SuggestedAction>[];
      for (final match in matches.take(6)) {
        final number = match.group(1)!;
        final text = match.group(2)!.trim();

        // Clean up the text: remove ANSI, keep first 40 chars
        final cleaned = text.replaceAll(RegExp(r'\x1B\[[0-9;]*[a-zA-Z]'), '');
        final label = cleaned.length > 40 ? '${cleaned.substring(0, 37)}...' : cleaned;

        options.add(_SuggestedAction(label, number));
      }

      if (options.isNotEmpty) {
        _suggestedActions = options;
        return;
      }
    }

    // Strategy 4: Look for checkbox lists - skip them
    // "◻ Do something"  "◼ Already done"
    final checkboxPattern = RegExp(r'^[◻◼☐☑]\s+(.+)$', multiLine: true);
    final checkMatches = checkboxPattern.allMatches(recentLines.join('\n'));

    if (checkMatches.length >= 2) {
      // This looks like a task list, not options. Skip.
      return;
    }

    // No clear pattern found - don't guess
  }

  String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1).toLowerCase();
  }

  // ─────────────────────────────────────────────────────────────────────
  // Quick keys and commands
  // ─────────────────────────────────────────────────────────────────────

}