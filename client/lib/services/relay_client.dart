import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/pair_config.dart';
import '../models/relay_agent.dart';

/// Фаза соединения с релеем.
enum RelayStatus { disconnected, connecting, connected }

/// Ошибка протокола релея (код из frame.error или локальная).
class RelayException implements Exception {
  const RelayException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// Событие релея (`{"type":"event","event":...,"data":...}`).
class RelayEvent {
  const RelayEvent(this.name, this.data);

  final String name;
  final dynamic data;
}

/// Контракт клиента релея для UI: соединение, снимок, операции с агентом.
///
/// Реализация по WebSocket — [WsRelayClient]; в виджет-тестах — фейк.
abstract class RelayClient {
  /// Статус соединения; подпишитесь на изменения для обновления UI.
  ValueNotifier<RelayStatus> get status;

  /// Поток событий релея (например, `pane.agent_status_changed`).
  Stream<RelayEvent> get events;

  /// Список агентов (`agents.snapshot`).
  Future<List<RelayAgent>> snapshot();

  /// Метка вывода терминала агента (`agent.output`).
  Future<String> output(String target, {int lines = 200, String format = 'text'});

  /// Шлёт комбинации клавиш агенту (`agent.keys`): ['enter'], ['ctrl', 'c'].
  Future<void> keys(String target, List<String> keys);

  /// Шлёт текст как сообщение агенту (`agent.prompt`).
  Future<void> prompt(String target, String text);

  /// Быстрая проверка, что релей жив, по http /healthz.
  Future<bool> healthz();

  /// Закрывает клиент: останавливает переподключения и события.
  Future<void> close();
}

/// Клиент релея по WebSocket.
///
/// Протокол (см. `cmd/relay/ws.go` и docs/01-architecture.md):
/// запрос `{"type":"request","id":N,"method":...,"params":{...}}`, ответ
/// `{"type":"response","id":N,"ok":true,"result":...}` либо
/// `{"type":"response","id":N,"error":{"code","message"}}`; события идут
/// отдельными frame без id. Автопереподключение с экспоненциальным бэкоффом
/// 1, 2, 4, ..., до 30 с.
class WsRelayClient implements RelayClient {
  WsRelayClient(this.config) {
    status = ValueNotifier<RelayStatus>(RelayStatus.disconnected);
    _events = StreamController<RelayEvent>.broadcast();
    _connect();
  }

  final PairConfig config;

  /// Статус соединения; подпишитесь на изменения для обновления UI.
  @override
  late final ValueNotifier<RelayStatus> status;

  /// Поток событий релея (например, `pane.agent_status_changed`).
  @override
  Stream<RelayEvent> get events => _events.stream;

  late final StreamController<RelayEvent> _events;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnectTimer;
  int _attempt = 0;
  bool _closed = false;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};

  static const Duration _requestTimeout = Duration(seconds: 15);
  static const Duration _maxReconnectDelay = Duration(seconds: 30);

  // --- публичные операции --------------------------------------------------

  /// Список агентов (`agents.snapshot`).
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

  /// Метка вывода терминала агента (`agent.output`).
  @override
  Future<String> output(String target, {int lines = 200, String format = 'text'}) async {
    final result = await _request('agent.output', {
      'target': target,
      'lines': lines,
      'format': format,
    });
    return result['output'] as String? ?? '';
  }

  /// Шлёт комбинации клавиш агенту (`agent.keys`): ['enter'], ['ctrl', 'c'].
  @override
  Future<void> keys(String target, List<String> keys) async {
    await _request('agent.keys', {'target': target, 'keys': keys});
  }

  /// Шлёт текст как сообщение агенту (`agent.prompt`).
  @override
  Future<void> prompt(String target, String text) async {
    await _request('agent.prompt', {'target': target, 'text': text});
  }

  /// Быстрая проверка, что релей жив, по http /healthz.
  @override
  Future<bool> healthz() async {
    try {
      final res = await http.get(config.healthUri).timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Закрывает клиент: останавливает переподключения и события.
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

  // --- соединение ----------------------------------------------------------

  Future<void> _connect() async {
    if (_closed) return;
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
      status.value = RelayStatus.connected;
      _sub = ws.stream.listen(_onMessage, onDone: _onDisconnect, onError: (_) => _onDisconnect());
    } catch (_) {
      if (_closed) return;
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
    switch (frame['type']) {
      case 'response':
        _onResponse(frame);
      case 'event':
        _events.add(RelayEvent(frame['event'] as String? ?? 'event', frame['data']));
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
      final message = err is Map ? '${err['message'] ?? ''}' : 'ошибка релея';
      completer.completeError(RelayException(code, message.isNotEmpty ? message : code));
    }
  }

  void _onDisconnect() {
    if (_closed) return;
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    status.value = RelayStatus.disconnected;
    _failPending();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_closed || _reconnectTimer != null) return;
    final seconds = min(pow(2, _attempt).toInt(), _maxReconnectDelay.inSeconds);
    _attempt++;
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      _reconnectTimer = null;
      _connect();
    });
  }

  void _failPending() {
    const err = RelayException('disconnected', 'Соединение с релеем разорвано');
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(err);
    }
    _pending.clear();
  }

  // --- запрос-ответ --------------------------------------------------------

  Future<Map<String, dynamic>> _request(String method, Map<String, dynamic> params) async {
    if (status.value != RelayStatus.connected) {
      throw const RelayException('not_connected', 'Нет соединения с релеем');
    }
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _sendFrame({'type': 'request', 'id': id, 'method': method, 'params': params});
    final timer = Timer(_requestTimeout, () {
      if (_pending.remove(id) != null) {
        completer.completeError(const RelayException('timeout', 'Релей не ответил'));
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