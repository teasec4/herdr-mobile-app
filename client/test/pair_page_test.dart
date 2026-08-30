import 'package:client/core/connection/mode_service.dart';
import 'package:client/models/pair_config.dart';
import 'package:client/pages/pair_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// PairPage: QR scanner + manual link entry. These tests cover the manual
/// path — the one users hit when they paste a link.
void main() {
  const validLink = 'herdrelay://pair?host=macbook-pro.tail85247a.ts.net'
      '&port=8375&mode=tailscale&token=0123456789abcdef0123456789abcdef';

  /// Universal-QR mode stubs: the relay is reachable over LAN and Tailscale.
  const twoModes = [
    RelayModeInfo(
      mode: 'lan',
      url: 'ws://192.168.1.5:8375',
      link: '',
      description: 'Local network',
    ),
    RelayModeInfo(
      mode: 'tailscale',
      url: 'ws://mac.ts.net:8375',
      link: '',
      description: 'Tailscale VPN',
    ),
  ];

  Future<void> pumpPair(
    WidgetTester tester, {
    Future<void> Function(PairConfig)? onPaired,
    Future<List<RelayModeInfo>> Function(PairConfig)? modesFetcher,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PairPage(
          onPaired: onPaired ?? (_) async {},
          modesFetcher: modesFetcher,
        ),
      ),
    );
  }

  testWidgets('вставка валидной ссылки вызывает onPaired с конфигом',
      (tester) async {
    PairConfig? result;
    await pumpPair(tester, onPaired: (c) async => result = c);

    await tester.enterText(find.byType(TextField), validLink);
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.host, 'macbook-pro.tail85247a.ts.net');
    expect(result!.mode, 'tailscale');
    expect(result!.port, 8375);
  });

  testWidgets('вставка невалидной ссылки показывает ошибку', (tester) async {
    var called = false;
    await pumpPair(tester, onPaired: (_) async => called = true);

    await tester.enterText(find.byType(TextField), 'not-a-link');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(called, isFalse);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('ссылка с коротким токеном отклоняется с ошибкой',
      (tester) async {
    await pumpPair(tester);

    await tester.enterText(
      find.byType(TextField),
      'herdrelay://pair?host=h&port=8375&mode=lan&token=short',
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
  });

  /// The Connect button shows a spinner while pairing, so `pumpAndSettle`
  /// can never settle while a modal (warning sheet / mode dialog) is up — the
  /// spinner keeps scheduling frames. Pump fixed durations instead.
  Future<void> pumpModalOpen(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  // --- Phase 1.1: LAN-only warning ---------------------------------------

  const lanLink = 'herdrelay://pair?host=192.168.1.5&port=8375&mode=lan'
      '&token=0123456789abcdef0123456789abcdef';

  testWidgets('LAN-ссылка показывает предупреждение, Continue anyway парит',
      (tester) async {
    PairConfig? result;
    await pumpPair(tester, onPaired: (c) async => result = c);

    await tester.enterText(find.byType(TextField), lanLink);
    await tester.tap(find.text('Connect'));
    await pumpModalOpen(tester);

    // Warning blocks pairing until the user confirms.
    expect(find.text('Limited connectivity detected'), findsOneWidget);
    expect(result, isNull);

    await tester.tap(find.text('Continue anyway'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.mode, 'lan');
    expect(result!.host, '192.168.1.5');
  });

  testWidgets('отмена LAN-предупреждения не запускает паринг', (tester) async {
    var called = false;
    await pumpPair(tester, onPaired: (_) async => called = true);

    await tester.enterText(find.byType(TextField), lanLink);
    await tester.tap(find.text('Connect'));
    await pumpModalOpen(tester);

    // Tap the barrier above the bottom sheet to dismiss it (returns false).
    await tester.tapAt(const Offset(20, 100));
    await tester.pumpAndSettle();

    expect(called, isFalse);
    expect(find.text('Limited connectivity detected'), findsNothing);
  });

  // --- Phase 4: universal QR (no `mode` param) ----------------------------

  const universalLink = 'herdrelay://pair?host=192.168.1.5'
      '&port=8375&token=0123456789abcdef0123456789abcdef';

  testWidgets('ссылка без mode предлагает выбрать режим из всех endpoint-ов',
      (tester) async {
    PairConfig? result;
    await pumpPair(
      tester,
      onPaired: (c) async => result = c,
      modesFetcher: (_) async => twoModes,
    );

    await tester.enterText(find.byType(TextField), universalLink);
    await tester.tap(find.text('Connect'));
    await pumpModalOpen(tester);

    expect(find.text('Select connection mode'), findsOneWidget);

    await tester.tap(find.text('tailscale'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.mode, 'tailscale');
    expect(result!.host, 'mac.ts.net');
    expect(result!.endpoints, hasLength(2)); // both modes saved for later
  });

  testWidgets('ошибка загрузки режимов не блокирует паринг', (tester) async {
    PairConfig? result;
    await pumpPair(
      tester,
      onPaired: (c) async => result = c,
      modesFetcher: (_) async =>
          throw const ModeFetchException('Cannot reach relay'),
    );

    await tester.enterText(find.byType(TextField), universalLink);
    await tester.tap(find.text('Connect'));
    await pumpModalOpen(tester);

    // Toast with the fetch error, then falls back to the LAN-only config —
    // which re-triggers the Phase 1.1 warning.
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('Limited connectivity detected'), findsOneWidget);
    expect(result, isNull);

    await tester.tap(find.text('Continue anyway'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.mode, 'lan'); // link default, no modes were learned
  });
}
