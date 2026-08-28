/// Агент из снапшота релея (`agents.snapshot`).
///
/// Форма записи совпадает с тем, что релей получает от herdr
/// (`HERDR_PLUGIN_EVENT_JSON`): pane_id, tab_id, workspace_id, agent,
/// agent_status, cwd, focused, terminal_id. Целевым идентификатором для
/// `agent.output` / `agent.keys` / `agent.prompt` является `pane_id`
/// (проверено на живом релее: terminal_id и tab_id herdr не принимает).
class RelayAgent {
  const RelayAgent({
    required this.id,
    required this.agent,
    required this.status,
    this.cwd,
    this.focused = false,
  });

  /// pane_id — единственный валидный target для операций с агентом.
  final String id;

  /// Имя агента (codex, kimi, ...). Может быть пустым.
  final String agent;

  /// Статус из herdr: done, running, waiting, error, ...
  final String status;

  final String? cwd;

  final bool focused;

  /// Заблокирован — ждёт ответа пользователя («нужен мой ответ»).
  bool get isBlocked => status.toLowerCase() == 'blocked';

  /// Человекочитаемое имя для списка: agent, иначе pane_id.
  String get displayAgent => agent.isEmpty ? id : agent;

  /// Сортировка списка для экрана: заблокированные (ждут ответа) сверху,
  /// остальные — по имени. Сохраняет стабильность в рамках групп.
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
    );
  }
}