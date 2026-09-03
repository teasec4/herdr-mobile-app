import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/agents_store.dart';
import '../controllers/modes_controller.dart';
import '../core/service_locator.dart';
import '../models/pair_config.dart';
import '../models/relay_agent.dart';
import '../repositories/agent_repository.dart';
import '../services/app_settings.dart';
import '../services/relay_client.dart';
import '../utils/async_value.dart';
import '../widgets/mode_picker_sheet.dart';
import '../widgets/status_chip.dart';
import 'agent_page.dart';
import 'run_page.dart';
import 'settings_page.dart';
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
    this.modesController,
    this.gateTimeout = const Duration(seconds: 10),
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

  /// Injectable for tests; defaults to the global [ModesController].
  final ModesController? modesController;

  /// How long the connection may stay not-connected before the unreachable-
  /// relay gate replaces the tab body (injectable for tests).
  final Duration gateTimeout;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final AgentRepository _repository;

  /// Single source of truth for agent/workspace status (Agents tab, AgentPage,
  /// WorkspacePage and SessionController all read from here — no per-page
  /// status copies, so every listener always shows the same current state).
  late final AgentsStore _store;

  int _tabIndex = 0; // 0 = Spaces, 1 = Agents, 2 = Run, 3 = Settings

  /// Unreachable-relay gate: after [HomePage.gateTimeout] of not-connected the
  /// gate replaces the tab body and offers offline alternatives (switch mode,
  /// connection settings, open anyway) instead of an endless spinner.
  Timer? _gateTimer;
  bool _gateVisible = false;

  /// Tabs ever visited: IndexedStack children are built lazily on first visit
  /// (eagerly building all three fetched getAgents + 2× session at startup).
  /// Seeded with the restored tab so it builds immediately.
  late final Set<int> _visitedTabs;

  @override
  void initState() {
    super.initState();
    _repository = getIt<AgentRepository>();
    _store = getIt<AgentsStore>();
    final settings = getIt<AppSettings>();
    _tabIndex = settings.homeTabIndex.clamp(0, 3);
    _visitedTabs = {_tabIndex};
    _repository.status.addListener(_onStatusChanged);
    // Seed from the current status (e.g. restored while connecting).
    _onStatusChanged();
    // Lazy load kept: the store is primed exactly when the Agents tab becomes
    // visible — at startup if it's the restored tab, otherwise on first
    // selection (see onDestinationSelected). Never from build.
    if (_tabIndex == 1) _store.ensureLoaded();
  }

  @override
  void dispose() {
    _repository.status.removeListener(_onStatusChanged);
    _gateTimer?.cancel();
    super.dispose();
  }

  /// Restarts the gate countdown; no-op once connected.
  void _startGateTimer() {
    _gateTimer?.cancel();
    _gateTimer = null;
    if (_repository.status.value == RelayStatus.connected) return;
    _gateTimer = Timer(widget.gateTimeout, () {
      _gateTimer = null;
      if (mounted && _repository.status.value != RelayStatus.connected) {
        setState(() => _gateVisible = true);
      }
    });
  }

  void _onStatusChanged() {
    if (_repository.status.value == RelayStatus.connected) {
      _gateTimer?.cancel();
      _gateTimer = null;
      if (_gateVisible && mounted) setState(() => _gateVisible = false);
    } else if (_gateTimer == null && !_gateVisible) {
      _startGateTimer();
    }
  }

  /// "Try again": hide the gate and give the auto-reconnect another chance.
  void _dismissGate() {
    setState(() => _gateVisible = false);
    _startGateTimer();
  }

  Future<void> _disconnect() async {
    await _repository.close();
    await widget.onForgetDevice();
  }

  /// Opens the mode picker (loads /pair modes via [ModesController], handles
  /// loading/error states inside the sheet) and applies the chosen mode.
  Future<void> _openModePicker() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (_) => ModePickerSheet(
        config: widget.config,
        modesController: widget.modesController ?? getIt<ModesController>(),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Herdr Mobile'),
        actions: [
          // Status-dependent cluster re-renders only when the connection
          // status changes (no whole-page setState on every event).
          ValueListenableBuilder<RelayStatus>(
            valueListenable: _repository.status,
            builder: (context, status, _) {
              final connected = status == RelayStatus.connected;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Flexible: a long mode (TAILSCALE) truncates with an
                  // ellipsis instead of overflowing the AppBar on narrow
                  // screens / large fonts.
                  Flexible(child: _modeBadge(context)),
                  const SizedBox(width: 4),
                  Icon(
                    connected ? Icons.circle : Icons.circle_outlined,
                    size: 12,
                    color: connected
                        ? Colors.green
                        : status == RelayStatus.connecting
                            ? Colors.orange
                            : Colors.grey,
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 80),
                      child: Text(
                        switch (status) {
                          RelayStatus.connected => 'online',
                          RelayStatus.connecting => 'connecting…',
                          RelayStatus.disconnected => 'offline',
                        },
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _repository.status.value == RelayStatus.connected
                ? () => _store.refresh()
                : null,
            tooltip: 'Refresh',
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'add':
                  widget.onAddDevice();
                case 'forget':
                  _confirmForget();
              }
            },
            itemBuilder: (context) => const [
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
      // The gate overlays the tabs (kept alive underneath) so dismissing it
      // restores the exact scroll/tab state; when visible it covers the body
      // with offline alternatives instead of a forever-spinner.
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            IndexedStack(
              index: _tabIndex,
              children: [
                // Tab order matches the NavigationBar: 0 Spaces, 1 Agents, 2 Run.
                // Unvisited tabs stay as placeholders so no data is fetched until
                // the user actually opens them (lazy init).
                if (_visitedTabs.contains(0))
                  const SpacesPage()
                else
                  const SizedBox.shrink(),
                if (_visitedTabs.contains(1))
                  RefreshIndicator(
                    onRefresh: _store.refresh,
                    child: _buildBody(),
                  )
                else
                  const SizedBox.shrink(),
                if (_visitedTabs.contains(2))
                  const RunPage()
                else
                  const SizedBox.shrink(),
                if (_visitedTabs.contains(3))
                  SettingsPage(
                    config: widget.config,
                    modesController: widget.modesController,
                    onModeSelected: widget.onModeSelected,
                    onRequestSwitch: widget.onRequestSwitch,
                  )
                else
                  const SizedBox.shrink(),
              ],
            ),
            if (_gateVisible)
              Positioned.fill(
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.surface,
                  child: _gateBody(),
                ),
              ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) {
          // Remember the selected tab across app restarts (AppSettings).
          getIt<AppSettings>().setHomeTabIndex(i);
          // Prime the Agents store the first time the tab is shown (was a
          // build side effect before; ensureLoaded is idempotent).
          if (i == 1) _store.ensureLoaded();
          setState(() {
            _tabIndex = i;
            _visitedTabs.add(i);
          });
        },
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
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  /// Unreachable-relay gate: after [HomePage.gateTimeout] without a working
  /// connection the app stops spinning and offers offline alternatives —
  /// switch mode (works from saved endpoints), connection settings, or open
  /// the app anyway. Auto-dismisses the moment the connection comes up.
  Widget _gateBody() {
    final theme = Theme.of(context);
    final c = widget.config;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text('Cannot reach the relay', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '${c.mode} · ${c.host}:${c.port}',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'The relay has not connected for a while. Try again, or switch '
              'to another mode — e.g. Tailscale if you are away from the '
              'local network.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _dismissGate,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _openModePicker,
              icon: const Icon(Icons.swap_horiz),
              label: const Text('Change mode…'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: widget.onRequestSwitch,
              icon: const Icon(Icons.tune),
              label: const Text('Connection settings'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() => _gateVisible = false),
              child: const Text('Open app anyway'),
            ),
          ],
        ),
      ),
    );
  }

  /// Connection mode badge (tap to switch the mode). The mode text is capped
  /// and ellipsized so a long mode (TAILSCALE) never overflows the AppBar.
  Widget _modeBadge(BuildContext context) {
    return InkWell(
      onTap: _openModePicker,
      borderRadius: BorderRadius.circular(6),
      child: Tooltip(
        message: 'Tap to switch connection mode',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: _modeColor(widget.config.mode).withOpacity(0.2),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: _modeColor(widget.config.mode).withOpacity(0.5),
              width: 1,
            ),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 110),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    widget.config.mode.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: _modeColor(widget.config.mode),
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                const Icon(Icons.arrow_drop_down, size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    // Lazy load: the store was primed when the Agents tab became visible
    // (initState if restored, onDestinationSelected otherwise) — nothing is
    // fetched until the user actually opens the tab.
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        return switch (_store.state) {
          AsyncIdle() || AsyncLoading() =>
            const Center(child: CircularProgressIndicator()),
          AsyncError(:final error) => ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Icon(Icons.error_outline,
                          size: 40, color: Theme.of(context).colorScheme.error),
                      const SizedBox(height: 8),
                      Text('$error', textAlign: TextAlign.center),
                      const SizedBox(height: 8),
                      TextButton(
                          onPressed: _store.refresh,
                          child: const Text('Retry')),
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
                // RepaintBoundary + stable key: a status delta on one tile
                // repaints only that tile's layer and keeps its state/scroll
                // across list rebuilds.
                return RepaintBoundary(
                  key: ValueKey(agent.id),
                  child: _AgentTile(
                    agent: agent,
                    onTap: () => _openAgent(agent),
                  ),
                );
              },
            ),
        };
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

