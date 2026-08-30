import 'dart:async';
import 'dart:convert';

import 'package:client/_legacy/ws_relay_client.dart';
import 'package:client/models/pair_config.dart';
import 'package:client/models/relay_event.dart';
import 'package:client/services/relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/fake_web_socket_channel.dart';

/// Baseline contract tests for [WsRelayClient].
///
/// These pin the current client behavior (request/response matching, events,
/// ping/pong, reconnect, timeouts, fail-on-disconnect) against a fake
/// [FakeWebSocketChannel] — no real network. After the layered refactor
/// (docs/09-refactoring-plan.md) the same tests must pass against the new
/// `RelayClientImpl` unchanged, proving the refactor preserves behavior.
///
/// One test (agent_status_changed key mapping, D1) is expected to be RED
/// before the fix: the server sends `agent_status` but the client read
/// `status`, so live status always came through as `unknown`.
void main() {
  PairConfig config() => const PairConfig(
        host: 'localhost',
        port: 8375,
        mode: 'lan',
        token: '0123456789abcdef0123456789abcdef',
      );

  /// Waits until the client reports connected (the connect is async).
  Future<void> waitConnected(WsRelayClient client) async {
    if (client.status.value == RelayStatus.connected) return;
    final done = Completer<void>();
    void listener() {
      if (client.status.value == RelayStatus.connected && !done.isCompleted) {
        done.complete();
      }
    }

    client.status.addListener(listener);
    await done.future.timeout(const Duration(seconds: 2));
    client.status.removeListener(listener);
  }

  Map<String, dynamic> frame(String type, [Map<String, dynamic>? extra]) =>
      {'type': type, ...?extra};

  group('WsRelayClient baseline', () {
    test('request resolves with result on ok response', () async {
      final channel = FakeWebSocketChannel();
      final client = WsRelayClient(config(), channelFactory: (_) => channel);
      await waitConnected(client);

      final future = client.snapshot();
      await pumpEventQueue();

      // The request frame went out.
      final sent = jsonDecode(channel.sent.single as String) as Map<String, dynamic>;
      expect(sent['type'], 'request');
      expect(sent['method'], 'agents.snapshot');
      expect(sent['params'], isEmpty);

      // The relay answers.
      channel.simulateMessage(jsonEncode(frame('response', {
        'id': sent['id'],
        'ok': true,
        'result': {
          'agents': [
            {
              'pane_id': 'p1',
              'agent': 'codex',
              'agent_status': 'working',
              'cwd': '/tmp',
              'focused': true,
            },
          ],
        },
      })));

      final agents = await future;
      expect(agents, hasLength(1));
      expect(agents[0].id, 'p1');
      expect(agents[0].agent, 'codex');
      expect(agents[0].status, 'working');
      expect(agents[0].cwd, '/tmp');
      expect(agents[0].focused, isTrue);

      await client.close();
    });

    test('request throws RelayException with code/message on error response',
        () async {
      final channel = FakeWebSocketChannel();
      final client = WsRelayClient(config(), channelFactory: (_) => channel);
      await waitConnected(client);

      final future = client.output('p1');
      await pumpEventQueue();
      final sent = jsonDecode(channel.sent.single as String) as Map<String, dynamic>;

      channel.simulateMessage(jsonEncode(frame('response', {
        'id': sent['id'],
        'error': {'code': 'not_found', 'message': 'no pane with id p1'},
      })));

      await expectLater(
        future,
        throwsA(isA<RelayException>()
            .having((e) => e.code, 'code', 'not_found')
            .having((e) => e.message, 'message', 'no pane with id p1')),
      );

      await client.close();
    });

    test('event frame is emitted as typed RelayEvent', () async {
      final channel = FakeWebSocketChannel();
      final client = WsRelayClient(config(), channelFactory: (_) => channel);
      await waitConnected(client);

      final events = <RelayEvent>[];
      final sub = client.events.listen(events.add);

      channel.simulateMessage(jsonEncode(
          frame('event', {'event': 'pane.updated', 'data': {'pane_id': 'p1'}})));
      await pumpEventQueue();

      expect(events, hasLength(1));
      expect(events.single, isA<PaneUpdated>());
      expect((events.single as PaneUpdated).paneId, 'p1');

      await sub.cancel();
      await client.close();
    });

    test('agent_status_changed maps status from agent_status key (D1)',
        () async {
      final channel = FakeWebSocketChannel();
      final client = WsRelayClient(config(), channelFactory: (_) => channel);
      await waitConnected(client);

      final events = <RelayEvent>[];
      final sub = client.events.listen(events.add);

      // The relay (internal/domain/event.go) sends agent_status, mirroring
      // herdr's pane.agent_status_changed payload (docs/10-herdr-api.md §5.3).
      channel.simulateMessage(jsonEncode(frame('event', {
        'event': 'pane.agent_status_changed',
        'data': {'pane_id': 'p1', 'agent_status': 'blocked'},
      })));
      await pumpEventQueue();

      expect(events, hasLength(1));
      expect(events.single, isA<AgentStatusChanged>());
      final e = events.single as AgentStatusChanged;
      expect(e.paneId, 'p1');
      // RED before fix D1: the client read data['status'] -> 'unknown'.
      expect(e.status, 'blocked');

      await sub.cancel();
      await client.close();
    });

    test('server ping is answered with pong', () async {
      final channel = FakeWebSocketChannel();
      final client = WsRelayClient(config(), channelFactory: (_) => channel);
      await waitConnected(client);

      channel.simulateMessage(jsonEncode(frame('ping')));
      await pumpEventQueue();

      final sent = channel.sent.map((s) => jsonDecode(s as String)).toList();
      expect(sent.last, {'type': 'pong'});

      await client.close();
    });

    test('pending request times out with RelayException(timeout)', () async {
      final channel = FakeWebSocketChannel();
      final client = WsRelayClient(
        config(),
        channelFactory: (_) => channel,
        requestTimeout: const Duration(milliseconds: 100),
      );
      await waitConnected(client);

      final future = client.snapshot();
      await expectLater(
        future,
        throwsA(isA<RelayException>().having((e) => e.code, 'code', 'timeout')),
      );

      await client.close();
    });

    test('disconnect fails pending requests and reports disconnected', () async {
      final channel = FakeWebSocketChannel();
      final client = WsRelayClient(config(), channelFactory: (_) => channel);
      await waitConnected(client);

      final future = client.snapshot();
      await pumpEventQueue();

      channel.simulateDone();
      await expectLater(
        future,
        throwsA(isA<RelayException>()
            .having((e) => e.code, 'code', 'disconnected')),
      );
      expect(client.status.value, RelayStatus.disconnected);

      await client.close();
    });

    test('reconnects automatically after disconnect (exponential backoff)',
        () async {
      var factoryCalls = 0;
      late FakeWebSocketChannel first;
      final channels = <FakeWebSocketChannel>[];
      final client = WsRelayClient(
        config(),
        channelFactory: (uri) {
          factoryCalls++;
          final c = FakeWebSocketChannel();
          channels.add(c);
          if (factoryCalls == 1) first = c;
          return c;
        },
      );
      await waitConnected(client);
      expect(factoryCalls, 1);

      first.simulateDone();
      // First backoff is 1 s (2^0); wait past it plus connect time.
      await Future<void>.delayed(const Duration(milliseconds: 1600));

      expect(factoryCalls, 2);
      await waitConnected(client);
      expect(client.status.value, RelayStatus.connected);

      await client.close();
    });

    test('pauseReconnect stops reconnect; resumeReconnect restarts it',
        () async {
      var factoryCalls = 0;
      late FakeWebSocketChannel first;
      final channels = <FakeWebSocketChannel>[];
      final client = WsRelayClient(
        config(),
        channelFactory: (uri) {
          factoryCalls++;
          final c = FakeWebSocketChannel();
          channels.add(c);
          if (factoryCalls == 1) first = c;
          return c;
        },
      );
      await waitConnected(client);

      client.pauseReconnect();
      first.simulateDone();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(factoryCalls, 1, reason: 'no reconnect while paused');
      expect(client.status.value, RelayStatus.disconnected);

      client.resumeReconnect();
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      expect(factoryCalls, 2, reason: 'reconnect after resume');
      await waitConnected(client);

      await client.close();
    });

    test('request on cold start waits briefly, then throws not_connected',
        () async {
      // Channel that never completes `ready` — like a relay that is slow or
      // unreachable while the client is starting.
      final channel = FakeWebSocketChannel(connected: false);
      final client = WsRelayClient(
        config(),
        channelFactory: (_) => channel,
        connectWait: const Duration(milliseconds: 100),
      );

      final future = client.snapshot();
      await expectLater(
        future,
        throwsA(isA<RelayException>()
            .having((e) => e.code, 'code', 'not_connected')),
      );
      // The pending connect keeps the status at connecting (ready never
      // completed); it is not connected, which is what matters.
      expect(client.status.value, isNot(RelayStatus.connected));

      // Unblock the pending connect so nothing leaks.
      channel.completeConnection();
      await client.close();
    });

    test('close stops reconnects and emits no further events', () async {
      final channel = FakeWebSocketChannel();
      final client = WsRelayClient(config(), channelFactory: (_) => channel);
      await waitConnected(client);

      final events = <RelayEvent>[];
      final sub = client.events.listen(events.add);

      await client.close();
      channel.simulateMessage(jsonEncode(frame('event', {
        'event': 'pane.updated',
        'data': {'pane_id': 'p1'},
      })));
      await pumpEventQueue();

      expect(events, isEmpty);
      expect(client.status.value, RelayStatus.disconnected);

      await sub.cancel();
    });
  });
}
