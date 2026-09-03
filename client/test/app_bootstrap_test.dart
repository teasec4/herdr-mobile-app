import 'dart:convert';

import 'package:client/controllers/app_session_controller.dart';
import 'package:client/core/service_locator.dart';
import 'package:client/main.dart';
import 'package:client/models/pair_config.dart';
import 'package:client/pages/home_page.dart';
import 'package:client/pages/pair_page.dart';
import 'package:client/services/config_store.dart';
import 'package:client/services/notification_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_notification_api.dart';
import 'fakes/fake_relay_client.dart';
import 'test_helper.dart';

/// ConfigStore whose restore blows up — proves a storage failure cannot hang
/// the splash screen.
class ThrowingConfigStore extends ConfigStore {
  @override
  Future<PairConfig?> loadActive() async => throw Exception('storage failure');
}

/// App-level cold start. These cover the "does the splash ever stick?" class
/// of bugs: whatever the storage/restore does, the app must always land on a
/// real screen — the scanner when there is no active relay, HomePage when there
/// is one. A thrown error in the restore path must not leave the full-screen
/// spinner up forever (regression: `_bootstrap` had no try/catch).
void main() {
  late FakeRelayClient client;

  final config = PairConfig.fromLink(
    'herdrelay://pair?host=192.168.1.5&port=8375&mode=lan'
    '&token=abcdef0123456789',
  );

  setUp(() {
    client = FakeRelayClient();
  });

  tearDown(() async {
    await teardownTestDependencies();
  });

  /// Minimal wiring for the "restore throws" case: the shared AppSession
  /// Controller resolves its ConfigStore lazily-ish at construction, so the
  /// throwing store must be registered before the controller is created.
  Future<void> setupWithThrowingConfigStore() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    getIt.registerSingleton<SharedPreferences>(prefs);
    getIt.registerSingleton<ConfigStore>(ThrowingConfigStore());
    getIt.registerSingleton<AppSessionController>(AppSessionController());
  }

  testWidgets('свежая установка без сессии → сканер, спиннера нет',
      (tester) async {
    await setupTestDependencies(client, config); // пустые prefs
    await tester.pumpWidget(HerdrMobileApp(clientFactory: (_) => client));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(PairPage), findsOneWidget);
  });

  testWidgets('есть сохранённая сессия → HomePage, спиннера нет',
      (tester) async {
    await setupTestDependencies(
      client,
      config,
      prefsSeed: {
        'pair_profiles': jsonEncode([config.toJson()]),
        'active_profile': config.profileKey,
      },
    );
    // setupRelayServices создаёт NotificationService, которому нужен API.
    getIt.registerSingleton<NotificationApi>(FakeNotificationApi());
    await tester.pumpWidget(HerdrMobileApp(clientFactory: (_) => client));
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(HomePage), findsOneWidget);
  });

  testWidgets('ошибка при восстановлении сессии → спиннер снимается, сканер',
      (tester) async {
    await setupWithThrowingConfigStore();
    await tester.pumpWidget(HerdrMobileApp(clientFactory: (_) => client));
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(PairPage), findsOneWidget);
  });
}
