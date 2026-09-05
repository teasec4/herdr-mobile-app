import 'package:client/controllers/agents_store.dart';
import 'package:client/controllers/app_session_controller.dart';
import 'package:client/controllers/attention_store.dart';
import 'package:client/controllers/modes_controller.dart';
import 'package:client/controllers/session_controller.dart';
import 'package:client/core/connection/mode_service.dart';
import 'package:client/core/service_locator.dart';
import 'package:client/models/pair_config.dart';
import 'package:client/repositories/agent_repository.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/command_history_service.dart';
import 'package:client/services/config_store.dart';
import 'package:client/services/relay_client.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_relay_client.dart';

/// Setup test dependencies with a fake relay client
///
/// [prefsSeed] pre-seeds SharedPreferences (e.g. to restore app settings in a
/// specific state).
Future<void> setupTestDependencies(
  FakeRelayClient fakeClient,
  PairConfig config, {
  Map<String, Object> prefsSeed = const {},
}) async {
  // Reset GetIt
  if (GetIt.instance.isRegistered<AgentRepository>()) {
    await GetIt.instance.reset();
  }

  // Register SharedPreferences
  SharedPreferences.setMockInitialValues(prefsSeed);
  final prefs = await SharedPreferences.getInstance();
  getIt.registerSingleton<SharedPreferences>(prefs);

  // Register ConfigStore
  getIt.registerSingleton<ConfigStore>(ConfigStore());

  // Register services
  getIt.registerSingleton<CommandHistoryService>(
    CommandHistoryService(getIt<SharedPreferences>()),
  );
  getIt.registerSingleton<ModeService>(ModeService());
  // Mirrors production wiring: modes live in a global controller.
  getIt.registerSingleton<ModesController>(
    ModesController(getIt<ModeService>().fetch),
  );
  getIt.registerSingleton<AppSettings>(
    AppSettings(getIt<SharedPreferences>()),
  );
  // Root app session (mirrors production wiring: global, survives relay
  // teardown).
  getIt.registerSingleton<AppSessionController>(AppSessionController());

  // Register fake client
  getIt.registerSingleton<RelayClient>(fakeClient);

  // Register AgentRepository
  getIt.registerSingleton<AgentRepository>(
    AgentRepository(getIt<RelayClient>(), getIt<AppSettings>()),
  );

  // Single source of truth for agent/workspace status (mirrors production
  // wiring).
  getIt.registerSingleton<AgentsStore>(
    AgentsStore(getIt<AgentRepository>()),
  );

  // Shared session state for the Spaces/Run tabs (mirrors production wiring).
  getIt.registerSingleton<SessionController>(
    SessionController(getIt<RelayClient>(), getIt<AgentsStore>()),
  );

  // Finished-while-away attention tracking (mirrors production wiring).
  getIt.registerSingleton<AttentionStore>(
    AttentionStore(
      getIt<AgentRepository>(),
      getIt<AgentsStore>(),
      getIt<AppSettings>(),
    ),
  );
}

/// Cleanup test dependencies
Future<void> teardownTestDependencies() async {
  if (getIt.isRegistered<SessionController>()) {
    getIt<SessionController>().dispose();
  }
  if (getIt.isRegistered<AttentionStore>()) {
    getIt<AttentionStore>().dispose();
  }
  if (getIt.isRegistered<AgentsStore>()) {
    getIt<AgentsStore>().dispose();
  }
  if (getIt.isRegistered<AppSessionController>()) {
    getIt<AppSessionController>().dispose();
  }
  await GetIt.instance.reset();
}
