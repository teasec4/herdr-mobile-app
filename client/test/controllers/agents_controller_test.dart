import 'dart:async';

import 'package:client/controllers/agents_controller.dart';
import 'package:client/core/service_locator.dart';
import 'package:client/models/pair_config.dart';
import 'package:client/models/relay_agent.dart';
import 'package:client/models/relay_event.dart';
import 'package:client/repositories/agent_repository.dart';
import 'package:client/services/relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/fake_relay_client.dart';
import '../test_helper.dart';

void main() {
  final config = PairConfig(
    host: 'h',
    port: 1,
    mode: 'lan',
    token: '0123456789abcdef0123456789abcdef',
  );

  RelayAgent agent(String id, String status) => RelayAgent.fromJson({
        'pane_id': id,
        'agent': id,
        'agent_status': status,
      });

  late FakeRelayClient client;
  late AgentRepository repository;

  setUp(() async {
    client = FakeRelayClient();
    await setupTestDependencies(client, config);
    repository = getIt<AgentRepository>();
  });

  tearDown(teardownTestDependencies);

  group('AgentsController', () {
    testWidgets('status delta applies locally without a snapshot',
        (tester) async {
      client.agents = [agent('p1', 'idle')];
      final c = AgentsController(repository);
      await c.refresh();
      expect(client.snapshotCalls, 1);

      final before = client.snapshotCalls;
      client.emit(AgentStatusChanged(paneId: 'p1', status: 'blocked'));
      await tester.pump();

      expect(c.state.dataOrNull!.single.status, 'blocked');
      expect(client.snapshotCalls, before,
          reason: 'status events must not re-fetch the snapshot');
    });

    testWidgets('unknown pane falls back to a debounced snapshot',
        (tester) async {
      client.agents = [agent('p1', 'idle')];
      final c = AgentsController(repository);
      await c.refresh();
      final before = client.snapshotCalls;

      client.emit(AgentStatusChanged(paneId: 'p-unknown', status: 'working'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(client.snapshotCalls, greaterThan(before));
    });

    testWidgets('pane.updated schedules a debounced snapshot', (tester) async {
      client.agents = [agent('p1', 'idle')];
      final c = AgentsController(repository);
      await c.refresh();
      final before = client.snapshotCalls;

      client.emit(const PaneUpdated(paneId: 'p2'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(client.snapshotCalls, greaterThan(before));
    });

    testWidgets('reconnect catch-up re-reads the list', (tester) async {
      client.agents = [agent('p1', 'idle')];
      final c = AgentsController(repository);
      await c.refresh();
      final before = client.snapshotCalls;

      client.status.value = RelayStatus.disconnected;
      client.status.value = RelayStatus.connected;
      await tester.pump();
      expect(client.snapshotCalls, greaterThan(before));
    });

    testWidgets('setPaused ignores events; unpause refreshes', (tester) async {
      client.agents = [agent('p1', 'idle')];
      final c = AgentsController(repository);
      await c.refresh();

      c.setPaused(true);
      final before = client.snapshotCalls;
      client.emit(AgentStatusChanged(paneId: 'p1', status: 'blocked'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.state.dataOrNull!.single.status, 'idle',
          reason: 'events while covered are ignored');
      expect(client.snapshotCalls, before);

      c.setPaused(false); // unpause triggers the catch-up refresh
      await tester.pump();
      expect(client.snapshotCalls, greaterThan(before));
    });

    testWidgets('generation guard discards a stale response', (tester) async {
      final gate = Completer<void>();
      client.firstSnapshotGate = gate;
      client.agents = [agent('p-old', 'idle')];
      final c = AgentsController(repository);
      c.refresh(); // call 1 — blocked on the gate
      await tester.pump();

      client.agents = [agent('p-new', 'working')];
      await c.refresh(); // call 2 — returns immediately
      expect(c.state.dataOrNull!.single.id, 'p-new');

      gate.complete(); // stale response must be discarded
      await tester.pump();
      expect(c.state.dataOrNull!.single.id, 'p-new');
    });
  });
}
