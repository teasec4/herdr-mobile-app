# 13 — Client settings: remembering UI state (analysis + decisions)

Status: **partially implemented (30.08)** · Date: 2026-08-30
Rationale: an audit of "what is not remembered between launches/openings". Each item is verified against the code
(file:line) at the time of writing.

## 0. Already cached

| What | Mechanism | Where |
|---|---|---|
| Terminal output | in-memory, revision-based (output cache with `knownRevision`; revision-guard in place) | `agent_repository.dart`, `agent_page.dart` |
| Agent snapshots | persistent offline fallback (`last_snapshot` + `:ts`) | `agent_repository.dart` → `AppSettings` |
| Pair profiles | multi-device (`pair_profiles`/`active_profile`) | `config_store.dart` |
| Command history | per-agent, 100 max | `command_history_service.dart` |
| Mode endpoints | per-profile (`PairConfig.endpoints`: mode → host:port) | `pair_config.dart`, `mode_picker_sheet.dart` |

## 0.1 Implemented (30.08)

- **AppSettings** (`services/app_settings.dart`) — typed, key-centralized layer over
  SharedPreferences: `homeTabIndex`, `terminalFontSize` (9–20, A−/A+ buttons on AgentPage),
  `autoScrollFollow`, `notificationsEnabled` ("Blocked agent alerts" toggle in the ⋮ menu →
  Notifications…, key `settings_notifications_enabled`, default true), agent snapshot cache.
  HomePage restores the tab, AgentPage — font size and auto-scroll.
- **Mode = endpoint** (`PairConfig.endpoints`): the profile remembers addresses of all relay modes;
  switching — `connectVia` (addresses of other modes are preserved); every successful `/pair`
  appends addresses (`withEndpoints`); offline switching from saved endpoints + manual
  input with the host following the mode. Details: [05 — Flutter](05-flutter-app.md) → mode badge.

## 1. Problems (verified against the code)

| # | Problem | Evidence | Estimate |
|---|---|---|---|
| 1 | **Home tab** always "Spaces" on launch | `home_page.dart:65` `_tabIndex = 0`; `_visitedTabs = {0}` does not survive restart | 30 min |
| 2 | **Terminal font size** hardcoded to 12px, no control | `ansi_terminal.dart:41` `fontSize: 12` in `defaultStyle`; `agent_page.dart:264` builds `AnsiTerminal` without a style | 2 h |
| 3 | **Auto-scroll** resets on every open | `agent_page.dart:43` `_stickToBottom = true`; `_onScroll` does not save | 1 h |
| 4 | **Transport mode** is not selectable or remembered | `service_locator.dart:57` `transportMode = 'ws'`; main.dart does not pass it; no UI selector (`HttpTransport` implemented, unreachable) | 1 day |
| 5 | **Connection test history** is not stored | `connection_page.dart` `_checkConnection` — a single `_checkResult`, no history | 1 day |

## 2. Decisions

### General app settings (items 1–3) — a new `AppSettings` service

`client/lib/services/app_settings.dart`, get_it singleton, wraps the already-loaded
`SharedPreferences` (after `getInstance()` prefs are cached in memory → getters are synchronous).
Registered in `setupDependencies()` (prefs are already awaited there) — HomePage reads the value synchronously in
`initState`, without "flashing" the wrong tab.

- `homeTabIndex` — int, default 0.
- `terminalFontSize` — double, default 12, range ~9–20.
- `autoScrollFollow` — bool, default true.

1. **Home tab**: `initState` → `_tabIndex = settings.homeTabIndex`, `_visitedTabs = {tab}`;
   `onDestinationSelected` → `settings.setHomeTabIndex(i)`.
2. **Font size**: `AgentPage._buildOutput` → `AnsiTerminal(style: AnsiTerminal.defaultStyle.copyWith(fontSize: …))`;
   in the AgentPage AppBar — A−/A+ buttons (or a slider popover following the ModePickerSheet pattern);
   AnsiTerminal memoization keyed by style — reparse on size change is correct.
3. **Auto-scroll**: `_stickToBottom` initialized from settings; `_onScroll` saves on toggle
   (fire-and-forget).

### Per-profile (items 4–5)

4. **Transport mode**: `transportMode` field in `PairConfig` (default `'ws'`, in `fromJson`/`toJson`);
   WS/HTTP toggle on ConnectionPage; `main.dart._setConfig` →
   `setupRelayServices(config, transportMode: config.transportMode)`; changing = update PairConfig +
   existing `onSwitch` path (teardown+setup already there).
5. **Test history**: `ConnectionTestHistoryService` modeled after `CommandHistoryService`
   (key `connection_test_history_<profileKey>`, max 20, JSON `{ts, ok, result}`);
   on ConnectionPage — a list of recent checks under the status card.

## 3. Coordination

A parallel session is editing `agent_page.dart` + `agent_repository.dart` (output cache `knownRevision`).
Implementation overlaps: items 2–3 (agent_page.dart). Items 1, 4, 5 — their files are not touched by the parallel
session. Before editing agent_page — re-read the file.

## 4. Implementation order

- **Batch A** (1–3): `AppSettings` + Home tab + font size + auto-scroll — one commit, quick wins.
- **Batch B** (4–5): `PairConfig.transportMode` + toggle + test history — second commit.
- Tests: `app_settings_test.dart`, widget tests (tab is restored, font-size applied,
  auto-scroll saved, test history written/read).
