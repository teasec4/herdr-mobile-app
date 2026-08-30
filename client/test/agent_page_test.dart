import 'package:client/models/pair_config.dart';
import 'package:client/models/relay_agent.dart';
import 'package:client/models/relay_event.dart';
import 'package:client/pages/agent_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_relay_client.dart';
import 'test_helper.dart';

void main() {
  late FakeRelayClient client;
  late RelayAgent agent;

  final config = PairConfig.fromLink(
    'herdrelay://pair?host=localhost&port=8375&mode=lan&token=abcdef0123456789',
  );

  setUp(() async {
    client = FakeRelayClient();
    await setupTestDependencies(client, config);
    agent = RelayAgent.fromJson({
      'pane_id': 'wG:p1',
      'agent': 'codex',
      'agent_status': 'blocked',
      'cwd': '/Users/me/proj',
    });
  });

  tearDown(() async {
    await teardownTestDependencies();
  });

  Future<void> pumpAgent(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: AgentPage(agent: agent)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('показывает имя агента, статус и вывод терминала', (tester) async {
    client.outputText = 'hello world\n';
    await pumpAgent(tester);

    expect(find.text('codex'), findsOneWidget);
    expect(find.text('blocked'), findsOneWidget);
    expect(find.text('hello world\n'), findsOneWidget);
  });

  testWidgets('пустой терминал: ввод идёт sendText, а не prompt', (tester) async {
    client.outputText = 'shell\n';
    await tester.pumpWidget(
      MaterialApp(
        home: AgentPage(
          agent: RelayAgent(
            id: 'w7:p1',
            agent: 'w7:p1',
            status: 'unknown',
            isPlainTerminal: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'ls -la');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(client.sendTextCalls, [('w7:p1', 'ls -la')]);
    expect(client.prompts, isEmpty);
  });

  testWidgets('отправка промпта: prompt(target, text), поле очищается, вывод перечитан',
      (tester) async {
    client.outputText = 'первый\n';
    await pumpAgent(tester);

    await tester.enterText(find.byType(TextField), 'привет');
    client.outputText = 'второй\n';
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();

    expect(client.prompts, [(agent.id, 'привет')]);
    expect(find.text('второй\n'), findsOneWidget);
    expect(find.text('первый\n'), findsNothing);
  });

  testWidgets('кнопка Ctrl-C шлёт agent.keys', (tester) async {
    await pumpAgent(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Ctrl-C'));
    await tester.pump();

    expect(client.keysCalls.length, 1);
    expect(client.keysCalls[0].$1, agent.id);
    expect(client.keysCalls[0].$2, ['C-c']);
  });

  testWidgets('предложенные действия появляются когда агент blocked с yes/no', (tester) async {
    client.outputText = 'Do you want to approve this? (y/n)\n';
    agent = RelayAgent.fromJson({
      'pane_id': 'wG:p1',
      'agent': 'codex',
      'agent_status': 'blocked',
      'cwd': '/Users/me/proj',
    });
    await pumpAgent(tester);

    // Should show y and n buttons (parsed from (y/n))
    expect(find.text('y'), findsOneWidget);
    expect(find.text('n'), findsOneWidget);

    // Tap y should send 'y'
    await tester.tap(find.text('y'));
    await tester.pumpAndSettle();

    expect(client.prompts, [(agent.id, 'y')]);
  });

  testWidgets('предложенные действия парсят нумерованные варианты', (tester) async {
    client.outputText = '''
Please choose an option:
1. Create new file
2. Update existing
3. Skip this step
''';
    agent = RelayAgent.fromJson({
      'pane_id': 'wG:p1',
      'agent': 'codex',
      'agent_status': 'blocked',
      'cwd': '/Users/me/proj',
    });
    await pumpAgent(tester);

    // Should show numbered options with truncated labels
    expect(find.textContaining('1:'), findsOneWidget);
    expect(find.textContaining('2:'), findsOneWidget);
    expect(find.textContaining('3:'), findsOneWidget);

    // Tap should send the number
    await tester.tap(find.textContaining('2:'));
    await tester.pumpAndSettle();

    expect(client.prompts, [(agent.id, '2')]);
  });

  testWidgets('событие pane.agent_status_changed обновляет статус агента', (tester) async {
    await pumpAgent(tester);
    expect(find.text('blocked'), findsOneWidget);

    client.emit(AgentStatusChanged(paneId: agent.id, status: 'done'));
    await tester.pumpAndSettle();

    expect(find.text('done'), findsOneWidget);
  });

  testWidgets('событие чужого агента не трогает экран', (tester) async {
    await pumpAgent(tester);

    client.emit(AgentStatusChanged(paneId: 'wG:other', status: 'done'));
    await tester.pumpAndSettle();

    expect(find.text('blocked'), findsOneWidget);
  });

  testWidgets('событие pane.output_changed перечитывает вывод (дебаунс)', (tester) async {
    client.outputText = 'первый\n';
    await pumpAgent(tester);

    client.outputText = 'второй\n';
    client.emit(OutputChanged(paneId: agent.id, revision: 2));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(find.text('второй\n'), findsOneWidget);
    expect(find.text('первый\n'), findsNothing);
  });

  testWidgets('pane.output_changed с уже виденной ревизией не перечитывает вывод', (tester) async {
    client.outputText = 'первый\n';
    await pumpAgent(tester);

    client.emit(OutputChanged(paneId: agent.id, revision: 1));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    client.outputText = 'второй\n';
    client.emit(OutputChanged(paneId: agent.id, revision: 1));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(find.text('второй\n'), findsNothing);
    expect(find.text('первый\n'), findsOneWidget);
  });

  testWidgets('pane.output_changed чужого агента не перечитывает вывод', (tester) async {
    client.outputText = 'первый\n';
    await pumpAgent(tester);

    client.outputText = 'второй\n';
    client.emit(OutputChanged(paneId: 'wG:other', revision: 2));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(find.text('второй\n'), findsNothing);
    expect(find.text('первый\n'), findsOneWidget);
  });
}
