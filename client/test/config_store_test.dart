import 'dart:convert';

import 'package:client/models/pair_config.dart';
import 'package:client/services/config_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  PairConfig profile({
    String? relayId,
    String? name,
    String host = 'h',
    int port = 8375,
    String? token,
    String mode = 'lan',
  }) =>
      PairConfig(
        host: host,
        port: port,
        mode: mode,
        token: token ?? 'x' * 64,
        relayId: relayId,
        name: name,
      );

  final store = ConfigStore();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('пустое хранилище — нет профилей и активного', () async {
    expect(await store.loadProfiles(), isEmpty);
    expect(await store.loadActive(), isNull);
  });

  test('миграция легаси pair_config в профиль + активный', () async {
    final legacy = profile(host: 'old-host', token: 't' * 64).toJson();
    SharedPreferences.setMockInitialValues({
      'pair_config': jsonEncode(legacy),
    });

    final profiles = await store.loadProfiles();
    expect(profiles, hasLength(1));
    expect(profiles.first.host, 'old-host');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('pair_config'), isNull,
        reason: 'легаси-ключ должен удаляться');
    expect(prefs.getString('active_profile'), 'old-host:8375');
    expect((await store.loadActive())?.host, 'old-host');
  });

  test('upsert по relayId — повторное сохранение не плодит дубли', () async {
    await store.saveProfile(profile(relayId: 'r1', host: 'a'));
    await store.saveProfile(profile(relayId: 'r1', host: 'b'));

    final profiles = await store.loadProfiles();
    expect(profiles, hasLength(1));
    expect(profiles.first.host, 'b');
    expect((await store.loadActive())?.profileKey, 'r1');
  });

  test('без relayId — каждый релей отдельный профиль, активен последний', () async {
    await store.saveProfile(profile(host: 'a'));
    await store.saveProfile(profile(host: 'b', port: 9000));

    final profiles = await store.loadProfiles();
    expect(profiles, hasLength(2));
    expect((await store.loadActive())?.host, 'b');
  });

  test('setActive переключает активный профиль', () async {
    await store.saveProfile(profile(relayId: 'r1', host: 'a'));
    await store.saveProfile(profile(relayId: 'r2', host: 'b'));

    await store.setActive('r1');
    expect((await store.loadActive())?.profileKey, 'r1');

    await store.setActive('r2');
    expect((await store.loadActive())?.profileKey, 'r2');
  });

  test('forget удаляет профиль, активность падает на следующий', () async {
    await store.saveProfile(profile(relayId: 'r1', host: 'a'));
    await store.saveProfile(profile(relayId: 'r2', host: 'b'));
    await store.setActive('r1');

    await store.forget('r1');
    final profiles = await store.loadProfiles();
    expect(profiles, hasLength(1));
    expect(profiles.first.profileKey, 'r2');
    expect((await store.loadActive())?.profileKey, 'r2');
  });

  test('forget последнего профиля — пусто и активного нет', () async {
    await store.saveProfile(profile(relayId: 'r1', host: 'a'));

    await store.forget('r1');
    expect(await store.loadProfiles(), isEmpty);
    expect(await store.loadActive(), isNull);
  });

  test('clear удаляет все ключи, включая легаси', () async {
    SharedPreferences.setMockInitialValues({
      'pair_config': jsonEncode(profile(host: 'legacy').toJson()),
    });
    await store.saveProfile(profile(relayId: 'r1', host: 'a'));

    await store.clear();
    expect(await store.loadProfiles(), isEmpty);
    expect(await store.loadActive(), isNull);
  });

  test('конкурентные saveProfile не теряют профили', () async {
    // Два "deep link" одновременно: каждый добавляет свой профиль. Без
    // сериализации read-modify-write один из них был бы перезаписан.
    await Future.wait([
      store.saveProfile(profile(relayId: 'r1', host: 'a')),
      store.saveProfile(profile(relayId: 'r2', host: 'b')),
    ]);

    final profiles = await store.loadProfiles();
    expect(profiles, hasLength(2));
    expect(profiles.map((p) => p.profileKey), containsAll(['r1', 'r2']));
  });

  test('конкурентный upsert одного и того же профиля оставляет один', () async {
    await Future.wait([
      store.saveProfile(profile(relayId: 'r1', host: 'a')),
      store.saveProfile(profile(relayId: 'r1', host: 'b')),
    ]);

    final profiles = await store.loadProfiles();
    expect(profiles, hasLength(1));
    expect(profiles.first.host, anyOf('a', 'b'));
  });
}