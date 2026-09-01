import 'package:client/controllers/app_session_controller.dart';
import 'package:client/core/service_locator.dart';
import 'package:client/models/pair_config.dart';
import 'package:client/models/relay_agent.dart';
import 'package:client/models/relay_event.dart';
import 'package:client/pages/agent_page.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/widgets/ansi_terminal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    // Status events flow through AgentsStore, which needs a snapshot to know
    // this agent; otherwise the pane is unknown and events only schedule a
    // re-snapshot instead of applying the delta locally.
    client.agents = [agent];
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

  testWidgets('статус-событие не перечитывает вывод и не делает снапшот', (tester) async {
    client.outputText = 'первый\n';
    await pumpAgent(tester);
    // initState/_refresh do one snapshot (metadata) + one output read.
    final snapshots = client.snapshotCalls;
    final outputs = client.outputCalls;
    expect(outputs, greaterThan(0));

    client.outputText = 'второй\n';
    // 'done' (not 'working'): a working agent now polls the frame every 150ms,
    // which would legitimately re-read the output — that case has its own test.
    client.emit(AgentStatusChanged(paneId: agent.id, status: 'done'));
    await tester.pumpAndSettle();

    // Status is applied locally; no extra snapshot/output traffic.
    expect(find.text('done'), findsOneWidget);
    expect(client.snapshotCalls, snapshots);
    expect(client.outputCalls, outputs);
    expect(find.text('второй\n'), findsNothing); // output not re-read
  });

  testWidgets('агент working: поллинг перечитывает вывод без событий (анимации)', (tester) async {
    client.outputText = 'первый\n';
    await pumpAgent(tester);
    final outputsBefore = client.outputCalls;

    // Working agent: the page polls the current frame every second, so \r-based
    // spinners (which never emit pane.scroll_changed) still repaint.
    client.emit(AgentStatusChanged(paneId: agent.id, status: 'working'));
    await tester.pumpAndSettle();
    expect(find.text('working'), findsOneWidget);

    // No event — only the poll timer advances the output.
    client.outputText = 'второй\n';
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pumpAndSettle();

    expect(find.text('второй\n'), findsOneWidget);
    expect(find.text('первый\n'), findsNothing);
    expect(client.outputCalls, greaterThan(outputsBefore),
        reason: 'live poll must re-read output while the agent is working');
  });

  testWidgets('агент done: поллинг не активен и не перечитывает вывод', (tester) async {
    client.outputText = 'первый\n';
    await pumpAgent(tester);

    client.emit(AgentStatusChanged(paneId: agent.id, status: 'done'));
    await tester.pumpAndSettle();
    expect(find.text('done'), findsOneWidget);

    client.outputText = 'второй\n';
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('второй\n'), findsNothing);
    expect(find.text('первый\n'), findsOneWidget);
  });

  testWidgets('статус-событие с именем агента обновляет заголовок', (tester) async {
    await pumpAgent(tester);

    client.emit(AgentStatusChanged(
      paneId: agent.id,
      status: 'working',
      agent: 'kimi',
      workspaceId: 'wF',
    ));
    await tester.pumpAndSettle();

    expect(find.text('kimi'), findsOneWidget);
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

  testWidgets('pane.output_changed без ревизии (0) всегда перечитывает вывод', (tester) async {
    client.outputText = 'первый\n';
    await pumpAgent(tester);
    final outputsBefore = client.outputCalls;

    client.outputText = 'второй\n';
    client.emit(OutputChanged(paneId: agent.id, revision: 0));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    // Revision 0 = "something changed" with no trackable revision: the page
    // must issue a real RPC, never reuse cached (possibly stale) text.
    expect(find.text('второй\n'), findsOneWidget);
    expect(client.outputCalls, greaterThan(outputsBefore));
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

  testWidgets('пустой терминал читает вывод через pane.output', (tester) async {
    client.outputText = 'shell-out\n';
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

    expect(find.text('shell-out\n'), findsOneWidget);
    expect(client.paneOutputCalls, 1,
        reason: 'plain terminal must read via pane.output, not agent.output');
  });

  testWidgets('A+ увеличивает размер шрифта терминала и сохраняет его', (tester) async {
    client.outputText = 'hello\n';
    await pumpAgent(tester);

    double fontSize() =>
        tester.widget<SelectableText>(find.byType(SelectableText)).style!.fontSize!;

    expect(fontSize(), AppSettings.kDefaultFontSize);
    await tester.tap(find.byIcon(Icons.text_increase));
    await tester.pumpAndSettle();
    expect(fontSize(), AppSettings.kDefaultFontSize + 1);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble(AppSettings.kTerminalFontSize), AppSettings.kDefaultFontSize + 1);
  });

  testWidgets('A− уменьшает размер шрифта', (tester) async {
    client.outputText = 'hello\n';
    await pumpAgent(tester);

    await tester.tap(find.byIcon(Icons.text_decrease));
    await tester.pumpAndSettle();

    final rich = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(rich.style!.fontSize, AppSettings.kDefaultFontSize - 1);
  });

  testWidgets('по умолчанию вывод липнет к низу (follow)', (tester) async {
    client.outputText = List.filled(100, 'line of terminal text').join('\n');
    await pumpAgent(tester);

    // The outer Scrollable (SingleChildScrollView) precedes SelectableText's
    // internal one in depth-first order.
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(AnsiTerminal),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(scrollable.position.pixels, scrollable.position.maxScrollExtent);
  });

  testWidgets('autoScrollFollow=false не липнет к низу при открытии', (tester) async {
    client.outputText = List.filled(100, 'line of terminal text').join('\n');
    await setupTestDependencies(client, config,
        prefsSeed: {AppSettings.kAutoScrollFollow: false});
    await tester.pumpWidget(
      MaterialApp(home: AgentPage(agent: agent)),
    );
    await tester.pumpAndSettle();

    // The outer Scrollable (SingleChildScrollView) precedes SelectableText's
    // internal one in depth-first order.
    final scrollable = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(AnsiTerminal),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(scrollable.position.pixels, lessThan(scrollable.position.maxScrollExtent));
  });

  // --- Phase 3: session version bumps close stale pages --------------------

  testWidgets('смена конфига закрывает открытую страницу агента (pop)',
      (tester) async {
    client.outputText = 'hello\n';
    // Push AgentPage as a nested route so Navigator.pop() works.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => AgentPage(agent: agent)),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(AgentPage), findsOneWidget);

    // Forgetting the config tears the services down (the store the page holds
    // is disposed); the session version bump must pop the page without
    // disposed-object errors.
    final session = getIt<AppSessionController>();
    await session.clear();
    await tester.pumpAndSettle();

    expect(find.byType(AgentPage), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
