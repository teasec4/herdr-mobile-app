import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/pair_config.dart';
import '../repositories/agent_repository.dart';
import '../services/action_parser_service.dart';
import '../services/command_history_service.dart';
import '../services/config_store.dart';
import '../services/relay_client.dart';
import '../services/relay_client_impl.dart';

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
}

/// Setup RelayClient and AgentRepository for a specific config
/// This is called when user pairs with a relay
void setupRelayServices(PairConfig config, {RelayClient Function(PairConfig)? clientFactory}) {
  // Unregister old instances if they exist
  if (getIt.isRegistered<AgentRepository>()) {
    final oldRepo = getIt<AgentRepository>();
    oldRepo.close();
    getIt.unregister<AgentRepository>();
  }
  if (getIt.isRegistered<RelayClient>()) {
    getIt.unregister<RelayClient>();
  }

  // Register new RelayClient (layered implementation by default; widget tests
  // inject a FakeRelayClient via clientFactory).
  final client = (clientFactory ?? RelayClientImpl.new)(config);
  getIt.registerSingleton<RelayClient>(client);

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
}
