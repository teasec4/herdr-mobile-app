# 09 — План рефакторинга: модульная архитектура клиента + дефекты логики

> Статус: **реализация завершена (Фазы 0–4, дефекты D1–D9)** — ветка `refactor/modular-architecture`
> Область: только Flutter-клиент (`client/`). Go-сервер не меняется.
> Связанные документы: [01 — Архитектура](01-architecture.md), [05 — Flutter-приложение](05-flutter-app.md), [08 — План исполнения](08-execution-plan.md), [10 — herdr API](10-herdr-api.md).

> **Два плана в одном:** (А) перенос архитектуры клиента на слои (§1–§8);
> (Б) исправления логики, найденные при сверке кода с [10 — herdr API](10-herdr-api.md) (§1.4).
> Фиксы (Б) не требуют архитектурных изменений и выполняются в начале соответствующих фаз.

## 0. Статус реализации

| Фаза | Статус | Коммит |
| --- | --- | --- |
| Серверные фиксы D2–D6, D9 | ✅ | `f724b1a` |
| Фаза 0 — baseline-тесты + D1/D8 | ✅ | `965b7f9` |
| Фаза 1 — Transport | ✅ | `5357948` (+ keepalive D7 в `dc106ca`~) |
| Фаза 2 — Protocol | ✅ | `13d94c2` |
| Фаза 3 — Client на слоях | ✅ | `402072c` |
| Фаза 4 — Connection Manager | ✅ | `dc106ca` |
| README модулей (контракты) | ✅ | — |

Итог: `WsRelayClient` (362 строки) удалён; на его месте `core/transport` +
`core/protocol` + `core/connection` + `services/relay_client_impl.dart`
(125 тестов зелёные, `dart analyze` — 0 warnings/errors).
Фаза 5 (HTTP fallback) — отложена (см. §5).

## 1. Контекст и мотивация

### 1.1 Текущее состояние (проверено по коду)

`WsRelayClient` (`client/lib/services/relay_client.dart`) — **362 строки**, монолит, в котором смешаны все уровни:

| Ответственность | Где в коде сейчас |
| --- | --- |
| WebSocket lifecycle | `_connect()`, `_onDisconnect()`, `_channel` |
| Reconnect с exponential backoff | `_scheduleReconnect()`, `_attempt`, `_reconnectTimer` (1, 2, 4, … до 30 c) |
| Protocol framing (JSON) | `_onMessage()`, `_sendFrame()` — jsonDecode/encode |
| Request-response matching | `_request()`, `_pending`, `_nextId`, таймаут 15 c |
| Event broadcasting | `_events` (StreamController), маппинг в `RelayEvent` |
| Ping/pong | `_onMessage()` → `case 'ping'` → `{'type': 'pong'}` |
| HTTP healthz | `healthz()` — 3 попытки с backoff |
| Status management | `status` (ValueNotifier), `lastError` |
| Reconnect pause/resume | `pauseReconnect()`, `resumeReconnect()` (для lifecycle) |

### 1.2 Почему рефакторим

1. **Тестируемость.** На `WsRelayClient` нет ни одного теста (в `client/test/` его нет). Сеть нельзя подменить, поведение (reconnect, timeout, failPending) не проверяется.
2. **Расширяемость.** HTTP-эндпоинты уже есть на сервере (`internal/transport/http/handler.go`: `output`/`keys`/`prompt`) — fallback на HTTP логичен, но вклиниться в монолит нельзя.
3. **Переиспользование.** Reconnect-логика нужна любому транспорту (WS, HTTP long-poll, в перспективе gRPC/WebRTC).
4. **Параллельная работа.** Два человека не могут трогать один файл на 362 строки.

### 1.3 Что НЕ переписываем (уже хорошо)

- **Интерфейс `RelayClient`** — уже отделён от реализации и стабилен: `status`, `events`, `snapshot`, `output`, `keys`, `prompt`, `healthz`, `pauseReconnect`, `resumeReconnect`, `close`. UI работает через него. **Не меняем сигнатуры** — иначе посыпятся страницы и тесты.
- **Lifecycle** — `_HerdRelayAppState` в `client/lib/main.dart` уже наблюдает `AppLifecycleState` и зовёт `pauseReconnect`/`resumeReconnect`. Фаза 4 = перенос этой логики в `ConnectionManager`, а не создание с нуля.
- **DI** — `setupRelayServices(config, {clientFactory})` в `client/lib/core/service_locator.dart` уже умеет подставлять фейк (используется в widget-тестах).
- **`FakeRelayClient`** (`client/test/fakes/fake_relay_client.dart`) — готовый фейк верхнего уровня.
- **Offline-кэш** в `AgentRepository` (last_snapshot в SharedPreferences) — не сломать при пересборке клиента.
- **Модели** (`RelayAgent`, `RelayEvent`, `PairConfig`) — не трогаем.

### 1.4 Дефекты логики, найденные при сверке с docs/10-herdr-api.md (план «Б»)

Сверка кода клиента и релея со справочником herdr API (0.8.0, protocol 19) выявила
несоответствия. Они исправляются **до или в начале** соответствующей фазы, независимо
от архитектурного переноса.

| # | Приоритет | Где | Дефект | Доказательство | Фикс | Статус |
|---|---|---|---|---|---|---|
| **D1** | 🔴 Критично | `client/lib/models/relay_event.dart` | `pane.agent_status_changed` парсится через `data['status']`, а сервер шлёт `agent_status` → статус в реальном времени **всегда `unknown`** (agent_page обновляет статус из события) | `internal/domain/event.go` — `AgentStatusChangedEvent` c json-тегом `agent_status`; docs/10 §5.3 (пример data) | `data?['agent_status'] ?? data?['status']` | ✅ |
| **D2** | 🔴 Критично | `internal/infrastructure/herdr/cli_repository.go:30` | Subprocess'у шлётся `HERDR_SOCKET`, но CLI **игнорирует** эту переменную (работает только `HERDR_SOCKET_PATH`) → все herdr-операции идут на дефолтный сокет, named session сломан | docs/10 §3.1, грабли №10 (проверено живьём) | слать `HERDR_SOCKET_PATH`; `cmd/relay/config.go` — читать `HERDR_SOCKET_PATH` (fallback на `HERDR_SOCKET`) | ✅ |
| **D3** | 🟠 Важно | `internal/infrastructure/herdr/socket_event_repository.go` | Нет подписки `pane.agent_status_changed` → статусы агентов приходят только через плагин-хук; без установленного плагина живых статусов нет | docs/10 §5.2 (scoped-подписка существует), §8 (сейчас статусы = хук) | добавить per-pane подписку `pane.agent_status_changed` + маппинг в `domain.ParseEvent` | ✅ |
| **D4** | 🟠 Важно | клиент `agent_page.dart` + сервер | `pane.scroll_changed` не несёт `revision` (всегда 0) → клиент дебаунсит 400 ms, но каждый тик = WS-запрос = subprocess herdr CLI; при активном выводе — лишняя нагрузка | docs/10 грабли №5; `agent_page.dart:102-115` | серверный дебаунс `scroll_changed` (пери-pane, ≥500 ms) в `socket_event_repository` | ✅ |
| **D5** | 🟡 Средне | `cmd/relay/router.go:29` | Маршрут `/api/events/pane.updated` мёртвый: хук `pane.updated` не может быть зарегистрирован (линковщик отклоняет как unknown event) | docs/10 грабли №1 | удалить маршрут (или пометить deprecated) | ✅ |
| **D6** | 🟡 Средне | релей→клиент | Snapshot не содержит `display_agent` (herdr его отдаёт) → на телефоне теряется отображаемое имя агента | docs/10 §6.1 (PaneInfo.display_agent); `client/lib/models/relay_agent.dart:51` | добавить `DisplayAgent` в `domain.Agent` и прокинуть в `RelayAgent` | ✅ (сервер; клиент уже читал `display_agent`) |
| **D7** | 🟡 Средне | клиент | Нет keepalive: никто не инициирует ping (клиент и сервер только отвечают) → мёртвое WS-соединение (NAT/сон телефона) не детектится до первого запроса | `relay_client.dart` (`case 'ping'` — только ответ); `ws/handler.go` | периодический ping в Transport (Фаза 1) | ✅ (`WebSocketTransport` keepalive, 20 s / pong 10 s) |
| **D8** | 🟢 Низко | `client/lib/models/relay_agent.dart:23` | Комментарий о статусах устарел («done, running, waiting, error») — herdr 0.8.0: `idle/working/blocked/done/unknown` | docs/10 §6.2 | поправить доки | ✅ |
| **D9** | 🟢 Низко | `socket_event_repository.go:216` | `"jsonrpc":"2.0"` в subscribe — лишнее поле (в схеме herdr его нет; безвредно) | docs/10 §3.2 | убрать при правке D3 | ✅ |

**Привязка к фазам:** D1, D8 → Фаза 0 (baseline-тест «event → статус» должен быть красным до фикса, зелёным после); D2, D5, D6 → серверные фиксы, выполняются первым коммитом (не зависят от рефакторинга); D3, D4, D9 → серверные улучшения, с ними же; D7 → Фаза 1 (keepalive в `Transport`).

## 2. Целевая архитектура: слоёный пирог

```
┌─────────────────────────────────────────────────────────────┐
│ UI (pages/widgets) — работает только с RelayClient          │
├─────────────────────────────────────────────────────────────┤
│ Client Layer    RelayClientImpl  — typed API, events,       │
│                 маппинг RelayStatus, делегирует в protocol  │
├─────────────────────────────────────────────────────────────┤
│ Protocol Layer  RequestResponseManager + Frame              │
│                 — JSON <-> Frame, id->completer, ping/pong  │
├─────────────────────────────────────────────────────────────┤
│ Transport Layer WebSocketTransport — байты/строки, статус,   │
│                 reconnect с backoff, pause/resume           │
├─────────────────────────────────────────────────────────────┤
│ Connection      ConnectionManager + RetryPolicy             │
│ (оркестрация)   — app lifecycle, fallback, политики ретраев │
└─────────────────────────────────────────────────────────────┘
```

**Правило границ:** стрелки зависимостей идут только вниз. Transport не знает про JSON и запросы. Protocol не знает про WebSocket и lifecycle. Client не знает про reconnect-таймеры. Connection знает обо всех, но не знает про домен (агенты, события).

### 2.1 Transport Layer — `lib/core/transport/`

Отвечает за: открыть соединение, отправить/получить raw строки, автореконнект, статус.

```dart
enum ConnectionStatus { disconnected, connecting, connected }

abstract class Transport {
  Stream<String> get messages;                    // raw text frames
  ValueNotifier<ConnectionStatus> get status;      // для UI и протокола
  String? get lastError;

  Future<void> connect(Uri uri);
  void send(String data);
  void pause();    // приостановить reconnect loop (background)
  void resume();   // возобновить (foreground)
  Future<void> close();
}
```

Решения по контракту (см. §4):
- **`String`, не `Uint8List`** — WS text frames, протокол — JSON-строки. Binary не нужен.
- **`pause()`/`resume()`** — на транспорте (не на клиенте): реконнект-пауза — свойство соединения.
- **Reconnect** — `ReconnectMixin`/`RetryPolicy` внутри транспорта: 1, 2, 4, … до 30 c (сохранить текущее поведение), плюс защита от дублей (один таймер, `cancelOnError`, `_closed`).
- **`HttpHealth`** — маленький класс для HTTP `healthz` (3 попытки с backoff, как сейчас в `WsRelayClient.healthz()`).

### 2.2 Protocol Layer — `lib/core/protocol/`

Отвечает за: JSON <-> Frame, request-response matching, ping/pong, ошибки протокола.

```dart
sealed class Frame {
  factory Frame.parse(String json);   // throws ProtocolException на мусоре
  String encode();
}

class RequestFrame  extends Frame { int id; String method; Map<String, dynamic> params; }
class ResponseFrame extends Frame { int id; bool ok; Map<String, dynamic>? result; RelayError? error; }
class EventFrame    extends Frame { String event; Map<String, dynamic>? data; }
class PingFrame     extends Frame {}
class PongFrame     extends Frame {}
```

```dart
class RequestResponseManager {
  RequestResponseManager(this.transport);   // слушает transport.messages и transport.status
  Future<Map<String, dynamic>> request(String method, Map<String, dynamic> params); // timeout 15 c
  // на disconnected: все pending завершаются RelayException('disconnected', ...)
  // на PingFrame: автоматически шлёт PongFrame — клиент ничего не знает про пинг
}
```

- **`_waitForConnected`** (текущая логика «дать WS момент на холодном старте, потом не_connected») — живёт здесь: `request()` при `connecting` ждёт до 8 c, при `disconnected` сразу бросает `RelayException('not_connected', lastError)`.
- **`_failPending`** — здесь же: подписка на `transport.status`; уход в `disconnected` завершает все pending ошибкой.

### 2.3 Client Layer — `lib/services/relay_client_impl.dart`

`RelayClientImpl implements RelayClient` — единственный новый код на верхнем уровне:

- `snapshot/output/keys/prompt` — typed-обёртки над `RequestResponseManager` (маппинг JSON → `RelayAgent` и обратно; сигнатуры `RelayClient` не меняются).
- `events` — слушает `transport.messages`, парсит `EventFrame`, транслирует в `RelayEvent` (broadcast controller).
- `status` — маппит `ConnectionStatus` → `RelayStatus` (`ValueNotifier<RelayStatus>` — публичный контракт UI).
- `healthz` — делегирует в `HttpHealth`.
- `pauseReconnect`/`resumeReconnect` — делегируют в `transport.pause()/resume()` (сигнатура интерфейса сохранена, чтобы не трогать `main.dart` до Фазы 4).
- `close` — закрывает транспорт, события, pending.

### 2.4 Connection Layer — `lib/core/connection/`

```dart
class ConnectionManager with WidgetsBindingObserver {
  ConnectionManager(this.transport, this.retryPolicy);
  // didChangeAppLifecycleState: paused/hidden -> transport.pause(); resumed -> transport.resume()
  // (логика переезжает сюда из main.dart)
  // опционально (Фаза 5): WS fails > 3 раз -> переключение на HttpTransport
}

abstract class RetryPolicy {
  bool shouldRetry(int attempt, Object error);
  Duration nextDelay(int attempt);
}
class ExponentialBackoff implements RetryPolicy { ... }  // 1..30 c
class FixedDelay      implements RetryPolicy { ... }
```

## 3. Что уже есть и что создаём (дельты по файлам)

| Файл | Статус |
| --- | --- |
| `services/relay_client.dart` (интерфейс + RelayStatus + RelayException) | остаётся; re-export `RelayException` из protocol для совместимости тестов/UI |
| `services/relay_client.dart` (WsRelayClient) | после Фазы 3 помечается `@Deprecated` и переезжает в `_legacy/` (rollback-план), удаляется в Фазе 4 |
| `core/transport/transport.dart`, `websocket_transport.dart`, `reconnect_mixin.dart`, `http_health.dart` | новые (Фаза 1) |
| `core/protocol/relay_protocol.dart`, `request_response_manager.dart`, `relay_exception.dart` | новые (Фаза 2) |
| `core/connection/connection_manager.dart`, `retry_policy.dart` | новые (Фаза 4) |
| `services/relay_client_impl.dart` | новый (Фаза 3) |
| `core/service_locator.dart` | обновляется: собирает граф transport → rpc → client → repo (+ ConnectionManager) |
| `main.dart` | упрощается: lifecycle уходит в ConnectionManager (Фаза 4) |

## 4. Решения (ADR — утверждены)

> Все 7 решений утверждены 30.08. При изменении контракта слоя — обновлять этот
> раздел и помечать изменение (дата, причина).

| # | Вопрос | Решение (утверждено) | Обоснование |
| --- | --- | --- | --- |
| 1 | `Stream<String>` или `Stream<Uint8List>` в Transport | **`String`** | WS text frames; протокол — JSON-строки. Binary — если понадобится, добавим отдельный метод |
| 2 | Где живёт `healthz()` | **Отдельный `HttpHealth` в transport**, клиент делегирует | Это сеть, но не протокол и не домен; сигнатура `RelayClient.healthz()` не меняется |
| 3 | Где живут `RelayStatus` / `RelayException` | `RelayStatus` — в `services/relay_client.dart` (публичный API UI); `RelayException` — в `core/protocol/`, re-export из `services/relay_client.dart` | UI и тесты импортируют их из `services/relay_client.dart` — ломать импорты не хотим |
| 4 | pause/resume | На **Transport** (`pause()/resume()`), не на клиенте | Пауза reconnect — свойство соединения; клиент делегирует (сигнатуры интерфейса сохранены) |
| 5 | `_waitForConnected` и `_failPending` | Оба — в **RequestResponseManager** | Это request-response семантика: ждать/фейлить запросы по статусу транспорта |
| 6 | Ping/pong | **Авто-ответ на `PingFrame` внутри RequestResponseManager** | Менеджер и так слушает все фреймы; клиент не знает про пинг |
| 7 | HTTP fallback | **Отложен в Фазу 5** (за feature flag) | Сервер уже умеет HTTP (output/keys/prompt); нужно проверить события по HTTP (long-poll/SSE) в `internal/transport/http/` |

## 5. План по фазам

### Фаза 0 — Baseline (2–3 дня, до ветки рефакторинга)

**Цель:** зафиксировать текущее поведение тестами, которые обязаны остаться зелёными после каждой фазы.

1. Создать ветку `refactor/modular-architecture` от текущего состояния.
2. Написать `client/test/services/relay_client_test.dart` против **существующего** `WsRelayClient`, используя подменяемый `WebSocketChannel` (hand-rolled fake на `StreamController` — без mockito, он не в зависимостях):
   - request → response матчинг (ok и error)
   - event → `RelayEvent` (с `name`/`data`), включая `pane.agent_status_changed`
   - ping → pong
   - timeout 15 c → `RelayException('timeout', ...)`
   - reconnect: симулированный disconnect → новый connect, backoff 1/2/4 c (fake clock не нужен — проверяем факт переподключения)
   - `pauseReconnect` → нет reconnect-попыток; `resumeReconnect` → reconnect
   - pending-запросы завершаются ошибкой при disconnect
   - `not_connected` при запросе без соединения
3. `flutter analyze` и `flutter test` — зелёные.

**Критерий готовности:** поведение клиента покрыто тестами; эти тесты не меняются при пересборке на слои (меняется только способ инстанцирования).

### Фаза 1 — Transport (неделя 1)

1. `core/transport/transport.dart` — интерфейс (контракт из §2.1).
2. `core/transport/reconnect_mixin.dart` — reconnect loop с backoff (перенос из `_scheduleReconnect`), `pause()/resume()`, защита от дублей.
3. `core/transport/websocket_transport.dart` — `WebSocketChannel.connect`, перенос `_connect/_onDisconnect`; **без** JSON, без requests/events, без healthz.
4. `core/transport/http_health.dart` — перенос `healthz()` (3 попытки, backoff 200/400 ms).
5. Тесты: `test/core/transport/websocket_transport_test.dart` (reconnect на симулированных disconnect, send/receive, pause/resume, status transitions) + `http_health_test.dart`.

**Критерий готовности:** `WebSocketTransport` сам переподключается, но не знает про JSON/requests/events. Параллельно работает старый `WsRelayClient` (приложение не переключено).

### Фаза 2 — Protocol (неделя 2)

1. `core/protocol/relay_exception.dart` — `RelayException` (+ `RelayError`), `ProtocolException`.
2. `core/protocol/relay_protocol.dart` — `sealed class Frame` + парсер (точный маппинг реального протокола из `cmd/relay/ws.go`: `type`, `id`, `ok`, `result`, `error`, `event`, `data`, `ping`).
3. `core/protocol/request_response_manager.dart` — `request()`, timeout 15 c, failPending на disconnected, автопинг-понг, wait-for-connected.
4. Тесты: `relay_protocol_test.dart` (parse/encode всех фреймов, мусор → ProtocolException), `request_response_manager_test.dart` (fake transport: матчинг, таймаут, failPending, ping/pong).

**Критерий готовности:** Protocol парсит любой relay JSON и матчит requests/responses без сетевого стека.

### Фаза 3 — Client на новых слоях (неделя 3)

1. `core/transport/fake_transport.dart` (test/fakes) — по образцу из плана, с `simulateMessage`/`sentMessages`.
2. `services/relay_client_impl.dart` — `RelayClientImpl` на Transport + RequestResponseManager (§2.3).
3. Переключение `service_locator.dart` на новую сборку; старый `WsRelayClient` → `@Deprecated`, перенос в `lib/_legacy/`.
4. Тесты: `relay_client_impl_test.dart` с FakeTransport (сценарий из плана: snapshot по симулированному response); **базовые тесты Фазы 0 переключаются на `RelayClientImpl` и остаются зелёными**.

**Критерий готовности:** UI работает как раньше; каждый слой тестируется независимо; `WsRelayClient` в `_legacy/` доступен для rollback.

### Фаза 4 — Connection Manager (неделя 4)

1. `core/transport/retry_policy.dart` — интерфейс + `ExponentialBackoff`, `FixedDelay` (перенос формулы 1..30 c; живёт в transport, чтобы не было зависимости transport → connection).
2. `core/connection/connection_manager.dart` — lifecycle из `main.dart` (`WidgetsBindingObserver` → `transport.pause()/resume()`), подключение RetryPolicy.
3. `main.dart` — убрать `WidgetsBindingObserver`; `service_locator.dart` регистрирует `ConnectionManager` рядом с client/repo.
4. Удаление `_legacy/WsRelayClient`.
5. Тесты: `connection_manager_test.dart` (paused/hidden → pause, resumed → resume; disposal без утечки observer), `retry_policy_test.dart` (в `test/core/transport/`).

**Критерий готовности:** приложение само паузит reconnect в background и возобновляет в foreground (поведение из main.dart сохранено, теперь тестируемое). Battery drain закрыт.

### Фаза 5 — HTTP fallback (опционально, future)

1. Аудит `internal/transport/http/handler.go`: какие методы есть, есть ли события (long-poll/SSE) — если нет, fallback сначала только для запросов, события остаются на WS.
2. `core/transport/http_transport.dart` — `implements Transport` (HTTP long-polling для `messages`).
3. Переключение в `ConnectionManager`: WS fails > 3 раз → HTTP, за feature flag.

**Критерий готовности:** смена транспорта не меняет Protocol/Client/UI.

## 6. Тестовая стратегия (vertical slices)

```
            ╱ E2E (1–2) — app_integration_test: тестовый relay + UI
           ╱ Integration (5–10) — RelayClientImpl + FakeTransport
          ╱ Unit (50–100) — protocol, transport, retry, manager
```

| Слой | Тест | Фейк |
| --- | --- | --- |
| Protocol | `relay_protocol_test.dart` — parse/encode, мусор | — |
| RPC | `request_response_manager_test.dart` — матчинг, timeout, failPending | `FakeTransport` |
| Transport | `websocket_transport_test.dart` — reconnect, pause/resume | fake `WebSocketChannel` |
| Connection | `connection_manager_test.dart`, `retry_policy_test.dart` | fake transport |
| Client | `relay_client_impl_test.dart` — typed API | `FakeTransport` |
| Baseline | `relay_client_test.dart` (Фаза 0) — гоняется против WsRelayClient, потом RelayClientImpl | fake `WebSocketChannel` |
| Widget | существующие `home_page_test.dart`, `agent_page_test.dart` | существующий `FakeRelayClient` |

Инструменты: `package:test`/`flutter_test`; mockito/mocktail **не добавляем** — hand-rolled fakes на `StreamController` достаточно и быстрее.

## 7. Итоговая структура директорий

```
client/lib/
├── core/
│   ├── transport/
│   │   ├── transport.dart              # interface + ConnectionStatus
│   │   ├── websocket_transport.dart
│   │   ├── reconnect_mixin.dart        # backoff + pause/resume
│   │   ├── retry_policy.dart           # ExponentialBackoff/FixedDelay
│   │   ├── http_health.dart            # healthz (3 попытки)
│   │   └── http_transport.dart         # Фаза 5 (future fallback)
│   ├── protocol/
│   │   ├── relay_protocol.dart         # sealed Frame + парсер
│   │   ├── request_response_manager.dart
│   │   └── relay_exception.dart
│   ├── connection/
│   │   └── connection_manager.dart     # lifecycle (из main.dart)
│   └── service_locator.dart
├── models/                             # без изменений
├── services/
│   ├── relay_client.dart               # interface + RelayStatus (без изменений для UI)
│   └── relay_client_impl.dart          # новая реализация на слоях
├── repositories/                       # без изменений (offline-кэш сохранить!)
├── pages/ · widgets/                   # без изменений
└── _legacy/                            # временно: WsRelayClient (rollback), удаляется в Фазе 4

client/test/
├── core/
│   ├── transport/  (websocket_transport_test, http_health_test, retry_policy_test)
│   ├── protocol/   (relay_protocol_test, request_response_manager_test)
│   └── connection/ (connection_manager_test)
├── services/       (relay_client_impl_test, relay_client_test ← baseline)
└── fakes/          (fake_transport.dart, fake_relay_client.dart ← существующий)
```

## 8. Правила работы

1. **Feature-driven границы.** Новая фича трогает один слой: HTTP fallback → только transport; offline mode → `CachingTransport` wrapper; metrics → декоратор вокруг `RequestResponseManager`.
2. **Contract-first.** Сначала интерфейс слоя → тесты против него → реализация → интеграция. Новый transport (WebRTC) = те же тесты, что у WS.
3. **Vertical slice testing** — пирамида из §6; один E2E.
4. **Incremental migration.** Не переписываем всё сразу: Фаза 0 фиксирует поведение, Фазы 1–2 работают параллельно со старым кодом, `_legacy/` даёт rollback до Фазы 4.
5. **Documentation as contracts.** У каждого модуля `README.md`: Purpose / Dependencies / API / Examples / Testing (шаблон — §9).

## 9. Шаблон README модуля

```markdown
# Transport Layer

## Purpose
Raw network connectivity: connect, send, receive, reconnect.

## Dependencies
- `dart:async` (Stream, Future) · `web_socket_channel`

## API
```dart
abstract class Transport { /* ... */ }
```

## Usage
final transport = WebSocketTransport(uri);
await transport.connect(uri);
transport.messages.listen((msg) => print('Got: $msg'));
transport.send('{"type":"ping"}');

## Testing
final transport = FakeTransport();
transport.simulateMessage('{"type":"pong"}');
expect(transport.sentMessages, contains('{"type":"ping"}'));
```

## 10. Метрики прогресса

Модульность работает, когда:
1. **Test isolation** — тесты одного слоя запускаются без остальных.
2. **Swap implementations** — `WebSocketTransport` → `HttpTransport` без изменений Client.
3. **Parallel development** — Transport и Protocol можно делать независимо.
4. **Incremental rollout** — новый transport включается feature flag'ом.

Проверяемо: `flutter test test/core` (без widget-тестов) — зелёное; замена транспорта в `service_locator.dart` одной строкой.

## 11. Чеклист

**До начала:**
- [x] Утвердить решения §4 (зафиксировать ADR) — **сделано 30.08**
- [x] Создать ветку `refactor/modular-architecture`
- [x] Серверные фиксы D2/D3/D4/D5/D6/D9 (не зависят от рефакторинга)
- [x] Фаза 0: baseline-тесты на `WsRelayClient` (эталон поведения), красный тест на D1 до фикса
- [ ] `flutter analyze` + `flutter test` зелёные на baseline

**Во время:**
- [x] Каждый слой: unit-тесты + README
- [x] Baseline-тесты зелёные после каждой фазы
- [x] `RelayClient`-интерфейс не меняется (UI не трогали)

**После:**
- [ ] Code review с фокусом на boundaries (нет cross-layer зависимостей)
- [x] Удалён `_legacy/WsRelayClient`
- [ ] Benchmark: время reconnect, latency запросов

## 12. Риски

| Риск | Митигация |
| --- | --- |
| «Parallel run» в мобильном приложении сложен (нет метрик у пользователей) | Заменяем на baseline-тесты: поведение фиксируется тестами, а не продакшен-наблюдением |
| Потеря инвариантов reconnect (один таймер, cancelOnError, дубли disconnect) | Переносить `_scheduleReconnect/_onDisconnect` как есть, покрыть тестами Фазы 0–1 |
| Смена пары: getIt-синглтоны и observer'ы не освобождены | `ConnectionManager.dispose()` снимает observer; `teardownRelayServices` закрывает транспорт |
| Сломан offline-кэш `AgentRepository` | Не трогаем репозиторий; покрыть `relay_client_impl_test` сценарием «relay offline» |
| iOS suspend ~30 c — reconnect пауза потеряется при переносе | `pause()/resume()` переносятся на транспорт, lifecycle — в ConnectionManager (Фаза 4) |

## 13. Открытые вопросы

1. Нужен ли HTTP fallback сейчас (Фаза 5) или только каркас `http_transport.dart`?
2. Добавлять ли метрики/логирование как декоратор в этой итерации?
3. Переносить ли `_legacy` в отдельную ветку вместо `lib/_legacy/` в основной?
