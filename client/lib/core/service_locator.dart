import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/pair_config.dart';
import '../repositories/agent_repository.dart';
import '../services/action_parser_service.dart';
import '../services/command_history_service.dart';
import '../services/config_store.dart';
import '../services/relay_client.dart';
import '../services/relay_client_impl.dart';
import 'connection/connection_manager.dart';
import 'connection/mode_service.dart';
import 'transport/http_transport.dart';
import 'transport/retry_policy.dart';
import 'transport/transport.dart';
import 'transport/websocket_transport.dart';

final getIt = GetIt.instance;

/// Initialize dependency injection container
Future<void> setupDependencies() async {
  // Register SharedPreferences (async singleton)
  final prefs = await SharedPreferences.getInstance();
  getIt.registerSingleton<SharedPreferences>(prefs);

  // Register ConfigStore (singleton)
  getIt.registerSingleton<ConfigStore>(ConfigStore());

  // Register services (singletons)
  getIt.registerSingleton<CommandHistoryService>(
    CommandHistoryService(getIt<SharedPreferences>()),
  );
  getIt.registerSingleton<ActionParserService>(ActionParserService());
  // Fetches relay connection modes (/pair) with retries — used by the
  // HomePage mode badge and the Connection screen.
  getIt.registerSingleton<ModeService>(ModeService());
}

/// Setup RelayClient and AgentRepository for a specific config
/// This is called when user pairs with a relay
///
/// Production wiring (no [clientFactory]):
///   WebSocketTransport + ExponentialBackoff
///     ├─ ConnectionManager (app lifecycle -> pause/resume)
///     ├─ RelayClientImpl (shares the transport)
///     └─ AgentRepository
/// Widget tests inject a FakeRelayClient via [clientFactory]; the transport
/// and ConnectionManager are then not created at all.
///
/// [transportMode] selects the transport: `ws` (default) or `http`
/// (Phase 5 fallback — /api/rpc + SSE). In the future this can be driven by
/// a feature flag / PairConfig field.
void setupRelayServices(
  PairConfig config, {
  RelayClient Function(PairConfig)? clientFactory,
  String transportMode = 'ws',
}) {
  // Unregister old instances if they exist
  if (getIt.isRegistered<AgentRepository>()) {
    final oldRepo = getIt<AgentRepository>();
    oldRepo.close();
    getIt.unregister<AgentRepository>();
  }
  if (getIt.isRegistered<ConnectionManager>()) {
    getIt<ConnectionManager>().dispose();
    getIt.unregister<ConnectionManager>();
  }
  if (getIt.isRegistered<RelayClient>()) {
    getIt.unregister<RelayClient>();
  }

  if (clientFactory != null) {
    getIt.registerSingleton<RelayClient>(clientFactory(config));
  } else {
    // One transport shared by the connection manager and the client.
    final Transport transport = switch (transportMode) {
      'http' => HttpTransport(baseUri: config.httpBaseUri, token: config.token),
      _ => WebSocketTransport(),
    };
    final retryPolicy = ExponentialBackoff();
    getIt.registerSingleton<ConnectionManager>(
      ConnectionManager(transport, retryPolicy),
    );
    getIt.registerSingleton<RelayClient>(
      RelayClientImpl(config, transport: transport),
    );
  }

  // Register AgentRepository (depends on RelayClient)
  getIt.registerSingleton<AgentRepository>(
    AgentRepository(getIt<RelayClient>(), getIt<SharedPreferences>()),
  );
}

/// Clean up relay services (on disconnect)
Future<void> teardownRelayServices() async {
  if (getIt.isRegistered<AgentRepository>()) {
    await getIt<AgentRepository>().close();
    getIt.unregister<AgentRepository>();
  }
  if (getIt.isRegistered<RelayClient>()) {
    getIt.unregister<RelayClient>();
  }
  if (getIt.isRegistered<ConnectionManager>()) {
    getIt<ConnectionManager>().dispose();
    getIt.unregister<ConnectionManager>();
  }
}
