import 'dart:async';

import 'package:flutter/material.dart';

import '../core/service_locator.dart';
import '../models/pair_config.dart';
import '../models/relay_agent.dart';
import '../models/relay_event.dart' as events;
import '../repositories/agent_repository.dart';
import '../services/relay_client.dart';
import '../utils/async_value.dart';
import '../utils/toast_service.dart';
import '../widgets/status_chip.dart';
import 'agent_page.dart';

/// Main screen: connection status and the list of agents on the computer.
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.config,
    required this.onRequestSwitch,
    required this.onAddDevice,
    required this.onForgetDevice,
  });

  final PairConfig config;

  /// Open the profile picker to switch to another paired relay.
  final Future<void> Function() onRequestSwitch;

  /// Open the scanner to pair with an additional relay.
  final Future<void> Function() onAddDevice;

  /// Forget the active relay (remove the saved pair, return to the scanner)
  /// without unpairing other profiles.
  final Future<void> Function() onForgetDevice;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final AgentRepository _repository;
  StreamSubscription<events.RelayEvent>? _eventSubscription;
  AsyncValue<List<RelayAgent>> _agentsState = const AsyncIdle();
  Timer? _refreshDebounce;

  @override
  void initState() {
    super.initState();
    _repository = getIt<AgentRepository>();
    _repository.status.addListener(_onStatusChanged);
    _eventSubscription = _repository.events.listen(_onEvent);
    _refresh();
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    _repository.status.removeListener(_onStatusChanged);
    _eventSubscription?.cancel();
    super.dispose();
  }

  void _onStatusChanged() {
    if (!mounted) return;
    // On reconnect, reload the list
    if (_repository.status.value == RelayStatus.connected && _agentsState.hasError) {
      _refresh();
    } else {
      setState(() {});
    }
  }

  void _onEvent(events.RelayEvent event) {
    if (!mounted) return;

    // DEBUG: log all events
    print('[HomePage] Event received: $event');

    // The plugin fires these events on agent status changes — re-read the
    // snapshot so the list stays fresh. Debounce a burst of events (e.g. a
    // batch task flipping many agents at once) into a single snapshot request.
    if (event is events.AgentStatusChanged || event is events.PaneUpdated) {
      _refreshDebounce?.cancel();
      _refreshDebounce = Timer(const Duration(milliseconds: 300), () {
        if (mounted) {
          print('[HomePage] Refreshing after event burst');
          _refresh();
        }
      });
    }
  }

  Future<void> _refresh() async {
    setState(() => _agentsState = const AsyncLoading());
    try {
      print('[HomePage] Fetching snapshot...');
      final agents = await _repository.getAgents();
      print('[HomePage] Got ${agents.length} agents:');
      for (final a in agents) {
        print('[HomePage]   ${a.id}: ${a.agent} (${a.status})');
      }
      if (mounted) {
        setState(() {
          _agentsState = AsyncData(RelayAgent.sorted(agents));
        });
        print('[HomePage] UI updated with ${agents.length} agents');
      }
    } catch (e) {
      print('[HomePage] Refresh error: $e');
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
                // Connection mode badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _modeColor(widget.config.mode).withOpacity(0.2),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: _modeColor(widget.config.mode).withOpacity(0.5),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    widget.config.mode.toUpperCase(),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: _modeColor(widget.config.mode),
                          fontWeight: FontWeight.bold,
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
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: _buildBody(connected),
        ),
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
            return _AgentTile(agent: agent, onTap: () => _openAgent(agent));
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
  const _AgentTile({required this.agent, required this.onTap});

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

