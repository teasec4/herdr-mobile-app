import 'dart:convert';

import 'package:client/core/protocol/relay_exception.dart';
import 'package:client/core/protocol/relay_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// Frame parsing/encoding — pure JSON in, typed frame out; no network.
void main() {
  group('Frame.parse', () {
    test('parses a request frame', () {
      final frame = Frame.parse(
        jsonEncode({
          'type': 'request',
          'id': 7,
          'method': 'agents.snapshot',
          'params': {'a': 1},
        }),
      );
      expect(frame, isA<RequestFrame>());
      final r = frame as RequestFrame;
      expect(r.id, 7);
      expect(r.method, 'agents.snapshot');
      expect(r.params, {'a': 1});
    });

    test('parses a success response frame', () {
      final frame = Frame.parse(jsonEncode({
        'type': 'response',
        'id': 1,
        'ok': true,
        'result': {'agents': []},
      }));
      expect(frame, isA<ResponseFrame>());
      final r = frame as ResponseFrame;
      expect(r.id, 1);
      expect(r.ok, isTrue);
      expect(r.result, {'agents': []});
      expect(r.error, isNull);
    });

    test('parses an error response frame', () {
      final frame = Frame.parse(jsonEncode({
        'type': 'response',
        'id': 2,
        'error': {'code': 'not_found', 'message': 'no pane with id p1'},
      }));
      final r = frame as ResponseFrame;
      expect(r.ok, isFalse);
      expect(r.error?.code, 'not_found');
      expect(r.error?.message, 'no pane with id p1');
      expect(r.result, isNull);
    });

    test('parses an event frame', () {
      final frame = Frame.parse(jsonEncode({
        'type': 'event',
        'event': 'pane.updated',
        'data': {'pane_id': 'p1'},
      }));
      final e = frame as EventFrame;
      expect(e.event, 'pane.updated');
      expect(e.data, {'pane_id': 'p1'});
    });

    test('parses ping and pong frames', () {
      expect(Frame.parse('{"type":"ping"}'), isA<PingFrame>());
      expect(Frame.parse('{"type":"pong"}'), isA<PongFrame>());
    });

    test('missing type throws ProtocolException', () {
      expect(() => Frame.parse('{"id":1}'), throwsA(isA<ProtocolException>()));
    });

    test('unknown type throws ProtocolException', () {
      expect(
        () => Frame.parse('{"type":"teleport"}'),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('invalid JSON throws ProtocolException', () {
      expect(() => Frame.parse('not json'), throwsA(isA<ProtocolException>()));
      expect(() => Frame.parse('[1,2,3]'), throwsA(isA<ProtocolException>()));
    });
  });

  group('Frame.encode', () {
    test('request round-trips', () {
      const frame = RequestFrame(id: 3, method: 'agent.output', params: {
        'target': 'p1',
        'lines': 200,
        'format': 'text',
      });
      final parsed = Frame.parse(frame.encode()) as RequestFrame;
      expect(parsed.id, 3);
      expect(parsed.method, 'agent.output');
      expect(parsed.params, {'target': 'p1', 'lines': 200, 'format': 'text'});
    });

    test('response round-trips', () {
      const frame = ResponseFrame(
        id: 1,
        ok: true,
        result: {'output': 'hello'},
      );
      final parsed = Frame.parse(frame.encode()) as ResponseFrame;
      expect(parsed.id, 1);
      expect(parsed.ok, isTrue);
      expect(parsed.result, {'output': 'hello'});
    });

    test('error response round-trips', () {
      const frame = ResponseFrame(
        id: 9,
        ok: false,
        error: RelayError(code: 'timeout', message: 'Relay did not respond'),
      );
      final parsed = Frame.parse(frame.encode()) as ResponseFrame;
      expect(parsed.id, 9);
      expect(parsed.ok, isFalse);
      expect(parsed.error?.code, 'timeout');
      expect(parsed.error?.message, 'Relay did not respond');
    });

    test('ping/pong round-trip', () {
      expect(Frame.parse(const PingFrame().encode()), isA<PingFrame>());
      expect(Frame.parse(const PongFrame().encode()), isA<PongFrame>());
    });
  });
}
