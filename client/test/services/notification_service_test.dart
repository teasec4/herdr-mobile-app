import 'package:client/models/relay_agent.dart';
import 'package:client/models/relay_event.dart';
import 'package:client/repositories/agent_repository.dart';
import 'package:client/services/app_settings.dart';
import 'package:client/services/notification_service.dart';
import 'package:client/services/relay_client.dart';
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

    test('reconnect with a blocked snapshot notifies (offline gap covered)',
        () async {
      // A pane was blocked while offline — the event never arrived. On the
      // next connected status the snapshot re-read must fire the notification.
      setLifecycle(AppLifecycleState.paused);
      client.agents = [
        const RelayAgent(id: 'p1', agent: 'codex', status: 'blocked'),
      ];

      // Simulate reconnect: disconnected -> connected.
      client.status.value = RelayStatus.disconnected;
      client.status.value = RelayStatus.connected;
      await Future<void>.delayed(Duration.zero);

      expect(api.shown, [('p1', 'codex')]);
    });

    test('snapshot path is idempotent while the pane stays blocked', () async {
      setLifecycle(AppLifecycleState.paused);
      client.agents = [
        const RelayAgent(id: 'p1', agent: 'codex', status: 'blocked'),
      ];
      client.status.value = RelayStatus.disconnected;
      client.status.value = RelayStatus.connected;
      await Future<void>.delayed(Duration.zero);
      expect(api.shown.length, 1);

      // Another reconnect must not re-notify the still-blocked pane.
      client.status.value = RelayStatus.disconnected;
      client.status.value = RelayStatus.connected;
      await Future<void>.delayed(Duration.zero);
      expect(api.shown.length, 1);
    });

    test('unblocked agent in the snapshot clears its dedup entry', () async {
      setLifecycle(AppLifecycleState.paused);
      client.agents = [
        const RelayAgent(id: 'p1', agent: 'codex', status: 'blocked'),
      ];
      client.status.value = RelayStatus.disconnected;
      client.status.value = RelayStatus.connected;
      await Future<void>.delayed(Duration.zero);
      expect(api.shown.length, 1);

      // The agent left blocked: after a snapshot sync, re-blocking must be
      // allowed to notify again.
      client.agents = [
        const RelayAgent(id: 'p1', agent: 'codex', status: 'idle'),
      ];
      client.status.value = RelayStatus.disconnected;
      client.status.value = RelayStatus.connected;
      await Future<void>.delayed(Duration.zero);
      expect(api.shown.length, 1, reason: 'idle snapshot must not notify');

      client.agents = [
        const RelayAgent(id: 'p1', agent: 'codex', status: 'blocked'),
      ];
      client.status.value = RelayStatus.disconnected;
      client.status.value = RelayStatus.connected;
      await Future<void>.delayed(Duration.zero);
      expect(api.shown.length, 2, reason: 're-blocking should notify again');
    });

    test('background transition re-reads the snapshot', () async {
      // A pane became blocked while the app was already paused (or the event
      // fired during the transition) — the lifecycle change re-reads the
      // snapshot so the notification still fires.
      client.agents = [
        const RelayAgent(id: 'p1', agent: 'codex', status: 'blocked'),
      ];
      setLifecycle(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(api.shown, [('p1', 'codex')]);
    });
  });

  group('finished notifications (done while away)', () {
    /// Backgrounds the app, runs a working -> done transition, flushes.
    Future<void> finishedInBackground(
      String paneId, {
      String agent = '',
    }) async {
      setLifecycle(AppLifecycleState.paused);
      client.emit(
          AgentStatusChanged(paneId: paneId, status: 'working', agent: agent));
      await Future<void>.delayed(Duration.zero);
      client.emit(
          AgentStatusChanged(paneId: paneId, status: 'done', agent: agent));
      await Future<void>.delayed(Duration.zero);
    }

    test('working -> done in the background notifies once per finish',
        () async {
      await finishedInBackground('p1', agent: 'codex');
      expect(api.finished, [('p1', 'codex')]);

      // A second done event (same finish, pane still done) must not re-notify.
      client.emit(AgentStatusChanged(paneId: 'p1', status: 'done'));
      await Future<void>.delayed(Duration.zero);
      expect(api.finished.length, 1);
    });

    test('agent starting work again re-arms the finish notification',
        () async {
      await finishedInBackground('p1');
      expect(api.finished.length, 1);

      // Working again -> done again: a new finish, a new notification.
      client.emit(AgentStatusChanged(paneId: 'p1', status: 'working'));
      await Future<void>.delayed(Duration.zero);
      client.emit(AgentStatusChanged(paneId: 'p1', status: 'done'));
      await Future<void>.delayed(Duration.zero);
      expect(api.finished.length, 2);
    });

    test('no finished notification while the app is in the foreground',
        () async {
      setLifecycle(AppLifecycleState.resumed);
      client.emit(AgentStatusChanged(paneId: 'p1', status: 'working'));
      await Future<void>.delayed(Duration.zero);
      client.emit(AgentStatusChanged(paneId: 'p1', status: 'done'));
      await Future<void>.delayed(Duration.zero);
      expect(api.finished, isEmpty);
    });

    test('blocked -> done is not a finish notification', () async {
      // A blocked agent has its own (urgent) notification; resolving straight
      // to done is not an unseen finish.
      setLifecycle(AppLifecycleState.paused);
      client.emit(AgentStatusChanged(paneId: 'p1', status: 'blocked'));
      await Future<void>.delayed(Duration.zero);
      client.emit(AgentStatusChanged(paneId: 'p1', status: 'done'));
      await Future<void>.delayed(Duration.zero);
      expect(api.finished, isEmpty);
    });

    test('disabled setting suppresses finished notifications', () async {
      settings.setNotificationsEnabled(false);
      await finishedInBackground('p1');
      expect(api.finished, isEmpty);
    });
  });
}
