import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/relay_agent.dart';
import '../models/relay_event.dart';
import '../repositories/agent_repository.dart';
import '../services/app_settings.dart';
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
class NotificationService with WidgetsBindingObserver {
  NotificationService(this._repository, this._settings, this._api);

  final AgentRepository _repository;
  final AppSettings _settings;
  final NotificationApi _api;

  StreamSubscription<RelayEvent>? _eventSub;
  final Set<String> _notifiedPaneIds = {};
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  /// Called with the agent pane id when the user taps a notification.
  void Function(String paneId)? onOpenAgent;

  /// Subscribes to agent events and the app lifecycle. Must be called once
  /// (from service registration); idempotent.
  void start() {
    if (_eventSub != null) return;
    WidgetsBinding.instance.addObserver(this);
    _eventSub = _repository.events.listen(_onEvent);
    _repository.status.addListener(_onConnectionStatus);
    _api.init(onTap: _handleTap);
    if (_settings.notificationsEnabled) {
      _api.requestPermission();
    }
    // Already backgrounded at start (e.g. service re-created while paused):
    // sync from the snapshot so blocked agents notify even with no new events.
    if (_inBackground) _syncFromSnapshot();
  }

  /// Unsubscribes; idempotent.
  void stop() {
    if (_eventSub == null) return;
    WidgetsBinding.instance.removeObserver(this);
    _eventSub?.cancel();
    _eventSub = null;
    _repository.status.removeListener(_onConnectionStatus);
    _notifiedPaneIds.clear();
  }

  void _handleTap(String paneId) {
    onOpenAgent?.call(paneId);
  }

  void _onEvent(RelayEvent event) {
    if (event is! AgentStatusChanged) return;
    if (event.status.toLowerCase() == 'blocked') {
      if (!_settings.notificationsEnabled) return;
      if (!_inBackground) return;
      if (_notifiedPaneIds.add(event.paneId)) {
        _api.showBlocked(event.paneId, event.agent);
      }
    } else {
      // Left the blocked state: allow a future notification for this pane.
      _notifiedPaneIds.remove(event.paneId);
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
    for (final agent in agents) {
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    if (_inBackground) _syncFromSnapshot();
  }
}
