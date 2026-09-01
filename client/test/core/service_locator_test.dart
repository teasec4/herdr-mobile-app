import 'package:client/core/service_locator.dart';
import 'package:client/core/transport/transport.dart';
import 'package:client/models/pair_config.dart';
import 'package:client/repositories/agent_repository.dart';
import 'package:client/services/config_store.dart';
import 'package:client/services/relay_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_relay_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const config = PairConfig(
    host: 'relay.local',
    port: 8375,
    mode: 'lan',
    token: 'abcd1234abcd1234abcd1234abcd1234',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await setupDependencies();
  });

  tearDown(() async {
    await teardownRelayServices();
    await getIt.reset();
  });

  test('repeated setupRelayServices with clientFactory is idempotent', () async {
    await setupRelayServices(config, clientFactory: (_) => FakeRelayClient());
    final first = getIt<RelayClient>();
    // Second call replaces the instances instead of throwing
    // AlreadyRegisteredException.
    await setupRelayServices(config, clientFactory: (_) => FakeRelayClient());

    expect(getIt<RelayClient>(), isNot(same(first)));
    expect(getIt<AgentRepository>(), isNotNull);
    // Old repository was awaited-closed; the new one serves fresh.
    final repo = getIt<AgentRepository>();
    expect(await repo.getAgents(), isEmpty);
  });

  test('repeated setupRelayServices (production wiring) replaces the transport',
      () async {
    await setupRelayServices(config);
    final firstTransport = getIt<Transport>();
    expect(firstTransport, isNotNull);

    // Second setup used to throw AlreadyRegisteredException because Transport
    // was never unregistered; now the old transport is closed and replaced.
    await setupRelayServices(config);
    final secondTransport = getIt<Transport>();
    expect(secondTransport, isNot(same(firstTransport)));

    // The replaced transport is closed (its reconnect loop is stopped).
    expect((firstTransport as dynamic).isClosed, isTrue);
  });

  test('teardown clears relay services but keeps global ones', () async {
    await setupRelayServices(config, clientFactory: (_) => FakeRelayClient());
    await teardownRelayServices();

    expect(getIt.isRegistered<RelayClient>(), isFalse);
    expect(getIt.isRegistered<AgentRepository>(), isFalse);
    // Global (non-relay) services survive the teardown.
    expect(getIt.isRegistered<RelayClient>(), isFalse);
    expect(getIt.isRegistered<ConfigStore>(), isTrue);
  });
}