import 'package:flutter/material.dart';

import '../controllers/session_controller.dart';
import '../core/service_locator.dart';
import '../models/relay_agent.dart';
import '../models/relay_session.dart';
import '../utils/async_value.dart';
import '../widgets/status_chip.dart';
import 'agent_page.dart';

/// Spaces tab: herdr workspaces (spaces) with their panes — agent panes and
/// plain terminals (docs/11-spaces.md). Tap a workspace to see its panes.
///
/// Pure view over [SessionController] (load, reconnect catch-up and live
/// status refresh live in the controller, shared with the Run tab).
class SpacesPage extends StatelessWidget {
  const SpacesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = getIt<SessionController>();
    // Loads once on the first build (idempotent afterwards).
    controller.ensureLoaded();
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return switch (controller.state) {
          AsyncIdle() || AsyncLoading() =>
            const Center(child: CircularProgressIndicator()),
          AsyncError(:final error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$error', textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: controller.refresh,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          AsyncData(:final data) when data.workspaces.isEmpty =>
            const Center(child: Text('No workspaces')),
          AsyncData(:final data) => _WorkspaceList(
              session: data,
              onRefresh: controller.refresh,
            ),
        };
      },
    );
  }
}

/// Workspace list with pull-to-refresh.
class _WorkspaceList extends StatelessWidget {
  const _WorkspaceList({required this.session, required this.onRefresh});

  final RelaySession session;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final workspaces = session.workspaces;
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: workspaces.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final ws = workspaces[i];
          final panes = session.panes
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
