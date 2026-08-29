import 'package:client/models/relay_agent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RelayAgent.fromJson', () {
    test('разбирает запись из снапшота релея', () {
      final agent = RelayAgent.fromJson({
        'pane_id': 'wG:p1',
        'agent': 'codex',
        'agent_status': 'blocked',
        'cwd': '/Users/me/proj',
        'focused': true,
      });
      expect(agent.id, 'wG:p1');
      expect(agent.agent, 'codex');
      expect(agent.status, 'blocked');
      expect(agent.cwd, '/Users/me/proj');
      expect(agent.focused, isTrue);
      expect(agent.displayAgent, 'codex');
    });

    test('fallback: pane_id из id/target, имя из display_agent', () {
      final agent = RelayAgent.fromJson({
        'id': 'wG:p2',
        'display_agent': 'kimi',
      });
      expect(agent.id, 'wG:p2');
      expect(agent.displayAgent, 'kimi');
    });

    test('fallback: пустое имя агента → id', () {
      final agent = RelayAgent.fromJson({'pane_id': 'wG:p3'});
      expect(agent.agent, '');
      expect(agent.displayAgent, 'wG:p3');
    });

    test('статус по умолчанию unknown, focused по умолчанию false', () {
      final agent = RelayAgent.fromJson({'pane_id': 'wG:p4'});
      expect(agent.status, 'unknown');
      expect(agent.focused, isFalse);
    });
  });

  group('RelayAgent.isBlocked', () {
    test('blocked в любом регистре — истина', () {
      expect(RelayAgent.fromJson({'pane_id': 'p', 'agent_status': 'blocked'}).isBlocked, isTrue);
      expect(RelayAgent.fromJson({'pane_id': 'p', 'agent_status': 'Blocked'}).isBlocked, isTrue);
    });

    test('прочие статусы — ложь', () {
      for (final s in ['idle', 'working', 'done', 'unknown', '']) {
        expect(RelayAgent.fromJson({'pane_id': 'p', 'agent_status': s}).isBlocked, isFalse, reason: s);
      }
    });
  });

  group('RelayAgent.sorted', () {
    RelayAgent agent(String id, String status) =>
        RelayAgent.fromJson({'pane_id': id, 'agent_status': status});

    test('blocked — сверху, затем по имени', () {
      final sorted = RelayAgent.sorted([
        agent('p:done', 'done'),
        agent('p:blocked-2', 'blocked'),
        agent('p:blocked-1', 'blocked'),
      ]);
      expect(sorted.map((a) => a.status).toList(), ['blocked', 'blocked', 'done']);
      // within a blocked group — by name
      expect(sorted[0].id, 'p:blocked-1');
      expect(sorted[1].id, 'p:blocked-2');
    });

    test('не мутирует исходный список', () {
      final input = [agent('a', 'done'), agent('b', 'blocked')];
      final sorted = RelayAgent.sorted(input);
      expect(input.first.status, 'done');
      expect(sorted.first.status, 'blocked');
    });

    test('пустой список — пустой результат', () {
      expect(RelayAgent.sorted([]), isEmpty);
    });
  });
}
