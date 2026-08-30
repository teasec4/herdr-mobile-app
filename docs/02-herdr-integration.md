# 02 — Интеграция с herdr: как «подрубается» плагин

Этот документ отвечает на вопрос «как плагин прописывается в herdr».
Всё ниже проверено по официальной документации herdr (`docs/.../plugins.mdx`,
`cli-reference`) и по живым примерам: `persiyanov/herdr-reviewr` и
`0cv/herdr-mobile-relay`. Пункты, помеченные «проверено живьём», подтверждены
на реальном herdr 0.8.0 в ходе разработки этого релея (луп L4).

## Модель плагина (коротко)

Плагин herdr — это **просто каталог с манифестом `herdr-plugin.toml` и
командами**. Никакого SDK и специального языка нет: плагином может быть
Bash-скрипт, JS-приложение, Rust/Go/Python бинарь, что угодно, что умеет
выполнять машина. Весь CLI herdr — это и есть API плагина: внутри команд
плагин зовёт `herdr ...` через переменную окружения `HERDR_BIN_PATH`
(указывает на запущенный бинарь herdr, переносимо между unix-сокетом и
named pipe). Кто хочет — шлёт сырой JSON-RPC прямо в сокет.

Ядро herdr написано на Rust и ведёт себя как «хост»: владеет установкой,
валидацией манифеста, хоткеями, терминальными пейнами, событиями, сокетом.
Плагин владеет своей логикой, зависимостями и состоянием.

## Манифест `herdr-plugin.toml`

Обязательные поля: `id`, `name`, `version`, `min_herdr_version`.
Опциональные: `platforms`, `description`.

Секции-хуки, которые нам интересны:

| секция | зачем |
| --- | --- |
| `[[build]]` | команды при установке (скачать бинарь, собрать, `npm ci`) |
| `[[startup]]` | команды при старте herdr (автозапуск) |
| `[[actions]]` | действия в меню herdr, можно повесить на хоткей в `config.toml` |
| `[[events]]` | реакция на события herdr (например `pane.agent_status_changed`) |
| `[[panes]]` | управляемые herdr терминальные пейны (setup-меню, QR) |
| `[[link_handlers]]` | обработчики ссылок (нам не нужно) |

Пример из еёр-документации:

```toml
id = "example.layout"
name = "Layout"
version = "0.1.0"
min_herdr_version = "0.7.0"
platforms = ["linux", "macos"]

[[events]]
on = "worktree.created"
command = ["herdr", "workspace", "list"]

[[panes]]
id = "board"
title = "Project board"
placement = "overlay"
command = ["herdr-board"]
```

`command` — это argv-массив, без шелла (если нужен шелл — сам запускай).

## Установка и линковка

```bash
# из GitHub (shorthand owner/repo[/subdir]):
herdr plugin install yg_kovalev/herdr_relay/plugin
# локально при разработке:
herdr plugin link /Users/yg_kovalev/go/herdr_relay/plugin
# проверить/управлять:
herdr plugin list
herdr plugin action list --plugin herdrelay.events
herdr plugin log list --plugin herdrelay.events
```

Установка из GitHub: herdr клонирует репо в
`~/.config/herdr/plugins/github/<id>-<hash>/`, показывает превью (в
интерактивном терминале), гоняет `[[build]]`, регистрирует. Переустановка
заменяет checkout. `herdr plugin install` понимает только GitHub-shorthand.
Установленные и слинкованные плагины глобальны для юзера, доступны во всех
сессиях herdr.

**Проверено живьём:** `herdr plugin link` сработал, `herdrelay.events` виден
в `herdr plugin list` как `enabled [local:...]`. При линковке (в отличие от
`install`) herdr **не выполняет** `[[build]]` — локально релей ставится
вручную: `bash plugin/install.sh` (детали в «Запуск релея»).

## Что нам реально нужно от плагина

Сам релей — **отдельный Go-процесс**, он не живёт внутри herdr. Плагин нужен
как тонкая обёртка для двух вещей:

1. **Пейринг.** Экшен «показать QR» (`show-pair-link`) и пейн `setup` —
   удобно сканировать с телефона один раз вместо вбивания URL+токен руками.
   QR = custom-scheme-ссылка `herdrelay://pair?...` с автоопределением режима
   (LAN / Tailscale / gateway), URL берётся из `GET /pair` релея — см.
   [07 — Онбординг](07-onboarding.md). Рендерит QR подкоманда
   `herdrelay pair --qr` (ANSI half-blocks прямо в терминал herdr).

2. **Установка/запуск релея.** `[[build]]` → `install.sh` собирает Go-релей в
   `bin/herdrelay` и ставит launchd-сервис (см. «Запуск релея»).

**Живой статус и вывод — НЕ через плагин (раньше статусы шли хуком, теперь
только сокет).** Хук-система herdr не имеет события для вывода терминала:
`pane.updated`, `pane.output_changed`, `pane.scroll_changed` отвергаются
линковщиком как unknown event (проверено брутфорсом на herdr 0.8.0). Статусы
раньше дублировались: хуком `on-event.sh` (`POST /api/events/herdr`) **и**
сокет-подпиской. Сокет самодостаточен (`events.subscribe` включает
`pane.agent_status_changed` по pane_id), поэтому хук и HTTP-роуты
`/api/events/*` удалены — одно изменение статуса = одно событие клиенту
(см. `docs/12-fix-plan.md` A1). Реализация:
`internal/infrastructure/herdr/socket_event_repository.go` и
[03-relay.md](03-relay.md) → «Обработка событий herdr». Плагин в этой схеме
не участвует вовсе.

Реализованный манифест (`plugin/herdr-plugin.toml`):

```toml
id = "herdrelay.events"
name = "HerdRelay"
version = "0.1.0"
description = "Remote control for Herdr: monitor and check agents from your phone over LAN/Tailscale"
platforms = ["macos", "linux"]

# собрать Go-релей в bin/ и поставить launchd-сервис (macOS)
[[build]]
command = ["bash", "install.sh"]

# [[events]]-хука нет: статусы и живой вывод релей получает напрямую по
# unix-сокету herdr (events.subscribe) — см. «Живой статус и вывод» ниже.

# «Показать QR» — открывает пейн setup со ссылкой/QR пары
[[actions]]
id = "show-pair-link"
title = "HerdRelay: show phone link / QR"
command = ["bash", "open-pane.sh", "setup"]

[[panes]]
id = "setup"
title = "HerdRelay: Setup"
placement = "zoomed"
command = ["bash", "setup-menu.sh"]
```

Про `id`: точки внутри id плагина допустимы (`herdrelay.events`), а внутри id
экшенов/пейнов — нет; herdr квалифицирует как `plugin.id.action`.

## Запуск релея: плагин против сервиса

Было два подхода (Решение 2). **Закрыто: выбран A — релей = системный сервис.**

- **A. Релей = системный сервис** (launchd на macOS / systemd на Linux).
  Плагин только для событий, QR и установки. Управление жизненным циклом
  предсказуемое, релей переживает перезапуски herdr. ← **реализовано:**
  `install.sh` собирает `bin/herdrelay` и ставит
  `~/Library/LaunchAgents/com.herdrelay.relay.plist` (RunAtLoad + KeepAlive,
  логи в `${XDG_STATE_HOME:-$HOME/.local/state}/herdrelay/`, env
  `HERDRELAY_MODE=lan`), порт по умолчанию 8375 (env `HERDRELAY_PORT`).
- **B. Релей = `[[startup]]`-хук** плагина, стартует вместе с herdr.
  Проще в установке (один `plugin install`), но жизненный цикл связан с herdr
  — отклонён.

Проверка сервиса (проверено живьём):
```bash
launchctl print gui/$(id -u)/com.herdrelay.relay  # state=running, pid, пути логов
curl -s localhost:8375/healthz                    # {"ok":true}
```

## События herdr: что проверено живьём

- **`pane.agent_status_changed`** — смена статуса агента. Приходит релею по
  unix-сокету (`events.subscribe` с per-pane подпиской), а не через плагин-хук
  (хук удалён — он дублировал сокет, см. `docs/12-fix-plan.md` A1).
  Подтверждено на реальном herdr 0.8.0: WS-клиент получал событие с полным
  `data` (pane_id, agent_status, agent, display_agent, workspace_id, title).
- `worktree.created` — ревьюровский кейс, нам не нужен.

События статусов и вывода — только через сокет, не через хук. Все имена
событий вывода (`pane.updated`, `pane.output_changed`, `pane.scroll_changed`)
линковщик отвергает: `herdr plugin link` → warning «unknown event». Проверено
на herdr 0.8.0. Живой статус/вывод работает через JSON-RPC-подписку релея по
unix-сокету: `events.subscribe` c `pane.updated` (глобальная),
`pane.scroll_changed` и `pane.agent_status_changed` по pane_id; нотификации
приходят как `{"event":"pane.scroll_changed","data":{...}}`
(данные: pane_id, scroll.max_offset_from_bottom, offset_from_bottom,
viewport_rows), `{"event":"pane.agent_status_changed","data":{...}}` и
`{"event":"pane_updated","data":{"pane":{...}}}`. Формат запроса/ответа и
диалект сокета — в [03-relay.md](03-relay.md) → «Обработка событий herdr».

Раньше статусы шли ещё и плагинным хуком (`on-event.sh` → `POST
/api/events/herdr`, контракт env `HERDR_PLUGIN_EVENT_JSON`), что давало два
события на одно изменение. Хук и роуты `/api/events/*` удалены — сокет
самодостаточен (`pane_updated` при подписке перечисляет существующие панели).

Полный список доступных событий уточняется по схеме/докам herdr на этапе
реализации (в `docs/next/.../plugins.mdx` и `cli-reference`).

## Ссылки

- Официальная документация плагинов лазит тут:
  `<herdr repo>/docs/next/website/src/content/docs/plugins.mdx`.
- `herdr api schema` — полный контракт сокета (то же самое в репо herdr:
  `docs/next/api/herdr-api.schema.json`).
- Референсы: `persiyanov/herdr-reviewr` (Rust-плагин, манифест с build/panes/
  actions/events), `0cv/herdr-mobile-relay` (Go-плагин + событие + сервис).