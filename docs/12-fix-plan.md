# План исправлений: аудит потока сообщений herdr ↔ релей ↔ клиент

Статус: **частично реализовано (30.08)** — A1, A2, A3, B3 закрыты; остальные фазы (B1–B2, B4–B5, C, D, E, F) — в очереди.
Дата: 2026-08-30
Основание: ручной аудит потока событий/команд (`pane.agent_status_changed` приходит двумя путями,
CLI herdr без таймаутов, синхронный broadcast, нет give-up на ретраях и т.д.). Каждый пункт ниже
сверен с кодом (файл:строка) на момент написания.

---

## 0. Резюме

- **Все находки аудита подтверждены** (14 тестов Go только в `cmd/relay` на стабах; Flutter 148 тестов).
- Критичных проблем три: (1) двойная рассылка `agent_status_changed` (хук + сокет), (2) CLI herdr
  и HTTP-сервер без таймаутов → зависший `herdr` блокирует запрос навсегда, (3) синхронный
  `Broadcast` → медленный клиент стопорит рассылку всем.
- План разбит на фазы A–F; A+B дают максимум пользы и должны идти первыми.

---

## 1. Верифицированные находки (сверка с кодом)

### 1.1 Дублирование и костыли

| # | Находка | Подтверждение в коде |
|---|---|---|
| D1 | **Двойной путь `agent_status_changed`**: HTTP-хук плагина + подписка по сокету → каждое изменение статуса бродкастится клиенту дважды | `plugin/on-event.sh` → `router.go:23-25` → `internal/transport/http/handler.go:168-194` (`HandlePluginEvent` → `eventService.Broadcast`); сокет: `internal/infrastructure/herdr/socket_event_repository.go:126` (подписка `pane.agent_status_changed` на pane) |
| D2 | Дубль-роут `/api/events/pane.agent_status_changed` — мёртвая копия `/api/events/herdr` | `cmd/relay/router.go:26-28` |
| D3 | Slow-consumer: `Broadcast` синхронно пишет каждому клиенту; `Client.Write` под mutex блокируется при полном TCP-буфере → медленный клиент стопорит рассылку всем | `internal/transport/ws/hub.go:44-58`, `:96-100` |
| D4 | Потеря полей события: `AgentStatusChangedEvent` содержит только `pane_id`+`agent_status`; `agent`, `display_agent`, `workspace_id`, `tab_id`, `cwd`, `title` из herdr-payload молча отбрасываются | `internal/domain/event.go:12-15`; реальный payload — `docs/10-herdr-api.md:354` |
| D5 | Revision-guard инертен: `OutputChangedEvent.Revision` с `omitempty`, всегда 0 → guard на клиенте никогда не срабатывает | `internal/domain/event.go:40-43`; `client/lib/pages/agent_page.dart:106-109` (`revision > 0` никогда) |
| D6 | Pong-фрейм попадает в поток сообщений клиента (верхний слой игнорирует, но неаккуратно) | `client/lib/core/transport/websocket_transport.dart:118-121` vs `client/lib/core/protocol/request_response_manager.dart:103` |
| D7 | `emitEvent` при полном канале ждёт до 5 с (`time.After`) → может тормозить чтение сокета herdr | `socket_event_repository.go:198-210` |
| D8 | Внутренние каналы: события 100 (`event_service.go:47`), listener 10 (`:74`); при полном listener событие дропается молча (`:99-113`, `default`) | `internal/service/event_service.go` |
| D9 | `errRestart`-цикл: каждая новая панель = полный рестарт сокет-коннекта (при старте с N панелями — N рестартов) | `socket_event_repository.go:56-70,161-169` |
| D10 | Server-side snapshot не кэшируется: каждый запрос спавнит CLI-подпроцесс | `cmd/relay/main.go:40-41` + `internal/infrastructure/herdr/cli_repository.go:47` |
| D11 | Мелкий баг кэша: `RelayAgent.toJson` не пишет `workspace_id` → кэш `last_snapshot` теряет workspaceId | `client/lib/models/relay_agent.dart:67-73` |

### 1.2 Обработка ошибок

| # | Находка | Подтверждение |
|---|---|---|
| E1 | `HttpTransport.send` — fire-and-forget: при `status != 200` только `lastError`; `catchError` глотает сетевые ошибки молча; вызывающий код ждёт полные 15 с | `client/lib/core/transport/http_transport.dart:131-153`; `request_response_manager.dart:62-68` |
| E2 | `getAgents()` ловит любую ошибку и молча отдаёт кэш; свежесть (`lastCachedAt()`) UI не показывает | `client/lib/repositories/agent_repository.dart:27-37` |
| E3 | Сервер на ошибки CLI отвечает 502 без деталей (приемлемо) | `internal/transport/http/handler.go:57,121,160` |
| E4 | Race на клиенте: `_channel?.sink.add` молча роняет request-фрейм при обрыве между проверкой статуса и отправкой → запрос висит до таймаута | `websocket_transport.dart:157`; `request_response_manager.dart:45-60` |
| E5 | Нет graceful shutdown: `eventService.Stop()` никем не вызывается, SIGTERM не обрабатывается | `cmd/relay/main.go:15-68` |

### 1.3 Ретраи и таймауты

| # | Находка | Подтверждение |
|---|---|---|
| R1 | **CLI herdr без таймаута**: `exec.Command` без контекста — зависший herdr = висящий запрос навсегда (самый критичный пробел) | `cli_repository.go:28-42` |
| R2 | `http.Server` без `ReadHeaderTimeout/ReadTimeout/WriteTimeout/IdleTimeout` | `main.go:67` |
| R3 | `http.DefaultClient` без таймаута в `fetchPairInfo` | `cmd/relay/pairfetch.go:21` |
| R4 | `await ws.ready` без собственного таймаута | `websocket_transport.dart:104` |
| R5 | `shouldRetry` возвращает true всегда — даже при неверном токене (401) клиент ретраит бесконечно, нет различения «переходная/навсегда» | `client/lib/core/transport/retry_policy.dart:26,46` |
| R6 | Reconnect-цикл сокета: `time.Sleep` на `:65/:76` не прерывается `Close()` (`:256-265`) — «спящий» цикл при shutdown | `socket_event_repository.go:40-78` |

### 1.4 Безопасность

| # | Находка | Подтверждение |
|---|---|---|
| S1 | `CheckOrigin: true` — любой origin открывает WS (осознанный компромисс для LAN) | `internal/transport/ws/handler.go:13-14` |
| S2 | Токен принимается и через `?token=` — светится в URL/логах/прокси | `cmd/relay/router.go:59` |
| S3 | Read-цикл без read/write deadlines и без лимита размера сообщения | `ws/handler.go:48-64` |
| S4 | `handleFrame` — switch без `default`: неизвестные типы фреймов молча игнорируются | `ws/handler.go:67-80` |
| S5 | Нет лимита тела POST (`keys/prompt/events/herdr`) | `internal/transport/http/handler.go` |
| S6 | Хорошо: `verifyToken` — `subtle.ConstantTimeCompare`; токен-файл 0600 | `router.go:54-62`; тесты `TestLoadTokenCreatesFile` |

### 1.5 Дебаг-вывод в проде

| # | Находка | Подтверждение |
|---|---|---|
| G1 | `print(...)` на каждый fetch/событие | `home_page.dart:90,99,109-114,120,123`; `agent_page.dart:71,118,129,172,176` |
| G2 | Хук пишет каждый ивент в `/tmp/herdr-relay-events.log` (помечено «comment out in production», но включено) | `plugin/on-event.sh:27` |

### 1.6 Тесты

| # | Находка | Подтверждение |
|---|---|---|
| T1 | Go: 14 тестов только в `cmd/relay/server_test.go`; вся herdr-интеграция на стабах (`stubAgentRepo`/`stubEventRepo`/`stubDetector`); `internal/domain`, `internal/infrastructure/herdr`, `internal/service`, `internal/transport/*` — `[no test files]` | `go test ./...` |
| T2 | Flutter: 148 тестов, транспорты/протокол/страницы покрыты; дедуп, двойная рассылка, таймауты CLI не тестируются | `client/test/` |

---

## 2. План исправлений по фазам

### Фаза A — Данные и дубли (база, влияет на всё остальное)

#### A1. Единый источник `agent_status_changed` = сокет; убрать хук и дубль-роут — ✅ реализовано
- **Проблема**: D1, D2. Каждое изменение статуса бродкастится дважды; клиент делает лишние запросы
  (3× snapshot + 2× read на одно изменение при открытой agent-странице).
- **Решение**:
  - Удалить `[[events]]`-блок (`on = "pane.agent_status_changed"`) из `plugin/herdr-plugin.toml`;
    удалить/опустошить `plugin/on-event.sh` (сокет самодостаточен — комментарий
    `socket_event_repository.go:120`; `pane.updated` при подписке перечисляет существующие панели).
  - Удалить дубль-роут `router.go:26-28`; оставить `/api/events/herdr` только если остаётся
    какой-то HTTP-источник (сейчас нет — можно удалить и его, если хук убран полностью).
  - Обновить `docs/01-architecture.md`, `docs/02-herdr-integration.md`, `README.md`,
    `CHANGELOG.md` (упоминания хука).
- **Тесты**: T1-расширение — fake unix-socket (см. F1) доказывает, что статус приходит ровно один раз.

#### A2. Расширить `AgentStatusChangedEvent` полями — ✅ реализовано
- **Проблема**: D4. Клиент не может обновить агента из события (нет `display_agent`, `cwd`,
  `workspace_id`, `tab_id`), поэтому делает snapshot-запрос.
- **Решение**: `internal/domain/event.go:12-15` — добавить `Agent, DisplayAgent, WorkspaceID, TabID,
  Cwd, Title` (payload: `docs/10-herdr-api.md:354`). На клиенте: `relay_event.dart` (парсинг полей),
  `agent_page.dart` — обновлять `_agent` из события целиком.
- **Тесты**: unit на `domain.ParseEvent` (новый `internal/domain/event_test.go`); клиент —
  `relay_event_test.dart` на парсинг полей.

#### A3. Убрать инертный revision-guard — ✅ реализовано (безопасным вариантом)
- **Проблема**: D5. `pane.scroll_changed` не несёт `revision` (docs gotcha №5), guard никогда не
  срабатывает; защита от дублей — debounce, который уже есть.
- **Решение**: удалить `_lastRevision`/guard из `agent_page.dart:106-109` (и `revision` из
  `OutputChanged`-парсинга, если не появится реальный источник). Документировать в коде.
- **Тесты**: клиентские тесты agent-страницы не ломаются; комментарий-обоснование.
- **Примечание (реализация 30.08)**: guard не удалён, а **оживлён** — релей теперь прикрепляет к
  `pane.output_changed` последний известный `revision` из `pane.updated`, **только строго растущий**
  (устаревшая/равная ревизия не шлётся, чтобы guard не пропустил живой апдейт). Клиентский guard
  начинает работать; при отсутствии ревизии клиент, как и раньше, полагается на debounce.

### Фаза B — Таймауты и зависания (самое опасное)

#### B1. Таймаут на CLI herdr
- **Проблема**: R1.
- **Решение**: `cli_repository.go:28-42` — `exec.CommandContext` с таймаутом
  (по умолчанию 10 с, env `HERDRELAY_CLI_TIMEOUT`, `cmd/relay/config.go`); при `context.DeadlineExceeded`
  — `DispatchError{Code: "timeout"}` (клиент получит быструю понятную ошибку вместо вечного ожидания).
- **Тесты**: unit `cli_repository_test.go` — фейковый `bin`-скрипт, который спит дольше таймаута;
  проверка, что `run` возвращает ошибку вовремя и не висит.

#### B2. Таймауты `http.Server` + graceful shutdown
- **Проблема**: R2, E5.
- **Решение**: `main.go:67` — `http.Server{ReadHeaderTimeout: 5s, ReadTimeout: 30s, WriteTimeout: 30s,
  IdleTimeout: 60s}`; обработка SIGTERM/SIGINT: `eventService.Stop()`, `server.Shutdown(ctx)`.
  (Отдельно: `Close()` сокет-репозитория должен прерывать `time.Sleep` в reconnect-цикле — R6,
  см. B3.)
- **Тесты**: `server_test.go` — старт/стоп сервера с shutdown (без реального herdr).

#### B3. Прерываемый reconnect-цикл сокета — ✅ реализовано
- **Проблема**: R6. `time.Sleep` на `:65/:76` не прерывается `Close()`.
- **Решение**: заменить `time.Sleep` на `select { case <-time.After(...): case <-r.stopCh: }`;
  `Close()` закрывает `stopCh` (с `sync.Once`).
- **Тесты**: unit `socket_event_repository_test.go` — `Subscribe` + `Close` сразу: цикл завершается
  без паузы (не висит 2+ с).

#### B4. Таймаут HTTP-клиента в pairfetch
- **Проблема**: R3.
- **Решение**: `pairfetch.go:21` — `http.Client{Timeout: 5 * time.Second}` (или пакетный клиент).

#### B5. Таймаут на `ws.ready` + 401-детекция
- **Проблема**: R4 (+ связка с R5).
- **Решение**: `websocket_transport.dart:104` — `await ws.ready.timeout(...)`; классифицировать ошибку
  апгрейда (401/403) как «неверный токен» (см. D1 ниже).

### Фаза C — Slow consumer

#### C1. Per-client очередь в WS-hub — ✅ реализовано (queue 128, slow consumer закрывается, broadcast не блокируется; hub_test)
- **Проблема**: D3.
- **Решение**: `hub.go` — у каждого `Client` канал-очередь (напр. 64) + writer-goroutine;
  `Broadcast` кладёт сообщение неблокирующе, при переполнении — drop-oldest (или дроп нового +
  счётчик в лог); ошибка записи → закрыть клиента. Убрать блокирующий `Write` под mutex из
  горячего пути.
- **Тесты**: unit `hub_test.go` (новый) — медленный клиент (полная очередь) не блокирует
  `Broadcast` другим; дроп-oldest работает; закрытие клиента при ошибке записи.

### Фаза D — Клиент: ретраи, транспорт, UX

#### D1. Give-up на ретраях при невосстановимых ошибках
- **Проблема**: R5. При неверном токене (401 на WS-апгрейде/SSE) клиент ретраит бесконечно
  и висит в «connecting…».
- **Решение**: расширить контракт — `RetryPolicy.shouldRetry(attempt, error)` дополняется признаком
  «fatal» (транспорт помечает 401/403), либо отдельный метод `isFatal(error)`. `ExponentialBackoff`
  возвращает false для fatal. UI (`connection_page.dart`/статус) показывает
  «неверный токен — пересканируйте QR» и прекращает reconnect-цикл.
- **Тесты**: `retry_policy_test.dart` — fatal-ошибка → `shouldRetry == false`; transport-тесты — 401
  на SSE/апгрейде не планирует reconnect.

#### D2. HTTP-транспорт: таймаут и проброс ошибок
- **Проблема**: E1.
- **Решение**: `http_transport.dart:131-153` — `_client.post(...).timeout(...)`; при ошибке/не-200
  класть **error-фрейм в `_messages`** (не только `lastError`), чтобы `RequestResponseManager`
  фейлил запрос мгновенно с понятным `RelayException`. `send` остаётся `void` (контракт),
  но ошибка доставляется в протокольный слой.
- **Тесты**: `http_transport_test.dart` — таймаут/сетевая ошибка/401 → в `_messages` приходит
  error-фрейм; `request_response_manager` фейлит запрос сразу.

#### D3. Agent-страница: debounce статуса + без лишнего snapshot — ✅ (в f7a701f)

**Доп. (после аудита): reconnect catch-up** — HomePage/SpacesPage/RunPage перечитывают данные при переходе disconnected→connected (события за разрыв теряются): `_wasDisconnected` + refresh/`_load()`; тест home_page_test «после реконнекта список перечитывается».
- **Проблема**: D1 (клиентская часть), E4.
- **Решение**: `agent_page.dart:117-131` — debounce refresh по `AgentStatusChanged` (300–400 мс,
  как у output); после A2 событие несёт `display_agent/cwd/workspace_id` → `_refreshAgentFromSnapshot()`
  на событие не нужен (оставить только для ручного refresh). Закрыть race E4: в
  `request_response_manager.request` — проверять connected повторно после `send` (или вернуть
  `send`→`bool`).
- **Тесты**: `agent_page_test.dart` — бурст статус-событий → один refresh.

#### D4. Чистка debug-вывода и UX свежести кэша
- **Проблема**: G1, G2, E2.
- **Решение**: убрать `print` из `home_page.dart`/`agent_page.dart`; `on-event.sh` (если остаётся)
  — лог только под env-флагом. `home_page` — если список из кэша, показывать
  «показаны сохранённые данные от HH:MM» (по `AgentRepository.lastCachedAt()`); `getAgents()` —
  возвращать признак «из кэша». Починить D11 (`toJson` → `workspace_id`).
- **Тесты**: `home_page_test.dart` — баннер свежести при кэше; `agent_repository_test.dart` — признак
  кэша.

### Фаза E — Безопасность/гигиена WS и HTTP

| Пункт | Решение | Файлы |
|---|---|---|
| S3 | `SetReadLimit` (~64 КБ), `SetReadDeadline`/`SetWriteDeadline` + pong-обработчик (keepalive на уровне WS) | `internal/transport/ws/handler.go` |
| S4 | `default` в `handleFrame`: логировать неизвестный тип; не молча | `internal/transport/ws/handler.go:67-80` |
| S5 | `http.MaxBytesReader` на POST-эндпоинтах (`keys/prompt/events/herdr/rpc`) | `internal/transport/http/handler.go` |
| S1/S2 | Оставить как осознанный компромисс (LAN); задокументировать. Опционально: `Origin`-проверка по конфигу; токен только в `Authorization` для не-QR-клиентов | `ws/handler.go:13-14`, `router.go:59` |

### Фаза F — Тесты (регрессионная защита фаз A–C)

#### F1. Интеграционный тест с fake herdr-сокетом (Go)
- Фейковый unix-socket в тесте: принимает `events.subscribe` (JSON-RPC), отвечает
  `subscription_started`, шлёт `pane_updated`, `pane.agent_status_changed`, `pane.scroll_changed`.
- Проверяет: (A1) статус приходит ровно один раз (нет дублей), (B1) CLI-таймаут, (C1) slow-consumer
  не блокирует, (B3) `Close()` прерывает reconnect.
- Файлы: `internal/infrastructure/herdr/socket_event_repository_test.go`,
  `internal/service/event_service_test.go`, `internal/transport/ws/hub_test.go`.

#### F2. Клиентские тесты
- `retry_policy_test.dart` (D1), `http_transport_test.dart` (D2), `agent_page_test.dart` (D3),
  `home_page_test.dart` (D4).

---

## 3. Порядок и зависимости

```
Фаза A (данные/дубли) ──► Фаза B (таймауты) ──► Фаза C (slow consumer)
        │                       │
        └──► Фаза D (клиент) ◄──┘        Фаза E (безопасность) — независима
                                             │
Фаза F (тесты) — пишется вместе с A–C, финальный прогон после E
```

- A1, A2, A3 — один PR (устранение дублей + поля + guard): даёт видимый эффект сразу.
- B1–B5 — один PR (все таймауты): критично для надёжности.
- C1 — отдельный PR (hub-очередь).
- D1–D4 — один PR (клиентские ретраи/транспорт/UX).
- E — отдельный PR (безопасность).
- F1/F2 — по каждому PR, финальный полный прогон.

## 4. Критерии приёмки

- `go test ./...` и `flutter test` зелёные; `flutter analyze` 0 warnings.
- Живой прогон: изменение статуса агента → ровно одно событие в клиенте (лог/счётчик), один
  snapshot-запрос на бурст, agent-страница обновляется из события без snapshot.
- Зависший `herdr` (kill -STOP) → запросы фейлятся за ~10 с с понятной ошибкой, не висят вечно.
- Неверный токен → клиент прекращает reconnect и показывает «неверный токен» (не «connecting…»).
- Медленный клиент (throttle сети) не замедляет рассылку остальным.
- В логах релея/клиента нет debug-print'ов и `/tmp/herdr-relay-events.log`.
