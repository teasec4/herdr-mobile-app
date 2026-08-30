import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/pair_config.dart';
import '../models/relay_agent.dart';
import '../models/relay_event.dart';

/// Relay connection phase.
enum RelayStatus { disconnected, connecting, connected }

/// Relay protocol error (code from frame.error or a local one).
class RelayException implements Exception {
  const RelayException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// Relay client contract for the UI: connection, snapshot, agent operations.
///
/// WebSocket implementation — [WsRelayClient]; in widget tests — a fake.
abstract class RelayClient {
  /// Connection status; subscribe to changes to update the UI.
  ValueNotifier<RelayStatus> get status;

  /// Stream of relay events (e.g. `pane.agent_status_changed`).
  Stream<RelayEvent> get events;

  /// List of agents (`agents.snapshot`).
  Future<List<RelayAgent>> snapshot();

  /// Agent terminal output (`agent.output`).
  Future<String> output(String target, {int lines = 200, String format = 'text'});

  /// Sends key combinations to the agent (`agent.keys`): ['enter'], ['ctrl', 'c'].
  Future<void> keys(String target, List<String> keys);

  /// Sends text as a message to the agent (`agent.prompt`).
  Future<void> prompt(String target, String text);

  /// Quick check that the relay is alive via http /healthz.
  Future<bool> healthz();

  /// Pauses reconnect attempts while the app is in the background.
  void pauseReconnect();

  /// Resumes reconnect attempts when the app returns to the foreground.
  void resumeReconnect();

  /// Closes the client: stops reconnects and events.
  Future<void> close();
}

/// Relay client over WebSocket.
///
/// Protocol (see `cmd/relay/ws.go` and docs/01-architecture.md):
/// request `{"type":"request","id":N,"method":...,"params":{...}}`, response
/// `{"type":"response","id":N,"ok":true,"result":...}` or
/// `{"type":"response","id":N,"error":{"code","message"}}`; events arrive
/// as separate frames without an id. Auto-reconnect with exponential backoff
/// 1, 2, 4, ..., up to 30 s.
class WsRelayClient implements RelayClient {
  WsRelayClient(this.config) {
    status = ValueNotifier<RelayStatus>(RelayStatus.disconnected);
    _events = StreamController<RelayEvent>.broadcast();
    _connect();
  }

  final PairConfig config;

  /// Connection status; subscribe to changes to update the UI.
  @override
  late final ValueNotifier<RelayStatus> status;

  /// Stream of relay events (e.g. `pane.agent_status_changed`).
  @override
  Stream<RelayEvent> get events => _events.stream;

  late final StreamController<RelayEvent> _events;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnectTimer;
  int _attempt = 0;
  bool _closed = false;
  bool _reconnectPaused = false;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};

  /// Last connection error (shown to the user instead of a generic message).
  String? lastError;

  static const Duration _requestTimeout = Duration(seconds: 15);
  static const Duration _maxReconnectDelay = Duration(seconds: 30);
  static const Duration _connectWait = Duration(seconds: 8);

  // --- public operations --------------------------------------------------------------------

  /// List of agents (`agents.snapshot`).
  @override
  Future<List<RelayAgent>> snapshot() async {
    final result = await _request('agents.snapshot', const {});
    final list = result['agents'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => RelayAgent.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  /// Agent terminal output (`agent.output`).
  @override
  Future<String> output(String target, {int lines = 200, String format = 'text'}) async {
    final result = await _request('agent.output', {
      'target': target,
      'lines': lines,
      'format': format,
    });
    return result['output'] as String? ?? '';
  }

  /// Sends key combinations to the agent (`agent.keys`): ['enter'], ['ctrl', 'c'].
  @override
  Future<void> keys(String target, List<String> keys) async {
    await _request('agent.keys', {'target': target, 'keys': keys});
  }

  /// Sends text as a message to the agent (`agent.prompt`).
  @override
  Future<void> prompt(String target, String text) async {
    await _request('agent.prompt', {'target': target, 'text': text});
  }

  /// Quick check that the relay is alive via http /healthz.
  ///
  /// A single check can fail on a transient network blip, so it retries a few
  /// times with a short backoff before reporting the relay as offline.
  @override
  Future<bool> healthz() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final res = await http
            .get(config.healthUri)
            .timeout(const Duration(seconds: 3));
        if (res.statusCode == 200) return true;
      } catch (_) {
        // transient failure — fall through and retry
      }
      if (attempt < 2) {
        await Future.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      }
    }
    return false;
  }

  /// Pauses reconnect attempts while the app is in the background.
  @override
  void pauseReconnect() {
    _reconnectPaused = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// Resumes reconnect attempts when the app returns to the foreground.
  @override
  void resumeReconnect() {
    _reconnectPaused = false;
    if (status.value != RelayStatus.connected) {
      _scheduleReconnect();
    }
  }

  /// Closes the client: stops reconnects and events.
  @override
  Future<void> close() async {
    _closed = true;
    _reconnectTimer?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    _failPending();
    status.value = RelayStatus.disconnected;
    await _events.close();
  }

  // --- connection --------------------------------------------------------------------

  Future<void> _connect() async {
    if (_closed) return;

    // Cancel any previous subscription before opening a new connection, so a
    // stale stream can't deliver messages into the new connection's handlers.
    await _sub?.cancel();
    _sub = null;

    status.value = RelayStatus.connecting;
    final ws = WebSocketChannel.connect(Uri.parse(config.wsUri.toString()));
    _channel = ws;

    try {
      await ws.ready;
      if (_closed) {
        ws.sink.close();
        return;
      }
      _attempt = 0;
      lastError = null;
      status.value = RelayStatus.connected;

      // Single handler for both done and error; cancelOnError stops the stream
      // after the first error so onDone can't fire a second disconnect.
      _sub = ws.stream.listen(
        _onMessage,
        onDone: _onDisconnect,
        onError: (e) {
          lastError = '$e';
          _onDisconnect();
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (_closed) return;
      lastError = '$e';
      ws.sink.close();
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic raw) {
    final Map<String, dynamic> frame;
    try {
      frame = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    // DEBUG: log incoming frames
    if (frame['type'] == 'event') {
      print('[RelayClient] WS event: ${frame['event']}');
    }

    switch (frame['type']) {
      case 'response':
        _onResponse(frame);
      case 'event':
        _events.add(RelayEvent.fromJson({
          'name': frame['event'] as String? ?? 'event',
          'data': frame['data'] as Map<String, dynamic>?,
        }));
      case 'ping':
        _sendFrame(const {'type': 'pong'});
    }
  }

  void _onResponse(Map<String, dynamic> frame) {
    final id = frame['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null) return;
    if (frame['ok'] == true) {
      final result = frame['result'];
      completer.complete(
        result is Map ? result.cast<String, dynamic>() : const <String, dynamic>{},
      );
    } else {
      final err = frame['error'];
      final code = err is Map ? '${err['code']}' : 'error';
      final message = err is Map ? '${err['message'] ?? ''}' : 'relay error';
      completer.completeError(RelayException(code, message.isNotEmpty ? message : code));
    }
  }

  void _onDisconnect() {
    if (_closed) return;

    // Prevent duplicate reconnect scheduling: onError and onDone can both fire
    // for a failed stream (unless cancelOnError stops it first).
    if (_reconnectTimer != null) return;

    lastError ??= 'Relay connection lost';
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    status.value = RelayStatus.disconnected;
    _failPending();
    _scheduleReconnect();
  }

  /// Waits up to [_connectWait] for the status to become [RelayStatus.connected]
  /// (the WS may still be establishing on a cold start / reconnect backoff).
  Future<void> _waitForConnected() async {
    if (status.value == RelayStatus.connected) return;
    final completer = Completer<void>();
    void listener() {
      if (status.value == RelayStatus.connected && !completer.isCompleted) {
        completer.complete();
      }
    }

    status.addListener(listener);
    try {
      await completer.future.timeout(_connectWait, onTimeout: () {});
    } finally {
      status.removeListener(listener);
    }
  }

  void _scheduleReconnect() {
    if (_closed || _reconnectTimer != null || _reconnectPaused) return;
    final seconds = min(pow(2, _attempt).toInt(), _maxReconnectDelay.inSeconds);
    _attempt++;
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      _reconnectTimer = null;
      _connect();
    });
  }

  void _failPending() {
    const err = RelayException('disconnected', 'Relay connection lost');
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(err);
    }
    _pending.clear();
  }

  // --- request-response ---------------------------------------------------------------

  Future<Map<String, dynamic>> _request(String method, Map<String, dynamic> params) async {
    if (status.value != RelayStatus.connected) {
      // Give the WS a moment to (re)connect on a cold start instead of failing
      // the first operation instantly. After the wait, surface the real reason.
      await _waitForConnected();
      if (status.value != RelayStatus.connected) {
        throw RelayException('not_connected', lastError ?? 'No connection to relay');
      }
    }
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _sendFrame({'type': 'request', 'id': id, 'method': method, 'params': params});
    final timer = Timer(_requestTimeout, () {
      if (_pending.remove(id) != null) {
        completer.completeError(const RelayException('timeout', 'Relay did not respond'));
      }
    });
    try {
      return await completer.future;
    } finally {
      timer.cancel();
    }
  }

  void _sendFrame(Map<String, dynamic> frame) {
    _channel?.sink.add(jsonEncode(frame));
  }
}