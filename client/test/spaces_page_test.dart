import 'package:client/models/pair_config.dart';
import 'package:client/models/relay_event.dart';
import 'package:client/models/relay_session.dart';
import 'package:client/pages/agent_page.dart';
import 'package:client/pages/run_page.dart';
import 'package:client/pages/spaces_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_relay_client.dart';
import 'test_helper.dart';

/// Spaces tab (workspace list → panes → terminal) and Run tab (start agent).
void main() {
  final config = PairConfig(
    host: '192.168.1.5',
    port: 8375,
    mode: 'lan',
    token: '0123456789abcdef0123456789abcdef',
  );

  final session = RelaySession(
    workspaces: const [
      RelayWorkspace(id: 'wH', label: 'herdr_relay', status: 'working', paneCount: 2),
      RelayWorkspace(id: 'w7', label: 'awake', status: 'idle', paneCount: 1),
    ],
    panes: const [
      RelayPane(
        id: 'wH:p8',
        workspaceId: 'wH',
        tabId: 'wH:t1',
        agent: 'kimi',
        status: 'working',
      ),
      RelayPane(
        id: 'wH:p9',
        workspaceId: 'wH',
        tabId: 'wH:t1',
        agent: '',
        status: 'unknown',
      ),
      RelayPane(
        id: 'w7:p1',
        workspaceId: 'w7',
        tabId: 'w7:t1',
        agent: '',
        status: 'unknown',
      ),
    ],
    focusedWorkspaceId: 'wH',
  );

  late FakeRelayClient client;

  setUp(() async {
    client = FakeRelayClient();
    client.sessionData = session;
    await setupTestDependencies(client, config);
  });

  tearDown(teardownTestDependencies);

  group('SpacesPage', () {
    testWidgets('показывает workspace из session', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SpacesPage())),
      );
      await tester.pumpAndSettle();

      expect(find.text('herdr_relay'), findsOneWidget);
      expect(find.text('awake'), findsOneWidget);
      expect(find.textContaining('2 pane'), findsOneWidget);
    });

    testWidgets('тап по workspace открывает его panes', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SpacesPage())),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('herdr_relay'));
      await tester.pumpAndSettle();

      // WorkspacePage: agent pane and plain terminal both visible.
      expect(find.text('kimi'), findsOneWidget);
      expect(find.text('wH:p9'), findsOneWidget);
      // The other workspace's pane is not listed.
      expect(find.text('w7:p1'), findsNothing);
    });

    testWidgets('тап по pane открывает терминал AgentPage', (tester) async {
      client.outputText = 'hello\n';
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SpacesPage())),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('herdr_relay'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('kimi'));
      await tester.pumpAndSettle();

      expect(find.byType(AgentPage), findsOneWidget);
    });
  });

  group('RunPage', () {
    testWidgets('запускает агента в свободный pane выбранного workspace',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: RunPage())),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Agent name'), 'my-codex');
      await tester.tap(find.text('Start agent'));
      await tester.pumpAndSettle();

      expect(client.startAgentCalls, [( 'my-codex', 'codex', 'wH:p9')]);
    });

    testWidgets('без свободного pane кнопка недоступна', (tester) async {
      // All panes have agents in this session.
      client.sessionData = const RelaySession(
        workspaces: [
          RelayWorkspace(id: 'wH', label: 'herdr_relay'),
        ],
        panes: [
          RelayPane(id: 'wH:p8', workspaceId: 'wH', tabId: 'wH:t1', agent: 'kimi'),
        ],
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: RunPage())),
      );
      await tester.pumpAndSettle();

      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Start agent'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.onPressed, isNull);
      expect(find.textContaining('No free pane'), findsOneWidget);
    });
  });

  testWidgets('событие статуса перечитывает session (live-статус)', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SpacesPage())),
    );
    await tester.pumpAndSettle();
    final before = client.sessionCalls;

    client.emit(AgentStatusChanged(
      paneId: 'wH:p8',
      status: 'blocked',
      workspaceId: 'wH',
    ));
    // The controller is created in setUp (outside the fake-async test zone),
    // so its debounce timer is real — advance real time, then settle frames.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pumpAndSettle();

    expect(client.sessionCalls, greaterThan(before),
        reason: 'status events must re-read the session');
  });
}
