# 05 — Flutter-приложение (`client/`)

Мобильный клиент для iOS/Android. Работает во всех транспортах: LAN, Tailscale
(режим B1 — телефону нужен Tailscale), Tailscale Funnel (B2 — публичный HTTPS,
телефону Tailscale не нужен). Клиент построен слоями: `core/transport` +
`core/protocol` + `core/connection` + тонкий `services/relay_client_impl.dart`
(результат рефакторинга, [09 — План](09-refactoring-plan.md), фазы 0–5).

## Слои и зависимости

```
┌─ pages/widgets — UI работает только через RelayClient и PairConfig
├─ services/relay_client.dart      интерфейс RelayClient + RelayStatus (стабилен для UI)
├─ services/relay_client_impl.dart сборка: Transport + RequestResponseManager + HttpHealth
├─ core/protocol  Frame (sealed), RequestResponseManager, RelayException
├─ core/transport Transport (интерфейс), WebSocketTransport, HttpTransport,
│                 ReconnectMixin, RetryPolicy, HttpHealth
├─ core/connection ConnectionManager (lifecycle), ModeService (режимы /pair)
└─ models/ PairConfig · RelayAgent · RelayEvent (без изменений)
```

| пакет | зачем |
| --- | --- |
| `web_socket_channel` | WebSocket-канал к релею (`WebSocketTransport`) |
| `http` | HTTP fallback (`HttpTransport`: `/api/rpc` + SSE), `HttpHealth`, режимы `/pair` |
| `get_it` | DI: `RelayClient`, `AgentRepository`, `ConfigStore`, `ModeService`, `ConnectionManager` |
| `shared_preferences` | сохранение профилей пары + offline-кэш последнего снимка |
| `app_links` | deep link по custom scheme `herdrelay://` |
| `mobile_scanner` | сканирование QR-ссылки пары |

## Экраны

1. **PairPage — онбординг.** Скан QR (`mobile_scanner`) или ручная вставка
   ссылки `herdrelay://pair?...`; ссылка валидируется (токен ≥ 16 символов, без
   символов, ломающих query). Ошибки — тостом (`ToastService`), успех —
   переход на главный экран.

2. **HomePage — список агентов** (главный).
   - карточка агента: имя, статус (`idle/working/blocked/done/unknown`), cwd;
     blocked — сверху и подсветкой («нужен мой ответ»);
   - pull-to-refresh + живое обновление по событиям WS (события дебаунсятся
     300 мс, чтобы пачка событий не порождала N snapshot-запросов);
   - **offline cache**: последний успешный снимок кэшируется в
     `shared_preferences` (`AgentRepository`); при недоступном релее
     показывается закешированный список;
   - в AppBar — **кликабельный бейдж режима** (`LAN`/`TAILSCALE`): тап открывает
     `ModePickerSheet` со списком режимов от релея (`/pair`); выбор режима
     переподключает. Рядом — живой статус соединения (online/connecting/offline);
   - меню «⋮»: **Connection…** (экран соединения), **Add device…**, **Forget device**.

3. **ConnectionPage — экран «Соединение»** (всё о том, как мы подключены):
   - карточка устройства: имя, `host:port`, режим, ws-адрес, id профиля;
   - живой статус + кнопка **Test** (healthz + snapshot: «OK · N agent(s) · Xms»);
   - **Connection mode**: режимы от `/pair` (lan/tailscale/funnel), переключение;
   - **Saved devices**: все сохранённые профили — переключение/удаление;
   - **Pair**: вставка ссылки + «Forget this device» (с подтверждением).

4. **AgentPage — терминал агента.**
   - вывод: моноширинный тёмный терминал, автоскролл, живое обновление по
     `pane.output_changed` с debounce ~400 мс, ANSI — своим SGR-парсером
     (`widgets/ansi_terminal.dart`);
   - строка ввода: промпт (`agent.prompt`); быстрые клавиши Esc/Ctrl-C
     (`agent.keys`); история команд; кнопки действий из вывода.

## Транспорт

- **WebSocketTransport** — raw-строки, без знания протокола. Reconnect с
  `RetryPolicy` (default `ExponentialBackoff`: 1, 2, 4, … до 30 с; формула и
  лимит — `core/transport/retry_policy.dart`). Защита от дублей: один таймер,
  `cancelOnError`, единый обработчик `onDone/onError`.
- **Keepalive** (по умолчанию 20 с ping / 10 с окно pong): детектит «полумёртвые»
  соединения (мобильные NAT молча роняют сокет) и переподключается.
- **Lifecycle** — `core/connection/connection_manager.dart`
  (`WidgetsBindingObserver`): `paused`/`hidden` → `transport.pause()`,
  `resumed` → `transport.resume()` (бережёт батарею; iOS замораживает сокеты
  ~30 с в фоне).
- **HttpTransport** — HTTP fallback (Phase 5): `send()` POSTит request-фрейм в
  `/api/rpc`, события — SSE-стрим `/api/events/stream`; тот же reconnect/backoff.
  Включается в `service_locator` параметром `transportMode: 'ws'|'http'`.
- **HttpHealth** — `/healthz`, до 3 попыток с коротким backoff.

## Протокол

- `core/protocol/relay_protocol.dart` — `sealed Frame`:
  `Request/Response/Event/Ping/Pong`, строгий `Frame.parse` (мусор →
  `ProtocolException`).
- `core/protocol/request_response_manager.dart` — id→completer, таймаут 15 с,
  при disconnect все pending завершаются ошибкой, автопинг-понг, cold-start
  ожидание до 8 с перед `not_connected`.
- `RelayException`/`RelayError`/`ProtocolException` — `core/protocol/`;
  `services/relay_client.dart` делает `export`, чтобы UI/тесты продолжали
  импортировать из одного места.

## События

`pane.agent_status_changed` (ключ **`agent_status`** — клиент читает именно его),
`pane.updated`, `pane.output_changed` (у `pane.scroll_changed` нет `revision` —
дебаунс на клиенте). Статусы агентов: `idle/working/blocked/done/unknown`
(docs/10-herdr-api.md §6.2).

## Ошибки и их отображение

- `ToastService` мапит протокольные ошибки в понятный текст: `not_connected` →
  «проверьте сеть», `timeout` → «попробуйте ещё раз», `unauthorized` →
  «пересканируйте QR».
- `ModeService` (режимы `/pair`) — до 3 попыток с backoff, таймаут 5 с; 401/403
  — сразу без ретраев; понятные сообщения («Cannot reach relay…», «Relay did
  not respond in time…»); в `ModePickerSheet` — стейты loading/error+Retry/list.
- Ссылка пары валидируется на входе (токен ≥ 16 символов, без `& # ?` пробела).

## Тесты (148)

- **unit**: `test/core/protocol/` (parse/encode, matching, timeout, fail-on-
  disconnect), `test/core/transport/` (reconnect, keepalive, pause/resume,
  HttpTransport против dart:io mock, HttpHealth, RetryPolicy),
  `test/core/connection/` (lifecycle, ModeService с ретраями/лимитами).
- **integration**: `test/services/relay_client_impl_test.dart` —
  `RelayClientImpl` + `FakeTransport`.
- **widget**: `home_page_test`, `connection_page_test`, `pair_page_test`,
  `agent_page_test`.
- **fakes**: `FakeRelayClient`, `FakeTransport`, `FakeWebSocketChannel`.

`flutter analyze` — 0 warnings/errors.

## Что сознательно НЕ в v1

- Workspaces/worktrees/диффы.
- Ответы на структурированные approve-флоу агентов: «ответить» = текст/клавиши
  в терминал (покрывает большинство кейсов).
- Push-уведомления (FCM/APNs) — план (см. [06 — Roadmap](06-roadmap.md));
  локальных нотификаций тоже нет, blocked подсвечивается в списке.
- `flutter_xterm` вместо своего ANSI-парсера — план v2.

## Безопасность и известные риски

- Токен пары хранится в `shared_preferences` и передаётся как `?token=` в query
  WS; логирование только через `PairConfig.toJsonSafe()` (маска токена).
- Certificate pinning для funnel mode сознательно не реализован (риск
  задокументирован): funnel идёт через Tailscale Funnel с Let's Encrypt;
  pinning требует платформенной реализации и усложняет ротацию — пересмотреть
  при публичном распространении.
- Валидация входящих ссылок пары (см. PairPage).
