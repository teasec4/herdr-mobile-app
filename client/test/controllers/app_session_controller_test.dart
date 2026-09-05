import 'dart:convert';

import 'package:client/controllers/app_session_controller.dart';
import 'package:client/core/service_locator.dart';
import 'package:client/models/pair_config.dart';
import 'package:client/services/config_store.dart';
import 'package:client/services/notification_api.dart';
import 'package:client/services/relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/fake_notification_api.dart';
import '../fakes/fake_relay_client.dart';
import '../test_helper.dart';

/// AppSessionController mode persistence: the stored profile must follow
/// reality — a mode is written only once the relay actually connected over it,
/// never when the fallback manager merely *proposes* an unreachable candidate
/// (docs: leaving home / metro — LAN while away must not end up as the stored
/// mode just because it was tried).
void main() {
  final lanConfig = PairConfig.fromLink(
    'herdrelay://pair?host=192.168.1.5&port=8375&mode=lan'
    '&token=abcdef0123456789&relay_id=relay-1',
  );
  final tailscaleConfig = PairConfig(
    host: 'mac.tailnet.ts.net',
    port: 8375,
    mode: 'tailscale',
    token: 'abcdef0123456789',
    relayId: 'relay-1',
    name: 'MacBook',
    endpoints: {
      'lan': const RelayEndpoint(host: '192.168.1.5', port: 8375),
      'tailscale': const RelayEndpoint(host: 'mac.tailnet.ts.net', port: 8375),
    },
  );

  late FakeRelayClient client;

  setUp(() {
    client = FakeRelayClient();
  });

  tearDown(() async {
    await teardownTestDependencies();
  });

  Future<AppSessionController> setup({bool seedProfile = false}) async {
    await setupTestDependencies(
      client,
      lanConfig,
      prefsSeed: seedProfile
          ? {
              'pair_profiles': jsonEncode([lanConfig.toJson()]),
              'active_profile': lanConfig.profileKey,
            }
          : const {},
    );
    // setupRelayServices (driven by setConfig) constructs a NotificationService
    // that needs the platform facade registered (as in connection_page_test).
    getIt.registerSingleton<NotificationApi>(FakeNotificationApi());
    final session = getIt<AppSessionController>();
    session.clientFactory = (_) => client;
    return session;
  }

  testWidgets('mode is persisted only after the candidate actually connects',
      (tester) async {
    final session = await setup(seedProfile: true);
    final store = getIt<ConfigStore>();
    expect((await store.loadActive())!.mode, 'lan');

    // The fallback manager proposes Tailscale while it is NOT reachable yet:
    // the app reconnects, but the client reports only "connecting".
    client.status.value = RelayStatus.disconnected;
    await session.setConfig(tailscaleConfig);
    await tester.pump();

    expect(session.config!.mode, 'tailscale');
    expect((await store.loadActive())!.mode, 'lan',
        reason: 'an unreachable candidate must not be written to the profile');

    // The candidate finally connects -> only now it becomes the stored mode.
    client.status.value = RelayStatus.connected;
    await tester.pump();
    expect((await store.loadActive())!.mode, 'tailscale');
  });

  testWidgets('a fallback candidate that never connects is never persisted',
      (tester) async {
    final session = await setup(seedProfile: true);
    final store = getIt<ConfigStore>();

    client.status.value = RelayStatus.disconnected;
    await session.setConfig(tailscaleConfig);
    await tester.pump();

    // Wait out any async persistence that might have been scheduled.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect((await store.loadActive())!.mode, 'lan',
        reason: 'still-lan: the disconnected candidate stayed out of storage');
  });

  testWidgets('cold start over a working profile leaves the stored mode alone',
      (tester) async {
    final session = await setup(seedProfile: true);
    // FakeRelayClient is connected by default, like a relay that answers.
    await session.bootstrap();
    await tester.pump();

    expect(session.config, isNotNull, reason: 'bootstrap applied the profile');
    expect((await getIt<ConfigStore>().loadActive())!.mode, 'lan',
        reason: 'same-mode cold start must not rewrite the profile');
  });
}
