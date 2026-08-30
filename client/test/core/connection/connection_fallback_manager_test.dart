import 'package:client/core/connection/connection_fallback_manager.dart';
import 'package:client/core/transport/transport.dart';
import 'package:client/models/pair_config.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fakes/fake_transport.dart';

/// ConnectionFallbackManager (docs/AUTO_MODE_SWITCHING_PLAN.md, Phase 2):
/// auto-switches to another saved endpoint when the active mode goes dark.
///
/// Tests run in a fake-async zone (testWidgets), so the internal [Timer] is
/// advanced with `tester.pump(...)` instead of real sleeps.
void main() {
  // lan (current) + tailscale + funnel endpoints; no gateway endpoint, so the
  // priority walk must stop there without ever retrying the dead modes.
  PairConfig config() => PairConfig(
        host: '192.168.1.5',
        port: 8375,
        mode: 'lan',
        token: 'a' * 64,
        endpoints: {
          'lan': const RelayEndpoint(host: '192.168.1.5', port: 8375),
          'tailscale': const RelayEndpoint(host: 'mac.tailnet.ts.net', port: 8375),
          'funnel': const RelayEndpoint(host: 'abc.funnel.ts.net', port: 443),
        },
      );

  testWidgets('offline at start: falls back to the next priority mode',
      (tester) async {
    final transport = FakeTransport(); // disconnected
    final seen = <String>[];
    final manager = ConnectionFallbackManager(
      transport: transport,
      config: config(),
      onFallback: (c) async => seen.add(c.mode),
    );
    addTearDown(manager.dispose);

    await tester.pump(const Duration(seconds: 8));
    expect(seen, ['tailscale'], reason: 'lan failed -> next priority mode');

    // No status change, no re-attach: exactly one attempt, no loop.
    await tester.pump(const Duration(seconds: 8));
    expect(seen, ['tailscale']);
  });

  testWidgets('already connected: no fallback is scheduled', (tester) async {
    final transport = FakeTransport();
    transport.status.value = ConnectionStatus.connected;
    final seen = <String>[];
    final manager = ConnectionFallbackManager(
      transport: transport,
      config: config(),
      onFallback: (c) async => seen.add(c.mode),
    );
    addTearDown(manager.dispose);

    await tester.pump(const Duration(seconds: 8));
    expect(seen, isEmpty);
  });

  testWidgets('reconnect within the delay absorbs a flaky drop',
      (tester) async {
    final transport = FakeTransport();
    transport.status.value = ConnectionStatus.connected;
    final seen = <String>[];
    final manager = ConnectionFallbackManager(
      transport: transport,
      config: config(),
      onFallback: (c) async => seen.add(c.mode),
    );
    addTearDown(manager.dispose);

    // Brief drop, then back before the fallback countdown elapses.
    transport.status.value = ConnectionStatus.disconnected;
    transport.status.value = ConnectionStatus.connected;

    await tester.pump(const Duration(seconds: 8));
    expect(seen, isEmpty, reason: 'recovery cancelled the pending attempt');
  });

  testWidgets('dispose cancels the pending fallback', (tester) async {
    final transport = FakeTransport(); // disconnected -> schedules fallback
    final seen = <String>[];
    final manager = ConnectionFallbackManager(
      transport: transport,
      config: config(),
      onFallback: (c) async => seen.add(c.mode),
    );

    manager.dispose();
    await tester.pump(const Duration(seconds: 8));
    expect(seen, isEmpty, reason: 'timer cancelled by dispose');
  });

  testWidgets(
      'walks the priority list once, skipping failed modes and missing '
      'endpoints (no lan<->tailscale ping-pong)', (tester) async {
    final transport = FakeTransport(); // disconnected
    final seen = <String>[];
    late final ConnectionFallbackManager manager;
    manager = ConnectionFallbackManager(
      transport: transport,
      config: config(),
      onFallback: (c) async {
        seen.add(c.mode);
        // The app reconnects with a fresh transport for the new mode; here it
        // also fails, so the manager must continue down the list.
        final nextTransport = FakeTransport(); // disconnected
        manager.attach(nextTransport, c);
      },
    );
    addTearDown(manager.dispose);

    await tester.pump(const Duration(seconds: 8));
    expect(seen, ['tailscale']);
    await tester.pump(const Duration(seconds: 8));
    expect(seen, ['tailscale', 'funnel'], reason: 'lan must not be retried');
    await tester.pump(const Duration(seconds: 8));
    // gateway has no saved endpoint -> walk exhausted, stop.
    expect(seen, ['tailscale', 'funnel']);
  });

  testWidgets('attach to a live transport resets the failure set',
      (tester) async {
    final transport = FakeTransport(); // disconnected
    final seen = <String>[];
    final manager = ConnectionFallbackManager(
      transport: transport,
      config: config(),
      onFallback: (c) async => seen.add(c.mode),
    );
    addTearDown(manager.dispose);

    // Outage: fall to tailscale, then the user gets back home and manually
    // reconnects over a now-working LAN (live transport).
    await tester.pump(const Duration(seconds: 8));
    expect(seen, ['tailscale']);

    final live = FakeTransport();
    live.status.value = ConnectionStatus.connected;
    manager.attach(live, config());
    await tester.pump(const Duration(seconds: 8));
    expect(seen, ['tailscale'], reason: 'live attach clears failed modes');
  });
}
