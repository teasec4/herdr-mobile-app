import 'dart:async';

import 'package:flutter/material.dart';

import '../core/service_locator.dart';
import '../models/relay_agent.dart';
import '../models/relay_session.dart';
import '../services/relay_client.dart';
import '../widgets/status_chip.dart';
import 'agent_page.dart';

/// Spaces tab: herdr workspaces (spaces) with their panes — agent panes and
/// plain terminals (docs/11-spaces.md). Tap a workspace to see its panes.
class SpacesPage extends StatefulWidget {
  const SpacesPage({super.key});

  @override
  State<SpacesPage> createState() => _SpacesPageState();
}

class _SpacesPageState extends State<SpacesPage> {
  RelaySession? _session;
  bool _loading = true;
  Object? _error;
  bool _wasDisconnected = false;

  @override
  void initState() {
    super.initState();
    _load();
    getIt<RelayClient>().status.addListener(_onConnectionStatus);
  }

  @override
  void dispose() {
    getIt<RelayClient>().status.removeListener(_onConnectionStatus);
    super.dispose();
  }

  /// Reloads the session after a reconnect — events during the gap were lost.
  void _onConnectionStatus() {
    if (!mounted) return;
    final s = getIt<RelayClient>().status.value;
    if (s == RelayStatus.connected && _wasDisconnected) {
      _wasDisconnected = false;
      _load();
    } else if (s != RelayStatus.connected) {
      _wasDisconnected = true;
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final session = await getIt<RelayClient>().session();
      if (!mounted) return;
      setState(() {
        _session = session;
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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$_error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton.tonal(
                onPressed: _load,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    final workspaces = _session?.workspaces ?? const <RelayWorkspace>[];
    if (workspaces.isEmpty) {
      return const Center(child: Text('No workspaces'));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: workspaces.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final ws = workspaces[i];
          final panes = (_session?.panes ?? const <RelayPane>[])
              .where((p) => p.workspaceId == ws.id)
              .toList();
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Text(
                ws.label.isEmpty ? '?' : ws.label.characters.first.toUpperCase(),
              ),
            ),
            title: Text(ws.label.isEmpty ? ws.id : ws.label),
            subtitle: Text('${panes.length} pane(s) · ${ws.id}'),
            trailing: StatusChip(status: ws.status),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => WorkspacePage(workspace: ws, panes: panes),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Panes of a single workspace: agents and plain terminals. Tap a pane to
/// open its terminal (output, keys; prompt works for agent panes).
class WorkspacePage extends StatelessWidget {
  const WorkspacePage({super.key, required this.workspace, required this.panes});

  final RelayWorkspace workspace;
  final List<RelayPane> panes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(workspace.label.isEmpty ? workspace.id : workspace.label),
      ),
      body: panes.isEmpty
          ? const Center(child: Text('No panes in this workspace'))
          : ListView.separated(
              itemCount: panes.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final pane = panes[i];
                final isAgent = pane.isAgentPane;
                return ListTile(
                  leading: Icon(
                    isAgent ? Icons.smart_toy : Icons.terminal,
                    color: isAgent
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                  ),
                  title: Text(pane.agent.isEmpty ? pane.id : pane.agent),
                  subtitle: Text('${pane.id} · ${pane.status}'),
                  trailing: StatusChip(status: pane.status),
                  onTap: () {
                    final agent = RelayAgent(
                      id: pane.id,
                      agent: pane.agent.isEmpty ? pane.id : pane.agent,
                      status: pane.status,
                      cwd: pane.cwd,
                      workspaceId: pane.workspaceId,
                      isPlainTerminal: !isAgent,
                    );
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => AgentPage(agent: agent),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}
