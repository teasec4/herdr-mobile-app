import 'dart:async';

import 'package:client/core/connection/mode_service.dart';
import 'package:client/models/pair_config.dart';
import 'package:client/widgets/mode_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final config = PairConfig(
    host: 'mac.local.c.tailnet.ts.net',
    port: 8375,
    mode: 'tailscale',
    token: '0123456789abcdef0123456789abcdef',
    relayId: 'relay-0123456789abcdef',
    name: 'home-mac',
  );

  /// Opens the sheet the way production does (showModalBottomSheet) so
  /// Navigator.pop inside the sheet works.
  Future<void> openSheet(
    WidgetTester tester, {
    required Future<List<RelayModeInfo>> Function(PairConfig) fetcher,
    required void Function(PairConfig) onSelected,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (_) => ModePickerSheet(
                    config: config,
                    fetcher: fetcher,
                    onSelected: (c) async => onSelected(c),
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
  }

  testWidgets('ручной LAN при недоступном релее переключает с сохранённым токеном',
      (tester) async {
    PairConfig? selected;
    await openSheet(
      tester,
      fetcher: (_) async =>
          throw const ModeFetchException('Cannot reach relay'),
      onSelected: (c) => selected = c,
    );

    // The failed /pair fetch must not block manual switching.
    expect(find.text('Relay unreachable? Connect manually'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Host'), '192.168.1.5');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(selected, isNotNull);
    expect(selected!.host, '192.168.1.5');
    expect(selected!.port, 8375);
    expect(selected!.mode, 'lan');
    expect(selected!.token, config.token, reason: 'token comes from the profile');
    expect(selected!.relayId, config.relayId, reason: 'profile identity kept');
  });

  testWidgets('пустой хост не переключает режим', (tester) async {
    PairConfig? selected;
    await openSheet(
      tester,
      fetcher: (_) async => const <RelayModeInfo>[],
      onSelected: (c) => selected = c,
    );

    await tester.enterText(find.widgetWithText(TextField, 'Host'), '   ');
    await tester.tap(find.text('Connect'));
    await tester.pump();

    expect(selected, isNull, reason: 'invalid host must not switch');
  });

  testWidgets('ручной ввод виден сразу, пока /pair ещё грузится', (tester) async {
    final gate = Completer<List<RelayModeInfo>>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (_) => ModePickerSheet(
                    config: config,
                    fetcher: (_) => gate.future,
                    onSelected: (_) async {},
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
    // Only a frame — the fetcher never completes, so no pumpAndSettle.
    await tester.pump(const Duration(milliseconds: 100));

    // The manual fallback is reachable even while the fetch is pending, so an
    // offline user is never blocked by the doomed /pair request.
    expect(find.text('Relay unreachable? Connect manually'), findsOneWidget);
  });
}
