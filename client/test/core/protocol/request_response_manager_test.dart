import 'dart:convert';

import 'package:client/core/protocol/relay_exception.dart';
import 'package:client/core/protocol/request_response_manager.dart';
import 'package:client/core/transport/transport.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fakes/fake_transport.dart';

/// Request/response matching over a fake transport: ids, timeouts, fail-on-
/// disconnect, ping/pong, cold-start handling. No network, no client.
void main() {
  group('RequestResponseManager', () {
    test('resolves with the result of the matching response', () async {
      final t = FakeTransport();
      final rpc = RequestResponseManager(t);
      t.status.value = ConnectionStatus.connected;

      final future = rpc.request('agents.snapshot', const {});
      await pumpEventQueue();

      final sent = jsonDecode(t.sentMessages.single) as Map<String, dynamic>;
      expect(sent['type'], 'request');
      expect(sent['method'], 'agents.snapshot');

      rpc.handleMessage(jsonEncode({
        'type': 'response',
        'id': sent['id'],
        'ok': true,
        'result': {'agents': []},
      }));

      expect(await future, {'agents': []});
      rpc.dispose();
    });

    test('rejects with the relay error code/message', () async {
      final t = FakeTransport();
      final rpc = RequestResponseManager(t);
      t.status.value = ConnectionStatus.connected;

      final future = rpc.request('agent.output', const {'target': 'p1'});
      await pumpEventQueue();
      final id = (jsonDecode(t.sentMessages.single) as Map)['id'];

      rpc.handleMessage(jsonEncode({
        'type': 'response',
        'id': id,
        'error': {'code': 'agent_blocked', 'message': 'agent is blocked'},
      }));

      await expectLater(
        future,
        throwsA(isA<RelayException>()
            .having((e) => e.code, 'code', 'agent_blocked')
            .having((e) => e.message, 'message', 'agent is blocked')),
      );
      rpc.dispose();
    });

    test('times out when the relay never answers', () async {
      final t = FakeTransport();
      final rpc = RequestResponseManager(
        t,
        requestTimeout: const Duration(milliseconds: 100),
      );
      t.status.value = ConnectionStatus.connected;

      final future = rpc.request('agents.snapshot', const {});
      await expectLater(
        future,
        throwsA(isA<RelayException>().having((e) => e.code, 'code', 'timeout')),
      );
      rpc.dispose();
    });

    test('pending requests fail on disconnect', () async {
      final t = FakeTransport();
      final rpc = RequestResponseManager(t);
      t.status.value = ConnectionStatus.connected;

      final future = rpc.request('agents.snapshot', const {});
      await pumpEventQueue();

      t.status.value = ConnectionStatus.disconnected;

      await expectLater(
        future,
        throwsA(isA<RelayException>()
            .having((e) => e.code, 'code', 'disconnected')),
      );
      rpc.dispose();
    });

    test('answers server ping with pong', () async {
      final t = FakeTransport();
      final rpc = RequestResponseManager(t);
      t.status.value = ConnectionStatus.connected;

      rpc.handleMessage('{"type":"ping"}');
      await pumpEventQueue();

      expect(t.sentMessages, ['{"type":"pong"}']);
      rpc.dispose();
    });

    test('ignores event and garbage frames', () async {
      final t = FakeTransport();
      final rpc = RequestResponseManager(t);
      t.status.value = ConnectionStatus.connected;

      rpc.handleMessage('garbage');
      rpc.handleMessage('{"type":"event","event":"pane.updated","data":{}}');
      await pumpEventQueue();

      expect(t.sentMessages, isEmpty);
      rpc.dispose();
    });

    test('cold start: waits briefly, then throws not_connected', () async {
      final t = FakeTransport(); // status stays disconnected
      final rpc = RequestResponseManager(t, connectWait: const Duration(milliseconds: 100));

      final future = rpc.request('agents.snapshot', const {});
      await expectLater(
        future,
        throwsA(isA<RelayException>()
            .having((e) => e.code, 'code', 'not_connected')),
      );
      expect(t.sentMessages, isEmpty, reason: 'nothing sent while offline');
      rpc.dispose();
    });

    test('cold start: request succeeds once the transport connects in time',
        () async {
      final t = FakeTransport();
      final rpc = RequestResponseManager(t, connectWait: const Duration(seconds: 1));

      final future = rpc.request('agents.snapshot', const {});
      await pumpEventQueue();
      t.status.value = ConnectionStatus.connected; // connects during the wait
      await pumpEventQueue();

      final sent = jsonDecode(t.sentMessages.single) as Map<String, dynamic>;
      rpc.handleMessage(jsonEncode({
        'type': 'response',
        'id': sent['id'],
        'ok': true,
        'result': {'agents': []},
      }));

      expect(await future, {'agents': []});
      rpc.dispose();
    });
  });
}
