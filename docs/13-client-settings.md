# 13 — Настройки клиента: запоминание UI-состояния (анализ + решения)

Статус: **частично реализовано (30.08)** · Дата: 2026-08-30
Основание: аудит «что не запоминается между запусками/открытиями». Каждый пункт сверен с кодом
(файл:строка) на момент написания.

## 0. Уже кэшируется

| Что | Механизм | Где |
|---|---|---|
| Вывод терминала | in-memory, revision-based (кэш вывода с `knownRevision`; revision-guard на месте) | `agent_repository.dart`, `agent_page.dart` |
| Снапшоты агентов | persistent offline fallback (`last_snapshot` + `:ts`) | `agent_repository.dart` → `AppSettings` |
| Профили пар | multi-device (`pair_profiles`/`active_profile`) | `config_store.dart` |
| История команд | per-agent, 100 max | `command_history_service.dart` |
| Endpoints режимов | per-profile (`PairConfig.endpoints`: mode → host:port) | `pair_config.dart`, `mode_picker_sheet.dart` |

## 0.1 Реализовано (30.08)

- **AppSettings** (`services/app_settings.dart`) — типизированный key-centralized слой над
  SharedPreferences: `homeTabIndex`, `terminalFontSize` (9–20, кнопки A−/A+ на AgentPage),
  `autoScrollFollow`, кэш снапшота агентов. HomePage восстанавливает таб, AgentPage — размер
  шрифта и автоскролл.
- **Режим = endpoint** (`PairConfig.endpoints`): профиль помнит адреса всех режимов релея;
  переключение — `connectVia` (адреса других режимов сохраняются); каждый успешный `/pair`
  дописывает адреса (`withEndpoints`); офлайн-переключение из сохранённых endpoints + ручной
  ввод с хостом, следующим за режимом. Детали: [05 — Flutter](05-flutter-app.md) → бейдж режима.

## 1. Проблемы (сверено с кодом)

| # | Проблема | Подтверждение | Оценка |
|---|---|---|---|
| 1 | **Home tab** всегда «Spaces» при запуске | `home_page.dart:65` `_tabIndex = 0`; `_visitedTabs = {0}` не переживает рестарт | 30 мин |
| 2 | **Font size терминала** жёстко 12px, нет контроля | `ansi_terminal.dart:41` `fontSize: 12` в `defaultStyle`; `agent_page.dart:264` строит `AnsiTerminal` без стиля | 2 ч |
| 3 | **Auto-scroll** сбрасывается при каждом открытии | `agent_page.dart:43` `_stickToBottom = true`; `_onScroll` не сохраняет | 1 ч |
| 4 | **Transport mode** не выбирается и не запоминается | `service_locator.dart:57` `transportMode = 'ws'`; main.dart его не передаёт; UI-выбора нет (`HttpTransport` реализован, недостижим) | 1 день |
| 5 | **История теста соединения** не хранится | `connection_page.dart` `_checkConnection` — один `_checkResult`, без истории | 1 день |

## 2. Решения

### Общие настройки приложения (пункты 1–3) — новый сервис `AppSettings`

`client/lib/services/app_settings.dart`, get_it-синглтон, оборачивает уже загруженный
`SharedPreferences` (после `getInstance()` prefs кэшируются в памяти → геттеры синхронные).
Регистрация в `setupDependencies()` (prefs там уже awaited) — HomePage читает значение синхронно в
`initState`, без «мигания» не того таба.

- `homeTabIndex` — int, default 0.
- `terminalFontSize` — double, default 12, диапазон ~9–20.
- `autoScrollFollow` — bool, default true.

1. **Home tab**: `initState` → `_tabIndex = settings.homeTabIndex`, `_visitedTabs = {tab}`;
   `onDestinationSelected` → `settings.setHomeTabIndex(i)`.
2. **Font size**: `AgentPage._buildOutput` → `AnsiTerminal(style: AnsiTerminal.defaultStyle.copyWith(fontSize: …))`;
   в AppBar AgentPage — кнопки A−/A+ (или слайдер-поповер по паттерну ModePickerSheet);
   мемоизация AnsiTerminal ключуется по стилю — репарс при смене размера корректен.
3. **Auto-scroll**: `_stickToBottom` инициализируется из настроек; `_onScroll` при переключении
   сохраняет (fire-and-forget).

### Per-profile (пункты 4–5)

4. **Transport mode**: поле `transportMode` в `PairConfig` (default `'ws'`, в `fromJson`/`toJson`);
   переключатель WS/HTTP на ConnectionPage; `main.dart._setConfig` →
   `setupRelayServices(config, transportMode: config.transportMode)`; смена = обновить PairConfig +
   существующий путь `onSwitch` (teardown+setup уже там).
5. **Test history**: `ConnectionTestHistoryService` по образцу `CommandHistoryService`
   (ключ `connection_test_history_<profileKey>`, максимум 20, JSON `{ts, ok, result}`);
   на ConnectionPage — список последних проверок под карточкой статуса.

## 3. Координация

Параллельная сессия правит `agent_page.dart` + `agent_repository.dart` (кэш вывода `knownRevision`).
Пересечения реализации: пункты 2–3 (agent_page.dart). Пункты 1, 4, 5 — их файлы параллельная
сессия не трогает. Перед правкой agent_page — перечитать файл.

## 4. Порядок реализации

- **Батч A** (1–3): `AppSettings` + Home tab + font size + auto-scroll — один коммит, быстрые победы.
- **Батч B** (4–5): `PairConfig.transportMode` + переключатель + история тестов — второй коммит.
- Тесты: `app_settings_test.dart`, widget-тесты (таб восстанавливается, font-size применяется,
  auto-scroll сохраняется, история тестов пишется/читается).
