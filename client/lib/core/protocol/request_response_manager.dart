import 'dart:async';

import '../transport/transport.dart';
import 'relay_exception.dart';
import 'relay_protocol.dart';

/// Request-response matching over a [Transport]: sends request frames with
/// incrementing ids, resolves futures from matching response frames, fails
/// pending requests on disconnect/timeout, and answers server pings.
///
/// This is the whole RPC semantics of the relay protocol, extracted from the
/// legacy `WsRelayClient._request/_onResponse/_failPending/_waitForConnected`
/// (docs/09-refactoring-plan.md §2.2).
///
/// The manager does NOT subscribe to [Transport.messages] itself: the owning
/// [RelayClientImpl] is the single transport subscriber, parses each frame
/// once, surfaces events, and routes everything else here via [handleFrame]
/// (docs/09-refactoring-plan.md §2.3, M2 — one frame parse per message).
class RequestResponseManager {
  /// [requestTimeout] and [connectWait] are injectable for tests
  /// (15 s / 8 s in production).
  RequestResponseManager(
    this._transport, {
    this.requestTimeout = const Duration(seconds: 15),
    this.connectWait = const Duration(seconds: 8),
  }) {
    _transport.status.addListener(_onStatus);
    _statusListener = _onStatus;
  }

  final Transport _transport;
  final Duration requestTimeout;
  final Duration connectWait;

  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _nextId = 1;
  late final void Function() _statusListener;

  /// Sends a request and waits for the matching response.
  ///
  /// Throws [RelayException] with `not_connected` if the transport is not
  /// connected (after a short cold-start wait), `timeout` if the relay does
  /// not answer within [requestTimeout], or the relay's own error code.
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (_transport.status.value != ConnectionStatus.connected) {
      // Give the transport a moment to (re)connect on a cold start instead of
      // failing the first operation instantly.
      await _waitForConnected();
      if (_transport.status.value != ConnectionStatus.connected) {
        throw RelayException(
          'not_connected',
          _transport.lastError ?? 'No connection to relay',
        );
      }
    }

    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _transport.send(RequestFrame(id: id, method: method, params: params).encode());

    final timer = Timer(requestTimeout, () {
      if (_pending.remove(id) != null) {
        completer.completeError(
          const RelayException('timeout', 'Relay did not respond'),
        );
      }
    });

    try {
      return await completer.future;
    } finally {
      timer.cancel();
    }
  }

  /// Handles one raw inbound frame.
  ///
  /// The owning client parses each frame exactly once and routes non-event
  /// frames to [handleFrame]; this entry point exists for callers (and tests)
  /// that only have the raw text — it parses, then delegates.
  void handleMessage(String raw) {
    final Frame frame;
    try {
      frame = Frame.parse(raw);
    } on ProtocolException {
      return; // garbage frame — ignore
    }
    handleFrame(frame);
  }

  /// Routes one already-parsed frame: resolves matching responses, answers
  /// server pings, and ignores events/requests/pongs (events are surfaced to
  /// the UI by RelayClientImpl, not here).
  void handleFrame(Frame frame) {
    switch (frame) {
      case ResponseFrame():
        final completer = _pending.remove(frame.id);
        if (completer == null) return;
        if (frame.ok) {
          completer.complete(frame.result ?? const {});
        } else {
          final err = frame.error ??
              const RelayError(code: 'error', message: 'relay error');
          completer.completeError(
            RelayException(err.code, err.message.isNotEmpty ? err.message : err.code),
          );
        }
      case PingFrame():
        // Server keepalive — answer automatically; upper layers never see it.
        _transport.send(const PongFrame().encode());
      case RequestFrame():
      case EventFrame():
      case PongFrame():
        break;
    }
  }

  void _onStatus() {
    if (_transport.status.value == ConnectionStatus.disconnected) {
      _failPending();
    }
  }

  /// Completes every pending request with `disconnected` (called on
  /// disconnect so callers fail fast instead of waiting for the timeout).
  void _failPending() {
    const err = RelayException('disconnected', 'Relay connection lost');
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(err);
    }
    _pending.clear();
  }

  /// Waits up to [connectWait] for the transport to become connected (the WS
  /// may still be establishing on a cold start / reconnect backoff).
  Future<void> _waitForConnected() async {
    if (_transport.status.value == ConnectionStatus.connected) return;
    final completer = Completer<void>();
    void listener() {
      if (_transport.status.value == ConnectionStatus.connected &&
          !completer.isCompleted) {
        completer.complete();
      }
    }

    _transport.status.addListener(listener);
    try {
      await completer.future.timeout(connectWait, onTimeout: () {});
    } finally {
      _transport.status.removeListener(listener);
    }
  }

  /// Stops listening; call from the owning client's `close()`.
  void dispose() {
    _transport.status.removeListener(_statusListener);
    _failPending();
  }
}
