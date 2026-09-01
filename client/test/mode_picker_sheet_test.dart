import 'dart:async';

import 'package:client/controllers/modes_controller.dart';
import 'package:client/core/connection/mode_service.dart';
import 'package:client/models/pair_config.dart';
import 'package:client/widgets/mode_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Built via fromLink so the profile's own endpoint is seeded (a real
  // tailscale-paired profile remembers its tailnet host).
  final config = PairConfig.fromLink(
    'herdrelay://pair?host=mac.local.c.tailnet.ts.net&port=8375'
    '&mode=tailscale&token=0123456789abcdef0123456789abcdef'
    '&relay_id=relay-0123456789abcdef&name=home-mac',
  );

  /// Opens the sheet the way production does (showModalBottomSheet) so
  /// Navigator.pop inside the sheet works.
  Future<void> openSheet(
    WidgetTester tester, {
    required ModesController modesController,
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
                    modesController: modesController,
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
      modesController: ModesController(
          (_) async => throw const ModeFetchException('Cannot reach relay')),
      onSelected: (c) => selected = c,
    );

    // The failed /pair fetch must not block manual switching.
    expect(find.text('Relay unreachable? Connect manually'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Host'), '192.168.1.5');
    await tester.ensureVisible(find.text('Connect'));
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
      modesController:
          ModesController((_) async => const <RelayModeInfo>[]),
      onSelected: (c) => selected = c,
    );

    await tester.enterText(find.widgetWithText(TextField, 'Host'), '   ');
    await tester.ensureVisible(find.text('Connect'));
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
                    modesController: ModesController((_) => gate.future),
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

  testWidgets('выбор режима из /pair сливает endpoints и переключает на правильный хост',
      (tester) async {
    PairConfig? selected;
    await openSheet(
      tester,
      modesController: ModesController((_) async => const [
        RelayModeInfo(
          mode: 'lan',
          url: 'ws://192.168.1.5:8375',
          link: '',
          description: 'Local network',
        ),
        RelayModeInfo(
          mode: 'tailscale',
          url: 'ws://mac.tailnet.ts.net:8375',
          link: '',
          description: 'Tailscale VPN',
        ),
      ]),
      onSelected: (c) => selected = c,
    );

    // The profile is a tailscale pair; switch to the LAN radio.
    await tester.tap(find.text('lan'));
    await tester.pumpAndSettle();

    // Switched to the LAN endpoint with the LAN IP…
    expect(selected!.mode, 'lan');
    expect(selected!.host, '192.168.1.5');
    // …and the tailscale endpoint from /pair is remembered for offline switches.
    expect(selected!.endpointFor('tailscale'),
        const RelayEndpoint(host: 'mac.tailnet.ts.net', port: 8375));
    expect(selected!.token, config.token);
    expect(selected!.relayId, config.relayId);
  });

  testWidgets('офлайн: переключение из сохранённых endpoints без /pair', (tester) async {
    final withEndpoints = config.withEndpoints({
      'lan': const RelayEndpoint(host: '192.168.1.5', port: 8375),
    });
    PairConfig? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (_) => ModePickerSheet(
                    config: withEndpoints,
                    modesController: ModesController((_) async =>
                        throw const ModeFetchException('Cannot reach relay')),
                    onSelected: (c) async => selected = c,
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

    // /pair failed, but the profile remembers the LAN endpoint.
    expect(find.text('Saved modes for this relay'), findsOneWidget);
    await tester.tap(find.text('lan'));
    await tester.pumpAndSettle();

    expect(selected!.mode, 'lan');
    expect(selected!.host, '192.168.1.5');
    expect(selected!.endpointFor('tailscale'),
        const RelayEndpoint(host: 'mac.local.c.tailnet.ts.net', port: 8375));
  });

  testWidgets('ручная форма: хост следует за выбранным режимом', (tester) async {
    final withEndpoints = config.withEndpoints({
      'lan': const RelayEndpoint(host: '192.168.1.5', port: 8375),
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (_) => ModePickerSheet(
                    config: withEndpoints,
                    modesController: ModesController((_) async =>
                        throw const ModeFetchException('Cannot reach relay')),
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
    await tester.pumpAndSettle();

    // LAN is the default manual mode → its stored endpoint is prefilled.
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Host'))
          .controller!
          .text,
      '192.168.1.5',
    );

    // Switching the mode replaces the host with that mode's stored endpoint —
    // never carries another mode's host over.
    await tester.ensureVisible(find.text('LAN'));
    await tester.tap(find.text('LAN'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tailscale').last);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Host'))
          .controller!
          .text,
      'mac.local.c.tailnet.ts.net',
    );
  });
}