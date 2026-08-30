import 'dart:convert';
import 'dart:io';

import 'package:client/core/transport/http_health.dart';
import 'package:client/core/transport/transport.dart';
import 'package:client/models/pair_config.dart';
import 'package:client/models/relay_event.dart';
import 'package:client/services/relay_client.dart';
import 'package:client/services/relay_client_impl.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/fake_transport.dart';

/// RelayClientImpl integration: client + FakeTransport, no network.
///
/// Mirrors the baseline scenarios of relay_client_test.dart (which still runs
/// against the legacy WsRelayClient) — these prove the layered client keeps
/// the same behavior.
void main() {
  PairConfig config() => const PairConfig(
        host: 'localhost',
        port: 8375,
        mode: 'lan',
        token: '0123456789abcdef0123456789abcdef',
      );

  group('RelayClientImpl with FakeTransport', () {
    test('snapshot maps the response into RelayAgent list', () async {
      final t = FakeTransport();
      final client = RelayClientImpl(config(), transport: t);
      await pumpEventQueue(); // FakeTransport.connect -> connected

      expect(client.status.value, RelayStatus.connected);

      final future = client.snapshot();
      await pumpEventQueue();
      final sent = jsonDecode(t.sentMessages.single) as Map<String, dynamic>;
      expect(sent['method'], 'agents.snapshot');

      t.simulateMessage(jsonEncode({
        'type': 'response',
        'id': sent['id'],
        'ok': true,
        'result': {
          'agents': [
            {'pane_id': 'p1', 'agent': 'codex', 'agent_status': 'working'},
          ],
        },
      }));

      final agents = await future;
      expect(agents, hasLength(1));
      expect(agents[0].id, 'p1');
      expect(agents[0].agent, 'codex');
      expect(agents[0].status, 'working');

      await client.close();
    });

    test('output/keys/prompt send the right method and params', () async {
      final t = FakeTransport();
      final client = RelayClientImpl(config(), transport: t);
      await pumpEventQueue();

      final outputFuture = client.output('p1', lines: 50, format: 'ansi');
      await pumpEventQueue();
      var sent = jsonDecode(t.sentMessages.last) as Map<String, dynamic>;
      expect(sent['method'], 'agent.output');
      expect(sent['params'], {'target': 'p1', 'lines': 50, 'format': 'ansi'});
      t.simulateMessage(jsonEncode({
        'type': 'response',
        'id': sent['id'],
        'ok': true,
        'result': {'output': 'hello world'},
      }));
      expect(await outputFuture, 'hello world');

      final keysFuture = client.keys('p1', ['ctrl', 'c']);
      await pumpEventQueue();
      sent = jsonDecode(t.sentMessages.last) as Map<String, dynamic>;
      expect(sent['method'], 'agent.keys');
      expect(sent['params'], {'target': 'p1', 'keys': ['ctrl', 'c']});
      t.simulateMessage(jsonEncode({
        'type': 'response',
        'id': sent['id'],
        'ok': true,
        'result': {'ok': true},
      }));
      await keysFuture;

      final promptFuture = client.prompt('p1', 'continue');
      await pumpEventQueue();
      sent = jsonDecode(t.sentMessages.last) as Map<String, dynamic>;
      expect(sent['method'], 'agent.prompt');
      expect(sent['params'], {'target': 'p1', 'text': 'continue'});
      t.simulateMessage(jsonEncode({
        'type': 'response',
        'id': sent['id'],
        'ok': true,
        'result': {'ok': true},
      }));
      await promptFuture;

      await client.close();
    });

    test('event frames become typed RelayEvent with agent_status (D1)',
        () async {
      final t = FakeTransport();
      final client = RelayClientImpl(config(), transport: t);
      await pumpEventQueue();

      final events = <RelayEvent>[];
      final sub = client.events.listen(events.add);

      t.simulateMessage(jsonEncode({
        'type': 'event',
        'event': 'pane.agent_status_changed',
        'data': {'pane_id': 'p1', 'agent_status': 'blocked'},
      }));
      await pumpEventQueue();

      expect(events.single, isA<AgentStatusChanged>());
      final e = events.single as AgentStatusChanged;
      expect(e.paneId, 'p1');
      expect(e.status, 'blocked');

      await sub.cancel();
      await client.close();
    });

    test('transport status is mapped to client RelayStatus', () async {
      final t = FakeTransport();
      final client = RelayClientImpl(config(), transport: t);
      await pumpEventQueue();
      expect(client.status.value, RelayStatus.connected);

      t.status.value = ConnectionStatus.connecting;
      expect(client.status.value, RelayStatus.connecting);

      t.status.value = ConnectionStatus.disconnected;
      expect(client.status.value, RelayStatus.disconnected);

      await client.close();
    });

    test('pauseReconnect/resumeReconnect delegate to the transport', () async {
      final t = _CountingTransport();
      final client = RelayClientImpl(config(), transport: t);
      await pumpEventQueue();

      client.pauseReconnect();
      expect(t.paused, 1);
      client.resumeReconnect();
      expect(t.resumed, 1);

      await client.close();
    });

    test('healthz checks the relay /healthz endpoint', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) {
        req.response.statusCode = 200;
        req.response.write('{"ok":true}');
        req.response.close();
      });

      final cfg = config();
      final health = HttpHealth();
      final client = RelayClientImpl(
        PairConfig(
          host: '127.0.0.1',
          port: server.port,
          mode: cfg.mode,
          token: cfg.token,
        ),
        transport: FakeTransport(),
        health: health,
      );
      await pumpEventQueue();

      expect(await client.healthz(), isTrue);
      await client.close();
    });

    test('close stops events and reports disconnected', () async {
      final t = FakeTransport();
      final client = RelayClientImpl(config(), transport: t);
      await pumpEventQueue();

      final events = <RelayEvent>[];
      final sub = client.events.listen(events.add);

      await client.close();
      expect(client.status.value, RelayStatus.disconnected);
      expect(t.status.value, ConnectionStatus.disconnected);

      await sub.cancel();
    });
  });
}

/// Test double that records pause/resume calls.
class _CountingTransport extends FakeTransport {
  int paused = 0;
  int resumed = 0;

  @override
  void pause() => paused++;

  @override
  void resume() => resumed++;
}
