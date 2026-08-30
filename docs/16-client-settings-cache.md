# Client Settings & Preferences Cache — What's Implemented & What's Missing

**Date:** 2026-08-30  
**Status:** Analysis of current state + recommendations

---

## 1. What's Already Cached ✅

### 1.1 Terminal Output Cache (AgentRepository)
**File:** `client/lib/repositories/agent_repository.dart:27-28, 80-109`

```dart
final Map<String, _CachedOutput> _outputCache = {};

Future<String> getOutput(String agentId, {int lines = 500, int? knownRevision}) async {
  final cached = _outputCache[agentId];
  if (knownRevision != null && cached != null && cached.revision == knownRevision) {
    return cached.text; // ✅ Cache hit: skip RPC
  }
  // ... fetch fresh
}
```

**Status:** ✅ **DONE** — in-memory cache with revision tracking  
**Coverage:** Terminal output для всех agents/panes  
**Invalidation:** По revision change из событий

---

### 1.2 Agent Snapshot Cache (AgentRepository)
**File:** `client/lib/repositories/agent_repository.dart:15-78`

```dart
static const String _cacheKey = 'last_snapshot';

Future<List<RelayAgent>> getAgents() async {
  try {
    final agents = await _client.snapshot();
    await _cacheAgents(agents); // ✅ Persist to SharedPreferences
    return agents;
  } catch (_) {
    final cached = await _loadCachedAgents(); // ✅ Offline fallback
    if (cached.isNotEmpty) return cached;
    rethrow;
  }
}
```

**Status:** ✅ **DONE** — persistent cache (SharedPreferences)  
**Coverage:** Agent list для offline mode  
**Invalidation:** On successful fetch

---

### 1.3 Connection Profiles Cache (ConfigStore)
**File:** `client/lib/services/config_store.dart:27-143`

```dart
static const String _profilesKey = 'pair_profiles';
static const String _activeKey = 'active_profile';

Future<List<PairConfig>> loadProfiles() // ✅ All saved relays
Future<PairConfig?> loadActive()        // ✅ Current relay
Future<void> saveProfile(PairConfig)    // ✅ Add/update relay
```

**Status:** ✅ **DONE** — persistent profiles with active selection  
**Coverage:** Multiple relay connections (home/work/etc)  
**Invalidation:** Manual (user forgets device)

---

### 1.4 Command History Cache (CommandHistoryService)
**File:** `client/lib/services/command_history_service.dart:4-53`

```dart
static const String _keyPrefix = 'command_history_';
static const int _maxHistorySize = 100;

Future<void> addCommand(String agentId, String command) async {
  final history = await load(agentId);
  history.add(command);
  if (history.length > _maxHistorySize) {
    history.removeRange(0, history.length - _maxHistorySize);
  }
  await save(agentId, history); // ✅ Persist per-agent history
}
```

**Status:** ✅ **DONE** — persistent, per-agent, max 100 commands  
**Coverage:** Command history для agent prompt input  
**Invalidation:** Manual clear or size limit

---

## 2. What's NOT Cached (Opportunities) 🚧

### 2.1 UI Preferences — **HIGH PRIORITY**

#### 2.1.1 Home Page Tab Selection
**Current behavior:** Always opens on "Spaces" tab (index 0)  
**Problem:** User switches to "Agents" tab → closes app → reopens → back to "Spaces"

**File:** `client/lib/pages/home_page.dart:61`
```dart
int _tabIndex = 0; // ❌ Always resets to Spaces
```

**Solution:**
```dart
class UIPreferences {
  final SharedPreferences _prefs;
  
  Future<int> getHomeTab() async => _prefs.getInt('home_tab_index') ?? 0;
  Future<void> setHomeTab(int index) async => _prefs.setInt('home_tab_index', index);
}

// In HomePage:
@override
void initState() {
  super.initState();
  _loadTabIndex();
}

Future<void> _loadTabIndex() async {
  final prefs = getIt<UIPreferences>();
  final savedIndex = await prefs.getHomeTab();
  if (mounted) setState(() => _tabIndex = savedIndex);
}

// In NavigationBar:
onDestinationSelected: (i) {
  setState(() => _tabIndex = i);
  getIt<UIPreferences>().setHomeTab(i); // ✅ Remember selection
}
```

**Impact:** Better UX — app remembers user's preferred view

---

#### 2.1.2 Terminal Font Size
**Current behavior:** Hardcoded 12px in AnsiTerminal.defaultStyle

**File:** `client/lib/widgets/ansi_terminal.dart:37-44`
```dart
static const TextStyle defaultStyle = TextStyle(
  fontFamily: 'monospace',
  fontSize: 12, // ❌ Hardcoded, no user control
  // ...
);
```

**Problem:** 
- На маленьких экранах (phones) 12px может быть мелковато
- На планшетах можно было бы больше
- Accessibility: пользователи с плохим зрением не могут увеличить

**Solution:**
```dart
class UIPreferences {
  Future<double> getTerminalFontSize() async => 
    _prefs.getDouble('terminal_font_size') ?? 12.0;
  
  Future<void> setTerminalFontSize(double size) async =>
    _prefs.setDouble('terminal_font_size', size);
}

// In AgentPage:
Widget _buildOutput(ThemeData theme) {
  final fontSize = _terminalFontSize; // from initState
  return AnsiTerminal(
    text: _output,
    style: AnsiTerminal.defaultStyle.copyWith(fontSize: fontSize),
  );
}

// Add UI controls (+ / - buttons or slider):
Row(
  children: [
    IconButton(
      icon: Icon(Icons.remove),
      onPressed: () => _adjustFontSize(-1),
    ),
    Text('${_terminalFontSize.toInt()}px'),
    IconButton(
      icon: Icon(Icons.add),
      onPressed: () => _adjustFontSize(1),
    ),
  ],
)

void _adjustFontSize(double delta) async {
  final newSize = (_terminalFontSize + delta).clamp(8.0, 24.0);
  setState(() => _terminalFontSize = newSize);
  await getIt<UIPreferences>().setTerminalFontSize(newSize);
}
```

**Impact:** 
- Accessibility improvement
- User personalization
- Better UX on different screen sizes

---

#### 2.1.3 Auto-scroll Preference (Terminal)
**Current behavior:** Always auto-scrolls to bottom when new output arrives

**File:** `client/lib/pages/agent_page.dart:43`
```dart
bool _stickToBottom = true; // ❌ Always resets on page open
```

**Problem:** User scrolls up to read history → new output arrives → auto-scrolls to bottom → user loses place

**Current mitigation:** `_stickToBottom` turns off when user scrolls up, но **resets при reopening page**

**Solution:**
```dart
class UIPreferences {
  Future<bool> getAutoScrollTerminal() async => 
    _prefs.getBool('auto_scroll_terminal') ?? true;
  
  Future<void> setAutoScrollTerminal(bool enabled) async =>
    _prefs.setBool('auto_scroll_terminal', enabled);
}

// In AgentPage:
@override
void initState() {
  super.initState();
  _loadAutoScrollPreference();
}

Future<void> _loadAutoScrollPreference() async {
  final prefs = getIt<UIPreferences>();
  final autoScroll = await prefs.getAutoScrollTerminal();
  if (mounted) setState(() => _stickToBottom = autoScroll);
}

// Add toggle button in AppBar:
IconButton(
  icon: Icon(_stickToBottom ? Icons.vertical_align_bottom : Icons.vertical_align_center),
  onPressed: () {
    setState(() => _stickToBottom = !_stickToBottom);
    getIt<UIPreferences>().setAutoScrollTerminal(_stickToBottom);
  },
  tooltip: _stickToBottom ? 'Auto-scroll ON' : 'Auto-scroll OFF',
)
```

**Impact:** Power users can disable auto-scroll permanently

---

### 2.2 Connection Preferences — **MEDIUM PRIORITY**

#### 2.2.1 Last Used Transport Mode (WS vs HTTP)
**Current behavior:** Always WebSocket, HTTP fallback только manual

**File:** `client/lib/core/service_locator.dart:81-84`
```dart
final Transport transport = switch (transportMode) {
  'http' => HttpTransport(...),
  _ => WebSocketTransport(), // ❌ Always default to WS
};
```

**Problem:** Если у пользователя WebSocket блокируется firewall, приходится каждый раз вручную переключаться на HTTP

**Solution:**
```dart
class ConnectionPreferences {
  Future<String> getPreferredTransport() async =>
    _prefs.getString('preferred_transport') ?? 'ws';
  
  Future<void> setPreferredTransport(String mode) async =>
    _prefs.setString('preferred_transport', mode);
}

// In ConnectionPage: add transport mode selector
SegmentedButton<String>(
  selected: {_transportMode},
  onSelectionChanged: (Set<String> newSelection) async {
    setState(() => _transportMode = newSelection.first);
    await getIt<ConnectionPreferences>().setPreferredTransport(newSelection.first);
    // Reconnect with new transport
    await widget.onReconnect(_transportMode);
  },
  segments: [
    ButtonSegment(value: 'ws', label: Text('WebSocket')),
    ButtonSegment(value: 'http', label: Text('HTTP')),
  ],
)
```

**Impact:** Меньше friction для пользователей за корп. firewall

---

#### 2.2.2 Connection Test History
**Current behavior:** Test results lost при closing ConnectionPage

**File:** `client/lib/pages/connection_page.dart:88-103`
```dart
bool _checking = false;
bool _checkOk = false;
String? _checkResult; // ❌ Lost on page close
```

**Problem:** User tests connection → result OK → closes page → comes back → no history, must test again

**Solution:**
```dart
class ConnectionHistory {
  Future<List<ConnectionTest>> getHistory(String profileKey) async {
    final json = _prefs.getString('connection_history_$profileKey');
    // ... parse list of {timestamp, ok, latency_ms, error}
  }
  
  Future<void> addTest(String profileKey, ConnectionTest test) async {
    final history = await getHistory(profileKey);
    history.add(test);
    // Keep last 20 tests
    if (history.length > 20) history.removeAt(0);
    await _save(profileKey, history);
  }
}

// In ConnectionPage: show recent test results
if (_testHistory.isNotEmpty)
  ...ListTile(
    title: Text('Last test: ${_testHistory.last.timestamp}'),
    subtitle: Text(_testHistory.last.ok 
      ? 'OK (${_testHistory.last.latencyMs}ms)'
      : 'Failed: ${_testHistory.last.error}'),
  ),
```

**Impact:** User can see connection stability over time

---

### 2.3 Behavioral Flags — **LOW PRIORITY**

#### 2.3.1 "Don't Show Again" Dialogs
**Use case:** Onboarding hints, feature announcements

**Not currently implemented**, но если добавите:
```dart
class OnboardingFlags {
  Future<bool> hasSeenWelcome() async => _prefs.getBool('seen_welcome') ?? false;
  Future<void> markWelcomeSeen() async => _prefs.setBool('seen_welcome', true);
  
  Future<bool> hasSeenSpacesIntro() async => _prefs.getBool('seen_spaces_intro') ?? false;
  Future<void> markSpacesIntroSeen() async => _prefs.setBool('seen_spaces_intro', true);
}

// In HomePage first launch:
@override
void initState() {
  super.initState();
  _showOnboardingIfNeeded();
}

Future<void> _showOnboardingIfNeeded() async {
  final flags = getIt<OnboardingFlags>();
  if (!await flags.hasSeenWelcome()) {
    await _showWelcomeDialog();
    await flags.markWelcomeSeen();
  }
}
```

---

#### 2.3.2 Debug Mode / Advanced Features Toggle
**Use case:** Show advanced settings только для power users

```dart
class DebugPreferences {
  Future<bool> isDebugMode() async => _prefs.getBool('debug_mode') ?? false;
  Future<void> setDebugMode(bool enabled) async => _prefs.setBool('debug_mode', enabled);
}

// In AppBar: hold logo 5 seconds to toggle
GestureDetector(
  onLongPress: () async {
    final prefs = getIt<DebugPreferences>();
    final current = await prefs.isDebugMode();
    await prefs.setDebugMode(!current);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Debug mode: ${!current ? "ON" : "OFF"}')),
    );
  },
  child: Text('HerdRelay'),
)

// In settings: show debug options only if enabled
if (await getIt<DebugPreferences>().isDebugMode())
  ListTile(
    title: Text('Clear all caches'),
    onTap: _clearAllCaches,
  ),
```

---

## 3. Implementation: Unified PreferencesService

### 3.1 Architecture

**Create:** `client/lib/services/preferences_service.dart`

```dart
import 'package:shared_preferences/shared_preferences.dart';

/// Centralized service for all UI preferences and settings.
/// 
/// Namespaced keys prevent collisions:
/// - ui.* — UI state (tab index, font size)
/// - connection.* — connection preferences (transport mode)
/// - flags.* — behavioral flags (onboarding, debug mode)
class PreferencesService {
  PreferencesService(this._prefs);
  
  final SharedPreferences _prefs;
  
  // ─────────────────────────────────────────────────────────────────
  // UI Preferences
  // ─────────────────────────────────────────────────────────────────
  
  /// Home page tab index (0=Spaces, 1=Agents, 2=Run)
  Future<int> getHomeTabIndex() async => _prefs.getInt('ui.home_tab_index') ?? 0;
  Future<void> setHomeTabIndex(int index) async => 
    await _prefs.setInt('ui.home_tab_index', index);
  
  /// Terminal font size (8-24px, default 12)
  Future<double> getTerminalFontSize() async => 
    _prefs.getDouble('ui.terminal_font_size') ?? 12.0;
  Future<void> setTerminalFontSize(double size) async =>
    await _prefs.setDouble('ui.terminal_font_size', size.clamp(8.0, 24.0));
  
  /// Auto-scroll terminal to bottom on new output
  Future<bool> getAutoScrollTerminal() async =>
    _prefs.getBool('ui.auto_scroll_terminal') ?? true;
  Future<void> setAutoScrollTerminal(bool enabled) async =>
    await _prefs.setBool('ui.auto_scroll_terminal', enabled);
  
  /// Theme mode: 'system' | 'light' | 'dark'
  Future<String> getThemeMode() async =>
    _prefs.getString('ui.theme_mode') ?? 'system';
  Future<void> setThemeMode(String mode) async =>
    await _prefs.setString('ui.theme_mode', mode);
  
  // ─────────────────────────────────────────────────────────────────
  // Connection Preferences
  // ─────────────────────────────────────────────────────────────────
  
  /// Preferred transport: 'ws' | 'http'
  Future<String> getPreferredTransport() async =>
    _prefs.getString('connection.transport') ?? 'ws';
  Future<void> setPreferredTransport(String mode) async =>
    await _prefs.setString('connection.transport', mode);
  
  /// Last known connection test result per profile
  Future<ConnectionTestResult?> getLastTestResult(String profileKey) async {
    final json = _prefs.getString('connection.test_$profileKey');
    if (json == null) return null;
    try {
      return ConnectionTestResult.fromJson(jsonDecode(json));
    } catch (_) {
      return null;
    }
  }
  
  Future<void> saveTestResult(String profileKey, ConnectionTestResult result) async {
    await _prefs.setString('connection.test_$profileKey', jsonEncode(result.toJson()));
  }
  
  // ─────────────────────────────────────────────────────────────────
  // Behavioral Flags
  // ─────────────────────────────────────────────────────────────────
  
  /// Has user seen welcome dialog?
  Future<bool> hasSeenWelcome() async => _prefs.getBool('flags.seen_welcome') ?? false;
  Future<void> markWelcomeSeen() async => await _prefs.setBool('flags.seen_welcome', true);
  
  /// Has user seen spaces intro?
  Future<bool> hasSeenSpacesIntro() async => _prefs.getBool('flags.seen_spaces_intro') ?? false;
  Future<void> markSpacesIntroSeen() async => await _prefs.setBool('flags.seen_spaces_intro', true);
  
  /// Debug mode enabled?
  Future<bool> isDebugMode() async => _prefs.getBool('flags.debug_mode') ?? false;
  Future<void> setDebugMode(bool enabled) async => await _prefs.setBool('flags.debug_mode', enabled);
  
  // ─────────────────────────────────────────────────────────────────
  // Batch Operations
  // ─────────────────────────────────────────────────────────────────
  
  /// Clear all UI preferences (keep profiles and history)
  Future<void> clearUIPreferences() async {
    final keys = _prefs.getKeys().where((k) => k.startsWith('ui.'));
    for (final key in keys) {
      await _prefs.remove(key);
    }
  }
  
  /// Clear all flags (for testing/debugging)
  Future<void> clearFlags() async {
    final keys = _prefs.getKeys().where((k) => k.startsWith('flags.'));
    for (final key in keys) {
      await _prefs.remove(key);
    }
  }
  
  /// Export all preferences as JSON (for backup/debugging)
  Map<String, dynamic> exportAll() {
    final result = <String, dynamic>{};
    for (final key in _prefs.getKeys()) {
      result[key] = _prefs.get(key);
    }
    return result;
  }
}

/// Connection test result stored per profile
class ConnectionTestResult {
  ConnectionTestResult({
    required this.timestamp,
    required this.ok,
    this.latencyMs,
    this.error,
  });
  
  final DateTime timestamp;
  final bool ok;
  final int? latencyMs;
  final String? error;
  
  factory ConnectionTestResult.fromJson(Map<String, dynamic> json) => ConnectionTestResult(
    timestamp: DateTime.parse(json['timestamp'] as String),
    ok: json['ok'] as bool,
    latencyMs: json['latency_ms'] as int?,
    error: json['error'] as String?,
  );
  
  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'ok': ok,
    if (latencyMs != null) 'latency_ms': latencyMs,
    if (error != null) 'error': error,
  };
}
```

### 3.2 Register in Service Locator

**Modify:** `client/lib/core/service_locator.dart:26-38`

```dart
Future<void> setupDependencies() async {
  final prefs = await SharedPreferences.getInstance();
  getIt.registerSingleton<SharedPreferences>(prefs);
  
  // NEW: Register PreferencesService
  getIt.registerSingleton<PreferencesService>(PreferencesService(prefs));
  
  getIt.registerSingleton<ConfigStore>(ConfigStore());
  getIt.registerSingleton<CommandHistoryService>(
    CommandHistoryService(prefs),
  );
  // ...
}
```

---

## 4. Implementation Priority

### Phase 1: High-Value UX (2 days)
1. ✅ **Home tab index** (30 min) — remembers last view
2. ✅ **Terminal font size** (2 hours) — accessibility + customization
3. ✅ **Auto-scroll preference** (1 hour) — power user control

**Files to modify:**
- Create `services/preferences_service.dart`
- Modify `core/service_locator.dart` (register service)
- Modify `pages/home_page.dart` (tab index)
- Modify `pages/agent_page.dart` (font size, auto-scroll)
- Add settings UI (font size controls in AgentPage AppBar)

### Phase 2: Connection UX (1 day)
4. ✅ **Preferred transport mode** (1 hour)
5. ✅ **Connection test history** (2 hours)

**Files to modify:**
- Modify `pages/connection_page.dart` (transport selector, test history)
- Modify `core/service_locator.dart` (use preferred transport)

### Phase 3: Polish (optional, 0.5 day)
6. **Theme mode** (1 hour) — system/light/dark
7. **Onboarding flags** (1 hour)
8. **Debug mode toggle** (30 min)

---

## 5. Testing Strategy

### 5.1 Unit Tests
```dart
// test/services/preferences_service_test.dart
test('getHomeTabIndex returns default 0', () async {
  final prefs = await SharedPreferences.getInstance();
  final service = PreferencesService(prefs);
  
  expect(await service.getHomeTabIndex(), 0);
});

test('setHomeTabIndex persists across instances', () async {
  final prefs = await SharedPreferences.getInstance();
  
  final service1 = PreferencesService(prefs);
  await service1.setHomeTabIndex(2);
  
  final service2 = PreferencesService(prefs);
  expect(await service2.getHomeTabIndex(), 2);
});

test('setTerminalFontSize clamps to 8-24', () async {
  final service = PreferencesService(prefs);
  
  await service.setTerminalFontSize(30.0); // too big
  expect(await service.getTerminalFontSize(), 24.0);
  
  await service.setTerminalFontSize(5.0); // too small
  expect(await service.getTerminalFontSize(), 8.0);
});
```

### 5.2 Widget Tests
```dart
testWidgets('HomePage remembers last tab', (tester) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt('ui.home_tab_index', 1); // Agents tab
  
  await tester.pumpWidget(MyApp());
  
  // Should open on Agents tab, not Spaces
  expect(find.text('Agents'), findsOneWidget);
  expect(find.byType(AgentTile), findsWidgets);
});

testWidgets('AgentPage respects font size preference', (tester) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setDouble('ui.terminal_font_size', 16.0);
  
  await tester.pumpWidget(MyApp());
  // ... navigate to AgentPage
  
  final terminal = tester.widget<AnsiTerminal>(find.byType(AnsiTerminal));
  expect(terminal.style?.fontSize, 16.0);
});
```

---

## 6. Migration & Rollout

### 6.1 Backward Compatibility
**No breaking changes** — new keys only:
- Old: (none, hardcoded defaults)
- New: `ui.*`, `connection.*`, `flags.*`

Existing caches не затрагиваются:
- `last_snapshot` (agents)
- `pair_profiles` (connections)
- `command_history_*` (per-agent)

### 6.2 Rollout Plan
1. Merge PreferencesService (infrastructure only, no behavior change)
2. Phase 1: Ship tab index + font size (visible UX improvement)
3. Monitor crash rates, user feedback
4. Phase 2: Ship transport mode + test history
5. Phase 3: Theme mode + flags (polish)

---

## 7. Summary

### Already Implemented ✅
- Terminal output cache (in-memory, revision-based)
- Agent snapshot cache (persistent, offline fallback)
- Connection profiles (multi-device support)
- Command history (per-agent, 100 max)

### High-Priority Additions 🎯
1. **Home tab memory** — UX win, 30 min
2. **Terminal font size** — accessibility, 2 hours
3. **Auto-scroll preference** — power users, 1 hour

### Total Effort
- **Phase 1 (high-value):** 2 days
- **Phase 2 (connection):** 1 day
- **Phase 3 (polish):** 0.5 day optional

**Recommendation:** Start with Phase 1 (home tab + font size) — biggest UX impact with minimal effort.
