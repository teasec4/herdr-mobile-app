import 'package:client/models/pair_config.dart';
import 'package:client/widgets/manual_mode_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Manual mode dialog: live reachability check over /healthz and a custom
/// host/port commit (AUTO_MODE_SWITCHING_PLAN, Phase 3).
void main() {
  final config = PairConfig(
    host: '192.168.1.5',
    port: 8375,
    mode: 'lan',
    token: '0123456789abcdef0123456789abcdef',
  );

  Future<void> pumpDialog(
    WidgetTester tester, {
    required http.Client client,
    void Function(PairConfig?)? onResult,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  final cfg = await showManualModeDialog(
                    context,
                    config: config,
                    httpClient: client,
                  );
                  onResult?.call(cfg);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('«Test connection» опрашивает /healthz и показывает результат',
      (tester) async {
    Uri? probed;
    final client = MockClient((request) async {
      probed = request.url;
      return http.Response('ok', 200);
    });
    await pumpDialog(tester, client: client);

    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(probed, Uri.parse('http://192.168.1.5:8375/healthz'));
    expect(find.textContaining('Reachable (HTTP 200)'), findsOneWidget);
  });

  testWidgets('недостижимый relay показывает «Not reachable»', (tester) async {
    final client = MockClient((_) async {
      throw http.ClientException('Connection refused');
    });
    await pumpDialog(tester, client: client);

    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Not reachable'), findsOneWidget);
  });

  testWidgets('Connect возвращает конфиг с введёнными host/port', (tester) async {
    final client = MockClient((_) async => http.Response('ok', 200));
    PairConfig? result;
    await pumpDialog(tester, client: client, onResult: (c) => result = c);

    await tester.enterText(find.byType(TextField).at(0), '10.0.0.7');
    await tester.enterText(find.byType(TextField).at(1), '9000');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.mode, 'lan');
    expect(result!.host, '10.0.0.7');
    expect(result!.port, 9000);
  });
}
