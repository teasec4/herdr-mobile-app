# 03 — Релей (Go, `cmd/relay`)

Единственный процесс на ноуте, который понимает herdr-сокет и отдаёт её
телефону. Уже есть go.mod (`module herdrelay`, Go 1.26.1).

## Обязанности

1. Общаться с herdr (сокет `~/.config/herdr/herdr.sock` по умолчанию, путь
   виден в `herdr status`; настраивается через env `HERDR_SOCKET`/конфиг).
2. Обслуживать телефон: WS-канал (через гейтвей или напрямую) + HTTP fallback.
3. Принимать события от плагина herdr (`pane.agent_status_changed`) и
   раздавать их подключённым клиентам.
4. Аутентифицировать клиентов (bearer-токен пары).

## Связь с herdr: два варианта

### V1 — через CLI (просто и версионно-устойчиво)

Весь CLI herdr отдаёт структурированный JSON. Релей просто `exec`-ит:

```go
// список агентов и статусы
herdr api snapshot
// срез вывода терминала (последние N строк, текст или ansi)
herdr agent read <target> --lines 200 --format text
// послать клавиши
herdr agent send-keys <target> Esc
// послать промпт
herdr agent prompt <target> "продолжай"
```

Звать через `$HERDR_BIN_PATH ?? "herdr"`, как завещает plugin-документация.
Плюс: ничего не ломается при обновлениях herdr, код тривиальный.
Минус: оверхед на спавн процесса (для нашего трафика незаметно).

### V2 — прямой JSON-RPC в сокет

Полная JSON-schema доступна (`herdr api schema`). Пишем маленький RPC-клиент
на unix-сокет, метод `agent.read` и т.п. Быстрее, без спавна процессов, есть
потенциал для стриминга. Делаем, когда v1 заработает, экономно.

**Открытый факт для реализации:** точный формат `target` для `agent read /
send-keys / prompt` — стабильный id агента (из снимка: `pane_id`,
`terminal_id` или имя). Агенты с одинаковыми именами (две `kimi`) есть в живом
снимке, значит имя не уникально — берём `pane_id`. Проверить на этапе v1.

## WS/HTTP API для телефона

- WS-эндпоинт `/ws` — основной канал (JSON-конверт из
  [01-architecture](01-architecture.md)).
- HTTP-эндпоинты (удобно для отладки/curl и для простого клиента):
  - `GET /api/snapshot` — агенты + статусы (JSON).
  - `GET /api/agents/<id>/output?lines=N&format=text|ansi`.
  - `POST /api/agents/<id>/keys` `{"keys":["Esc"]}`.
  - `POST /api/agents/<id>/prompt` `{"text":"..."}`.
- `GET /healthz`.

Режимы подключения (соответствуют QR-схеме пары из
[07 — Онбординг](07-onboarding.md)):

- **lan**: релей слушает `:8375` на LAN-интерфейсе (конкретный LAN-IP).
  Телефон в той же сети. Никакой инфраструктуры.
- **tailscale** (B1): релей слушает `:8375` на tailnet-интерфейсе
  (`tailscale0`), телефон в tailnet ходит напрямую по
  `ws://<machine>.<tailnet>.ts.net:8375`. `tailscale serve` для этого не
  нужен — в tailnet порт уже доступен по WireGuard.
- **funnel** (B2): релей слушает на `127.0.0.1:8375`, наружу смотрит
  `tailscale funnel 8375` (публичный HTTPS на 443, телефону Tailscale не
  нужен). Токен обязателен.
- **gateway** (C): у релея нет входящего порта; он сам держит исходящий
  WS-коннект к гейтвею (URL+токен в конфиге) и ждёт, пока гейтвей пришлёт
  телефонный канал.

## Конфиг (v1, без зависимостей)

Флаги/env:

```text
HERDRELAY_MODE=lan|tailscale|funnel|gateway  # по умолчанию lan
HERDRELAY_LISTEN=127.0.0.1:8375              # для lan — LAN-IP, для
                                             # tailscale — tailscale0,
                                             # для funnel — 127.0.0.1
HERDRELAY_GATEWAY_URL=wss://gw.example.com/ws  # только для gateway
HERDRELAY_TOKEN=<токен пары>                  # генерится при первом запуске
HERDR_SOCKET=~/.config/herdr/herdr.sock
```

Токен пары генерируется при первом запуске. `GET /pair` отдаёт доступные
режимы с готовыми URL (автодетект: LAN-IP, MagicDNS-имя, funnel-адрес, гейтвей
из env) — см. [07 — Онбординг](07-onboarding.md). Плагин печатает QR в пейне
herdr, телефон сканирует. В `funnel`-режиме релей вызывает
`tailscale funnel <port>`; в `lan`/`tailscale` порт доступен без `serve`.

## Какие данные берём из снимка

`herdr api snapshot` отдаёт за один вызов:

- `agents[]`: `agent` (имя, напр. `codex`, `kimi`), `agent_status`
  (`idle|working|blocked|done`), `cwd`, `focused`, `pane_id`, `tab_id`,
  `terminal_id`, `terminal_title`, `workspace_id`.
- воркспейсы, табы — на v2.

Приложение рисует: имя, статус (blocked — сверху), воркспейс, `terminal_title`.

## Аутентификация

- Gateway-режим: гейтвей при коннекте релея проверяет токен; релей передаёт
  токен и `relay_id`, гейтвей шлёт только легитимные каналы.
- Direct-режим: bearer-токен на все эндпоинты.
- Трейт: никакой write-метод без валидного токена.

## Обработка событий от плагина

Плагин шлёт хук (`on-event.sh`) → релей по UDP на `127.0.0.1:<port>` или
локальный HTTP POST. Релей матчит событие в снимок и шлёт по активным
клиентским WS-каналам `{"type":"event","event":"agent_status_changed",...}`.

## Запуск

macOS: launchd-юнит (`plist`), s/systemd для Linux — см.
[04-gateway](04-gateway.md) для окружений и [06-roadmap](06-roadmap.md).
Установка/обновление бинаря — через `[[build]]` плагина (в `$HERDR_PLUGIN_ROOT/bin`).