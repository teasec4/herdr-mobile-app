import 'dart:io';

/// Real probe (VM/Android/iOS/macOS/desktop): the flutter test runner sets
/// `FLUTTER_TEST` for the test VM, so long-lived timers can be suppressed in
/// widget tests that never tear their services down.
bool get isFlutterTestEnvironment =>
    Platform.environment.containsKey('FLUTTER_TEST');
