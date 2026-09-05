import 'package:client/models/relay_agent.dart';
import 'package:client/services/background_blocked_watch.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

RelayAgent agent(String id, String status) => RelayAgent(
      id: id,
      agent: 'codex',
      status: status,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('newlyBlocked', () {
    test('returns only blocked agents not in the seen set', () {
      final agents = [
        agent('p1', 'blocked'),
        agent('p2', 'blocked'),
        agent('p3', 'working'),
      ];
      expect(newlyBlocked(agents, {'p1'}).map((a) => a.id), ['p2']);
      expect(newlyBlocked(agents, {'p1', 'p2'}), isEmpty);
    });

    test('an empty seen set reports every blocked agent', () {
      final blocked = newlyBlocked([agent('p1', 'blocked')], <String>{});
      expect(blocked.map((a) => a.id), ['p1']);
    });

    test('is case-insensitive about the blocked status', () {
      final blocked = newlyBlocked([agent('p1', 'Blocked')], <String>{});
      expect(blocked, hasLength(1));
    });
  });

  group('nextSeen', () {
    test('keeps blocked ids and drops agents that left the state', () {
      final seen = nextSeen([
        agent('p1', 'blocked'),
        agent('p2', 'idle'), // was blocked, now free -> drop
      ]);
      expect(seen, {'p1'});
    });

    test('a re-blocked agent notifies again (dropped from the previous seen)',
        () {
      final first = nextSeen([agent('p1', 'blocked')]);
      expect(newlyBlocked([agent('p1', 'blocked')], first), isEmpty);

      // p1 got unstuck, then blocked again later.
      final later = nextSeen([agent('p1', 'idle')]);
      expect(newlyBlocked([agent('p1', 'blocked')], later), hasLength(1));
    });
  });

  group('heartbeatFresh', () {
    test('null heartbeat is never fresh', () {
      expect(heartbeatFresh(1000, null), isFalse);
    });

    test('fresh within the window, stale outside it', () {
      const window = Duration(milliseconds: 200);
      expect(heartbeatFresh(1000, 950, window), isTrue); // 50 ms ago
      expect(heartbeatFresh(1000, 500, window), isFalse); // 500 ms ago
    });
  });

  group('seen persistence', () {
    test('read/write round-trips through SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      expect(await readSeen(prefs), isEmpty);
      await writeSeen(prefs, {'p1', 'p2'});
      expect(await readSeen(prefs), {'p1', 'p2'});
    });

    test('corrupt stored data degrades to an empty set', () async {
      SharedPreferences.setMockInitialValues(
          {'blocked_seen_v1': 'not-json{{{'});
      final prefs = await SharedPreferences.getInstance();
      expect(await readSeen(prefs), isEmpty);
    });
  });
}
