import 'package:client/models/relay_event.dart';
import 'package:client/repositories/agent_repository.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_notification_api.dart';
import '../fakes/fake_relay_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRelayClient client;
  late AgentRepository repository;
  late AppSettings settings;
  late FakeNotificationApi api;
  late NotificationService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    settings = AppSettings(prefs);
    client = FakeRelayClient();
    repository = AgentRepository(client, settings);
    api = FakeNotificationApi();
    service = NotificationService(repository, settings, api);
    service.start();
    // Flush the async broadcast delivery of the init/permission calls.
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() {
    service.stop();
  });

  /// Puts the app in the given lifecycle state (observers are notified).
  void setLifecycle(AppLifecycleState state) {
    WidgetsBinding.instance.handleAppLifecycleStateChanged(state);
  }

  /// Backgrounds the app, emits a blocked event, and flushes the stream.
  Future<void> blockedInBackground(String paneId, {String agent = ''}) async {
    setLifecycle(AppLifecycleState.paused);
    client.emit(AgentStatusChanged(paneId: paneId, status: 'blocked', agent: agent));
    await Future<void>.delayed(Duration.zero);
  }

  group('NotificationService', () {
    test('blocked in background shows one notification per pane',
        () async {
      await blockedInBackground('p1', agent: 'codex');
      expect(api.shown, [('p1', 'codex')]);

      // Second blocked event for the same pane must not re-notify.
      client.emit(AgentStatusChanged(paneId: 'p1', status: 'blocked'));
      await Future<void>.delayed(Duration.zero);
      expect(api.shown.length, 1);
    });

    test('no notification while the app is in the foreground',
        () async {
      setLifecycle(AppLifecycleState.resumed);
      client.emit(AgentStatusChanged(paneId: 'p1', status: 'blocked'));
      await Future<void>.delayed(Duration.zero);
      expect(api.shown, isEmpty);
    });

    test('leaving the blocked state re-arms the pane', () async {
      await blockedInBackground('p1');
      expect(api.shown.length, 1);

      client.emit(AgentStatusChanged(paneId: 'p1', status: 'idle'));
      await Future<void>.delayed(Duration.zero);
      await blockedInBackground('p1');
      expect(api.shown.length, 2, reason: 're-blocking should notify again');
    });

    test('disabled setting suppresses notifications', () async {
      settings.setNotificationsEnabled(false);
      await blockedInBackground('p1');
      expect(api.shown, isEmpty);
    });

    test('requestPermission is asked on start when enabled',
        () async {
      expect(api.permissionRequests, 1);
    });

    test('no permission request when notifications are disabled', () async {
      SharedPreferences.setMockInitialValues(
          {AppSettings.kNotificationsEnabled: false});
      final prefs = await SharedPreferences.getInstance();
      final disabled = AppSettings(prefs);
      final api2 = FakeNotificationApi();
      final s = NotificationService(repository, disabled, api2);
      s.start();
      await Future<void>.delayed(Duration.zero);
      expect(api2.permissionRequests, 0);
      s.stop();
    });

    test('tap delivers the pane id to onOpenAgent', () async {
      String? opened;
      service.onOpenAgent = (paneId) => opened = paneId;
      api.tap('p1');
      expect(opened, 'p1');
    });

    test('start is idempotent', () async {
      final before = api.permissionRequests;
      service.start(); // second call must be a no-op
      await Future<void>.delayed(Duration.zero);
      expect(api.permissionRequests, before);
    });
  });
}
