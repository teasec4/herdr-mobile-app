/// An agent from the relay snapshot (`agents.snapshot`).
///
/// The record shape matches what the relay receives from herdr
/// (`HERDR_PLUGIN_EVENT_JSON`): pane_id, tab_id, workspace_id, agent,
/// agent_status, cwd, focused, terminal_id. The target identifier for
/// `agent.output` / `agent.keys` / `agent.prompt` is `pane_id`
/// (verified against a live relay: herdr rejects terminal_id and tab_id).
class RelayAgent {
  const RelayAgent({
    required this.id,
    required this.agent,
    required this.status,
    this.cwd,
    this.focused = false,
    this.workspaceId = '',
    this.isPlainTerminal = false,
  });

  /// pane_id is the only valid target for agent operations.
  final String id;

  /// Agent name (codex, kimi, ...). May be empty.
  final String agent;

  /// Status from herdr: idle, working, blocked, done, unknown
  /// (docs/10-herdr-api.md §6.2).
  final String status;

  final String? cwd;

  final bool focused;

  /// Workspace (space) this agent's pane belongs to ('' when unknown).
  final String workspaceId;

  /// True when this is a plain terminal pane (no agent): input is sent as
  /// literal text (`pane.send_text`), not as an agent prompt.
  final bool isPlainTerminal;

  /// Blocked — waiting for the user's response ("needs my reply").
  bool get isBlocked => status.toLowerCase() == 'blocked';

  /// Copy with selected fields replaced. Used to apply event deltas (e.g. a
  /// status change) without losing fields the event does not carry.
  RelayAgent copyWith({
    String? id,
    String? agent,
    String? status,
    String? cwd,
    bool? focused,
    String? workspaceId,
    bool? isPlainTerminal,
  }) {
    return RelayAgent(
      id: id ?? this.id,
      agent: agent ?? this.agent,
      status: status ?? this.status,
      cwd: cwd ?? this.cwd,
      focused: focused ?? this.focused,
      workspaceId: workspaceId ?? this.workspaceId,
      isPlainTerminal: isPlainTerminal ?? this.isPlainTerminal,
    );
  }

  /// Human-readable name for the list: agent, otherwise pane_id.
  String get displayAgent => agent.isEmpty ? id : agent;

  /// Sorts the list for the screen: blocked agents (awaiting a reply) on top,
  /// the rest by name. Keeps stability within groups.
  static List<RelayAgent> sorted(List<RelayAgent> agents) {
    final list = [...agents];
    list.sort((a, b) {
      if (a.isBlocked != b.isBlocked) return a.isBlocked ? -1 : 1;
      return a.displayAgent.toLowerCase().compareTo(b.displayAgent.toLowerCase());
    });
    return list;
  }

  factory RelayAgent.fromJson(Map<String, dynamic> json) {
    final id = json['pane_id'] ?? json['id'] ?? json['target'] ?? '';
    return RelayAgent(
      id: id is String ? id : '$id',
      agent: (json['display_agent'] ?? json['agent'] ?? json['tab_label'] ?? '')
          .toString(),
      status: (json['agent_status'] ?? json['status'] ?? 'unknown').toString(),
      cwd: json['cwd'] as String?,
      focused: json['focused'] == true,
      workspaceId: (json['workspace_id'] ?? '').toString(),
    );
  }

  /// Serializes back to the snapshot shape (round-trips with [fromJson]) so a
  /// successful snapshot can be cached for offline use.
  Map<String, dynamic> toJson() => {
        'pane_id': id,
        'agent': agent,
        'agent_status': status,
        if (cwd != null) 'cwd': cwd,
        'focused': focused,
      };
}