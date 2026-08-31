import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Launch data of a notification tap that started the app (cold start).
class NotificationLaunchDetailsData {
  const NotificationLaunchDetailsData({
    required this.launchedFromNotification,
    this.paneId,
  });

  /// Whether the app was launched by tapping a notification.
  final bool launchedFromNotification;

  /// Agent pane id carried in the payload, or null.
  final String? paneId;
}

/// Thin, testable facade over the local-notifications plugin.
///
/// `NotificationService` talks to this interface instead of the plugin so
/// unit tests can substitute a fake (see `test/fakes/fake_notification_api`).
/// Everything platform-specific (channels, permissions, payload parsing)
/// lives here; on unsupported platforms the methods degrade to no-ops.
abstract class NotificationApi {
  /// One-shot plugin initialization. [onTap] receives the notification
  /// payload (the agent pane id) when a notification is tapped; also called
  /// on cold start if the app was launched from a notification.
  Future<void> init({required void Function(String paneId) onTap});

  /// Asks the OS for notification permission (Android 13+ / iOS / macOS).
  /// Returns whether permission is granted (may be null on desktop/web).
  Future<bool?> requestPermission();

  /// Shows the "agent blocked" notification.
  Future<void> showBlocked(String paneId, String agentName);

  /// Whether this launch came from a notification tap, and its payload.
  Future<NotificationLaunchDetailsData?> getLaunchDetails();
}

/// Production [NotificationApi] backed by `flutter_local_notifications`.
class LocalNotificationsApi implements NotificationApi {
  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  LocalNotificationsApi([FlutterLocalNotificationsPlugin? plugin])
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  /// Channel for blocked-agent alerts (Android 8+).
  static const AndroidNotificationChannel _blockedChannel =
      AndroidNotificationChannel(
    'blocked_agents',
    'Blocked agents',
    description: 'Alerts when an agent needs your response',
    importance: Importance.high,
  );

  @override
  Future<void> init({required void Function(String paneId) onTap}) async {
    if (_initialized) return;
    if (kIsWeb) return; // Local notifications are a no-op on the web.

    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const darwin = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      const linux = LinuxInitializationSettings(defaultActionName: 'Open');
      const settings = InitializationSettings(
        android: android,
        iOS: darwin,
        macOS: darwin,
        linux: linux,
      );

      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: (response) {
          final paneId = _payloadOf(response);
          if (paneId != null) onTap(paneId);
        },
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(_blockedChannel);
    } catch (_) {
      // Plugin unavailable (widget tests, unsupported host): degrade to a
      // no-op so app flow is never blocked by notification setup.
    }
    // Mark initialized either way so we never retry a failed setup.
    _initialized = true;
  }

  /// Extracts the agent pane id from a payload; returns null on garbage.
  String? _payloadOf(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return null;
    return payload;
  }

  @override
  Future<bool?> requestPermission() async {
    if (kIsWeb) return true;
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        return android.requestNotificationsPermission();
      }
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) {
        return ios
            .requestPermissions(alert: true, badge: true, sound: true)
            .then((v) => v ?? false);
      }
      final macos = _plugin.resolvePlatformSpecificImplementation<
          MacOSFlutterLocalNotificationsPlugin>();
      if (macos != null) {
        return macos
            .requestPermissions(alert: true, badge: true, sound: true)
            .then((v) => v ?? false);
      }
      // Desktop Linux/Windows and web: permission is implicit or unsupported.
      return true;
    } catch (_) {
      return true; // Plugin unavailable: treat permission as implicitly granted.
    }
  }

  @override
  Future<void> showBlocked(String paneId, String agentName) async {
    if (!_initialized) return; // init is a no-op on unsupported platforms
    await _plugin.show(
      id: paneId.hashCode, // stable per pane; replaces a stale notification
      title: 'Agent blocked',
      body: '$agentName is waiting for your response',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _blockedChannel.id,
          _blockedChannel.name,
          channelDescription: _blockedChannel.description,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(presentAlert: true, presentSound: true),
        macOS: const DarwinNotificationDetails(presentAlert: true, presentSound: true),
      ),
      payload: paneId,
    );
  }

  @override
  Future<NotificationLaunchDetailsData?> getLaunchDetails() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) {
      return null;
    }
    final paneId = details.notificationResponse?.payload;
    return NotificationLaunchDetailsData(
      launchedFromNotification: true,
      paneId: (paneId == null || paneId.isEmpty) ? null : paneId,
    );
  }
}