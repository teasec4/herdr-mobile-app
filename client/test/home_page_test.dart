import 'package:client/models/pair_config.dart';
import 'package:client/models/relay_agent.dart';
import 'package:client/pages/agent_page.dart';
import 'package:client/pages/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_relay_client.dart';
import 'test_helper.dart';

void main() {
  late FakeRelayClient client;

  final config = PairConfig.fromLink(
    'herdrelay://pair?host=192.168.1.5&port=8375&mode=lan'
    '&token=abcdef0123456789',
  );

  setUp(() async {
    client = FakeRelayClient();
    await setupTestDependencies(client, config);
  });

  tearDown(() async {
    await teardownTestDependencies();
  });

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          config: config,
          onDisconnect: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  RelayAgent agent(String id, String name, String status) => RelayAgent.fromJson({
        'pane_id': id,
        'agent': name,
        'agent_status': status,
      });

  testWidgets('пустой список — заглушка «Агенты не найдены»', (tester) async {
    await pumpHome(tester);
    expect(find.text('No agents found'), findsOneWidget);
  });

  testWidgets('blocked-агент отображается первым', (tester) async {
    client.agents = [
      agent('p:bob', 'bob', 'done'),
      agent('p:alice', 'alice', 'blocked'),
    ];
    await pumpHome(tester);

    final aliceY = tester.getTopLeft(find.text('alice')).dy;
    final bobY = tester.getTopLeft(find.text('bob')).dy;
    expect(aliceY, lessThan(bobY));
    expect(find.text('blocked'), findsOneWidget);
  });

  testWidgets('тап по агенту открывает AgentPage с тем же клиентом', (tester) async {
    client.agents = [agent('p:alice', 'alice', 'done')];
    client.outputText = 'вывод агента\n';
    await pumpHome(tester);

    await tester.tap(find.text('alice'));
    await tester.pumpAndSettle();

    expect(find.byType(AgentPage), findsOneWidget);
    expect(find.text('вывод агента\n'), findsOneWidget);
  });

  testWidgets('ошибка снимка показывает «Повторить», повторный тап чинит', (tester) async {
    client.snapshotError = true;
    await pumpHome(tester);
    expect(find.text('Retry'), findsOneWidget);

    client.snapshotError = false;
    client.agents = [agent('p:alice', 'alice', 'done')];
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('alice'), findsOneWidget);
  });
}
