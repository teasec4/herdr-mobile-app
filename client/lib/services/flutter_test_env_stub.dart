/// Compile-time safe probe for the `flutter test` VM.
///
/// `dart:io` is unavailable on the web target, so the real check lives in
/// `flutter_test_env_io.dart` (selected when `dart.library.io` is available);
/// everywhere else this stub reports false. Kept in its own library so
/// [notification_service] can gate long-lived timers that would otherwise
/// trip the widget-test "pending timers" invariant.
bool get isFlutterTestEnvironment => false;
