import 'dart:async';

import 'package:client/controllers/session_controller.dart';
import 'package:client/core/service_locator.dart';
import 'package:client/models/pair_config.dart';
import 'package:client/models/relay_event.dart';
import 'package:client/models/relay_session.dart';
import 'package:client/services/relay_client.dart';
import 'package:client/utils/async_value.dart';
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

  const session = RelaySession(
    workspaces: [RelayWorkspace(id: 'wH', label: 'herdr_relay')],
    panes: [
      RelayPane(id: 'wH:p8', workspaceId: 'wH', tabId: 'wH:t1', agent: 'kimi'),
      RelayPane(id: 'wH:p9', workspaceId: 'wH', tabId: 'wH:t1', agent: ''),
    ],
  );

  group('SessionController', () {
    testWidgets('ensureLoaded fetches once; refresh reloads', (tester) async {
      final client = FakeRelayClient()..sessionData = session;
      await setupTestDependencies(client, config);
      final c = getIt<SessionController>();

      expect(client.sessionCalls, 0, reason: 'lazy — nothing fetched yet');
      c.ensureLoaded();
      c.ensureLoaded(); // no-op while a load is in flight/done
      await tester.pump();
      expect(client.sessionCalls, 1);
      expect(c.state, isA<AsyncData<RelaySession>>());

      await c.refresh();
      expect(client.sessionCalls, 2);

      await teardownTestDependencies();
    });

    testWidgets('pane structure change reloads the session (debounced)',
        (tester) async {
      final client = FakeRelayClient()..sessionData = session;
      await setupTestDependencies(client, config);
      final c = getIt<SessionController>();
      c.ensureLoaded();
      await tester.pump();
      expect(client.sessionCalls, 1);

      // Pane structure changes (not agent status — those live in AgentsStore)
      // invalidate the session snapshot, so it is re-read debounced.
      client.emit(const PaneUpdated(paneId: 'wH:p10'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(client.sessionCalls, 2,
          reason: 'pane structure events must re-read the session');

      await teardownTestDependencies();
    });

    testWidgets('reconnect catch-up re-reads the session', (tester) async {
      final client = FakeRelayClient()..sessionData = session;
      await setupTestDependencies(client, config);
      final c = getIt<SessionController>();
      c.ensureLoaded();
      await tester.pump();
      final before = client.sessionCalls;

      client.status.value = RelayStatus.disconnected;
      client.status.value = RelayStatus.connected;
      await tester.pump();
      expect(client.sessionCalls, greaterThan(before),
          reason: 'reconnect after a gap must reload the session');

      await teardownTestDependencies();
    });

    testWidgets('generation guard discards a stale response', (tester) async {
      final client = FakeRelayClient()..sessionData = session;
      await setupTestDependencies(client, config);
      final c = getIt<SessionController>();

      // First load blocked on the gate; a newer refresh supersedes it.
      final gate = Completer<void>();
      client.firstSessionGate = gate;
      client.sessionData = const RelaySession(
        workspaces: [RelayWorkspace(id: 'old', label: 'old-ws')],
        panes: [],
      );
      c.refresh(); // call 1 — blocked
      await tester.pump();

      client.sessionData = const RelaySession(
        workspaces: [RelayWorkspace(id: 'new', label: 'new-ws')],
        panes: [],
      );
      await c.refresh(); // call 2 — returns immediately
      expect(c.state.dataOrNull?.workspaces.single.id, 'new');

      // Unblock the stale call — its response must be discarded.
      gate.complete();
      await tester.pump();
      expect(c.state.dataOrNull?.workspaces.single.id, 'new',
          reason: 'a stale (older generation) response must not win');

      await teardownTestDependencies();
    });

    testWidgets('freePaneFor returns the first agent-less pane', (tester) async {
      final client = FakeRelayClient()..sessionData = session;
      await setupTestDependencies(client, config);
      final c = getIt<SessionController>();
      c.ensureLoaded();
      await tester.pump();

      expect(c.freePaneFor('wH')?.id, 'wH:p9');
      expect(c.freePaneFor('missing'), isNull);
      expect(c.freePaneFor(null), isNull);

      await teardownTestDependencies();
    });
  });
}
