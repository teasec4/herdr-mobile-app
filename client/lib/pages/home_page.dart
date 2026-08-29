import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/pair_config.dart';
import '../models/relay_agent.dart';
import '../services/relay_client.dart';
import '../widgets/status_chip.dart';
import 'agent_page.dart';

/// Main screen: connection status and the list of agents on the computer.
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.config, required this.onDisconnect});

  final PairConfig config;

  /// Unpair the device (clear the saved pair and return to the scanner).
  final Future<void> Function() onDisconnect;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final RelayClient _client;
  List<RelayAgent> _agents = const [];
  bool _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // The relay client is shared app-wide (see main.dart).
    _client = context.read<RelayClient>();
    _client.status.addListener(_onStatusChanged);
    _client.events.listen(_onEvent);
    _refresh();
  }

  @override
  void dispose() {
    _client.status.removeListener(_onStatusChanged);
    _client.close();
    super.dispose();
  }

  void _onStatusChanged() {
    if (!mounted) return;
    // On reconnect, drop the stale error and reload the list by itself.
    if (_client.status.value == RelayStatus.connected && _error != null) {
      _refresh();
    } else {
      setState(() {});
    }
  }

  void _onEvent(RelayEvent event) {
    // The plugin fires this event on every agent status change —
    // re-read the snapshot so the list stays fresh.
    if (event.name == 'pane.agent_status_changed') {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    setState(() => _error = null);
    try {
      final agents = await _client.snapshot();
      if (mounted) {
        setState(() {
          _agents = RelayAgent.sorted(agents);
          _loaded = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _disconnect() async {
    await _client.close();
    await widget.onDisconnect();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _client.status.value == RelayStatus.connected;
    return Scaffold(
      appBar: AppBar(
        title: const Text('HerdRelay'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(
                  connected ? Icons.circle : Icons.circle_outlined,
                  size: 12,
                  color: connected
                      ? Colors.green
                      : _client.status.value == RelayStatus.connecting
                          ? Colors.orange
                          : Colors.grey,
                ),
                const SizedBox(width: 6),
                Text(
                  switch (_client.status.value) {
                    RelayStatus.connected => 'в сети',
                    RelayStatus.connecting => 'подключение…',
                    RelayStatus.disconnected => 'нет связи',
                  },
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: connected ? _refresh : null,
            tooltip: 'Обновить',
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'disconnect') _disconnect();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'disconnect',
                child: Text('Отключить устройство'),
              ),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _buildBody(connected),
      ),
    );
  }

  Widget _buildBody(bool connected) {
    if (_error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(Icons.error_outline, size: 40, color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 8),
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                TextButton(onPressed: _refresh, child: const Text('Повторить')),
              ],
            ),
          ),
        ],
      );
    }
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_agents.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Icon(Icons.terminal, size: 40, color: Colors.grey),
                const SizedBox(height: 8),
                const Text('Агенты не найдены'),
                const SizedBox(height: 4),
                Text(
                  'Запустите агента (например, `herdr codex`) на компьютере '
                  'или нажмите «Обновить».',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: _agents.length + 1,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == _agents.length) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              '${widget.config.mode} · ${widget.config.host}:${widget.config.port}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }
        final agent = _agents[i];
        return _AgentTile(agent: agent, onTap: () => _openAgent(agent));
      },
    );
  }

  void _openAgent(RelayAgent agent) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentPage(agent: agent),
      ),
    );
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

