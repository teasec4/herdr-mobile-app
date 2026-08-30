import 'package:flutter/widgets.dart';

import '../transport/transport.dart';
import 'retry_policy.dart';

/// Orchestrates the connection across the app lifecycle
/// (docs/09-refactoring-plan.md §2.4).
///
/// Observes [AppLifecycleState]: on `paused`/`hidden` it pauses the
/// transport's reconnect loop (iOS suspends sockets ~30 s after backgrounding;
/// a reconnect loop would drain battery), on `resumed` it resumes it. This
/// logic previously lived in `main.dart`; the app only wires this class up via
/// the service locator and never talks lifecycle itself.
///
/// The [RetryPolicy] is held here (and passed to the transport) so policies
/// can be swapped per deployment without touching Transport or Protocol.
class ConnectionManager with WidgetsBindingObserver {
  ConnectionManager(this.transport, this.retryPolicy) {
    WidgetsBinding.instance.addObserver(this);
  }

  final Transport transport;
  final RetryPolicy retryPolicy;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        transport.pause();
      case AppLifecycleState.resumed:
        transport.resume();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Removes the lifecycle observer; call when the relay services are torn
  /// down (e.g. on device switch).
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }
}
