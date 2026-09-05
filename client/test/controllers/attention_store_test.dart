import 'package:client/controllers/agents_store.dart';
import 'package:client/controllers/attention_store.dart';
import 'package:client/models/relay_agent.dart';
import 'package:client/models/relay_event.dart';
import 'package:client/repositories/agent_repository.dart';
import 'package:client/services/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_relay_client.dart';

/// AttentionStore: "finished while you were away" tracking.
///
/// A pane becomes unseen on a `working → done/idle` transition that happens
/// while its chat is not open; it clears on view, on a restart (working), or
/// when the pane disappears. Marks persist across launches (AppSettings).
void main() {
  late AppSettings settings;
  late FakeRelayClient client;
  late AgentRepository repository;
  late AgentsStore agents;
  late AttentionStore attention;

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  /// Emits a status event for [paneId] and lets the broadcast deliver it.
  Future<void> status(String paneId, String status) async {
    client.emit(AgentStatusChanged(paneId: paneId, status: status));
    await flush();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    settings = AppSettings(prefs);
    client = FakeRelayClient();
    repository = AgentRepository(client, settings);
    agents = AgentsStore(repository);
    attention = AttentionStore(repository, agents, settings);
  });

  tearDown(() {
    attention.dispose();
    agents.dispose();
  });

  test('working -> done while away marks the pane unseen', () async {
    await status('p1', 'working'); // first sighting: no transition context
    expect(attention.isUnseen('p1'), isFalse);

    await status('p1', 'done'); // finish while not viewing
    expect(attention.isUnseen('p1'), isTrue);
    expect(attention.unseenCount, 1);
  });

  test('finish while the chat is open is NOT marked', () async {
    attention.view('p1'); // user is reading this pane
    await status('p1', 'working');
    await status('p1', 'done');
    expect(attention.isUnseen('p1'), isFalse);

    attention.closeView('p1');
  });

  test('viewing the pane clears the mark', () async {
    await status('p1', 'working');
    await status('p1', 'done');
    expect(attention.unseenCount, 1);

    attention.view('p1'); // opening the chat = seen
    expect(attention.isUnseen('p1'), isFalse);
    expect(attention.unseenCount, 0);
  });

  test('agent starting to work again clears the mark', () async {
    await status('p1', 'working');
    await status('p1', 'done');
    expect(attention.isUnseen('p1'), isTrue);

    await status('p1', 'working'); // restarted
    expect(attention.isUnseen('p1'), isFalse);
  });

  test('blocked does not mark (it has its own notification path)', () async {
    await status('p1', 'working');
    await status('p1', 'blocked');
    expect(attention.isUnseen('p1'), isFalse);
  });

  test('marks survive a restart and are loaded back', () async {
    await status('p1', 'working');
    await status('p1', 'done');
    expect(attention.isUnseen('p1'), isTrue);
    expect(settings.unseenDoneIds, contains('p1'));

    // "Restart": a fresh store over the same persisted settings.
    final again = AttentionStore(repository, agents, settings);
    addTearDown(again.dispose);
    expect(again.isUnseen('p1'), isTrue,
        reason: 'finish marked before the app was closed stays unseen');
  });

  test('a finish while the app is closed is caught after reopen '
      '(prev seeded from the snapshot)', () async {
    // The snapshot already reports the agent as working when the app opens.
    client.agents = [
      const RelayAgent(id: 'p1', agent: 'codex', status: 'working'),
    ];
    await agents.refresh();
    await flush();

    await status('p1', 'done'); // finishes while the user is elsewhere
    expect(attention.isUnseen('p1'), isTrue,
        reason: 'prev=working came from the snapshot seed');
  });

  test('marks are pruned when the pane disappears from the snapshot',
      () async {
    client.agents = [
      const RelayAgent(id: 'p1', agent: 'codex', status: 'working'),
    ];
    await agents.refresh();
    await flush();
    await status('p1', 'done');
    expect(attention.isUnseen('p1'), isTrue);

    // Pane gone on the next refresh -> the stale mark is dropped.
    client.agents = [const RelayAgent(id: 'p2', agent: 'kimi', status: 'idle')];
    await agents.refresh();
    await flush();
    expect(attention.isUnseen('p1'), isFalse);
  });
}
