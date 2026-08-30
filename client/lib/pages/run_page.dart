import 'package:flutter/material.dart';

import '../controllers/session_controller.dart';
import '../core/service_locator.dart';
import '../models/relay_session.dart';
import '../services/relay_client.dart';
import '../utils/async_value.dart';
import '../utils/toast_service.dart';

/// Supported agent kinds from `herdr agent start --kind` (docs/10-herdr-api.md).
const List<String> agentKinds = [
  'pi', 'claude', 'codex', 'gemini', 'cursor', 'devin', 'agy', 'cline',
  'omp', 'mastracode', 'opencode', 'copilot', 'kimi', 'kiro', 'droid', 'amp',
  'grok', 'hermes', 'kilo', 'qodercli', 'maki',
];

/// Run tab: launch an agent from the phone into a free pane of a workspace
/// (`agent.start`). The first plain (agent-less) pane of the chosen workspace
/// is used; creating panes/workspaces from the phone is a later step
/// (docs/11-spaces.md).
///
/// Workspace/pane data comes from the shared [SessionController]; this page
/// keeps only UI state (kind/workspace selection, name field, start in-flight).
class RunPage extends StatefulWidget {
  const RunPage({super.key});

  @override
  State<RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<RunPage> {
  final TextEditingController _nameController = TextEditingController();
  String _kind = 'codex';
  String? _workspaceId;
  bool _starting = false;
  late final SessionController _controller;

  @override
  void initState() {
    super.initState();
    _controller = getIt<SessionController>();
    _controller.ensureLoaded();
    // Default the workspace selection once data arrives; keep it on refresh.
    _controller.addListener(_ensureDefaultWorkspace);
    // The controller may already be loaded (e.g. the Spaces tab fetched it) —
    // pick the default now (no setState needed before the first build).
    _workspaceId ??=
        _controller.state.dataOrNull?.workspaces.firstOrNull?.id;
  }

  @override
  void dispose() {
    _controller.removeListener(_ensureDefaultWorkspace);
    _nameController.dispose();
    super.dispose();
  }

  void _ensureDefaultWorkspace() {
    final session = _controller.state.dataOrNull;
    if (session != null && session.workspaces.isNotEmpty && _workspaceId == null) {
      setState(() => _workspaceId = session.workspaces.first.id);
    }
  }

  /// First free (agent-less) pane of the selected workspace, if any.
  RelayPane? get _freePane => _controller.freePaneFor(_workspaceId);

  Future<void> _start() async {
    final pane = _freePane;
    final name = _nameController.text.trim();
    if (pane == null) {
      ToastService.showError(context,
          'No free pane in this workspace — run an agent there first on the computer.');
      return;
    }
    if (name.isEmpty) {
      ToastService.showError(context, 'Enter an agent name');
      return;
    }
    setState(() => _starting = true);
    try {
      await getIt<RelayClient>().startAgent(name, _kind, pane.id);
      if (mounted) {
        ToastService.showSuccess(
            context, 'Started $name ($_kind) in ${pane.id}');
        _nameController.clear();
        // The pane now has an agent — refresh the session so free-pane info
        // and workspace statuses stay current.
        _controller.refresh();
      }
    } catch (e) {
      if (mounted) ToastService.showError(context, e);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        switch (_controller.state) {
          case AsyncIdle() || AsyncLoading():
            return const Center(child: CircularProgressIndicator());
          case AsyncError(:final error):
            return Center(
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
            );
          case AsyncData(:final data) when data.workspaces.isEmpty:
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No workspaces — create one on the computer first'),
              ),
            );
          case AsyncData(:final data):
            final workspaces = data.workspaces;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Run an agent', style: theme.textTheme.titleMedium),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: _kind,
                  decoration: const InputDecoration(
                    labelText: 'Agent kind',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final k in agentKinds)
                      DropdownMenuItem(value: k, child: Text(k)),
                  ],
                  onChanged: (v) => setState(() => _kind = v ?? _kind),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _workspaceId,
                  decoration: const InputDecoration(
                    labelText: 'Workspace',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final ws in workspaces)
                      DropdownMenuItem(
                        value: ws.id,
                        child: Text(ws.label.isEmpty ? ws.id : ws.label),
                      ),
                  ],
                  onChanged: (v) => setState(() => _workspaceId = v),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Agent name',
                    hintText: 'codex-1',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _freePane == null
                      ? 'No free pane in this workspace — all panes have agents.'
                      : 'Will start in free pane ${_freePane!.id}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: (_starting || _freePane == null) ? null : _start,
                  icon: _starting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow),
                  label: const Text('Start agent'),
                ),
              ],
            );
        }
      },
    );
  }
}
