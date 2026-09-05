import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/relay_agent.dart';
import '../models/relay_event.dart';
import '../repositories/agent_repository.dart';
import '../services/app_settings.dart';
import 'background_blocked_watch.dart';
import 'flutter_test_env_stub.dart' if (dart.library.io) 'flutter_test_env_io.dart'
    as flutter_test_env;
import 'notification_api.dart';
import 'relay_client.dart';

/// Shows local notifications when an agent becomes blocked while the app is
/// not in the foreground (backgrounded or phone locked), so the user can
/// resolve the blocker from the agent.
///
/// Rules:
///   - only fires when the app is NOT `resumed` (per product decision);
///   - respects [AppSettings.notificationsEnabled];
///   - one notification per pane while it stays blocked (dedup), cleared
///     (allowed to fire again) once the agent leaves the blocked state;
///   - tapping the notification opens the agent pane via [onOpenAgent].
///
/// The live event stream is the fast path, but events received while offline
/// are lost — so on reconnect, and whenever the app drops into the
/// background, the agent snapshot is re-read and any pane blocked in the
/// meantime is notified from there ([_syncFromSnapshot]).
///
/// Long-background coverage (the OS suspended/killed the process) is handled
/// by the periodic WorkManager task ([registerBackgroundWatch]) which
/// re-checks the relay snapshot from a background isolate. While this service
/// is active it keeps a foreground heartbeat fresh so the background task
/// stays quiet (no duplicate notifications). [syncBackgroundWatch] is called
/// with the current notifications toggle so production wiring can
/// register/cancel that task; tests leave it null (disabled).
class NotificationService with WidgetsBindingObserver {
  NotificationService(
    this._repository,
    this._settings,
    this._api, {
    this.syncBackgroundWatch,
  });

  final AgentRepository _repository;
  final AppSettings _settings;
  final NotificationApi _api;

  /// Called with `notificationsEnabled` on start and whenever the setting
  /// changes; production wiring registers/cancels the WorkManager task.
  final Future<void> Function(bool enabled)? syncBackgroundWatch;

  StreamSubscription<RelayEvent>? _eventSub;
  final Set<String> _notifiedPaneIds = {};

  /// pane_id -> last status seen via events/snapshots, used to recognize a
  /// finish (`working → done/idle`) and to re-arm per pane after it leaves
  /// the finished state.
  final Map<String, String> _lastStatus = {};

  /// Pane ids already notified about "finished while you were away"; cleared
  /// when the pane's agent starts working again (allows one notification per
  /// finish).
  final Set<String> _finishedNotifiedPaneIds = {};
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;
  Timer? _heartbeatTimer;
  DateTime? _lastHeartbeat;

  /// Called with the agent pane id when the user taps a notification.
  void Function(String paneId)? onOpenAgent;

  /// Subscribes to agent events and the app lifecycle. Must be called once
  /// (from service registration); idempotent.
  void start() {
    if (_eventSub != null) return;
    WidgetsBinding.instance.addObserver(this);
    _settings.addListener(_onSettingsChanged);
    _eventSub = _repository.events.listen(_onEvent);
    _repository.status.addListener(_onConnectionStatus);
    _api.init(onTap: _handleTap);
    if (_settings.notificationsEnabled) {
      _api.requestPermission();
    }
    _syncBackgroundWatch();
    _updateHeartbeatTimer();
    // Already backgrounded at start (e.g. service re-created while paused):
    // sync from the snapshot so blocked agents notify even with no new events.
    if (_inBackground) _syncFromSnapshot();
  }

  /// Unsubscribes; idempotent. The WorkManager task itself is app-scoped and
  /// is left alone here (it is only cancelled when the notifications setting
  /// is turned off, via [_onSettingsChanged]).
  void stop() {
    if (_eventSub == null) return;
    WidgetsBinding.instance.removeObserver(this);
    _settings.removeListener(_onSettingsChanged);
    _eventSub?.cancel();
    _eventSub = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _repository.status.removeListener(_onConnectionStatus);
    _notifiedPaneIds.clear();
    _finishedNotifiedPaneIds.clear();
  }

  void _onSettingsChanged() {
    _syncBackgroundWatch();
    _updateHeartbeatTimer();
  }

  void _syncBackgroundWatch() {
    syncBackgroundWatch?.call(_settings.notificationsEnabled);
  }

  void _handleTap(String paneId) {
    onOpenAgent?.call(paneId);
  }

  void _onEvent(RelayEvent event) {
    if (event is! AgentStatusChanged) return;
    final paneId = event.paneId;
    final status = event.status.toLowerCase();
    final prev = _lastStatus[paneId];
    _lastStatus[paneId] = status;

    if (_settings.notificationsEnabled) {
      // Activity while the app is in use keeps the background task quiet.
      _touchForegroundHeartbeat();
    }
    if (status == 'blocked') {
      if (!_settings.notificationsEnabled) return;
      if (!_inBackground) return;
      if (_notifiedPaneIds.add(paneId)) {
        _api.showBlocked(paneId, event.agent);
      }
      return;
    }
    // Left the blocked state: allow a future notification for this pane.
    _notifiedPaneIds.remove(paneId);
    if (!_settings.notificationsEnabled) return;

    if (prev == 'working' && (status == 'done' || status == 'idle')) {
      // The agent finished while the user was away: one quiet notification per
      // finish (dedup until the agent starts working again).
      if (_inBackground && _finishedNotifiedPaneIds.add(paneId)) {
        _api.showFinished(paneId, event.agent);
      }
    } else if (status == 'working' || status == 'blocked') {
      // The agent is active again: allow a future finish notification.
      _finishedNotifiedPaneIds.remove(paneId);
    }
  }

  /// Re-reads the agent snapshot and notifies for every pane blocked since
  /// the last check. Offline gaps are covered by the reconnect call, missed
  /// background blocks by the lifecycle call; both are idempotent per pane
  /// (the [_notifiedPaneIds] dedup applies to this path too).
  Future<void> _syncFromSnapshot() async {
    if (!_settings.notificationsEnabled) return;
    if (!_inBackground) return;
    final List<RelayAgent> agents;
    try {
      agents = await _repository.getAgents();
    } catch (_) {
      return; // offline, no cache — the next connected status will retry
    }
    _touchForegroundHeartbeat();
    for (final agent in agents) {
      // Seed the last-status map from the snapshot so a finish that happens
      // right after (re)connect is recognized (prev = working).
      _lastStatus[agent.id] = agent.status.toLowerCase();
      if (agent.isBlocked) {
        if (_notifiedPaneIds.add(agent.id)) {
          _api.showBlocked(agent.id, agent.agent);
        }
      } else {
        // Left the blocked state: allow a future notification for this pane.
        _notifiedPaneIds.remove(agent.id);
      }
    }
  }

  void _onConnectionStatus() {
    if (_repository.status.value == RelayStatus.connected) _syncFromSnapshot();
  }

  bool get _inBackground => _lifecycle != AppLifecycleState.resumed;

  /// While the app is foregrounded (and notifications are on) the heartbeat
  /// timer keeps the WorkManager background task from double-notifying. The
  /// task itself also stays quiet for [heartbeatFreshWindow] after the last
  /// heartbeat, covering the brief backgrounded-but-alive window.
  ///
  /// The timer is skipped under `flutter test` (env probe): DI-constructed
  /// services in widget tests are never torn down, and a pending periodic
  /// timer would trip the binding's timer invariant.
  void _updateHeartbeatTimer() {
    final active = !_inBackground &&
        _settings.notificationsEnabled &&
        !flutter_test_env.isFlutterTestEnvironment;
    if (active) {
      _heartbeatTimer ??= Timer.periodic(
        const Duration(seconds: 30),
        (_) => _touchForegroundHeartbeat(),
      );
    } else {
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
    }
  }

  /// Writes the foreground heartbeat (throttled).
  void _touchForegroundHeartbeat() {
    final now = DateTime.now();
    if (_lastHeartbeat != null &&
        now.difference(_lastHeartbeat!) < const Duration(seconds: 10)) {
      return;
    }
    _lastHeartbeat = now;
    // ignore: discarded_futures
    touchForegroundHeartbeat();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _updateHeartbeatTimer();
    if (_inBackground) _syncFromSnapshot();
  }
}
