/// Relay events sent from the server via WebSocket
sealed class RelayEvent {
  const RelayEvent();

  /// Parse raw event from server
  factory RelayEvent.fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String?;
    final data = json['data'] as Map<String, dynamic>?;

    return switch (name) {
      'pane.agent_status_changed' => AgentStatusChanged(
          paneId: data?['pane_id'] as String? ?? '',
          status: data?['status'] as String? ?? 'unknown',
        ),
      'pane.updated' => PaneUpdated(
          paneId: data?['pane_id'] as String? ?? '',
        ),
      'pane.output_changed' => OutputChanged(
          paneId: data?['pane_id'] as String? ?? '',
          revision: data?['revision'] as int? ?? 0,
        ),
      _ => UnknownEvent(name: name ?? 'unknown', data: data),
    };
  }
}

/// Agent status changed (working, blocked, idle, done)
class AgentStatusChanged extends RelayEvent {
  final String paneId;
  final String status;

  const AgentStatusChanged({required this.paneId, required this.status});

  @override
  String toString() => 'AgentStatusChanged(paneId: $paneId, status: $status)';
}

/// Pane updated (generic update event)
class PaneUpdated extends RelayEvent {
  final String paneId;

  const PaneUpdated({required this.paneId});

  @override
  String toString() => 'PaneUpdated(paneId: $paneId)';
}

/// Output changed with revision number
class OutputChanged extends RelayEvent {
  final String paneId;
  final int revision;

  const OutputChanged({required this.paneId, required this.revision});

  @override
  String toString() => 'OutputChanged(paneId: $paneId, revision: $revision)';
}

/// Unknown event type (fallback)
class UnknownEvent extends RelayEvent {
  final String name;
  final Map<String, dynamic>? data;

  const UnknownEvent({required this.name, this.data});

  @override
  String toString() => 'UnknownEvent(name: $name, data: $data)';
}
