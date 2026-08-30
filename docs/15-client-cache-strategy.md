# Client-Side Caching Strategy

**Date:** 2026-08-30  
**Purpose:** Comprehensive caching strategy for Flutter client to improve performance, reduce network calls, and enable offline functionality

---

## 1. Current State Analysis

### 1.1 Existing Cache Infrastructure

| Component | Storage | What's Cached | Invalidation |
|---|---|---|---|
| **ConfigStore** | SharedPreferences | Relay profiles (host/port/token) | Manual (user forgets device) |
| **AgentRepository** | SharedPreferences | Last agent snapshot | On successful fetch |
| **AgentRepository** | In-memory | Terminal output (by revision) | On revision change |
| **CommandHistoryService** | SharedPreferences | Per-agent command history | Manual (user clears) |

**Storage types available:**
- `SharedPreferences` — key-value store, persisted to disk (async)
- In-memory (`Map<K, V>`) — fast but lost on app restart
- `path_provider` + file I/O — for large binary data (not used yet)

### 1.2 What's NOT Cached (Opportunities)

| Data Type | Current Behavior | Cache Potential | Priority |
|---|---|---|---|
| **Session snapshot** (workspaces/panes) | Fetched every reconnect | High — rarely changes | P1 |
| **Relay modes** (LAN/Tailscale/Funnel) | Fetched on mode picker open | Medium — static config | P2 |
| **Agent metadata** (display names, CWDs) | In snapshot, refetched often | High — bundled with snapshot cache | P1 |
| **Connection test results** | Lost on page close | Low — ephemeral diagnostic | P3 |
| **Suggested actions** (parsed from output) | Recomputed on every output change | Medium — could memoize | P3 |
| **ANSI parsed spans** | Memoized by text hash (in-memory) | Already optimized | — |

---

## 2. Caching Strategy by Data Type

### 2.1 Session Snapshot Cache (P1 — High Impact)

**Problem:**
- Every reconnect → `session.snapshot` RPC (workspaces, panes, agents)
- Snapshot can be 10-50KB JSON for 20+ agents
- Network latency: 50-100ms
- User sees loading spinner during reconnect

**Solution:** Persistent cache with stale-while-revalidate

```dart
class SessionCache {
  final SharedPreferences _prefs;
  static const _key = 'session_snapshot';
  static const _tsKey = 'session_snapshot_ts';
  
  // In-memory cache (fast path)
  RelaySession? _memoryCache;
  
  Future<RelaySession?> get() async {
    // Fast path: in-memory
    if (_memoryCache != null) return _memoryCache;
    
    // Disk cache
    final json = _prefs.getString(_key);
    if (json == null) return null;
    
    try {
      _memoryCache = RelaySession.fromJson(jsonDecode(json));
      return _memoryCache;
    } catch (_) {
      return null;
    }
  }
  
  Future<void> set(RelaySession session) async {
    _memoryCache = session;
    await _prefs.setString(_key, jsonEncode(session.toJson()));
    await _prefs.setString(_tsKey, DateTime.now().toIso8601String());
  }
  
  Future<void> clear() async {
    _memoryCache = null;
    await _prefs.remove(_key);
    await _prefs.remove(_tsKey);
  }
  
  Future<DateTime?> getCachedAt() async {
    final ts = _prefs.getString(_tsKey);
    return ts != null ? DateTime.tryParse(ts) : null;
  }
}
```

**Usage pattern (stale-while-revalidate):**
```dart
// In HomePage initState:
Future<void> _loadSession() async {
  // Show cached immediately (instant UI)
  final cached = await _sessionCache.get();
  if (cached != null) {
    setState(() => _session = cached);
  }
  
  // Fetch fresh in background
  try {
    final fresh = await _client.session();
    await _sessionCache.set(fresh);
    if (mounted) setState(() => _session = fresh);
  } catch (e) {
    // Network error: keep showing cached
    if (cached == null) rethrow;
  }
}
```

**Benefits:**
- Instant UI on app launch (0ms vs 100ms)
- Offline mode: app functional without network (read-only)
- Graceful degradation: stale data better than loading spinner

**Invalidation:**
- On successful `session.snapshot` fetch
- On disconnect (optional — could keep stale data)
- Manual: user "refresh" action

**Risks:**
- Stale agent statuses shown → mitigated by live events (pane.agent_status_changed)
- Deleted agents still visible → fixed on next successful fetch

---

### 2.2 Agent Snapshot Cache (Already Implemented, Enhance)

**Current:** `agent_repository.dart` lines 15-73

**Enhancement 1:** Add TTL metadata
```dart
class AgentRepository {
  static const _cacheTTL = Duration(minutes: 5);
  
  Future<List<RelayAgent>> getAgents() async {
    // Check cache age
    final cacheAge = await _getCacheAge();
    if (cacheAge != null && cacheAge > _cacheTTL) {
      // Too old: clear and refetch
      await _clearCache();
    }
    
    try {
      final agents = await _client.snapshot();
      await _cacheAgents(agents);
      return agents;
    } catch (_) {
      // Fallback to cache even if stale
      final cached = await _loadCachedAgents();
      if (cached.isNotEmpty) return cached;
      rethrow;
    }
  }
  
  Future<Duration?> _getCacheAge() async {
    final ts = await lastCachedAt();
    return ts != null ? DateTime.now().difference(ts) : null;
  }
}
```

**Enhancement 2:** Merge live events into cache
```dart
// When pane.agent_status_changed arrives:
void _onStatusEvent(AgentStatusChanged event) {
  final cached = _loadCachedAgentsSync(); // synchronous read
  if (cached != null) {
    final updated = cached.map((a) {
      if (a.id == event.paneId) {
        return a.copyWith(status: event.status);
      }
      return a;
    }).toList();
    _cacheAgentsSync(updated); // update cache immediately
  }
}
```

**Benefits:**
- Cache stays fresh via live events (no 5-minute staleness)
- Offline-first: app works without network for read-only use

---

### 2.3 Connection Modes Cache (P2 — Medium Impact)

**Problem:**
- Mode picker fetches `/pair` endpoint every time it opens
- Modes rarely change (static config)
- 100-200ms latency for a dropdown

**Solution:** Cache with manual invalidation

```dart
class ModeService {
  final SharedPreferences _prefs;
  static const _key = 'relay_modes';
  static const _tsKey = 'relay_modes_ts';
  static const _ttl = Duration(hours: 24); // modes are static
  
  Future<List<RelayModeInfo>> fetch(PairConfig config) async {
    // Try cache first
    final cached = await _getCache();
    if (cached != null) {
      final age = await _getCacheAge();
      if (age != null && age < _ttl) {
        return cached; // fresh cache: skip network
      }
    }
    
    // Fetch fresh
    try {
      final modes = await _fetchFromRelay(config);
      await _setCache(modes);
      return modes;
    } catch (e) {
      // Network error: return stale cache if available
      if (cached != null) return cached;
      rethrow;
    }
  }
  
  Future<void> invalidate() async {
    await _prefs.remove(_key);
    await _prefs.remove(_tsKey);
  }
}
```

**Usage:**
```dart
// Mode picker: instant open with cached data
final modes = await _modeService.fetch(config); // <5ms if cached
```

**Invalidation:**
- TTL 24 hours (modes rarely change)
- Manual: "Refresh modes" button in settings (optional)

---

### 2.4 Command History Cache (Already Implemented, Document)

**Current:** `command_history_service.dart` — already uses SharedPreferences

**Enhancement:** Add size limit (prevent unbounded growth)
```dart
class CommandHistoryService {
  static const _maxHistoryPerAgent = 100;
  
  Future<void> addCommand(String agentId, String command) async {
    final history = await load(agentId);
    history.add(command);
    
    // Trim to max size (FIFO)
    if (history.length > _maxHistoryPerAgent) {
      history.removeRange(0, history.length - _maxHistoryPerAgent);
    }
    
    await _save(agentId, history);
  }
}
```

---

### 2.5 Terminal Output Cache (Already Implemented in Phase 2)

**Current:** In-memory `Map<paneID, CachedOutput>` with revision tracking

**Already optimal** — no changes needed beyond Phase 2 plan.

---

### 2.6 UI State Cache (Optional — P3)

**Use case:** Remember user preferences across sessions

**Examples:**
- Home page tab index (Spaces/Agents/Run)
- Agent page scroll position
- Terminal font size preference
- Dark mode setting

**Implementation:**
```dart
class UIPreferences {
  final SharedPreferences _prefs;
  
  // Home page last selected tab
  Future<int> getHomeTab() async => _prefs.getInt('home_tab') ?? 0;
  Future<void> setHomeTab(int index) async => await _prefs.setInt('home_tab', index);
  
  // Terminal font size
  Future<double> getTerminalFontSize() async => _prefs.getDouble('terminal_font_size') ?? 12.0;
  Future<void> setTerminalFontSize(double size) async => await _prefs.setDouble('terminal_font_size', size);
  
  // Theme mode
  Future<String> getThemeMode() async => _prefs.getString('theme_mode') ?? 'system';
  Future<void> setThemeMode(String mode) async => await _prefs.setString('theme_mode', mode);
}
```

**Priority:** Low — UX improvement, not performance

---

## 3. Cache Architecture Design

### 3.1 Layered Cache Pattern

```
┌─────────────────────────────────────────────┐
│           UI Layer (Pages/Widgets)          │
└──────────────────┬──────────────────────────┘
                   │
┌──────────────────▼──────────────────────────┐
│         Repository Layer (Caching)          │
│  ┌──────────────────────────────────────┐  │
│  │   In-Memory Cache (Map<K,V>)         │  │ ← Fast path
│  │   - Terminal output                   │  │
│  │   - Session snapshot (singleton)      │  │
│  └──────────────────────────────────────┘  │
│                   │                         │
│  ┌────────────────▼─────────────────────┐  │
│  │   Persistent Cache (SharedPreferences)│ ← Survives restart
│  │   - Agent snapshot                    │  │
│  │   - Session snapshot                  │  │
│  │   - Connection modes                  │  │
│  │   - Command history                   │  │
│  └──────────────────────────────────────┘  │
└──────────────────┬──────────────────────────┘
                   │
┌──────────────────▼──────────────────────────┐
│         Service Layer (Network)             │
│  - RelayClient (WebSocket/HTTP)             │
└─────────────────────────────────────────────┘
```

### 3.2 Cache Abstraction (Generic Helper)

**Create:** `client/lib/utils/cache_manager.dart`

```dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Generic cache manager with TTL and stale-while-revalidate support.
class CacheManager<T> {
  CacheManager({
    required this.prefs,
    required this.key,
    required this.fromJson,
    required this.toJson,
    this.ttl = const Duration(hours: 1),
  });

  final SharedPreferences prefs;
  final String key;
  final T Function(Map<String, dynamic>) fromJson;
  final Map<String, dynamic> Function(T) toJson;
  final Duration ttl;

  String get _timestampKey => '${key}_ts';
  T? _memoryCache;

  /// Get cached value (in-memory fast path, then disk).
  Future<T?> get() async {
    // Memory cache
    if (_memoryCache != null) return _memoryCache;

    // Disk cache
    final json = prefs.getString(key);
    if (json == null) return null;

    try {
      final data = jsonDecode(json) as Map<String, dynamic>;
      _memoryCache = fromJson(data);
      return _memoryCache;
    } catch (e) {
      // Corrupt cache: clear it
      await clear();
      return null;
    }
  }

  /// Set cached value (writes to both memory and disk).
  Future<void> set(T value) async {
    _memoryCache = value;
    await prefs.setString(key, jsonEncode(toJson(value)));
    await prefs.setString(_timestampKey, DateTime.now().toIso8601String());
  }

  /// Clear cache.
  Future<void> clear() async {
    _memoryCache = null;
    await prefs.remove(key);
    await prefs.remove(_timestampKey);
  }

  /// Get cache age (null if never cached).
  Future<Duration?> getAge() async {
    final ts = prefs.getString(_timestampKey);
    if (ts == null) return null;
    final cachedAt = DateTime.tryParse(ts);
    if (cachedAt == null) return null;
    return DateTime.now().difference(cachedAt);
  }

  /// Check if cache is fresh (within TTL).
  Future<bool> isFresh() async {
    final age = await getAge();
    return age != null && age < ttl;
  }

  /// Stale-while-revalidate pattern: return cached immediately, fetch fresh in background.
  Future<T> getOrFetch({
    required Future<T> Function() fetcher,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      // Try cache first
      final cached = await get();
      if (cached != null && await isFresh()) {
        return cached; // Fresh cache: skip fetch
      }

      // Stale cache: return it, but fetch fresh in background
      if (cached != null) {
        fetcher().then((fresh) => set(fresh)).catchError((_) {
          // Fetch failed: keep stale cache
        });
        return cached;
      }
    }

    // No cache or force refresh: fetch fresh
    final fresh = await fetcher();
    await set(fresh);
    return fresh;
  }
}
```

**Usage example:**
```dart
class SessionRepository {
  late final CacheManager<RelaySession> _cache;
  
  SessionRepository(SharedPreferences prefs, RelayClient client) {
    _cache = CacheManager(
      prefs: prefs,
      key: 'session_snapshot',
      fromJson: RelaySession.fromJson,
      toJson: (s) => s.toJson(),
      ttl: Duration(minutes: 5),
    );
  }
  
  Future<RelaySession> getSession({bool forceRefresh = false}) {
    return _cache.getOrFetch(
      fetcher: () => _client.session(),
      forceRefresh: forceRefresh,
    );
  }
}
```

---

## 4. Implementation Plan

### Phase 1: Core Cache Infrastructure (1 day)
**Files to create:**
- `client/lib/utils/cache_manager.dart` — generic cache helper
- `client/lib/utils/cache_manager_test.dart` — unit tests

**Files to modify:**
- None (just adding infrastructure)

**Tests:**
- [ ] CacheManager.get/set/clear
- [ ] CacheManager TTL expiration
- [ ] CacheManager stale-while-revalidate

### Phase 2: Session Snapshot Cache (1 day)
**Files to create:**
- `client/lib/repositories/session_repository.dart` — wraps RelayClient.session()

**Files to modify:**
- `client/lib/pages/spaces_page.dart` — use SessionRepository
- `client/lib/pages/home_page.dart` — use SessionRepository for workspace data
- `client/lib/core/service_locator.dart` — register SessionRepository

**Benefits:**
- 50-100ms faster reconnect (cached session)
- Offline mode: last known session shown

### Phase 3: Connection Modes Cache (0.5 day)
**Files to modify:**
- `client/lib/core/connection/mode_service.dart` — add CacheManager
- `client/lib/widgets/mode_picker_sheet.dart` — show cached modes instantly

**Benefits:**
- Mode picker opens instantly (<5ms vs 100-200ms)

### Phase 4: Enhanced Agent Cache (0.5 day)
**Files to modify:**
- `client/lib/repositories/agent_repository.dart` — add TTL, event-based updates

**Benefits:**
- Cache stays fresh via live events
- Offline-first agent list

### Phase 5: UI Preferences Cache (optional, 0.5 day)
**Files to create:**
- `client/lib/services/ui_preferences.dart`

**Files to modify:**
- `client/lib/pages/home_page.dart` — remember last tab
- `client/lib/widgets/ansi_terminal.dart` — remember font size

**Benefits:**
- Better UX: app remembers user preferences

---

## 5. Cache Invalidation Strategy

| Cache Type | Invalidation Trigger | Strategy |
|---|---|---|
| **Session snapshot** | On successful fetch | Replace |
| **Session snapshot** | On disconnect | Keep (offline mode) |
| **Agent snapshot** | On successful fetch | Replace |
| **Agent snapshot** | Live event (status change) | Merge update |
| **Terminal output** | On revision change | Replace |
| **Connection modes** | TTL 24h | Auto-expire |
| **Command history** | Manual clear | User action |
| **UI preferences** | Never | Persistent |

### Invalidation API
```dart
class CacheInvalidator {
  final SessionRepository _session;
  final AgentRepository _agent;
  final ModeService _modes;
  
  /// Clear all caches (e.g., on logout or device switch).
  Future<void> clearAll() async {
    await _session.clearCache();
    await _agent.clearCache();
    await _modes.invalidate();
  }
  
  /// Clear only transient caches (keep user preferences).
  Future<void> clearTransient() async {
    await _session.clearCache();
    await _agent.clearCache();
    // Keep: modes, command history, UI preferences
  }
}
```

---

## 6. Memory Management

### 6.1 Cache Size Limits

| Cache Type | Max Size | Enforcement |
|---|---|---|
| **In-memory output** | 50 panes × 50KB = 2.5MB | LRU eviction |
| **Persistent session** | ~50KB | Single entry |
| **Persistent agents** | ~20KB | Single entry |
| **Command history** | 100 commands × 100 panes = 1MB | FIFO per agent |
| **Total persistent** | ~2-3MB | Acceptable for mobile |

### 6.2 LRU Eviction for In-Memory Caches

```dart
class LRUCache<K, V> {
  LRUCache(this.maxEntries);
  
  final int maxEntries;
  final _cache = <K, _Entry<V>>{};
  final _lru = <K>[];
  
  V? get(K key) {
    final entry = _cache[key];
    if (entry == null) return null;
    
    // Move to end (most recently used)
    _lru.remove(key);
    _lru.add(key);
    
    return entry.value;
  }
  
  void set(K key, V value) {
    if (_cache.containsKey(key)) {
      _lru.remove(key);
    } else if (_cache.length >= maxEntries) {
      // Evict least recently used
      final evictKey = _lru.removeAt(0);
      _cache.remove(evictKey);
    }
    
    _cache[key] = _Entry(value);
    _lru.add(key);
  }
  
  void clear() {
    _cache.clear();
    _lru.clear();
  }
}

class _Entry<V> {
  _Entry(this.value);
  final V value;
}
```

**Apply to AgentRepository:**
```dart
class AgentRepository {
  final _outputCache = LRUCache<String, _CachedOutput>(50); // max 50 panes
}
```

---

## 7. Monitoring & Metrics

### 7.1 Cache Hit Rate Tracking

```dart
class CacheMetrics {
  int _hits = 0;
  int _misses = 0;
  
  void recordHit() => _hits++;
  void recordMiss() => _misses++;
  
  double get hitRate => _hits + _misses > 0 ? _hits / (_hits + _misses) : 0;
  
  Map<String, dynamic> toJson() => {
    'hits': _hits,
    'misses': _misses,
    'hit_rate': hitRate,
  };
}
```

**Add to each cache:**
```dart
class CacheManager<T> {
  final CacheMetrics metrics = CacheMetrics();
  
  Future<T?> get() async {
    final value = await _getInternal();
    if (value != null) {
      metrics.recordHit();
    } else {
      metrics.recordMiss();
    }
    return value;
  }
}
```

**Expose via debug screen:**
```dart
// DebugPage (or dev menu)
Text('Session cache hit rate: ${sessionRepo.cache.metrics.hitRate.toStringAsFixed(2)}');
Text('Agent cache hit rate: ${agentRepo.metrics.hitRate.toStringAsFixed(2)}');
```

### 7.2 Cache Size Monitoring

```dart
extension SharedPreferencesSize on SharedPreferences {
  int estimateSize() {
    int total = 0;
    for (final key in getKeys()) {
      final value = get(key);
      if (value is String) total += value.length;
    }
    return total;
  }
}

// In debug screen:
final prefs = getIt<SharedPreferences>();
Text('Cache size: ${(prefs.estimateSize() / 1024).toStringAsFixed(1)} KB');
```

---

## 8. Testing Strategy

### 8.1 Unit Tests

```dart
// test/utils/cache_manager_test.dart
test('CacheManager returns null on first get', () async {
  final manager = CacheManager<TestData>(...);
  expect(await manager.get(), isNull);
});

test('CacheManager persists value across instances', () async {
  final prefs = await SharedPreferences.getInstance();
  
  final manager1 = CacheManager<TestData>(prefs: prefs, key: 'test', ...);
  await manager1.set(TestData('hello'));
  
  final manager2 = CacheManager<TestData>(prefs: prefs, key: 'test', ...);
  expect(await manager2.get(), equals(TestData('hello')));
});

test('CacheManager TTL expires', () async {
  final manager = CacheManager<TestData>(ttl: Duration(milliseconds: 50), ...);
  await manager.set(TestData('value'));
  
  await Future.delayed(Duration(milliseconds: 60));
  
  expect(await manager.isFresh(), isFalse);
});

test('stale-while-revalidate returns cached immediately', () async {
  final manager = CacheManager<TestData>(...);
  await manager.set(TestData('stale'));
  
  final stopwatch = Stopwatch()..start();
  final result = await manager.getOrFetch(
    fetcher: () async {
      await Future.delayed(Duration(milliseconds: 100));
      return TestData('fresh');
    },
  );
  stopwatch.stop();
  
  // Should return stale immediately (<10ms)
  expect(stopwatch.elapsedMilliseconds, lessThan(10));
  expect(result, equals(TestData('stale')));
});
```

### 8.2 Integration Tests

```dart
// test/repositories/session_repository_test.dart
test('SessionRepository serves cached session on reconnect', () async {
  final client = FakeRelayClient();
  final repo = SessionRepository(client, mockPrefs);
  
  // First fetch
  await repo.getSession();
  expect(client.sessionCallCount, 1);
  
  // Simulate disconnect/reconnect
  client.disconnect();
  client.connect();
  
  // Second fetch: should use cache (no network call)
  await repo.getSession();
  expect(client.sessionCallCount, 1); // still 1
});
```

### 8.3 Widget Tests

```dart
testWidgets('HomePage shows cached agents immediately', (tester) async {
  final client = FakeRelayClient();
  final prefs = await SharedPreferences.getInstance();
  
  // Seed cache
  await prefs.setString('last_snapshot', jsonEncode([...]));
  
  await tester.pumpWidget(MyApp());
  
  // Verify agents shown immediately (before network completes)
  expect(find.byType(AgentTile), findsWidgets);
  expect(find.byType(CircularProgressIndicator), findsNothing);
});
```

---

## 9. Migration Plan

### 9.1 Rollout Strategy

1. **Phase 1 (infrastructure):** Merge CacheManager utility
2. **Phase 2 (high impact):** Session cache + enhanced agent cache
   - Deploy to beta testers (10% of users)
   - Monitor crash rates, cache hit rates
3. **Phase 3 (polish):** Modes cache + UI preferences
4. **Phase 4 (cleanup):** Remove legacy cache code, document

### 9.2 Feature Flags

```dart
class FeatureFlags {
  static const enableSessionCache = true;  // can toggle via remote config
  static const enableModesCache = true;
  static const enableUIPreferences = true;
}

// Usage:
if (FeatureFlags.enableSessionCache) {
  return await _sessionRepo.getSession();
} else {
  return await _client.session(); // old path
}
```

### 9.3 Backward Compatibility

**Old cache keys remain valid:**
- `last_snapshot` (agents) — already in use
- `session_snapshot` — new, no conflict
- `relay_modes` — new, no conflict

**Migration:** Not needed (additive changes only)

---

## 10. Performance Targets

| Metric | Before | After | Improvement |
|---|---|---|---|
| **App launch to UI** | 200-300ms | 50-100ms | 66% faster |
| **Reconnect to agents visible** | 100-200ms | 10-20ms | 90% faster |
| **Mode picker open** | 100-200ms | <5ms | 95% faster |
| **Offline agent list** | Not available | Available | ∞ |
| **Cache storage** | ~50KB | ~2-3MB | +2.5MB (acceptable) |

---

## 11. Summary & Recommendations

### Immediate Priority (Week 1-2):
1. ✅ **Implement CacheManager utility** (1 day)
2. ✅ **Session snapshot cache** (1 day) — biggest UX win
3. ✅ **Enhanced agent cache with TTL** (0.5 day)

### Near-term (Week 3-4):
4. ✅ **Connection modes cache** (0.5 day)
5. ✅ **Add cache metrics/monitoring** (0.5 day)

### Future (Month 2+):
6. **UI preferences cache** (0.5 day) — UX polish
7. **LRU eviction for output cache** (0.5 day) — memory optimization

### Total Effort: **4-5 days** for core features (Phases 1-4)

---

## Appendix A: Files to Create/Modify

### New Files:
- `client/lib/utils/cache_manager.dart`
- `client/lib/utils/cache_manager_test.dart`
- `client/lib/repositories/session_repository.dart`
- `client/lib/repositories/session_repository_test.dart`
- `client/lib/services/ui_preferences.dart` (optional)

### Modified Files:
- `client/lib/repositories/agent_repository.dart` (add TTL)
- `client/lib/core/connection/mode_service.dart` (add cache)
- `client/lib/pages/home_page.dart` (use SessionRepository)
- `client/lib/pages/spaces_page.dart` (use SessionRepository)
- `client/lib/core/service_locator.dart` (register new services)

**End of strategy document.**
