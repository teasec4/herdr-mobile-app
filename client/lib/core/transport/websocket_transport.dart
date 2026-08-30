import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'reconnect_mixin.dart';
import 'transport.dart';

/// WebSocket [Transport]: raw text frames, auto-reconnect with exponential
/// backoff (1, 2, 4, … 30 s), pause/resume for app lifecycle.
///
/// Deliberately protocol-agnostic: no JSON parsing, no requests, no events —
/// see docs/09-refactoring-plan.md §2.1.
class WebSocketTransport with ReconnectMixin implements Transport {
  /// [channelFactory] is injectable for tests: it substitutes a fake
  /// [WebSocketChannel] so reconnect/send/receive can be tested with no real
  /// network. Production uses [WebSocketChannel.connect].
  WebSocketTransport({WebSocketChannel Function(Uri uri)? channelFactory})
      : _channelFactory = channelFactory ?? WebSocketChannel.connect {
    status = ValueNotifier<ConnectionStatus>(ConnectionStatus.disconnected);
    _messages = StreamController<String>.broadcast();
  }

  final WebSocketChannel Function(Uri uri) _channelFactory;

  @override
  late final ValueNotifier<ConnectionStatus> status;

  late final StreamController<String> _messages;

  @override
  Stream<String> get messages => _messages.stream;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Uri? _uri;
  bool _closed = false;

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

      // Single handler for both done and error; cancelOnError stops the stream
      // after the first error so onDone can't fire a second disconnect.
      _sub = ws.stream.listen(
        (data) {
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
  Future<void> close() async {
    _closed = true;
    stopReconnects();
    await _sub?.cancel();
    _sub = null;
    await _channel?.sink.close();
    _channel = null;
    status.value = ConnectionStatus.disconnected;
    await _messages.close();
  }
}
