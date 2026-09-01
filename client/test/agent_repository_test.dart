import 'package:client/repositories/agent_repository.dart';
import 'package:client/services/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_relay_client.dart';

void main() {
  late FakeRelayClient client;
  late AgentRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    client = FakeRelayClient();
    repo = AgentRepository(client, AppSettings(prefs));
  });

  test('ревизия 0 никогда не даёт кэш-хит — всегда RPC', () async {
    client.outputText = 'первый';
    client.outputRevision = 0;
    await repo.getOutput('p1', knownRevision: 0);
    await repo.getOutput('p1', knownRevision: 0);
    expect(client.outputCalls, 2,
        reason: 'revision 0 means "changed/unknown", cached text is stale');
  });

  test('отсутствующая ревизия (null) — всегда RPC', () async {
    client.outputText = 'первый';
    client.outputRevision = 3;
    await repo.getOutput('p1', knownRevision: null);
    await repo.getOutput('p1', knownRevision: null);
    expect(client.outputCalls, 2);
  });

  test('совпадающая ненулевая ревизия даёт кэш-хит', () async {
    client.outputText = 'первый';
    client.outputRevision = 5;
    await repo.getOutput('p1', knownRevision: 5);
    await repo.getOutput('p1', knownRevision: 5);
    expect(client.outputCalls, 1);
    expect(await repo.getOutput('p1', knownRevision: 5), 'первый');
  });

  test('разная ревизия — RPC и обновление кэша', () async {
    client.outputText = 'первый';
    client.outputRevision = 5;
    await repo.getOutput('p1', knownRevision: 5);
    client.outputText = 'второй';
    client.outputRevision = 6;
    await repo.getOutput('p1', knownRevision: 6);
    expect(client.outputCalls, 2);
    expect(await repo.getOutput('p1', knownRevision: 6), 'второй');
  });

  test('LRU: переполнение кэша вытесняет старейшие записи', () async {
    client.outputText = 'x';
    client.outputRevision = 1;
    for (var i = 0; i < 60; i++) {
      await repo.getOutput('p$i', knownRevision: 1);
    }
    // 60 записей > кап 50: первые 10 вытеснены, последние в кэше.
    final before = client.outputCalls;
    await repo.getOutput('p0', knownRevision: 1); // вытеснена — снова RPC
    expect(client.outputCalls, before + 1);
    final before2 = client.outputCalls;
    await repo.getOutput('p59', knownRevision: 1); // в кэше — кэш-хит
    expect(client.outputCalls, before2);
  });

  test('pane.output использует тот же кэш и правило ревизий', () async {
    client.outputText = 'shell';
    client.outputRevision = 2;
    await repo.getPaneOutput('w7:p1', knownRevision: 2);
    await repo.getPaneOutput('w7:p1', knownRevision: 2);
    expect(client.paneOutputCalls, 1);
    await repo.getPaneOutput('w7:p1', knownRevision: 0);
    expect(client.paneOutputCalls, 2);
  });
}
