import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'retry_policy.dart';
import 'reconnect_mixin.dart';
import 'transport.dart';

/// WebSocket [Transport]: raw text frames, auto-reconnect with a [RetryPolicy]
/// (default [ExponentialBackoff]: 1, 2, 4, … 30 s), pause/resume for app
/// lifecycle, and optional keepalive to detect half-dead connections
/// (mobile NATs silently drop idle sockets; docs/10-herdr-api.md, D7).
///
/// Deliberately protocol-agnostic: no JSON parsing, no requests, no events —
/// see docs/09-refactoring-plan.md §2.1. Keepalive is wire-level: it sends a
/// configurable request string (default the relay `ping` frame) and watches
/// for the response string; if none arrives within [keepalivePongTimeout] the
/// connection is treated as dead and reconnected.
class WebSocketTransport with ReconnectMixin implements Transport {
  /// [channelFactory] is injectable for tests: it substitutes a fake
  /// [WebSocketChannel] so reconnect/send/receive can be tested with no real
  /// network. Production uses [WebSocketChannel.connect]. [retryPolicy]
  /// defaults to [ExponentialBackoff].
  ///
  /// Keepalive is on by default (every 20 s, 10 s pong window) — pass
  /// `keepaliveInterval: null` to disable it (tests do).
  WebSocketTransport({
    WebSocketChannel Function(Uri uri)? channelFactory,
    RetryPolicy? retryPolicy,
    this.keepaliveInterval = const Duration(seconds: 20),
    this.keepalivePongTimeout = const Duration(seconds: 10),
    this.keepaliveRequest = '{"type":"ping"}',
    this.keepaliveResponse = '{"type":"pong"}',
  })  : _channelFactory = channelFactory ?? WebSocketChannel.connect,
        retryPolicy = retryPolicy ?? ExponentialBackoff() {
    status = ValueNotifier<ConnectionStatus>(ConnectionStatus.disconnected);
    _messages = StreamController<String>.broadcast();
  }

  final WebSocketChannel Function(Uri uri) _channelFactory;

  @override
  final RetryPolicy retryPolicy;

  /// How often a keepalive request is sent while connected; null disables
  /// keepalive entirely.
  final Duration? keepaliveInterval;

  /// How long to wait for the keepalive response before declaring the
  /// connection dead.
  final Duration keepalivePongTimeout;

  /// Request string sent by keepalive (wire-level; the relay answers pong).
  final String keepaliveRequest;

  /// Response string that satisfies keepalive.
  final String keepaliveResponse;

  @override
  late final ValueNotifier<ConnectionStatus> status;

  late final StreamController<String> _messages;

  @override
  Stream<String> get messages => _messages.stream;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Uri? _uri;
  bool _closed = false;
  Timer? _keepaliveTimer;
  Timer? _pongTimer;
  bool _awaitingPong = false;

  @override
  String? lastError;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> connect(Uri uri) async {
    _uri = uri;
    await reconnectNow();
  }

  @override
  Future<void> reconnectNow() async {
    if (_closed) return;
    final uri = _uri;
    if (uri == null) return;

    // Cancel any previous subscription before opening a new connection, so a
    // stale stream can't deliver messages into the new connection's handlers.
    await _sub?.cancel();
    _sub = null;

    status.value = ConnectionStatus.connecting;
    final ws = _channelFactory(uri);
    _channel = ws;

    try {
      await ws.ready;
      if (_closed) {
        ws.sink.close();
        return;
      }
      markConnected();
      lastError = null;
      status.value = ConnectionStatus.connected;
      _startKeepalive();

      // Single handler for both done and error; cancelOnError stops the stream
      // after the first error so onDone can't fire a second disconnect.
      _sub = ws.stream.listen(
        (data) {
          if (data == keepaliveResponse) {
            _onKeepalivePong();
          }
          if (data is String) _messages.add(data);
        },
        onDone: _onDisconnected,
        onError: (e) {
          lastError = '$e';
          _onDisconnected();
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (_closed) return;
      lastError = '$e';
      ws.sink.close();
      scheduleReconnect();
    }
  }

  void _onDisconnected() {
    if (_closed) return;

    // Prevent duplicate reconnect scheduling: onError and onDone can both fire
    // for a failed stream (unless cancelOnError stops it first).
    if (hasScheduledReconnect) return;

    lastError ??= 'Connection lost';
    _stopKeepalive();
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    status.value = ConnectionStatus.disconnected;
    scheduleReconnect();
  }

  @override
  void send(String data) {
    _channel?.sink.add(data);
  }

  @override
  void pause() {
    super.pause();
    _stopKeepalive();
  }

  @override
  void resume() {
    super.resume();
    if (status.value == ConnectionStatus.connected) {
      _startKeepalive();
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    stopReconnects();
    _stopKeepalive();
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
    status.value = ConnectionStatus.disconnected;
    await _messages.close();
  }

  // --- keepalive ------------------------------------------------------------------

  void _startKeepalive() {
    _stopKeepalive();
    final interval = keepaliveInterval;
    if (interval == null) return;
    _keepaliveTimer = Timer.periodic(interval, (_) => _sendKeepalive());
  }

  void _sendKeepalive() {
    send(keepaliveRequest);
    _awaitingPong = true;
    // Deadline runs from the FIRST unanswered ping: a subsequent ping must
    // not extend it, or a peer that never pongs would keep the window open
    // forever when keepaliveInterval < keepalivePongTimeout.
    if (_pongTimer == null) {
      _pongTimer = Timer(keepalivePongTimeout, () {
        if (_awaitingPong) {
          _awaitingPong = false;
          lastError = 'Keepalive timeout (no pong)';
          _onDisconnected();
        }
      });
    }
  }

  void _onKeepalivePong() {
    _awaitingPong = false;
    _pongTimer?.cancel();
    _pongTimer = null;
  }

  void _stopKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
    _pongTimer?.cancel();
    _pongTimer = null;
    _awaitingPong = false;
  }
}
