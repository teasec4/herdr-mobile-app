import 'package:client/models/relay_agent.dart';
import 'package:client/pages/agent_page.dart';
import 'package:client/services/relay_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_relay_client.dart';

void main() {
  late FakeRelayClient client;
  late RelayAgent agent;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    client = FakeRelayClient();
    agent = RelayAgent.fromJson({
      'pane_id': 'wG:p1',
      'agent': 'codex',
      'agent_status': 'blocked',
      'cwd': '/Users/me/proj',
    });
  });

  Future<void> pumpAgent(WidgetTester tester) async {
    await tester.pumpWidget(
      Provider<RelayClient>.value(
        value: client,
        child: MaterialApp(home: AgentPage(agent: agent)),
      ),
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

  testWidgets('кнопки Esc и Ctrl-C шлют agent.keys', (tester) async {
    await pumpAgent(tester);

    // Find ActionChips by their label text
    await tester.tap(find.text('Esc'));
    await tester.pump();
    await tester.tap(find.text('Ctrl-C'));
    await tester.pump();

    expect(client.keysCalls.length, 2);
    expect(client.keysCalls[0].$1, agent.id);
    expect(client.keysCalls[0].$2, ['esc']);
    expect(client.keysCalls[1].$1, agent.id);
    expect(client.keysCalls[1].$2, ['ctrl', 'c']);
  });

  testWidgets('событие pane.agent_status_changed обновляет статус агента', (tester) async {
    await pumpAgent(tester);
    expect(find.text('blocked'), findsOneWidget);

    client.emit(RelayEvent('pane.agent_status_changed', {
      'pane_id': agent.id,
      'agent_status': 'done',
    }));
    await tester.pumpAndSettle();

    expect(find.text('done'), findsOneWidget);
  });

  testWidgets('событие чужого агента не трогает экран', (tester) async {
    await pumpAgent(tester);

    client.emit(RelayEvent('pane.agent_status_changed', {
      'pane_id': 'wG:other',
      'agent_status': 'done',
    }));
    await tester.pumpAndSettle();

    expect(find.text('blocked'), findsOneWidget);
  });

  testWidgets('событие pane.output_changed перечитывает вывод (дебаунс)', (tester) async {
    client.outputText = 'первый\n';
    await pumpAgent(tester);

    client.outputText = 'второй\n';
    client.emit(RelayEvent('pane.output_changed', {
      'pane_id': agent.id,
      'revision': 2,
    }));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(find.text('второй\n'), findsOneWidget);
    expect(find.text('первый\n'), findsNothing);
  });

  testWidgets('pane.output_changed с уже виденной ревизией не перечитывает вывод', (tester) async {
    client.outputText = 'первый\n';
    await pumpAgent(tester);

    client.emit(RelayEvent('pane.output_changed', {
      'pane_id': agent.id,
      'revision': 1,
    }));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    client.outputText = 'второй\n';
    client.emit(RelayEvent('pane.output_changed', {
      'pane_id': agent.id,
      'revision': 1,
    }));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(find.text('второй\n'), findsNothing);
    expect(find.text('первый\n'), findsOneWidget);
  });

  testWidgets('pane.output_changed чужого агента не перечитывает вывод', (tester) async {
    client.outputText = 'первый\n';
    await pumpAgent(tester);

    client.outputText = 'второй\n';
    client.emit(RelayEvent('pane.output_changed', {
      'pane_id': 'wG:other',
      'revision': 2,
    }));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(find.text('второй\n'), findsNothing);
    expect(find.text('первый\n'), findsOneWidget);
  });
}
