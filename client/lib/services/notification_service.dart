import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/relay_event.dart';
import '../repositories/agent_repository.dart';
import '../services/app_settings.dart';
import 'notification_api.dart';

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
    _api.init(onTap: _handleTap);
    if (_settings.notificationsEnabled) {
      _api.requestPermission();
    }
  }

  /// Unsubscribes; idempotent.
  void stop() {
    if (_eventSub == null) return;
    WidgetsBinding.instance.removeObserver(this);
    _eventSub?.cancel();
    _eventSub = null;
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

  bool get _inBackground => _lifecycle != AppLifecycleState.resumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
  }
}
