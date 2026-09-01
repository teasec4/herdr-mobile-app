import 'package:client/controllers/modes_controller.dart';
import 'package:client/core/connection/mode_service.dart';
import 'package:client/models/pair_config.dart';
import 'package:client/models/relay_agent.dart';
import 'package:client/models/relay_event.dart';
import 'package:client/pages/agent_page.dart';
import 'package:client/pages/help_page.dart';
import 'package:client/pages/home_page.dart';
import 'package:client/services/relay_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_relay_client.dart';
import 'test_helper.dart';

void main() {
  late FakeRelayClient client;

  final config = PairConfig.fromLink(
    'herdrelay://pair?host=192.168.1.5&port=8375&mode=lan'
    '&token=abcdef0123456789',
  );

  /// Default stub modes for badge tests.
  const stubModes = [
    RelayModeInfo(
      mode: 'lan',
      url: 'ws://192.168.1.5:8375',
      link: 'herdrelay://pair?host=192.168.1.5&port=8375&mode=lan'
          '&token=abcdef0123456789',
      description: 'Local network',
    ),
    RelayModeInfo(
      mode: 'tailscale',
      url: 'ws://mac.tailnet.ts.net:8375',
      link: 'herdrelay://pair?host=mac.tailnet.ts.net&port=8375'
          '&mode=tailscale&token=abcdef0123456789',
      description: 'Tailscale VPN',
    ),
  ];

  setUp(() async {
    client = FakeRelayClient();
    await setupTestDependencies(client, config);
  });

  tearDown(() async {
    await teardownTestDependencies();
  });

  Future<void> pumpHome(
    WidgetTester tester, {
    Future<void> Function()? onSwitch,
    Future<void> Function(PairConfig)? onModeSelected,
    ModesController? modesController,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          config: config,
          onRequestSwitch: onSwitch ?? () async {},
          onAddDevice: () async {},
          onForgetDevice: () async {},
          onModeSelected: onModeSelected ?? (_) async {},
          modesController:
              modesController ?? ModesController((_) async => stubModes),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Switches the bottom navigation to the Agents tab (the default tab is
  /// Spaces).
  Future<void> goToAgents(WidgetTester tester) async {
    await tester.tap(find.text('Agents'));
    await tester.pumpAndSettle();
  }

  RelayAgent agent(String id, String name, String status) => RelayAgent.fromJson({
        'pane_id': id,
        'agent': name,
        'agent_status': status,
      });

  testWidgets('пустой список — заглушка «Агенты не найдены»', (tester) async {
    await pumpHome(tester);
    await goToAgents(tester);
    expect(find.text('No agents found'), findsOneWidget);
  });

  testWidgets('blocked-агент отображается первым', (tester) async {
    client.agents = [
      agent('p:bob', 'bob', 'done'),
      agent('p:alice', 'alice', 'blocked'),
    ];
    await pumpHome(tester);
    await goToAgents(tester);

    final aliceY = tester.getTopLeft(find.text('alice')).dy;
    final bobY = tester.getTopLeft(find.text('bob')).dy;
    expect(aliceY, lessThan(bobY));
    expect(find.text('blocked'), findsOneWidget);
  });

  testWidgets('тап по агенту открывает AgentPage с тем же клиентом', (tester) async {
    client.agents = [agent('p:alice', 'alice', 'done')];
    client.outputText = 'вывод агента\n';
    await pumpHome(tester);
    await goToAgents(tester);

    await tester.tap(find.text('alice'));
    await tester.pumpAndSettle();

    expect(find.byType(AgentPage), findsOneWidget);
    expect(find.text('вывод агента\n'), findsOneWidget);
  });

  testWidgets('ошибка снимка показывает «Повторить», повторный тап чинит', (tester) async {
    client.snapshotError = true;
    await pumpHome(tester);
    await goToAgents(tester);
    expect(find.text('Retry'), findsOneWidget);

    client.snapshotError = false;
    client.agents = [agent('p:alice', 'alice', 'done')];
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('alice'), findsOneWidget);
  });

  testWidgets('статус-событие обновляет тайл локально, без snapshot', (tester) async {
    client.agents = [agent('p:alice', 'alice', 'done')];
    await pumpHome(tester);
    await goToAgents(tester);

    final snapshots = client.snapshotCalls;
    client.emit(AgentStatusChanged(paneId: 'p:alice', status: 'blocked'));
    await tester.pumpAndSettle();

    // Tile updated in place from the event — no snapshot round-trip.
    expect(find.text('blocked'), findsOneWidget);
    expect(client.snapshotCalls, snapshots);
  });

  testWidgets('статус-событие с именем агента обновляет тайл', (tester) async {
    client.agents = [agent('p:alice', 'alice', 'done')];
    await pumpHome(tester);
    await goToAgents(tester);

    client.emit(AgentStatusChanged(
      paneId: 'p:alice',
      status: 'working',
      agent: 'kimi',
    ));
    await tester.pumpAndSettle();

    expect(find.text('kimi'), findsOneWidget);
  });

  testWidgets('статус-событие неизвестного pane делает отложенный snapshot', (tester) async {
    client.agents = [agent('p:alice', 'alice', 'done')];
    await pumpHome(tester);
    await goToAgents(tester);

    final snapshots = client.snapshotCalls;
    client.emit(AgentStatusChanged(paneId: 'p:unknown', status: 'working'));
    // AgentsStore is registered in setUp (outside the fake-async test zone),
    // so its debounce timer is real — advance real time, then settle frames.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 350)),
    );
    await tester.pumpAndSettle();

    expect(client.snapshotCalls, greaterThan(snapshots));
  });

  testWidgets('агенты грузятся один раз при старте (общий store для всех табов)', (tester) async {
    client.agents = [agent('p:alice', 'alice', 'done')];
    await pumpHome(tester); // Spaces tab (default) triggers the shared store

    expect(client.snapshotCalls, 1,
        reason: 'one agents fetch serves the Spaces/Agents/Run tabs');

    await goToAgents(tester);
    expect(client.snapshotCalls, 1,
        reason: 'visiting Agents must not re-fetch (store is shared)');
    expect(find.text('alice'), findsOneWidget);
  });

  testWidgets('восстанавливает выбранный таб из настроек', (tester) async {
    client.agents = [agent('p:alice', 'alice', 'done')];
    await setupTestDependencies(client, config,
        prefsSeed: {'settings_home_tab_index': 1});
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          config: config,
          onRequestSwitch: () async {},
          onAddDevice: () async {},
          onForgetDevice: () async {},
          onModeSelected: (_) async {},
          modesController: ModesController((_) async => stubModes),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The Agents tab is active and built immediately (restored tab is
    // "visited"), so the list is fetched on startup.
    expect(client.snapshotCalls, greaterThan(0));
    expect(find.text('alice'), findsOneWidget);
  });

  testWidgets('переключение таба сохраняется в настройках', (tester) async {
    client.agents = [agent('p:alice', 'alice', 'done')];
    await pumpHome(tester);
    await goToAgents(tester);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('settings_home_tab_index'), 1);
  });

  testWidgets('шапка не переполняется на узком экране с длинным режимом', (tester) async {
    // Narrow phone (320 logical px @2x) + the longest mode label (TAILSCALE).
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(320 * 2, 640 * 2);
    addTearDown(tester.view.reset);

    final tailscaleConfig = PairConfig.fromLink(
      'herdrelay://pair?host=mac.tailnet.ts.net&port=8375&mode=tailscale'
      '&token=abcdef0123456789',
    );
    client = FakeRelayClient();
    await setupTestDependencies(client, tailscaleConfig);

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          config: tailscaleConfig,
          onRequestSwitch: () async {},
          onAddDevice: () async {},
          onForgetDevice: () async {},
          onModeSelected: (_) async {},
          modesController: ModesController((_) async => stubModes),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'the mode badge must truncate instead of overflowing');
  });

  group('меню устройств', () {
    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
    }

    testWidgets('показывает четыре пункта: Connection, Add, Forget, Help',
        (tester) async {
      await pumpHome(tester);
      await openMenu(tester);
      expect(find.text('Connection…'), findsOneWidget);
      expect(find.text('Add device…'), findsOneWidget);
      expect(find.text('Forget device'), findsOneWidget);
      expect(find.text('Help'), findsOneWidget);
    });

    testWidgets('«Help» открывает HelpPage', (tester) async {
      await pumpHome(tester);
      await openMenu(tester);

      await tester.tap(find.text('Help'));
      await tester.pumpAndSettle();

      expect(find.byType(HelpPage), findsOneWidget);
      expect(find.text('Connection issues'), findsOneWidget);
    });

    testWidgets('«Connection…» вызывает onRequestSwitch', (tester) async {
      var switched = false;
      await pumpHome(tester, onSwitch: () async => switched = true);
      await openMenu(tester);

      await tester.tap(find.text('Connection…'));
      await tester.pumpAndSettle();
      expect(switched, isTrue);
    });

    testWidgets('«Forget device» спрашивает подтверждение и забывает', (tester) async {
      var forgot = false;
      await pumpHome(tester);
      // Re-pump with a recording callback to verify the flow.
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(
            config: config,
            onRequestSwitch: () async {},
            onAddDevice: () async {},
            onForgetDevice: () async => forgot = true,
            onModeSelected: (_) async {},
            modesController: ModesController((_) async => stubModes),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openMenu(tester);

      await tester.tap(find.text('Forget device'));
      await tester.pumpAndSettle();
      expect(find.text('Forget this device?'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Forget'));
      await tester.pumpAndSettle();
      expect(forgot, isTrue);
    });
  });

  group('бейдж режима', () {
    testWidgets('показывает текущий режим и открывает выбор по клику',
        (tester) async {
      await pumpHome(tester);
      expect(find.text('LAN'), findsOneWidget); // badge

      await tester.tap(find.text('LAN'));
      await tester.pumpAndSettle();

      expect(find.text('Connection mode'), findsOneWidget);
      expect(find.text('tailscale'), findsOneWidget); // mode from stub
    });

    testWidgets('выбор режима вызывает onModeSelected с конфигом из link',
        (tester) async {
      PairConfig? selected;
      await pumpHome(tester, onModeSelected: (c) async => selected = c);

      await tester.tap(find.text('LAN'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('tailscale'));
      await tester.pumpAndSettle();

      expect(selected, isNotNull);
      expect(selected!.mode, 'tailscale');
      expect(selected!.host, 'mac.tailnet.ts.net');
    });

    testWidgets('ошибка загрузки режимов показывает Retry', (tester) async {
      var calls = 0;
      await pumpHome(
        tester,
        modesController: ModesController((_) async {
          calls++;
          throw const ModeFetchException(
              'Cannot reach relay — check your network or that the relay is running.');
        }),
      );

      await tester.tap(find.text('LAN'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Cannot reach relay'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(calls, 1);
    });
  });

  testWidgets('после реконнекта список перечитывается (catch-up)', (tester) async {
    client.agents = [agent('p:alice', 'alice', 'done')];
    await pumpHome(tester);
    await goToAgents(tester);
    final before = client.snapshotCalls;
    expect(before, greaterThanOrEqualTo(1));

    // Drop the connection: no refresh while offline.
    client.status.value = RelayStatus.disconnected;
    await tester.pumpAndSettle();
    expect(client.snapshotCalls, before);

    // Reconnect: the list is re-read to catch events lost during the gap.
    client.status.value = RelayStatus.connected;
    await tester.pumpAndSettle();
    expect(client.snapshotCalls, before + 1);
  });

  testWidgets('события при offline не ставят debounce-снапшот', (tester) async {
    client.agents = [agent('p:alice', 'alice', 'done')];
    await pumpHome(tester);
    await goToAgents(tester);
    final before = client.snapshotCalls;

    client.status.value = RelayStatus.disconnected;
    await tester.pumpAndSettle();
    client.emit(AgentStatusChanged(
      paneId: 'p:alice',
      status: 'blocked',
      workspaceId: 'wH',
    ));
    await tester.pump(const Duration(milliseconds: 400));

    expect(client.snapshotCalls, before, reason: 'offline events must not refresh');
  });
}
