import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../controllers/agents_store.dart';
import '../controllers/app_session_controller.dart';
import '../controllers/modes_controller.dart';
import '../controllers/session_controller.dart';
import '../models/pair_config.dart';
import '../repositories/agent_repository.dart';
import '../services/action_parser_service.dart';
import '../services/app_settings.dart';
import '../services/command_history_service.dart';
import '../services/config_store.dart';
import '../services/notification_api.dart';
import '../services/notification_service.dart';
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
  // Typed key-centralized settings/cache over SharedPreferences.
  getIt.registerSingleton<AppSettings>(
    AppSettings(getIt<SharedPreferences>()),
  );
  // Fetches relay connection modes (/pair) with retries — used by the
  // HomePage mode badge and the Connection screen.
  getIt.registerSingleton<ModeService>(ModeService());
  // Single source of truth for the relay's available modes. Global (lives in
  // setupDependencies, not setupRelayServices): the pair flow and mode picker
  // also need it during onboarding, before any relay services exist.
  getIt.registerSingleton<ModesController>(
    ModesController(getIt<ModeService>().fetch),
  );
  // Root app session: which pair is active, serialized config switches, and
  // the fallback manager wiring. Registered here (not in setupRelayServices)
  // because it must survive relay teardown — pages consult it to detect that
  // their cached getIt references went stale.
  getIt.registerSingleton<AppSessionController>(AppSessionController());
  // Local "agent blocked" notifications — platform facade over
  // flutter_local_notifications. The NotificationService is created per relay
  // connection in setupRelayServices (it depends on the live AgentRepository).
  getIt.registerSingleton<NotificationApi>(LocalNotificationsApi());
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
Future<void> setupRelayServices(
  PairConfig config, {
  RelayClient Function(PairConfig)? clientFactory,
  String transportMode = 'ws',
}) async {
  // Unregister old instances if they exist. Every register below is guarded so
  // a repeated setup (config switch racing a deep link) replaces services
  // instead of throwing AlreadyRegisteredException.
  if (getIt.isRegistered<SessionController>()) {
    getIt<SessionController>().dispose();
    getIt.unregister<SessionController>();
  }
  if (getIt.isRegistered<AgentsStore>()) {
    getIt<AgentsStore>().dispose();
    getIt.unregister<AgentsStore>();
  }
  if (getIt.isRegistered<AgentRepository>()) {
    final oldRepo = getIt<AgentRepository>();
    await oldRepo.close();
    getIt.unregister<AgentRepository>();
  }
  if (getIt.isRegistered<ConnectionManager>()) {
    getIt<ConnectionManager>().dispose();
    getIt.unregister<ConnectionManager>();
  }
  if (getIt.isRegistered<Transport>()) {
    // Close the old transport so its socket/reconnect timers are not leaked
    // when a new config is set up over an existing one.
    await getIt<Transport>().close();
    getIt.unregister<Transport>();
  }
  if (getIt.isRegistered<RelayClient>()) {
    getIt.unregister<RelayClient>();
  }
  if (getIt.isRegistered<NotificationService>()) {
    getIt<NotificationService>().stop();
    getIt.unregister<NotificationService>();
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
    // Expose the transport so ConnectionFallbackManager (main.dart) can watch
    // the connection state and auto-switch to another saved endpoint.
    getIt.registerSingleton<Transport>(transport);
    getIt.registerSingleton<ConnectionManager>(
      ConnectionManager(transport, retryPolicy),
    );
    getIt.registerSingleton<RelayClient>(
      RelayClientImpl(config, transport: transport),
    );
  }

  // Register AgentRepository (depends on RelayClient)
  getIt.registerSingleton<AgentRepository>(
    AgentRepository(getIt<RelayClient>(), getIt<AppSettings>()),
  );

  // Single source of truth for agent/workspace status (Agents tab, AgentPage,
  // WorkspacePage, SessionController all read from here).
  getIt.registerSingleton<AgentsStore>(
    AgentsStore(getIt<AgentRepository>()),
  );

  // Shared session state for the Spaces/Run tabs (loads once on registration).
  getIt.registerSingleton<SessionController>(
    SessionController(getIt<RelayClient>(), getIt<AgentsStore>()),
  );

  // Local notifications for blocked agents while the app is in the background.
  // Created per relay connection: it binds to the live AgentRepository events.
  getIt.registerSingleton<NotificationService>(
    NotificationService(
      getIt<AgentRepository>(),
      getIt<AppSettings>(),
      getIt<NotificationApi>(),
    ),
  )..start();
}

/// Clean up relay services (on disconnect)
Future<void> teardownRelayServices() async {
  if (getIt.isRegistered<SessionController>()) {
    getIt<SessionController>().dispose();
    getIt.unregister<SessionController>();
  }
  if (getIt.isRegistered<AgentsStore>()) {
    getIt<AgentsStore>().dispose();
    getIt.unregister<AgentsStore>();
  }
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
  if (getIt.isRegistered<Transport>()) {
    // Close the old transport so its socket/reconnect timers are not leaked
    // when the relay services are torn down (config switch / forget).
    await getIt<Transport>().close();
    getIt.unregister<Transport>();
  }
  if (getIt.isRegistered<NotificationService>()) {
    getIt<NotificationService>().stop();
    getIt.unregister<NotificationService>();
  }
}
