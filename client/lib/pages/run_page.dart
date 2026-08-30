import 'dart:async';

import 'package:flutter/material.dart';

import '../core/service_locator.dart';
import '../models/relay_session.dart';
import '../services/relay_client.dart';
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
class RunPage extends StatefulWidget {
  const RunPage({super.key});

  @override
  State<RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<RunPage> {
  final TextEditingController _nameController = TextEditingController();
  String _kind = 'codex';
  List<RelayWorkspace> _workspaces = const [];
  List<RelayPane> _panes = const [];
  String? _workspaceId;
  bool _loading = true;
  Object? _error;
  bool _starting = false;
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
    _nameController.dispose();
    super.dispose();
  }

  /// Reloads workspaces/panes after a reconnect (events during the gap lost).
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
        _workspaces = session.workspaces;
        _panes = session.panes;
        _workspaceId ??=
            session.workspaces.isEmpty ? null : session.workspaces.first.id;
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

  /// First free (agent-less) pane of the selected workspace, if any.
  RelayPane? get _freePane {
    final wsId = _workspaceId;
    if (wsId == null) return null;
    for (final p in _panes) {
      if (p.workspaceId == wsId && !p.isAgentPane) return p;
    }
    return null;
  }

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
    if (_workspaces.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No workspaces — create one on the computer first'),
        ),
      );
    }
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
            for (final ws in _workspaces)
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
}
