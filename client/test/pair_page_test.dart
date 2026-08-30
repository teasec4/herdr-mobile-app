import 'package:client/models/pair_config.dart';
import 'package:client/pages/pair_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// PairPage: QR scanner + manual link entry. These tests cover the manual
/// path — the one users hit when they paste a link.
void main() {
  const validLink = 'herdrelay://pair?host=macbook-pro.tail85247a.ts.net'
      '&port=8375&mode=tailscale&token=0123456789abcdef0123456789abcdef';

  Future<void> pumpPair(
    WidgetTester tester, {
    Future<void> Function(PairConfig)? onPaired,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PairPage(onPaired: onPaired ?? (_) async {}),
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
}
