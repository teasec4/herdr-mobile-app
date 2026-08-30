import 'dart:async';

import 'package:flutter/material.dart';

import '../core/connection/mode_service.dart';
import '../core/service_locator.dart';
import '../models/pair_config.dart';
import '../models/relay_agent.dart';
import '../models/relay_event.dart' as events;
import '../repositories/agent_repository.dart';
import '../services/relay_client.dart';
import '../utils/async_value.dart';
import '../utils/route_observer.dart';
import '../utils/toast_service.dart';
import '../widgets/mode_picker_sheet.dart';
import '../widgets/status_chip.dart';
import 'agent_page.dart';
import 'run_page.dart';
import 'spaces_page.dart';

/// Main screen: connection status and the list of agents on the computer.
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.config,
    required this.onRequestSwitch,
    required this.onAddDevice,
    required this.onForgetDevice,
    required this.onModeSelected,
    this.modesFetcher,
  });

  final PairConfig config;

  /// Open the profile picker to switch to another paired relay.
  final Future<void> Function() onRequestSwitch;

  /// Open the scanner to pair with an additional relay.
  final Future<void> Function() onAddDevice;

  /// Forget the active relay (remove the saved pair, return to the scanner)
  /// without unpairing other profiles.
  final Future<void> Function() onForgetDevice;

  /// Switch the connection mode (lan/tailscale/funnel): called with the new
  /// [PairConfig] parsed from the mode's link; the parent saves and reconnects.
  final Future<void> Function(PairConfig config) onModeSelected;

  /// Injectable for tests; defaults to [ModeService.fetch].
  final Future<List<RelayModeInfo>> Function(PairConfig config)? modesFetcher;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with RouteAware {
  late final AgentRepository _repository;
  StreamSubscription<events.RelayEvent>? _eventSubscription;
  AsyncValue<List<RelayAgent>> _agentsState = const AsyncIdle();
  Timer? _refreshDebounce;
  int _tabIndex = 0; // 0 = Spaces, 1 = Agents, 2 = Run

  /// True once the connection dropped: on the next connected state the list
  /// is re-read, because events that arrived during the gap were lost
  /// (docs/12-fix-plan.md, reconnect catch-up).
  bool _wasDisconnected = false;

  /// True while another route (AgentPage/WorkspacePage) is pushed on top: the
  /// list is not visible, so live events are ignored until we come back
  /// (didPopNext refreshes to catch up). Avoids hidden snapshot fetches.
  bool _paused = false;

  @override
  void initState() {
    super.initState();
    _repository = getIt<AgentRepository>();
    _repository.status.addListener(_onStatusChanged);
    _eventSubscription = _repository.events.listen(_onEvent);
    _refresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _refreshDebounce?.cancel();
    _repository.status.removeListener(_onStatusChanged);
    _eventSubscription?.cancel();
    super.dispose();
  }

  @override
  void didPushNext() {
    _paused = true;
  }

  @override
  void didPopNext() {
    _paused = false;
    if (mounted) _refresh(); // catch up while we were covered
  }

  void _onStatusChanged() {
    if (!mounted || _paused) return;
    final status = _repository.status.value;
    if (status == RelayStatus.connected) {
      // Catch up after a disconnect (events during the gap were lost) or an
      // earlier failure — always re-read the list.
      if (_wasDisconnected || _agentsState.hasError) {
        _wasDisconnected = false;
        _refresh();
        return;
      }
    } else {
      _wasDisconnected = true;
      // Events received while offline are pointless (the connection is
      // gone); the reconnect catch-up above re-reads the whole list.
      _refreshDebounce?.cancel();
    }
    // Connection badge (online/connecting/offline) re-render.
    setState(() {});
  }

  void _onEvent(events.RelayEvent event) {
    if (!mounted || _paused) return;

    if (event is events.AgentStatusChanged) {
      // The event carries the new status — update the tile in place instead of
      // re-reading the whole snapshot (statuses flip often while agents work).
      _applyStatusDelta(event);
      return;
    }
    if (event is events.PaneUpdated) {
      // A pane appeared/moved/changed — the list may need a full snapshot.
      _scheduleRefresh();
    }
  }

  /// Applies a status change locally from the event. A full snapshot is only
  /// taken when the pane is not in the current list (unknown to us); pane.updated
  /// covers genuinely new panes.
  void _applyStatusDelta(events.AgentStatusChanged event) {
    final current = _agentsState;
    if (current is! AsyncData<List<RelayAgent>>) {
      _scheduleRefresh(); // no list yet (loading/error) — fetch it
      return;
    }
    if (!current.data.any((a) => a.id == event.paneId)) {
      _scheduleRefresh(); // unknown pane — fall back to a snapshot
      return;
    }
    setState(() {
      _agentsState = AsyncData(RelayAgent.sorted([
        for (final a in current.data)
          if (a.id == event.paneId)
            a.copyWith(
              status: event.status,
              agent: event.agent.isEmpty ? a.agent : event.agent,
              workspaceId: event.workspaceId ?? a.workspaceId,
            )
          else
            a,
      ]));
    });
  }

  /// Debounces an event burst (e.g. a batch task flipping many agents) into a
  /// single snapshot request.
  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 300), () {
      // Skip while covered by AgentPage/WorkspacePage: didPopNext runs the
      // catch-up refresh when we come back, so no work is lost — just no
      // hidden snapshot fetch.
      if (mounted && !_paused) _refresh();
    });
  }

  Future<void> _refresh() async {
    // Keep the current list on screen while refreshing; show the spinner only
    // when there is nothing to show yet. This keeps the ListView mounted, so
    // scroll position and tile state survive event bursts.
    if (_agentsState is! AsyncData<List<RelayAgent>>) {
      setState(() => _agentsState = const AsyncLoading());
    }
    try {
      final agents = await _repository.getAgents();
      if (mounted) {
        setState(() {
          _agentsState = AsyncData(RelayAgent.sorted(agents));
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _agentsState = AsyncError(e));
        ToastService.showError(context, e);
      }
    }
  }

  Future<void> _disconnect() async {
    await _repository.close();
    await widget.onForgetDevice();
  }

  /// Opens the mode picker (fetches /pair modes via [ModeService], handles
  /// loading/error states inside the sheet) and applies the chosen mode.
  Future<void> _openModePicker() async {
    final fetcher = widget.modesFetcher ?? getIt<ModeService>().fetch;
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => ModePickerSheet(
        config: widget.config,
        fetcher: fetcher,
        onSelected: widget.onModeSelected,
      ),
    );
  }

  Future<void> _confirmForget() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget this device?'),
        content: const Text(
          'The saved pair will be removed. You can scan its QR again to reconnect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _disconnect();
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected = _repository.status.value == RelayStatus.connected;
    return Scaffold(
      appBar: AppBar(
        title: const Text('HerdRelay'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                // Connection mode badge — tap to switch the mode.
                InkWell(
                  onTap: _openModePicker,
                  borderRadius: BorderRadius.circular(6),
                  child: Tooltip(
                    message: 'Tap to switch connection mode',
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color:
                            _modeColor(widget.config.mode).withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: _modeColor(widget.config.mode)
                              .withOpacity(0.5),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.config.mode.toUpperCase(),
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: _modeColor(widget.config.mode),
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          const Icon(Icons.arrow_drop_down, size: 16),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  connected ? Icons.circle : Icons.circle_outlined,
                  size: 12,
                  color: connected
                      ? Colors.green
                      : _repository.status.value == RelayStatus.connecting
                          ? Colors.orange
                          : Colors.grey,
                ),
                const SizedBox(width: 6),
                Text(
                  switch (_repository.status.value) {
                    RelayStatus.connected => 'online',
                    RelayStatus.connecting => 'connecting…',
                    RelayStatus.disconnected => 'offline',
                  },
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: connected ? _refresh : null,
            tooltip: 'Refresh',
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'connection':
                  widget.onRequestSwitch();
                case 'add':
                  widget.onAddDevice();
                case 'forget':
                  _confirmForget();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'connection',
                child: Text('Connection…'),
              ),
              PopupMenuItem(
                value: 'add',
                child: Text('Add device…'),
              ),
              PopupMenuItem(
                value: 'forget',
                child: Text('Forget device'),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: IndexedStack(
          index: _tabIndex,
          children: [
            // Tab order matches the NavigationBar: 0 Spaces, 1 Agents, 2 Run.
            const SpacesPage(),
            RefreshIndicator(
              onRefresh: _refresh,
              child: _buildBody(connected),
            ),
            const RunPage(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.space_dashboard_outlined),
            selectedIcon: Icon(Icons.space_dashboard),
            label: 'Spaces',
          ),
          NavigationDestination(
            icon: Icon(Icons.smart_toy_outlined),
            selectedIcon: Icon(Icons.smart_toy),
            label: 'Agents',
          ),
          NavigationDestination(
            icon: Icon(Icons.play_circle_outline),
            selectedIcon: Icon(Icons.play_circle),
            label: 'Run',
          ),
        ],
      ),
    );
  }

  Widget _buildBody(bool connected) {
    return switch (_agentsState) {
      AsyncIdle() || AsyncLoading() => const Center(child: CircularProgressIndicator()),
      AsyncError(:final error) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Icon(Icons.error_outline, size: 40, color: Theme.of(context).colorScheme.error),
                  const SizedBox(height: 8),
                  Text('$error', textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  TextButton(onPressed: _refresh, child: const Text('Retry')),
                ],
              ),
            ),
          ],
        ),
      AsyncData(:final data) when data.isEmpty => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
              children: [
                const Icon(Icons.terminal, size: 40, color: Colors.grey),
                const SizedBox(height: 8),
                const Text('No agents found'),
                const SizedBox(height: 4),
                Text(
                  'Start an agent (e.g. `herdr codex`) on the computer '
                  'or press Refresh.',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      ),
      AsyncData(:final data) => ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: data.length + 1,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            if (i == data.length) {
              return Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '${widget.config.mode} · ${widget.config.host}:${widget.config.port}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              );
            }
            final agent = data[i];
            // Stable per-agent key: keeps tile state and scroll position across
            // list rebuilds (status deltas / refreshes).
            return _AgentTile(
              key: ValueKey(agent.id),
              agent: agent,
              onTap: () => _openAgent(agent),
            );
          },
        ),
    };
  }

  void _openAgent(RelayAgent agent) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentPage(agent: agent),
      ),
    );
  }

  Color _modeColor(String mode) {
    return switch (mode) {
      'lan' => Colors.blue,
      'tailscale' => Colors.purple,
      'funnel' => Colors.orange,
      _ => Colors.grey,
    };
  }
}

class _AgentTile extends StatelessWidget {
  const _AgentTile({super.key, required this.agent, required this.onTap});

  final RelayAgent agent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tile = ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: statusColor(theme, agent.status),
        child: Text(
          agent.displayAgent.characters.first.toUpperCase(),
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              agent.displayAgent,
              overflow: TextOverflow.ellipsis,
              style: agent.isBlocked ? const TextStyle(fontWeight: FontWeight.bold) : null,
            ),
          ),
          const SizedBox(width: 8),
          StatusChip(status: agent.status),
        ],
      ),
      subtitle: agent.cwd == null || agent.cwd!.isEmpty
          ? Text(agent.id, style: theme.textTheme.bodySmall)
          : Text('${agent.cwd}  ·  ${agent.id}', style: theme.textTheme.bodySmall),
      trailing: agent.focused ? const Icon(Icons.center_focus_strong, size: 16) : null,
    );

    // A blocked agent awaits a reply — highlight the whole tile.
    if (agent.isBlocked) {
      return Container(
        decoration: BoxDecoration(
          color: Colors.amber.withValues(alpha: 0.08),
          border: const Border(left: BorderSide(color: Colors.amber, width: 4)),
        ),
        // Material between DecoratedBox and ListTile: otherwise a debug assertion
        // about invisible ink effects (ListTile's background is drawn on the nearest Material).
        child: Material(color: Colors.transparent, child: tile),
      );
    }
    return tile;
  }
}

