import 'package:client/services/notification_api.dart';

/// Fake [NotificationApi] for unit/widget tests: no plugin, records calls and
/// lets tests drive the tap callback.
class FakeNotificationApi implements NotificationApi {
  /// Recorded `showBlocked(paneId, agentName)` calls.
  final List<(String, String)> shown = [];

  /// Recorded `showFinished(paneId, agentName)` calls.
  final List<(String, String)> finished = [];

  /// Recorded `requestPermission()` calls.
  int permissionRequests = 0;

  /// Last `init` tap callback, set by `init()`.
  void Function(String paneId)? onTap;

  /// What `getLaunchDetails()` returns (null = not launched from a notification).
  NotificationLaunchDetailsData? launchDetails;

  bool _initialized = false;

  @override
  Future<void> init({required void Function(String paneId) onTap}) async {
    _initialized = true;
    this.onTap = onTap;
  }

  @override
  Future<bool?> requestPermission() async {
    permissionRequests++;
    return true;
  }

  @override
  Future<void> showBlocked(String paneId, String agentName) async {
    shown.add((paneId, agentName));
  }

  @override
  Future<void> showFinished(String paneId, String agentName) async {
    finished.add((paneId, agentName));
  }

  @override
  Future<NotificationLaunchDetailsData?> getLaunchDetails() async {
    return launchDetails;
  }

  /// Simulates the user tapping the notification for [paneId].
  void tap(String paneId) => onTap?.call(paneId);

  /// Whether `init()` has been called.
  bool get initialized => _initialized;
}
