import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'transport.dart';

/// Exponential-backoff reconnect loop, shared by every [Transport]
/// implementation (WebSocket now, HTTP/gRPC later).
///
/// Delays follow the legacy client behavior: 1, 2, 4, … up to
/// [maxReconnectDelay] (30 s). Only one reconnect timer exists at a time, and
/// the host must call [markConnected] on a successful connect and
/// [stopReconnects] from `close()`.
///
/// The host (any [Transport]) implements three members:
/// - [reconnectNow] — opens a fresh connection;
/// - [isClosed] — true once the host is closed;
/// - [status] — the host's connection status (from [Transport]).
mixin ReconnectMixin {
  Timer? _reconnectTimer;
  int _attempt = 0;
  bool _reconnectPaused = false;

  /// Upper bound for the exponential backoff.
  static const Duration maxReconnectDelay = Duration(seconds: 30);

  /// True once the transport has been closed; stops all reconnects.
  bool get isClosed;

  /// The transport's connection status.
  ValueNotifier<ConnectionStatus> get status;

  /// Opens a fresh connection. Implemented by the host.
  Future<void> reconnectNow();

  /// Plans a reconnect unless one is already scheduled, the transport is
  /// closed, or reconnects are paused.
  void scheduleReconnect() {
    if (isClosed || _reconnectTimer != null || _reconnectPaused) return;
    final seconds = min(pow(2, _attempt).toInt(), maxReconnectDelay.inSeconds);
    _attempt++;
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
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

  @override
  void pause() {
    _reconnectPaused = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  @override
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
