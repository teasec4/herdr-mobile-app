# Connection Layer

## Purpose
Orchestrates the connection outside of Transport and Protocol: app-lifecycle
handling (pause reconnects in background, resume in foreground) and retry
policies that can be swapped per deployment without touching the other layers
(docs/09-refactoring-plan.md §2.4). Future homes: HTTP fallback when WS fails
N times, feature-flagged transport switching.

## Dependencies
- `flutter/widgets` (WidgetsBindingObserver)
- `core/transport/transport.dart`

## API
```dart
abstract class RetryPolicy {
  bool shouldRetry(int attempt, Object error);
  Duration nextDelay(int attempt);
}
class ExponentialBackoff implements RetryPolicy { /* 1, 2, 4, … 30 s */ }
class FixedDelay      implements RetryPolicy { /* constant delay */ }

class ConnectionManager with WidgetsBindingObserver {
  ConnectionManager(Transport transport, RetryPolicy retryPolicy);
  @override void didChangeAppLifecycleState(AppLifecycleState state);
  void dispose();  // removes the lifecycle observer
}
```

## Usage
```dart
final transport = WebSocketTransport();
final manager = ConnectionManager(transport, ExponentialBackoff());
getIt.registerSingleton<ConnectionManager>(manager);
// manager.dispose() on teardown (see core/service_locator.dart)
```

## Testing
- `test/core/transport/retry_policy_test.dart` — delay schedules, caps.
- `test/core/connection/connection_manager_test.dart` — lifecycle translation
  via `WidgetsBinding.instance.handleAppLifecycleStateChanged`, observer
  removal on dispose.
