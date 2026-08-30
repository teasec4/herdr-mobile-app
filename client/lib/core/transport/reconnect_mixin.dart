import 'dart:async';

import 'package:flutter/foundation.dart';

import 'retry_policy.dart';
import 'transport.dart';

/// Reconnect loop, shared by every [Transport] implementation (WebSocket now,
/// HTTP/gRPC later). The delay schedule comes from a [RetryPolicy] — the
/// default [ExponentialBackoff] reproduces the legacy client behavior
/// (1 s, 2 s, 4 s, … up to 30 s). Only one reconnect timer exists at a time,
/// and the host must call [markConnected] on a successful connect and
/// [stopReconnects] from `close()`.
///
/// The host (any [Transport]) implements four members:
/// - [reconnectNow] — opens a fresh connection;
/// - [retryPolicy] — the delay schedule;
/// - [isClosed] — true once the host is closed;
/// - [status] — the host's connection status (from [Transport]).
mixin ReconnectMixin {
  Timer? _reconnectTimer;
  int _attempt = 0;
  bool _reconnectPaused = false;

  /// True once the transport has been closed; stops all reconnects.
  bool get isClosed;

  /// The transport's connection status.
  ValueNotifier<ConnectionStatus> get status;

  /// Delay schedule for reconnects (host-provided).
  RetryPolicy get retryPolicy;

  /// Opens a fresh connection. Implemented by the host.
  Future<void> reconnectNow();

  /// Plans a reconnect unless one is already scheduled, the transport is
  /// closed, or reconnects are paused.
  void scheduleReconnect() {
    if (isClosed || _reconnectTimer != null || _reconnectPaused) return;
    final delay = retryPolicy.nextDelay(_attempt);
    _attempt++;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      reconnectNow();
    });
  }

  /// Resets the backoff counter; call after a successful connect.
  void markConnected() {
    _attempt = 0;
  }

  /// Whether a reconnect is currently scheduled (used to dedupe
  /// disconnect notifications: `onDone` and `onError` can both fire).
  bool get hasScheduledReconnect => _reconnectTimer != null;

  /// Pauses the reconnect loop; see [Transport.pause].
  void pause() {
    _reconnectPaused = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// Resumes the reconnect loop; see [Transport.resume].
  void resume() {
    _reconnectPaused = false;
    if (!isClosed && status.value != ConnectionStatus.connected) {
      scheduleReconnect();
    }
  }

  /// Cancels any pending reconnect; call from the host's `close()`.
  void stopReconnects() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }
}
