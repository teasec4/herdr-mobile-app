import 'package:client/controllers/session_controller.dart';
import 'package:client/core/connection/mode_service.dart';
import 'package:client/core/service_locator.dart';
import 'package:client/models/pair_config.dart';
import 'package:client/repositories/agent_repository.dart';
import 'package:client/services/action_parser_service.dart';
import 'package:client/services/command_history_service.dart';
import 'package:client/services/config_store.dart';
import 'package:client/services/relay_client.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_relay_client.dart';

/// Setup test dependencies with a fake relay client
Future<void> setupTestDependencies(FakeRelayClient fakeClient, PairConfig config) async {
  // Reset GetIt
  if (GetIt.instance.isRegistered<AgentRepository>()) {
    await GetIt.instance.reset();
  }

  // Register SharedPreferences
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  getIt.registerSingleton<SharedPreferences>(prefs);

  // Register ConfigStore
  getIt.registerSingleton<ConfigStore>(ConfigStore());

  // Register services
  getIt.registerSingleton<CommandHistoryService>(
    CommandHistoryService(getIt<SharedPreferences>()),
  );
  getIt.registerSingleton<ActionParserService>(ActionParserService());
  getIt.registerSingleton<ModeService>(ModeService());

  // Register fake client
  getIt.registerSingleton<RelayClient>(fakeClient);

  // Register AgentRepository
  getIt.registerSingleton<AgentRepository>(
    AgentRepository(getIt<RelayClient>(), getIt<SharedPreferences>()),
  );

  // Shared session state for the Spaces/Run tabs (mirrors production wiring).
  getIt.registerSingleton<SessionController>(
    SessionController(getIt<RelayClient>()),
  );
}

/// Cleanup test dependencies
Future<void> teardownTestDependencies() async {
  if (getIt.isRegistered<SessionController>()) {
    getIt<SessionController>().dispose();
  }
  await GetIt.instance.reset();
}
