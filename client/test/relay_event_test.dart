import 'package:client/models/relay_event.dart';
import 'package:flutter_test/flutter_test.dart';

/// AgentStatusChanged parsing: workspace_id must distinguish "absent" (null)
/// from an explicit empty string (a pane moved to the root) — audit P2.3.
void main() {
  test('workspaceId is null when the payload omits it', () {
    final e = RelayEvent.fromJson({
      'name': 'pane.agent_status_changed',
      'data': {'pane_id': 'p1', 'agent_status': 'working'},
    }) as AgentStatusChanged;
    expect(e.workspaceId, isNull);
  });

  test('workspaceId is an empty string when explicitly empty', () {
    final e = RelayEvent.fromJson({
      'name': 'pane.agent_status_changed',
      'data': {
        'pane_id': 'p1',
        'agent_status': 'working',
        'workspace_id': '',
      },
    }) as AgentStatusChanged;
    expect(e.workspaceId, '');
  });

  test('workspaceId is parsed when present', () {
    final e = RelayEvent.fromJson({
      'name': 'pane.agent_status_changed',
      'data': {'pane_id': 'p1', 'agent_status': 'idle', 'workspace_id': 'wH'},
    }) as AgentStatusChanged;
    expect(e.workspaceId, 'wH');
  });
}
