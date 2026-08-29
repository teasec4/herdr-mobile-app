import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/service_locator.dart';
import '../models/relay_agent.dart';
import '../models/relay_event.dart';
import '../repositories/agent_repository.dart';
import '../services/action_parser_service.dart';
import '../services/command_history_service.dart';
import '../utils/toast_service.dart';
import '../widgets/ansi_terminal.dart';
import '../widgets/status_chip.dart';

/// Agent details: live terminal output, sending a prompt, quick keys.
class AgentPage extends StatefulWidget {
  const AgentPage({super.key, required this.agent});

  /// Snapshot of the agent at open time; status is then updated from events.
  final RelayAgent agent;

  @override
  State<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends State<AgentPage> {
  late final AgentRepository _repository;
  late final CommandHistoryService _historyService;
  late final ActionParserService _parserService;
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
  List<String> _commandHistory = [];
  int? _historyIndex;
  String? _historyTemp;

  /// Suggested actions parsed from agent output.
  List<SuggestedAction> _suggestedActions = [];

  @override
  void initState() {
    super.initState();
    _repository = getIt<AgentRepository>();
    _historyService = getIt<CommandHistoryService>();
    _parserService = getIt<ActionParserService>();
    _agent = widget.agent;
    print('[AgentPage] Initialized with agent: id=${_agent.id}, status=${_agent.status}, agent=${_agent.agent}');
    _scroll.addListener(_onScroll);
    _eventSubscription = _repository.events.listen(_onEvent);
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

    // Output changed: debounce and refresh
    if (event is OutputChanged) {
      if (event.paneId != _agent.id) return;
      if (_lastRevision != null && event.revision <= _lastRevision!) return;
      _lastRevision = event.revision;
      _outputDebounce?.cancel();
      _outputDebounce =
          Timer(const Duration(milliseconds: 400), () => _refresh(silent: true));
      return;
    }

    // Agent status changed: update agent state and refresh
    if (event is AgentStatusChanged) {
      print('[AgentPage] AgentStatusChanged event: paneId=${event.paneId}, status=${event.status}, myId=${_agent.id}');
      if (event.paneId != _agent.id) return;
      setState(() {
        _agent = RelayAgent(
          id: _agent.id,
          agent: _agent.agent,
          status: event.status,
          focused: _agent.focused,
          cwd: _agent.cwd,
        );
      });
      print('[AgentPage] Updated agent status to: ${_agent.status}');
      _refresh();
    }
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
      // Also refresh agent metadata from snapshot to get current status
      if (!silent) {
        await _refreshAgentFromSnapshot();
      }

      final output = await _repository.getOutput(_agent.id, lines: 500);
      if (!mounted) return;
      setState(() {
        _output = output;
        _loading = false;
        _suggestedActions = _parserService.parse(output);
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted || silent) return;
      setState(() => _loading = false);
      ToastService.showError(context, e);
    }
  }

  /// Refresh agent metadata (status, etc.) from current snapshot
  Future<void> _refreshAgentFromSnapshot() async {
    try {
      final agents = await _repository.getAgents();
      final current = agents.where((a) => a.id == _agent.id).firstOrNull;
      if (current != null && mounted) {
        setState(() {
          _agent = current;
        });
        print('[AgentPage] Refreshed agent from snapshot: status=${_agent.status}');
      }
    } catch (e) {
      print('[AgentPage] Failed to refresh agent from snapshot: $e');
      // Ignore error - keep current agent state
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
      await _repository.sendPrompt(_agent.id, text);
      await _historyService.addCommand(_agent.id, text);
      _input.clear();
      _clearHistoryNavigation();
      // Reload command history from service
      _commandHistory = await _historyService.load(_agent.id);
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
      await _repository.sendKeys(_agent.id, keys);
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
    _commandHistory = await _historyService.load(_agent.id);
    if (mounted) setState(() {});
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
}