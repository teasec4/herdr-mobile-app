# 08 — Исполнительный план (лупы, контрольные точки, проверки)

Этот документ превращает архитектуру (01–07) в пошаговый план работы.
Проект делается **лупами** — законченными итерациями, которые можно запустить
и потрогать.

## Правила игры

- Каждый луп = **законченный кусок** + **контрольная точка (гейт)** — список
  проверок, которые обязаны пройти.
- **Гейт красный → не идём дальше**: чиним луп, пока проверки не зазеленеют.
- Проверки запускаются командами из раздела «проверки» лупа.
- Между лупами — общий контур обратной связи: пишем → запускаем → проверяем →
  чиним/фиксируем → берём следующий луп. Всё крутится на ноуте (релей) и на
  телефоне/симуляторе (клиент).
- Лупы релей/плагин/клиент можно вести параллельно, но гейты лупов
  выполняются в порядке слоёв: релей → плагин → клиент → сквозной.
- «Проверенные факты» дополняются по мере работы — это копилка того, что уже
  подтверждено живьём и на что можно опираться без перепроверки.

## Проверенные факты (закрыты на старте, дополняется по мере работы)

- herdr 0.8.0, сокет `~/.config/herdr/herdr.sock`, protocol 19.
- Таргет агента для `read/send-keys/prompt` — **`pane_id`** (имя неуникально:
  в снимке две `kimi`). Проверено живьём: `herdr agent read wG:p1 --lines 5
  --format text` отдаёт текст терминала; `--format ansi` — с ANSI-кодами.
- `herdr agent send-keys <TARGET> <KEY>...` (клавиши — отдельными аргументами,
  `esc` каноническое имя Esc).
- `herdr agent prompt <TARGET> <TEXT> [--wait] [--until STATUS]`.
- `herdr api snapshot` / `agent list` отдают JSON-конверт
  `{"id":..., "result":{...}}`.
- Событийный хук плагина: herdr передаёт событие через env
  **`HERDR_PLUGIN_EVENT_JSON`** в формате `{"data":{...}}` (pane_id, tab_id,
  tab_label, workspace_id, agent_status, agent, display_agent, cwd, ...). Имя
  события в env не приходит — его фиксирует манифест плагина
  (`pane.agent_status_changed`), релей подставляет каноническое имя сам.
- `pane.agent_status_changed` подтверждено живьём: после `herdr plugin link`
  события реально стреляли при смене статуса агента (`herdr plugin log list`
  → status=succeeded, exit_code=0), WS-клиент получал событие с полным `data`
  — E2E, не эмуляция.
- **Хуки herdr НЕ умеют события вывода терминала**: `pane.updated`,
  `pane.output_changed`, `pane.scroll_changed` → «unknown event» (проверено
  брутфорсом на 0.8.0). Живой вывод через плагин невозможен — только через сокет.
- **Сокет-подписка (Б-lite)**: unix-сокет herdr — newline-делимитед JSON-RPC 2.0,
  id запроса — строка. Запрос `events.subscribe` с полем `subscriptions`.
  Входящие нотификации плоские: `{"event":"pane.scroll_changed","data":{pane_id,
  scroll:{max_offset_from_bottom, offset_from_bottom, viewport_rows},
  workspace_id}}` и `{"event":"pane_updated","data":{"pane":{...}}}`.
- Токен релея: `~/.config/herdr/herdrelay.token` (0600, 64 hex); env
  `HERDRELAY_TOKEN` — приоритет. Порт по умолчанию 8375 (env `HERDRELAY_PORT`).
- При `herdr plugin link` (в отличие от `install`) `[[build]]` herdr **не
  выполняет** — локально релей ставится вручную: `bash plugin/install.sh`.

## Лупы релея (Go, `cmd/relay`)

### L0. Каркас: конфиг, токен, HTTP, `/healthz` — ✅ реализовано

- `main.go` — запуск, env-конфиг, `loadOrCreateToken`.
- HTTP-сервер: `/healthz`, auth-middleware (Bearer) на всё кроме `/healthz`.
- Токен: генерируется при первом запуске (32 байта hex), хранится в
  `~/.config/herdr/herdrelay.token` (0600), из env `HERDRELAY_TOKEN` — приоритет.

Проверки L0 (все прошли):
```bash
go build ./... && go vet ./...
./bin/relay &                          # токен напечатан/создан
curl -s localhost:8375/healthz         # {"ok":true}
curl -s -i localhost:8375/api/snapshot # 401 без токена
```

### L1. herdr v1: snapshot + read/keys/prompt по HTTP — ✅ реализовано

- `herdr.go` — тонкая обёртка CLI (subprocess), интерфейс `AgentAPI`.
- `GET /api/snapshot` → агенты+статусы; `GET /api/agents/{pane_id}/output`;
  `POST /api/agents/{pane_id}/keys`; `POST /api/agents/{pane_id}/prompt`.

Проверки L1 (все прошли):
```bash
curl -s -H "Authorization: Bearer $T" localhost:8375/api/snapshot  # живые агенты
curl -s -H "Authorization: Bearer $T" \
  "localhost:8375/api/agents/<pane_id>/output?lines=20"            # текст терминала
# сравнить с: herdr agent read <pane_id> --lines 20 --format text
```

### L2. WS-канал + события — ✅ реализовано

- `ws.go` — хаб клиентов, JSON-конверт (request/response/event/ping/pong),
  методы `agents.snapshot`, `agent.output`, `agent.keys`, `agent.prompt`.
- `POST /api/events` (auth) `{"event":"...","data":{...}}` → рассылка по всем
  WS-клиентам (эмуляция руками и для тестов).
- `POST /api/events/herdr` (auth) — отдельный вход для плагина: принимает
  сырой `HERDR_PLUGIN_EVENT_JSON` (`{"data":{...}}`) и рассылает с
  каноническим именем `pane.agent_status_changed`.

Проверки L2 (все прошли):
```bash
go test ./cmd/relay/ -run WS             # юнит: конверт request/response, ping/pong
go test ./cmd/relay/ -run HerdrEvent     # юнит: POST /api/events/herdr → WS-клиенты
# эмуляция события: curl -X POST -H "Authorization: Bearer $T" \
#   localhost:8375/api/events -d '{"event":"agent_status_changed","data":{}}'
# WS-клиент получает {"type":"event",...}
```

### L3. Пары и режимы: `/pair`, автодетект LAN/Tailscale — ✅ реализовано

- `pair.go` — детект доступных режимов: LAN-IP (`ipconfig getifaddr en0` /
  `hostname -I`), tailnet (`tailscale status --json` → MagicDNS-имя), funnel
  (если включён), gateway (из env).
- `GET /pair` → `{primary, urls:{mode→{url, link}}, token}`. QR рендерит
  плагин/клиент.
- Подкоманда `herdrelay pair [--qr]` — печатает режим / WS-url / ссылку;
  `--qr` рисует ANSI-QR (qrterminal, half blocks) прямо в терминал herdr.

Проверки L3 (все прошли):
```bash
curl -s -H "Authorization: Bearer $T" localhost:8375/pair
# в ответе: lan (192.168.x.x:8375) и tailscale (macbook-pro.tail….ts.net:8375),
# если tailnet жив
plugin/bin/herdrelay pair --qr        # ANSI-QR печатается в stdout
```

### L5. Б-lite: живой вывод через сокет-подписку — ✅ реализовано

- `herdrevents.go` — подписчик на unix-сокет herdr: `events.subscribe` с
  `pane.updated` (глобально) + `pane.scroll_changed` (по каждому pane_id).
- Seed-снимок: при старте берём `herdr api snapshot` (seedKnown), чтобы
  подписаться на уже существующие пейны; новые пейны подписываются
  инкрементально по `pane_updated`.
- Реконнект с бэкоффом 2s → 30s; на изменение скролла релей форвардит клиентам
  событие `pane.output_changed` (data: `{pane_id, workspace_id}`).
- Запуск из `main.go`; изолирован от HTTP-API.

Проверки L5:
```bash
go build ./... && go vet ./... && go test ./...  # зелёное
launchctl print gui/$(id -u)/com.herdrelay.relay  # релей жив, подписчик стартовал
# живой тест: печатаешь в терминале агента → клиент обновляет вывод по
# pane.output_changed (debounce ~400мс)
```

## Лупы плагина herdr (`plugin/`)

### L4. Плагин: манифест, QR-пейн, on-event, launchd — ✅ реализовано

- `herdr-plugin.toml` (id `herdrelay.events`):
  - `[[build]]` → `install.sh` (сборка релея + launchd);
  - `[[events]]` on `pane.agent_status_changed` → `on-event.sh`;
  - `[[actions]]` `show-pair-link` → `open-pane.sh setup`;
  - `[[panes]]` `setup` (placement zoomed) → `setup-menu.sh`.
- `on-event.sh` — читает `HERDR_PLUGIN_EVENT_JSON`, `curl -X POST
  http://127.0.0.1:8375/api/events/herdr` с Bearer-токеном из
  `~/.config/herdr/herdrelay.token`; при любой ошибке `exit 0` (не мешать herdr).
- `install.sh` — `go build` релея из корня репо в `bin/herdrelay`, ставит
  launchd-юнит `com.herdrelay.relay` (RunAtLoad + KeepAlive, логи в
  `${XDG_STATE_HOME:-$HOME/.local/state}/herdrelay/`, env `HERDRELAY_MODE=lan`),
  healthz-проверка.
- `setup-menu.sh` — статус релея + `bin/herdrelay pair --qr` + инструкция.
- `open-pane.sh` — `herdr plugin pane open --plugin herdrelay.events
  --entrypoint setup --placement zoomed --focus`.

Проверки L4 (все прошли):
```bash
bash plugin/install.sh              # собран bin/herdrelay, launchd, "relay is running on :8375"
launchctl print gui/$(id -u)/com.herdrelay.relay   # state=running, pid, пути логов
herdr plugin link /Users/yg_kovalev/go/herdr_relay/plugin
herdr plugin list                   # herdrelay.events (HerdRelay) enabled [local:...]
herdr plugin action list --plugin herdrelay.events # show-pair-link
# живые события (не эмуляция): сменить статус агента → 
#   herdr plugin log list --plugin herdrelay.events → status=succeeded, exit_code=0
#   подключённый WS-клиент получает pane.agent_status_changed с полным data
```
QR-пейн в живом TUI проверяется руками (открывает zoomed-пейн, не делаем без
спроса): `herdr plugin action invoke show-pair-link --plugin herdrelay.events`.

## Лупы клиента Flutter (`client/`)

### C1. Каркас + onboarding — ✅ реализовано (QR-скан проверен на телефоне по LAN)

- Custom scheme `herdrelay://` (Info.plist / intent-filter), скан/вставка
  ссылки, сохранение конфига, коннект к WS, healthz-проверка.
- Реализовано: `PairConfig` (парсинг/валидация ссылки, wsUri/healthUri),
  `ConfigStore` (SharedPreferences), `PairPage` (mobile_scanner + ручной ввод),
  deep link в `main.dart` (app_links), `RelayClient` — абстрактный контракт для
  UI, реализация по WS `WsRelayClient` (автореконнект с бэкоффом,
  request/response, события, ping/pong); клиент создаётся на уровне приложения
  (`main.dart`) и раздаётся всему дереву через `provider`
  (`Provider<RelayClient>.value` — один WS-канал на список и детали, виден и
  push-роутам); в тестах — подмена фейком `FakeRelayClient` через тот же
  `Provider.value`.

Проверки C1:
```bash
cd client && flutter analyze && flutter test   # зелёное (53 теста)
cd client && flutter run                # на телефоне в одной сети — пройдено по LAN
# навести на QR (L4) -> приложение открылось и подключилось
```

### C2. Список агентов — ✅ код

- Снимок + обновления по событиям (`pane.agent_status_changed` → переснапшот),
  **blocked сверху** (сортировка `RelayAgent.sorted` + подсветка карточки),
  pull-to-refresh.

### C3. Терминал-детали — ✅ код

- `AgentPage`: вывод терминала (`agent.output`, моноширинный тёмный терминал,
  автоскролл, **живое обновление по `pane.output_changed` с debounce ~400мс**),
  строка ввода (`agent.prompt`), быстрые клавиши Esc и Ctrl-C (`agent.keys`).
  Один общий WS-клиент на список и детали.
- ANSI-цвета — своим SGR-парсером в `widgets/ansi_terminal.dart` (TextSpan,
  тёмная тема, softWrap); тёмная тема всего приложения — в `main.dart`.
- Покрытие виджет-тестами (`test/agent_page_test.dart`, `test/home_page_test.dart`,
  `test/fakes/fake_relay_client.dart`): рендер вывода, отправка промпта,
  клавиши, обновление статуса по событию, сортировка blocked-сверху,
  навигация в детали, экран ошибки.

### C4. Сквозной гейт MVP (телефон) — ✅ LAN, [ ] B1

Проверки C4 (всё руками с телефона):
1. [x] Дома по LAN (режим A): скан QR → список → вывод → промпт → вижу ответ.
2. [ ] С улицы через tailnet (B1): то же самое.
3. [x] blocked-агент подсвечен сверху; ответ на него уходит за < 2 c.

## Полировка и харденинг (после MVP)

- `flutter_xterm`/настоящий скроллбэк, локальные нотификации, funnel (B2).
- Гейтвей (C) + Docker-деплой (`cmd/gateway`, `deploy/`).
- E2E-шифрование, push FCM, ротация токенов, несколько воркспейсов.

## Финальный гейт MVP

- [x] `go build ./... && go vet ./... && go test ./...` — зелёное.
- [x] `flutter analyze` — без ошибок, **53** unit-теста зелёные.
- [~] LAN (A) с телефона — ✅ пройдено живьём; tailnet (B1) с улицы — не проверено.
- [x] События blocked долетают мгновенно (плагин, не эмуляция).
- [x] Доки обновлены под фактическое поведение.
