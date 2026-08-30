# Changelog

All notable changes to HerdRelay project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-08-30

### Changed (big refactor, docs/09-refactoring-plan.md)

#### Flutter Client — layered architecture
- Monolithic `WsRelayClient` (362 lines) replaced by four layers:
  - `core/transport` — `Transport` interface, `WebSocketTransport`
    (reconnect via `RetryPolicy`, keepalive 20 s/10 s, pause/resume),
    `HttpTransport` (HTTP RPC + SSE fallback), `HttpHealth`, `RetryPolicy`
  - `core/protocol` — `sealed Frame` (Request/Response/Event/Ping/Pong),
    `RequestResponseManager` (matching, 15 s timeout, fail-on-disconnect,
    auto ping→pong, cold-start wait), `RelayException`
  - `core/connection` — `ConnectionManager` (app lifecycle),
    `ModeService` (fetch /pair modes with retries/limits/clear errors)
  - `services/relay_client_impl.dart` — typed `RelayClient` on the layers
- New **Connection screen**: device card, live status, connection test
  (healthz + snapshot), mode switching, saved devices, pair link entry
- **Tappable mode badge** on the home screen: opens a mode picker
  (lan/tailscale/funnel from `/pair`) with loading/error+Retry states
- Pair link entry now gives explicit success/error feedback
- `get_it` DI (was `provider`), profiles stored in `shared_preferences`
- 148 tests, `flutter analyze` 0 warnings

#### Go Relay Server
- Clean-architecture split into `internal/` (domain/service/infrastructure/
  transport), `cmd/relay` keeps `pair`/`status` subcommands
- **HTTP fallback endpoints**: `POST /api/rpc` (relay request frame in,
  response frame out) and `GET /api/events/stream` (SSE) — HTTP twin of `/ws`
- Shared `service.Dispatch` used by both WS and HTTP transports
- Event socket repo: single `events.subscribe` per connection, per-pane
  `pane.agent_status_changed` subscription (statuses without the plugin hook),
  `scroll_changed` debounce (500 ms/pane)
- herdr CLI calls now use `HERDR_SOCKET_PATH` (was ignored `HERDR_SOCKET`)

#### herdr Plugin
- `redeploy.sh`: one command to rebuild the relay, restart the launchd
  service, re-link the plugin and health-check

### Fixed (herdr API cross-check, docs/10)
- `pane.agent_status_changed` read `agent_status` (was `status` → live status
  always `unknown`); baseline test was red before the fix
- Dead `/api/events/pane.updated` route removed; `display_agent` forwarded;
  `jsonrpc` field dropped from subscribe

## [0.1.0] - 2026-08-29

### Added

#### Flutter Client
- **Home Page**: список всех AI агентов на компьютере с real-time обновлением статусов
- **Agent Page**: интерактивный терминал для взаимодействия с агентом
  - Live вывод агента с ANSI поддержкой (цвета, форматирование)
  - Отправка промптов и команд
  - Ctrl-C для прерывания работы агента
  - Умные интерактивные кнопки (парсят варианты ответа из вывода)
  - История команд с навигацией стрелками
- **Pair Page**: конфигурация подключения к relay (host, port, токен)
- **Status indicators**: визуальные чипы статусов (working, blocked, idle, done)
- **Provider-based DI**: RelayClient через Provider для shared state
- **Comprehensive tests**: 55 тестов покрывают все основные сценарии

#### Go Relay Server
- **WebSocket API**: real-time двусторонняя связь с клиентами
- **HTTP API**: REST endpoints для snapshot, agent output, prompt, keys
- **Event broadcasting**: push-уведомления об изменении статусов агентов
- **herdr integration**: взаимодействие с herdr CLI (agent list, read, prompt, send-keys)
- **Token authentication**: безопасная аутентификация через Bearer токен
- **Multi-client support**: одновременная работа нескольких клиентов

#### herdr Plugin
- **Event forwarding**: автоматическая отправка событий в relay
  - `pane.agent_status_changed` - изменение статуса агента
  - `pane.output_changed` - обновление вывода
  - `pane.updated` - общие изменения в pane
- **Auto-configuration**: автоматическая генерация токена при установке
- **Plugin lifecycle**: setup-menu, on-event hooks

#### Utilities & Documentation
- **relay-status.sh**: утилита управления relay (status, rebuild, restart, logs)
- **Diagnostics tools**: логирование на всех уровнях (plugin → relay → client)
- **Documentation**:
  - `README.md` - общее описание проекта (EN)
  - `RELAY_MANAGEMENT.md` - управление relay сервером
  - `DIAGNOSTICS.md` - диагностика обновления статусов
  - `DEBUG_STATUS_UPDATE.md` - детальная отладка событий
  - `client/TERMINAL_UI.md` - интерактивные кнопки терминала

### Features Details

#### Smart Interactive Buttons
Парсер автоматически распознаёт варианты ответа из вывода агента:
- **Inline опции**: `(y/n)`, `[yes/no]`, `accept/reject`
- **Вопросы**: "Would you like to...?" → Yes/No кнопки
- **Нумерованные списки**: `1. Option` → кнопки с текстом опций
- **Фильтрация**: task lists (◻/◼) не распознаются как варианты

#### Real-time Status Updates
- События от herdr пробрасываются через relay в Flutter
- Задержка 150ms между событием и snapshot (race condition fix)
- Правильная отмена подписок при dispose (no memory leaks)

#### Terminal Features
- ANSI escape codes rendering (цвета, bold, курсив)
- Auto-scroll to bottom (отключается при прокрутке вверх)
- Debounced output updates (не перегружает UI при быстром стриминге)
- Command history с навигацией (↑/↓)

### Fixed
- **Ctrl-C**: исправлен формат отправки (`C-c` вместо `['ctrl', 'c']`)
- **Subscription leaks**: правильная отмена StreamSubscription в dispose
- **Race condition**: задержка 150ms для синхронизации herdr state
- **Parser false positives**: убрана стратегия поиска ключевых слов

### Technical Stack
- **Frontend**: Flutter 3.24.3, Dart 3.5.3
- **Backend**: Go 1.23+
- **Integration**: herdr CLI, tmux, WebSocket
- **Testing**: flutter_test, widget tests, integration tests

### Known Limitations
- Только локальное подключение (localhost или IP в локальной сети)
- Требуется herdr >= 0.7.5
- macOS/Linux (Windows не тестировался)
- Парсер интерактивных кнопок работает только с текстовым выводом

---

## [Unreleased]

### Added
- **Идентичность релея**: релей при первом запуске генерирует стабильный `relay_id` (32 hex) и `name` хоста (`~/.config/herdr/herdrelay.id`); `relay_id`/`name` добавлены в ссылку пары и в универсальный QR.
- **Профили в клиенте**: приложение хранит несколько конфигураций пары (Switch / Add / Forget) — удобно при смене сети, сессии или переезде на другую машину.
- **`herdrelay status`**: подкоманда диагностики — режим, адрес, идентичность, пути конфига и живое состояние (exit 0 = релей работает).
- **Смена режима без пересборки**: `plugin/configure.sh` переписывает plist launchd (`HERDRELAY_MODE`, `HERDRELAY_GATEWAY_URL`) и перезапускает службу; install.sh и plist теперь читают `HERDRELAY_MODE`/`HERDRELAY_GATEWAY_URL` из окружения.

### Fixed (Flutter Client, надёжность)
- **Reconnect без дублей**: перед новым соединением старая подписка отменяется, `onError`/`onDone` объединены в один обработчик с `cancelOnError: true`, повторное планирование reconnect блокируется. Исключено появление >1 активного WS-соединения и потеря ответов на запросы.
- **Lifecycle**: при уходе приложения в фон reconnect-цикл приостанавливается, при возврате — возобновляется (бережёт батарею, не оставляет висящих pending-запросов).
- **Race condition в ConfigStore**: конкурентные `saveProfile` сериализуются (in-memory lock) — параллельные deep link'и больше не теряют профили.
- **Retry для healthz**: до 3 попыток с backoff вместо одной — единичный сетевой сбой не помечает релей офлайн.
- **Debounce обновления списка**: пачка одновременных событий (например, при batch-запуске) вызывает один snapshot вместо N параллельных запросов.
- **Offline cache агентов**: последний успешный снимок кэшируется и показывается, когда релей недоступен.
- **Понятные ошибки**: протокольные ошибки (`not_connected`/`timeout`/`unauthorized`) мапятся в человекочитаемый текст вместо сырого `toString()`.
- **Валидация ссылки пары**: токен не короче 16 символов и без символов, ломающих query-строку; `PairConfig.toJsonSafe()` маскирует токен для логов.

### Planned
- Remote API доступ (за пределами локальной сети)
- Поддержка мульти-workspace
- Настройки темы (тёмная/светлая)
- Поиск по выводу агента
- Экспорт истории агента
- Push notifications для критических событий

