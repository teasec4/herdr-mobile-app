import 'package:client/core/connection/mode_service.dart';
import 'package:client/core/service_locator.dart';
import 'package:client/models/pair_config.dart';
import 'package:client/models/relay_agent.dart';
import 'package:client/pages/connection_page.dart';
import 'package:client/services/config_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_relay_client.dart';
import 'test_helper.dart';

/// Connection screen: device card, live status, connection test, modes,
/// saved devices, pair entry — with a FakeRelayClient and a stubbed
/// modes fetcher (no network).
void main() {
  final config = PairConfig(
    host: 'macbook-pro.tail85247a.ts.net',
    port: 8375,
    mode: 'tailscale',
    token: '0123456789abcdef0123456789abcdef',
    relayId: 'r1',
    name: 'MacBook Pro',
  );

  /// Pushes ConnectionPage onto a navigator (so its internal `pop` calls
  /// work) and returns the fake client.
  Future<FakeRelayClient> pumpConnection(
    WidgetTester tester, {
    List<RelayModeInfo> modes = const [
      RelayModeInfo(
          mode: 'lan',
          url: 'ws://192.168.1.5:8375',
          link: '',
          description: 'Local network'),
      RelayModeInfo(
          mode: 'tailscale',
          url: 'ws://macbook-pro.tail85247a.ts.net:8375',
          link: '',
          description: 'Tailscale VPN'),
    ],
    void Function(PairConfig)? onSwitch,
    void Function()? onForgetActive,
    void Function(String)? onLink,
  }) async {
    final fake = FakeRelayClient();
    await setupTestDependencies(fake, config);
    await getIt<ConfigStore>().saveProfile(config);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ConnectionPage(
                      config: config,
                      onSwitch: (c) async => onSwitch?.call(c),
                      onForgetActive: () async => onForgetActive?.call(),
                      onLink: (l) async => onLink?.call(l),
                      modesFetcher: (_) async => modes,
                    ),
                  ),
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
    return fake;
  }

  /// Scrolls the ConnectionPage list until [finder] is visible. The first
  /// Scrollable in pre-order is the page's ListView (nested Scrollables come
  /// from SelectableText/TextField and must not be used for scrolling).
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  tearDown(teardownTestDependencies);

  testWidgets('показывает устройство, статус и ws-адрес', (tester) async {
    await pumpConnection(tester);

    expect(find.text('MacBook Pro'), findsOneWidget);
    expect(find.text('tailscale'), findsWidgets); // chip + mode list
    expect(find.text('macbook-pro.tail85247a.ts.net:8375'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget); // live status
    expect(
      find.textContaining('ws://macbook-pro.tail85247a.ts.net:8375/ws'),
      findsOneWidget,
    );
  });

  testWidgets('«Test» проверяет healthz + snapshot и показывает результат',
      (tester) async {
    final fake = await pumpConnection(tester);
    fake.agents = [
      const RelayAgent(id: 'p1', agent: 'kimi', status: 'idle'),
    ];

    await tester.tap(find.text('Test'));
    await tester.pumpAndSettle();

    expect(find.textContaining('OK'), findsOneWidget);
    expect(find.textContaining('1 agent'), findsOneWidget);
  });

  testWidgets('проверка показывает ошибку, когда relay недоступен',
      (tester) async {
    final fake = await pumpConnection(tester);
    fake.healthzResult = false;

    await tester.tap(find.text('Test'));
    await tester.pumpAndSettle();

    expect(find.textContaining('not reachable'), findsOneWidget);
  });

  testWidgets('выбор режима вызывает onSwitch с конфигом из link',
      (tester) async {
    PairConfig? switched;
    await pumpConnection(
      tester,
      modes: [
        RelayModeInfo(
          mode: 'lan',
          url: 'ws://192.168.1.5:8375',
          link: 'herdrelay://pair?host=192.168.1.5&port=8375&mode=lan'
              '&token=0123456789abcdef0123456789abcdef',
          description: 'Local network',
        ),
      ],
      onSwitch: (c) => switched = c,
    );

    await tester.tap(find.text('lan'));
    await tester.pumpAndSettle();

    expect(switched, isNotNull);
    expect(switched!.mode, 'lan');
    expect(switched!.host, '192.168.1.5');
  });

  testWidgets('смена режима с невалидным link показывает ошибку',
      (tester) async {
    await pumpConnection(
      tester,
      modes: const [
        RelayModeInfo(
          mode: 'funnel',
          url: 'https://x.ts.net',
          link: 'not-a-link',
          description: 'Public HTTPS',
        ),
      ],
    );

    await tester.tap(find.text('funnel'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('вставка ссылки вызывает onLink', (tester) async {
    String? pasted;
    await pumpConnection(tester, onLink: (l) => pasted = l);

    const link = 'herdrelay://pair?host=h&port=8375&mode=lan'
        '&token=0123456789abcdef0123456789abcdef';
    await scrollTo(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), link);
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(pasted, link);
  });

  testWidgets('«Forget this device» спрашивает подтверждение', (tester) async {
    var forgot = false;
    await pumpConnection(tester, onForgetActive: () => forgot = true);

    await scrollTo(tester, find.text('Forget this device'));
    await tester.tap(find.text('Forget this device'));
    await tester.pumpAndSettle();
    expect(find.text('Forget this device?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Forget'));
    await tester.pumpAndSettle();
    expect(forgot, isTrue);
  });

  testWidgets('список сохранённых устройств показывает активную пару',
      (tester) async {
    await pumpConnection(tester);

    await scrollTo(tester, find.text('Saved devices'));
    expect(find.text('MacBook Pro'), findsWidgets);
    expect(
      find.text('tailscale · macbook-pro.tail85247a.ts.net:8375'),
      findsWidgets,
    );
  });

  testWidgets('сохранённый профиль можно удалить из списка', (tester) async {
    await pumpConnection(tester);

    await scrollTo(tester, find.byIcon(Icons.delete_outline));
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    // Profile removed from the list; the card still shows the active config.
    expect(find.text('No saved devices yet'), findsOneWidget);
  });
}
