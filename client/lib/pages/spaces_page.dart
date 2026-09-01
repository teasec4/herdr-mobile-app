import 'package:flutter/material.dart';

import '../controllers/agents_store.dart';
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
/// Pure view over [SessionController] (load, reconnect catch-up and structure
/// refresh) + [AgentsStore] (live workspace statuses derived from agent
/// statuses — the same single source as the Agents tab).
class SpacesPage extends StatefulWidget {
  const SpacesPage({super.key});

  @override
  State<SpacesPage> createState() => _SpacesPageState();
}

class _SpacesPageState extends State<SpacesPage> {
  late final SessionController _controller;
  late final AgentsStore _store;

  /// The merged listenable is created once in [initState] — recreating it in
  /// `build` would re-subscribe the builder on every rebuild.
  late final Listenable _listenable;

  @override
  void initState() {
    super.initState();
    _controller = getIt<SessionController>();
    _store = getIt<AgentsStore>();
    // Loads once (idempotent afterwards); kept out of build so no side
    // effects run during layout.
    _controller.ensureLoaded();
    _store.ensureLoaded();
    _listenable = Listenable.merge([_controller, _store]);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _listenable,
      builder: (context, _) {
        return switch (_controller.state) {
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
                      onPressed: _controller.refresh,
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
              store: _store,
              onRefresh: _controller.refresh,
            ),
        };
      },
    );
  }
}

/// Workspace list with pull-to-refresh.
class _WorkspaceList extends StatelessWidget {
  const _WorkspaceList({
    required this.session,
    required this.store,
    required this.onRefresh,
  });

  final RelaySession session;
  final AgentsStore store;
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
            trailing: StatusChip(status: store.workspaceStatus(ws.id)),
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
///
/// Pane structure comes from the navigated [panes] snapshot (the session is
/// the only source of plain-terminal flags); each pane's live status is read
/// from [AgentsStore] so returning from a pane never shows a stale status.
class WorkspacePage extends StatelessWidget {
  const WorkspacePage({super.key, required this.workspace, required this.panes});

  final RelayWorkspace workspace;
  final List<RelayPane> panes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = getIt<AgentsStore>();
    return Scaffold(
      appBar: AppBar(
        title: Text(workspace.label.isEmpty ? workspace.id : workspace.label),
      ),
      body: panes.isEmpty
          ? const Center(child: Text('No panes in this workspace'))
          : ListenableBuilder(
              listenable: store,
              builder: (context, _) => ListView.separated(
                itemCount: panes.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final pane = panes[i];
                  final isAgent = pane.isAgentPane;
                  final status = store.statusOf(pane.id) ?? pane.status;
                  return ListTile(
                    leading: Icon(
                      isAgent ? Icons.smart_toy : Icons.terminal,
                      color: isAgent
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline,
                    ),
                    title: Text(pane.agent.isEmpty ? pane.id : pane.agent),
                    subtitle: Text('${pane.id} · $status'),
                    trailing: StatusChip(status: status),
                    onTap: () {
                      final agent = RelayAgent(
                        id: pane.id,
                        agent: pane.agent.isEmpty ? pane.id : pane.agent,
                        status: status,
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
            ),
    );
  }
}
