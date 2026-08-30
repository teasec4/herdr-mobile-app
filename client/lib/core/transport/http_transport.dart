import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'reconnect_mixin.dart';
import 'retry_policy.dart';
import 'transport.dart';

/// HTTP [Transport] fallback (docs/09-refactoring-plan.md Phase 5): speaks the
/// same wire protocol as the WebSocket transport, but over plain HTTP.
///
/// - `send(data)` POSTs a relay request frame to `/api/rpc` and feeds the
///   response frame back into [messages] — identical framing to /ws.
/// - A Server-Sent Events stream on `/api/events/stream` delivers event frames
///   into [messages], with the same reconnect/backoff behavior as WS.
///
/// The transport stays protocol-agnostic: it forwards raw strings in both
/// directions and never parses them.
class HttpTransport with ReconnectMixin implements Transport {
  /// [baseUri] is the relay HTTP base (e.g. `http://host:8375`), [token] is
  /// the pair token for the `Authorization: Bearer` header. [client] and
  /// [retryPolicy] are injectable for tests.
  HttpTransport({
    required this.baseUri,
    required this.token,
    http.Client? client,
    RetryPolicy? retryPolicy,
  })  : _client = client ?? http.Client(),
        retryPolicy = retryPolicy ?? ExponentialBackoff() {
    status = ValueNotifier<ConnectionStatus>(ConnectionStatus.disconnected);
    _messages = StreamController<String>.broadcast();
    _rpcUri = baseUri.replace(path: '/api/rpc');
    _streamUri = baseUri.replace(path: '/api/events/stream');
  }

  final Uri baseUri;
  final String token;
  final http.Client _client;

  @override
  final RetryPolicy retryPolicy;

  late final Uri _rpcUri;
  late final Uri _streamUri;

  @override
  late final ValueNotifier<ConnectionStatus> status;

  late final StreamController<String> _messages;

  @override
  Stream<String> get messages => _messages.stream;

  StreamSubscription<String>? _sseSub;
  bool _closed = false;

  @override
  String? lastError;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> connect(Uri uri) async {
    // [uri] (the relay http base) is ignored: the base was given in the
    // constructor. Kept for Transport contract symmetry.
    await reconnectNow();
  }

  @override
  Future<void> reconnectNow() async {
    if (_closed) return;
    await _sseSub?.cancel();
    _sseSub = null;

    status.value = ConnectionStatus.connecting;
    try {
      final request = http.Request('GET', _streamUri)
        ..headers['Accept'] = 'text/event-stream'
        ..headers['Authorization'] = 'Bearer $token';
      final response = await _client.send(request);
      if (response.statusCode != 200) {
        lastError = 'SSE ${response.statusCode}';
        status.value = ConnectionStatus.disconnected;
        scheduleReconnect();
        return;
      }

      markConnected();
      lastError = null;
      status.value = ConnectionStatus.connected;
      _sseSub = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        _onSseLine,
        onError: (Object e) {
          lastError = '$e';
          _onDisconnected();
        },
        onDone: _onDisconnected,
      );
    } catch (e) {
      if (_closed) return;
      lastError = '$e';
      status.value = ConnectionStatus.disconnected;
      scheduleReconnect();
    }
  }

  void _onSseLine(String line) {
    if (line.startsWith('data: ')) {
      _messages.add(line.substring('data: '.length));
    }
  }

  void _onDisconnected() {
    if (_closed) return;
    if (hasScheduledReconnect) return;

    lastError ??= 'Event stream lost';
    _sseSub?.cancel();
    _sseSub = null;
    status.value = ConnectionStatus.disconnected;
    scheduleReconnect();
  }

  @override
  void send(String data) {
    // Fire-and-forget: the response frame lands in [messages] like a WS
    // frame, so the Protocol layer matches it identically.
    _client
        .post(
          _rpcUri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: data,
        )
        .then((res) {
          if (res.statusCode == 200) {
            _messages.add(res.body);
          } else {
            lastError = 'RPC ${res.statusCode}';
          }
        })
        .catchError((Object e) {
          lastError = '$e';
        });
  }

  @override
  Future<void> close() async {
    _closed = true;
    stopReconnects();
    await _sseSub?.cancel();
    _sseSub = null;
    status.value = ConnectionStatus.disconnected;
    await _messages.close();
    _client.close();
  }
}
