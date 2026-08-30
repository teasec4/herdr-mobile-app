import 'dart:async';

import 'package:client/controllers/agents_store.dart';
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

  RelayAgent agent(String id, String status, {String workspace = ''}) =>
      RelayAgent.fromJson({
        'pane_id': id,
        'agent': id,
        'agent_status': status,
        'workspace_id': workspace,
      });

  late FakeRelayClient client;
  late AgentRepository repository;

  setUp(() async {
    client = FakeRelayClient();
    await setupTestDependencies(client, config);
    repository = getIt<AgentRepository>();
  });

  tearDown(teardownTestDependencies);

  group('AgentsStore', () {
    testWidgets('status delta applies locally without a snapshot',
        (tester) async {
      client.agents = [agent('p1', 'idle')];
      final store = AgentsStore(repository);
      await store.refresh();
      expect(client.snapshotCalls, 1);

      final before = client.snapshotCalls;
      client.emit(AgentStatusChanged(paneId: 'p1', status: 'blocked'));
      await tester.pump();

      expect(store.state.dataOrNull!.single.status, 'blocked');
      expect(store.statusOf('p1'), 'blocked');
      expect(client.snapshotCalls, before,
          reason: 'status events must not re-fetch the snapshot');
    });

    testWidgets('unknown pane falls back to a debounced snapshot',
        (tester) async {
      client.agents = [agent('p1', 'idle')];
      final store = AgentsStore(repository);
      await store.refresh();
      final before = client.snapshotCalls;

      client.emit(AgentStatusChanged(paneId: 'p-unknown', status: 'working'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(client.snapshotCalls, greaterThan(before));
    });

    testWidgets('pane.updated bumps structureRevision and schedules a snapshot',
        (tester) async {
      client.agents = [agent('p1', 'idle')];
      final store = AgentsStore(repository);
      await store.refresh();
      final before = client.snapshotCalls;

      client.emit(const PaneUpdated(paneId: 'p2'));
      // Broadcast delivery is asynchronous — flush it before asserting.
      await tester.pump();
      expect(store.structureRevision.value, 1,
          reason: 'SessionController derives session reloads from this');
      await tester.pump(const Duration(milliseconds: 400));
      expect(client.snapshotCalls, greaterThan(before));
    });

    testWidgets('reconnect catch-up re-reads the list', (tester) async {
      client.agents = [agent('p1', 'idle')];
      final store = AgentsStore(repository);
      await store.refresh();
      final before = client.snapshotCalls;

      client.status.value = RelayStatus.disconnected;
      client.status.value = RelayStatus.connected;
      await tester.pump();
      expect(client.snapshotCalls, greaterThan(before));
    });

    testWidgets('generation guard discards a stale response', (tester) async {
      final gate = Completer<void>();
      client.firstSnapshotGate = gate;
      client.agents = [agent('p-old', 'idle')];
      final store = AgentsStore(repository);
      store.refresh(); // call 1 — blocked on the gate
      await tester.pump();

      client.agents = [agent('p-new', 'working')];
      await store.refresh(); // call 2 — returns immediately
      expect(store.state.dataOrNull!.single.id, 'p-new');

      gate.complete(); // stale response must be discarded
      await tester.pump();
      expect(store.state.dataOrNull!.single.id, 'p-new');
    });

    testWidgets('workspaceStatus aggregates per-workspace priorities',
        (tester) async {
      client.agents = [
        agent('p1', 'idle', workspace: 'w1'),
        agent('p2', 'blocked', workspace: 'w1'),
        agent('p3', 'working', workspace: 'w2'),
      ];
      final store = AgentsStore(repository);
      await store.refresh();

      expect(store.workspaceStatus('w1'), 'blocked');
      expect(store.workspaceStatus('w2'), 'working');
      expect(store.workspaceStatus('w3'), 'unknown',
          reason: 'a workspace with no agents is unknown');
    });
  });
}
