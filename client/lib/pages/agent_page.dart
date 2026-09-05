import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/agents_store.dart';
import '../controllers/app_session_controller.dart';
import '../controllers/attention_store.dart';
import '../core/service_locator.dart';
import '../models/relay_agent.dart';
import '../models/relay_event.dart';
import '../repositories/agent_repository.dart';
import '../services/app_settings.dart';
import '../services/command_history_service.dart';
import '../utils/toast_service.dart';
import '../widgets/ansi_terminal.dart';
import '../widgets/status_chip.dart';

/// Agent details: live terminal output, sending a prompt, quick keys.
class AgentPage extends StatefulWidget {
  const AgentPage({super.key, required this.agent});

  /// Snapshot of the agent at open time; live status/name are read from
  /// [AgentsStore] (the single source of truth) and fall back to this.
  final RelayAgent agent;

  @override
  State<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends State<AgentPage> {
  late final AgentRepository _repository;
  late final AgentsStore _store;
  late final CommandHistoryService _historyService;

  /// Root session: on a config switch the relay services are torn down and
  /// recreated, so every cached getIt reference below becomes stale. We record
  /// the version at open time and pop when it changes — the terminal is invalid
  /// against the new repository (docs/plan, Critical 2).
  late final AppSessionController _session;
  late int _sessionVersionAtOpen;

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
  /// Restored from / persisted to [AppSettings] (docs/13 §1.3).
  late bool _stickToBottom;

  /// Terminal font size in points, from [AppSettings] (accessibility: A−/A+ in
  /// the AppBar).
  late double _terminalFontSize;

  late final AppSettings _settings;

  /// Debounce for live output updates: `pane.output_changed` events may arrive
  /// in bursts while an agent is streaming, so we wait until the stream settles
  /// before re-reading the tail.
  Timer? _outputDebounce;

  /// Periodic poll while the agent is `working` (see [_startLivePolling]):
  /// `\r`-based animations rewrite the current line without scrolling, so herdr
  /// never emits `pane.scroll_changed` for them and the event path stays silent.
  Timer? _livePollTimer;

  /// Last seen `revision` from a `pane.output_changed` event; older/equal
  /// revisions are ignored (out-of-order delivery safety). The server's
  /// events carry no revision (parsed as 0), so the guard only engages when
  /// a revision is actually present.
  int? _lastRevision;

  /// Command history and navigation state.
  List<String> _commandHistory = [];
  int? _historyIndex;
  String? _historyTemp;

  /// Guards against overlapping refreshes: a manual refresh and an event
  /// trigger may run concurrently — a stale response must not overwrite a
  /// fresher one (docs/12-fix-plan.md, refresh races).
  int _refreshGeneration = 0;

  @override
  void initState() {
    super.initState();
    _session = getIt<AppSessionController>();
    _sessionVersionAtOpen = _session.version;
    _session.addListener(_onSessionChanged);
    _repository = getIt<AgentRepository>();
    _store = getIt<AgentsStore>();
    _store.ensureLoaded();
    // Status flips arrive through the store (single source of truth); we sync
    // the live-poll timer with them so the timer exists only while working.
    _store.addListener(_onStoreChanged);
    _historyService = getIt<CommandHistoryService>();
    _settings = getIt<AppSettings>();
    _stickToBottom = _settings.autoScrollFollow;
    _terminalFontSize = _settings.terminalFontSize;
    _agent = widget.agent;
    _scroll.addListener(_onScroll);
    _eventSubscription = _repository.events.listen(_onEvent);
    // Opening the chat views the agent: a "finished while you were away" mark
    // is cleared here, and a finish while this chat stays open is not marked.
    // Deferred past the mount frame: view() notifies listeners, and the Home
    // page behind this route can be rebuilding during the push transition.
    if (getIt.isRegistered<AttentionStore>()) {
      final attention = getIt<AttentionStore>();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) attention.view(_agent.id);
      });
    }
    _loadCommandHistory();
    _refresh();
    _syncPollTimer();
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    if (getIt.isRegistered<AttentionStore>()) {
      getIt<AttentionStore>().closeView(_agent.id);
    }
    _store.removeListener(_onStoreChanged);
    _session.removeListener(_onSessionChanged);
    _scroll.removeListener(_onScroll);
    _input.dispose();
    _scroll.dispose();
    _inputFocusNode.dispose();
    _outputDebounce?.cancel();
    _livePollTimer?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atBottom =
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 48;
    if (atBottom != _stickToBottom) {
      setState(() => _stickToBottom = atBottom);
      // Remember the preference across page reopens.
      _settings.setAutoScrollFollow(atBottom);
    }
  }

  /// A config switch (pair via deep link, mode change, forget) tears down and
  /// recreates the relay services, leaving every getIt reference in this page
  /// pointing at disposed objects. The terminal cannot be meaningfully kept
  /// open against the new repository, so pop; the caller (notification flow,
  /// navigation) re-opens it against the fresh services.
  void _onSessionChanged() {
    if (!mounted) return;
    if (_session.version != _sessionVersionAtOpen) {
      Navigator.of(context).pop();
    }
  }

  /// Steps the terminal font size by [delta] (A−/A+) and persists it.
  void _changeFontSize(int delta) {
    setState(() {
      _terminalFontSize =
          (_terminalFontSize + delta).clamp(AppSettings.kMinFontSize, AppSettings.kMaxFontSize).toDouble();
    });
    _settings.setTerminalFontSize(_terminalFontSize);
  }

  void _onEvent(RelayEvent event) {
    if (!mounted) return;

    // Output changed: debounce and refresh. Agent status is not handled here —
    // live status/name come from AgentsStore (single source of truth) and are
    // rendered by the ListenableBuilder in the AppBar.
    if (event is OutputChanged) {
      if (event.paneId != _agent.id) return;
      // herdr's pane.scroll_changed carries no revision (always 0), so the
      // revision guard only applies when a revision is actually present.
      if (event.revision > 0) {
        if (_lastRevision != null && event.revision <= _lastRevision!) return;
        _lastRevision = event.revision;
      } else {
        // Revision 0 means "something changed but we have no revision to
        // track": drop the cached revision so the refresh is a real RPC and
        // can never hit the cache with stale text.
        _lastRevision = null;
      }
      _outputDebounce?.cancel();
      _outputDebounce = Timer(
        const Duration(milliseconds: 100),
        () => _refresh(silent: true, knownRevision: _lastRevision),
      );
      return;
    }
  }

  /// Polls the current frame every second while the agent is `working`.
  /// `\r`-based animations (spinners, progress lines) rewrite the same line
  /// without scrolling, so herdr emits no `pane.scroll_changed` and the event
  /// path never fires; polling is the only way those redraw on screen. The
  /// poll only exists while `working` (see [_syncPollTimer]).
  void _startLivePolling() {
    _livePollTimer?.cancel();
    _livePollTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _livePoll());
  }

  /// Starts/stops the live poll to match the agent's current status: the timer
  /// is created on entering `working` and cancelled on leaving it, so an idle
  /// agent pays no timer cost. Called from initState and on every [AgentsStore]
  /// change (status flips arrive through the store).
  void _syncPollTimer() {
    if (!mounted) return;
    final status = (_store.statusOf(_agent.id) ?? _agent.status).toLowerCase();
    final isWorking = status == 'working';
    if (isWorking && _livePollTimer == null) {
      _startLivePolling();
    } else if (!isWorking && _livePollTimer != null) {
      _livePollTimer?.cancel();
      _livePollTimer = null;
    }
  }

  void _onStoreChanged() {
    // Status flips arrive through the store. In widget tests the store's event
    // stream is subscribed before the test body runs, so its callbacks execute
    // outside the test's fake-async zone; creating the periodic poll timer
    // synchronously here would bind it to the real event loop and it would
    // never fire under fake time. Deferring to a post-frame callback creates
    // the timer in the binding's zone (which is also nicer: the timer starts
    // after the rebuild caused by the status change).
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncPollTimer());
  }

  void _livePoll() {
    if (!mounted) return;
    final status = (_store.statusOf(_agent.id) ?? _agent.status).toLowerCase();
    if (status != 'working') return;
    _refresh(silent: true, knownRevision: _lastRevision);
  }

  /// Re-reads the agent output. In [silent] mode (live update after a
  /// `pane.output_changed` event) the spinner/error stay untouched and a
  /// failure is swallowed — the last good output remains on screen; the next
  /// event will retry. [knownRevision] (the event's revision) lets the
  /// repository skip the RPC when the cached output already matches it.
  Future<void> _refresh({bool silent = false, int? knownRevision}) async {
    final gen = ++_refreshGeneration;
    if (!silent) {
      setState(() => _loading = true);
    }
    try {
      final output = _agent.isPlainTerminal
          ? await _repository.getPaneOutput(_agent.id,
              lines: 500, knownRevision: knownRevision)
          : await _repository.getOutput(_agent.id,
              lines: 500, knownRevision: knownRevision);
      if (!mounted || gen != _refreshGeneration) return;
      if (silent && output == _output) return; // no change, no repaint
      setState(() {
        _output = output;
        _loading = false;
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted || silent || gen != _refreshGeneration) return;
      setState(() => _loading = false);
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
      if (_agent.isPlainTerminal) {
        await _repository.sendText(_agent.id, text);
      } else {
        await _repository.sendPrompt(_agent.id, text);
      }
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
        // Live name/status from the shared store; falls back to the open-time
        // snapshot while the store has not loaded the agent yet.
        title: ListenableBuilder(
          listenable: _store,
          builder: (context, _) {
            final live = _store.byId(_agent.id);
            final name = live?.displayAgent ?? _agent.displayAgent;
            final status = live?.status ?? _agent.status;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 8),
                StatusChip(status: status),
              ],
            );
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.text_decrease),
            tooltip: 'Smaller text',
            onPressed: _terminalFontSize > AppSettings.kMinFontSize
                ? () => _changeFontSize(-1)
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.text_increase),
            tooltip: 'Larger text',
            onPressed: _terminalFontSize < AppSettings.kMaxFontSize
                ? () => _changeFontSize(1)
                : null,
          ),
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
      style: AnsiTerminal.defaultStyle.copyWith(fontSize: _terminalFontSize),
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