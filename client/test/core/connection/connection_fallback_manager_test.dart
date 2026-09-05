import 'package:client/core/connection/connection_fallback_manager.dart';
import 'package:client/core/transport/transport.dart';
import 'package:client/models/pair_config.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fakes/fake_transport.dart';

/// ConnectionFallbackManager (docs/AUTO_MODE_SWITCHING_PLAN.md, Phase 2):
/// auto-switches to another saved endpoint when the active mode is
/// unreachable.
///
/// Behavior under test (the metro / leaving-home scenarios):
///  - a single drop is absorbed by the transport's own reconnect loop — no
///    switch races a slow-but-live handshake;
///  - a mode switch happens only after [switchAfterFailures] failures;
///  - a mode we switched away from is not proposed again while its dead-mode
///    memory is fresh (no LAN bounce mid-ride);
///  - when every alternative is dead the app reverts to the last-good mode
///    (or, on a cold start into a dead zone, to the boot mode) instead of
///    being stranded on an endpoint that never worked.
///
/// The manager schedules no timers: all switching happens off status events,
/// so the tests use plain async with microtask flushes instead of fake clocks.

PairConfig cfg({String mode = 'lan', bool funnel = true}) => PairConfig(
      host: '192.168.1.5',
      port: 8375,
      mode: mode,
      token: 'a' * 64,
      endpoints: {
        'lan': const RelayEndpoint(host: '192.168.1.5', port: 8375),
        'tailscale': const RelayEndpoint(host: 'mac.tailnet.ts.net', port: 8375),
        if (funnel)
          'funnel': const RelayEndpoint(host: 'abc.funnel.ts.net', port: 443),
      },
    );

Future<void> flush() => Future<void>.delayed(Duration.zero);

void connect(FakeTransport t) {
  t.status.value = ConnectionStatus.connected;
}

void drop(FakeTransport t) {
  t.status.value = ConnectionStatus.disconnected;
}

/// One full failed reconnect attempt: connecting, then disconnected.
Future<void> failAttempt(FakeTransport t) async {
  t.status.value = ConnectionStatus.connecting;
  t.status.value = ConnectionStatus.disconnected;
  await flush();
}

/// A manager whose [onFallback] mimics the app layer: it records the
/// proposal and brings up a fresh (offline) transport for the new config,
/// exactly like `setConfig` -> teardown/setup -> attach does in production.
class Harness {
  Harness(
    PairConfig initial, {
    int switchAfterFailures = 2,
    Duration deadModeTtl = const Duration(minutes: 10),
  }) {
    manager = ConnectionFallbackManager(
      transport: current = FakeTransport(),
      config: initial,
      switchAfterFailures: switchAfterFailures,
      deadModeTtl: deadModeTtl,
      onFallback: (config) async {
        seen.add(config.mode);
        proposals.add(config);
        current = FakeTransport();
        manager.attach(current, config);
      },
    );
  }

  late final ConnectionFallbackManager manager;
  late FakeTransport current;
  final List<String> seen = [];
  final List<PairConfig> proposals = [];
}

void main() {

  test('single drop is absorbed by the transport reconnect — no switch',
      () async {
    final h = Harness(cfg());
    addTearDown(h.manager.dispose);
    connect(h.current);
    await flush();

    drop(h.current); // 1 failure
    await flush();
    connect(h.current); // reconnected before anything else happens
    await flush();

    expect(h.seen, isEmpty);
  });

  test('cold start on an unreachable mode switches after the failure threshold',
      () async {
    final h = Harness(cfg());
    addTearDown(h.manager.dispose);

    await failAttempt(h.current);
    expect(h.seen, isEmpty, reason: 'one failure is not enough');

    await failAttempt(h.current);
    expect(h.seen, ['tailscale']);
    final proposal = h.proposals.single;
    expect(proposal.mode, 'tailscale');
    expect(proposal.host, 'mac.tailnet.ts.net',
        reason: 'switch uses the saved tailscale endpoint');
  });

  test('a drop plus one failed reconnect triggers exactly one switch',
      () async {
    final h = Harness(cfg());
    addTearDown(h.manager.dispose);
    connect(h.current);
    await flush();

    drop(h.current); // drop counts as failure 1
    await flush();
    expect(h.seen, isEmpty, reason: 'a drop alone never switches');

    await failAttempt(h.current); // failed reconnect = failure 2
    expect(h.seen, ['tailscale']);

    // Back on the new mode: a single hiccup must not walk any further.
    connect(h.current);
    await flush();
    drop(h.current);
    await flush();
    expect(h.seen, ['tailscale']);
  });

  test('once switched away, a dead LAN is not re-proposed during the ride',
      () async {
    // LAN + Tailscale only: no funnel/gateway to hide behind.
    final h = Harness(cfg(funnel: false));
    addTearDown(h.manager.dispose);
    connect(h.current); // connected at home over LAN
    await flush();

    // Leave home: LAN goes dark and cannot reconnect -> switch to Tailscale.
    drop(h.current);
    await failAttempt(h.current);
    expect(h.seen, ['tailscale']);

    connect(h.current); // Tailscale connects and works in the metro
    await flush();
    drop(h.current); // blip
    await flush();
    connect(h.current); // ...and recovers
    await flush();
    expect(h.seen, ['tailscale']);

    // Sustained Tailscale outage while away: LAN is still dead-marked, so the
    // walk has nowhere to go and must NOT bounce back into LAN.
    drop(h.current);
    await failAttempt(h.current);
    expect(h.seen, ['tailscale'],
        reason: 'dead LAN must not be re-proposed in the same ride');

    // Even after more failures the app stays on Tailscale's reconnect loop.
    connect(h.current);
    await flush();
    drop(h.current);
    await failAttempt(h.current);
    expect(h.seen, ['tailscale']);
  });

  test('dead zone: after every alternative fails, reverts to the last-good mode',
      () async {
    // Profile saved as tailscale (worked yesterday); LAN endpoint remembered.
    final h = Harness(cfg(mode: 'tailscale', funnel: false));
    addTearDown(h.manager.dispose);
    connect(h.current); // connected over Tailscale
    await flush();

    // Tailscale drops hard; LAN has not failed recently, so it is proposed…
    drop(h.current);
    await failAttempt(h.current);
    expect(h.seen, ['lan']);

    // …but LAN is dead here too: after its own failures the walk is exhausted
    // and must revert to Tailscale (the last mode that actually connected).
    await failAttempt(h.current);
    await failAttempt(h.current);
    expect(h.seen, ['lan', 'tailscale']);
    expect(h.proposals.last.mode, 'tailscale',
        reason: 'revert reconnects over the mode that last connected');

    // No infinite LAN<->Tailscale ping-pong while both are down.
    connect(h.current);
    await flush();
    drop(h.current);
    await failAttempt(h.current);
    expect(h.seen, ['lan', 'tailscale']);
  });

  test('attach to an already-connected transport resets the failure counter',
      () async {
    final h = Harness(cfg());
    addTearDown(h.manager.dispose);
    connect(h.current);
    await flush();

    drop(h.current); // 1 failure accumulated on the old transport…
    await flush();

    // …then the user manually reconnects (a fresh, live transport): the stale
    // failure must not carry over and trigger an instant switch.
    final live = FakeTransport();
    connect(live);
    h.manager.attach(live, cfg());
    await flush();

    drop(live);
    await flush();
    expect(h.seen, isEmpty, reason: 'attach reset the failure counter');

    await failAttempt(live);
    expect(h.seen, ['tailscale']);
  });

  test('cold start into a dead zone returns to the boot mode, not LAN',
      () async {
    // Profile saved as tailscale (worked yesterday); LAN endpoint remembered.
    // The user opens the app in the metro while the tunnel is down: nothing
    // has connected yet, so no "last connected" exists to revert to — the
    // manager must anchor on the boot mode instead of stranding on LAN.
    final h = Harness(cfg(mode: 'tailscale', funnel: false));
    addTearDown(h.manager.dispose);

    await failAttempt(h.current); // tailscale: failed attempt 1
    expect(h.seen, isEmpty);
    await failAttempt(h.current); // attempt 2 -> LAN proposed
    expect(h.seen, ['lan']);

    await failAttempt(h.current); // LAN fails too
    await failAttempt(h.current);
    expect(h.seen, ['lan', 'tailscale'],
        reason: 'revert to the boot mode (no last-connected yet)');

    // Stable: no LAN<->tailscale ping-pong while both are down.
    await failAttempt(h.current);
    await failAttempt(h.current);
    expect(h.seen, ['lan', 'tailscale']);

    // Recovery: once the boot mode can connect again, it does.
    connect(h.current);
    await flush();
    expect(h.seen, ['lan', 'tailscale']);
  });

  test('dead-mode memory expires after the TTL', () async {
    final h = Harness(cfg(), deadModeTtl: const Duration(milliseconds: 80));
    addTearDown(h.manager.dispose);
    connect(h.current);
    await flush();

    drop(h.current); // LAN goes dark
    await failAttempt(h.current);
    expect(h.seen, ['tailscale']); // LAN is now dead-marked

    connect(h.current); // Tailscale connected
    await flush();
    // Wait out the dead-mode TTL: LAN may be reachable again (user came home).
    await Future<void>.delayed(const Duration(milliseconds: 160));

    drop(h.current);
    await failAttempt(h.current); // Tailscale outage -> walk
    expect(h.seen, ['tailscale', 'lan'],
        reason: 'expired dead-mark allows LAN again');
  });

  test('dispose stops further switching', () async {
    final h = Harness(cfg());
    connect(h.current);
    await flush();

    h.manager.dispose();
    drop(h.current);
    await failAttempt(h.current);
    expect(h.seen, isEmpty);
  });
}
