import 'dart:convert';

import 'relay_exception.dart';

/// One relay-protocol frame (docs/09-refactoring-plan.md §2.2).
///
/// The relay protocol mirrors what `cmd/relay` and `internal/transport/ws`
/// speak (see docs/01-architecture.md): requests carry an `id`, responses
/// carry `ok`/`result` or `error`, events carry `event`/`data`, and `ping`/
/// `pong` keep the connection warm.
sealed class Frame {
  const Frame();

  /// Parses one JSON text frame. Throws [ProtocolException] on invalid JSON
  /// or an unknown frame type.
  factory Frame.parse(String json) {
    final Map<String, dynamic> map;
    try {
      final decoded = jsonDecode(json);
      map = decoded as Map<String, dynamic>;
    } catch (_) {
      throw const ProtocolException('invalid JSON frame');
    }

    switch (map['type']) {
      case 'request':
        return RequestFrame(
          id: map['id'] as int? ?? 0,
          method: map['method'] as String? ?? '',
          params: (map['params'] as Map?)?.cast<String, dynamic>() ?? const {},
        );
      case 'response':
        final err = map['error'];
        return ResponseFrame(
          id: map['id'] as int? ?? 0,
          ok: map['ok'] == true,
          result: (map['result'] as Map?)?.cast<String, dynamic>(),
          error: err is Map
              ? RelayError(code: '${err['code']}', message: '${err['message'] ?? ''}')
              : null,
        );
      case 'event':
        return EventFrame(
          event: map['event'] as String? ?? 'event',
          data: (map['data'] as Map?)?.cast<String, dynamic>(),
        );
      case 'ping':
        return const PingFrame();
      case 'pong':
        return const PongFrame();
      default:
        throw ProtocolException('unknown frame type: ${map['type']}');
    }
  }

  /// Serializes the frame back to a JSON string.
  String encode();
}

/// A client → relay request (`agent.output`, `agents.snapshot`, …).
class RequestFrame extends Frame {
  const RequestFrame({
    required this.id,
    required this.method,
    this.params = const {},
  });

  final int id;
  final String method;
  final Map<String, dynamic> params;

  @override
  String encode() => jsonEncode({
        'type': 'request',
        'id': id,
        'method': method,
        'params': params,
      });
}

/// A relay → client answer to a [RequestFrame].
class ResponseFrame extends Frame {
  const ResponseFrame({
    required this.id,
    required this.ok,
    this.result,
    this.error,
  });

  final int id;

  /// `ok: true` — success with optional [result]; otherwise [error] is set.
  final bool ok;
  final Map<String, dynamic>? result;
  final RelayError? error;

  @override
  String encode() => jsonEncode({
        'type': 'response',
        'id': id,
        if (ok) 'ok': true,
        if (ok && result != null) 'result': result,
        if (!ok && error != null)
          'error': {'code': error!.code, 'message': error!.message},
      });
}

/// A relay → client notification (agent status changed, pane updated, …).
class EventFrame extends Frame {
  const EventFrame({required this.event, this.data});

  final String event;
  final Map<String, dynamic>? data;

  @override
  String encode() => jsonEncode({
        'type': 'event',
        'event': event,
        if (data != null) 'data': data,
      });
}

/// Server keepalive; the client answers with a [PongFrame].
class PingFrame extends Frame {
  const PingFrame();

  /// The exact wire string the relay's pong matcher expects. Transport-layer
  /// keepalive (WebSocketTransport) reuses this so the literal lives in one
  /// place (docs/03-relay.md keepalive section).
  static const String wire = '{"type":"ping"}';

  @override
  String encode() => wire;
}

/// Client's answer to a [PingFrame].
class PongFrame extends Frame {
  const PongFrame();

  /// Wire string consumed by the transport's keepalive watchdog.
  static const String wire = '{"type":"pong"}';

  @override
  String encode() => wire;
}
