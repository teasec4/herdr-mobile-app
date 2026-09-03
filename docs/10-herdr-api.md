# 10 — Полный справочник herdr API (для разработчиков)

> Назначение документа: единый справочник по API **herdr** для разработчиков нашего релея —
> что herdr даёт, что мы можем от него получать, что ему передавать, как это соединяется и работает.
> Это «документ-справка»: обращаемся к нему по мере необходимости, не держим в голове.
>
> Проверено живьём против **herdr 0.8.0** (channel `stable`, protocol 19, schema_version 1).
> Всё, что отмечено «проверено живьём», воспроизводилось на реальном бинаре через
> `herdr api snapshot` / raw-socket-соединение. Остальное — снято со схемы `herdr api schema --json`.

---

## 1. Что такое herdr и зачем это нам

**herdr** — терминальный мультиплексор + агент-рантайм для AI-агентов (аналог screen/tmux,
но с «машиной состояний» для агентов). Состоит из двух частей:

- **server** — демон, держит workspace/tab/pane (терминалы), процессы агентов, подписки;
- **client** — CLI/TUI (`herdr`), подключается к серверу.

Мы (релей herdr_relay) — **внешний потребитель**: не плагин и не агент, а отдельный процесс,
который подключается к серверу herdr как клиент и оркестрирует агентов в его панелях.
Вся интеграция происходит по одному Unix-сокету (см. раздел 3).

Архитектурно (см. `docs/01-architecture.md`) наш релей:

- запускает herdr и агентов в его панелях;
- получает живой статус агентов по socket-подпискам;
- управляет агентами: читает вывод, шлёт клавиши/подсказки, ждёт ответа;
- навешивает поверх мета-уровень: слоты/сессии/свой HTTP API (свой протокол поверх herdr).

Официальные источники: репозиторий `herdrdev/herdr`, доки `herdr.dev/docs/…` (socket-api,
cli-reference, plugins, agents, session-state, concepts, how-to-work), `herdr --skill`.

---

## 2. Три слоя доступа к herdr (и четвёртый — плагины)

| Слой | Что это | Когда используем | Статус у нас |
|---|---|---|---|
| **1. Agent skill** | Файлы-подсказки (`herdr --skill`), которые herdr инжектит в контекст агентов и объясняют, как работать с herdr | Агентам внутри панелей | Источник знаний, наш код не использует |
| **2. CLI-обёртки** | Библиотека `herdr-lib.sh` + команды `herdr api …` / `herdr agent …` | Простые одноразовые операции (snapshot, read, send-keys, prompt) | **Основной путь** для действий (см. раздел 8) |
| **3. Raw socket (JSON-RPC/NDJSON)** | Прямое соединение с Unix-сокетом сервера, запрос/ответ + поток событий | Длинные/живые вещи: подписки на события, ожидания | **Основной путь** для событий (socket_event_repository) |
| **4. Плагины** | Манифест + хуки/экшены, выполняемые сервером при событиях | Альтернатива/дополнение; у нас есть плагин-обёртка | Используем частично (см. раздел 7) |

**Правило выбора:** одноразовое действие → CLI-обёртка (просто и дешево).
Долгоживущий поток/событие/ожидание → raw socket. Сложная логика на стороне herdr
(хуки на события, экшены из UI) → плагин.

---

## 3. Транспорт и протокол

### 3.1 Сокеты

- **Дефолт:** `~/.config/herdr/herdr.sock`
- **Named session:** `~/.config/herdr/sessions/<name>/herdr.sock`

**Порядок разрешения сокета** (приоритет сверху вниз):

1. флаг CLI `--session <name>`;
2. env `HERDR_SOCKET_PATH` (путь к сокету напрямую);
3. env `HERDR_SESSION=<name>`;
4. дефолт `~/.config/herdr/herdr.sock`.

> ⚠ **Проверено живьём:** наша реализация (`cli_repository.go`) передаёт subprocess'у
> `HERDR_SOCKET=…`, но CLI **игнорирует эту переменную** и молча использует дефолтный сокет.
> Влияет только `HERDR_SOCKET_PATH`. Это потенциальный баг релея для named session
> (см. раздел 9, «грабли» №10).

Windows: вместо Unix-сокета — named pipe. У нас macOS/Linux, дальше по Unix.

### 3.2 Формат сообщений

Поверх сокета — **newline-delimited JSON** (NDJSON): каждый кадр — одна JSON-строка,
разделитель `\n`. Клиент читает сокет построчно.

**Запрос** (обязательные поля: `id` — строка, `method`, `params`):

```json
{"id":"req_1","method":"ping","params":{}}
```

- `id` **обязателен и является строкой** (в request base schema: `required:["id"]`,
  `id.type=string`).
- Поля `jsonrpc` в схеме **нет вообще**. Наш клиент шлёт `"jsonrpc":"2.0"` — лишнее поле,
  сервер его игнорирует, безвредно. Новый код может не слать.

**Ответ успеха** — `result` дискриминируется полем `type` (всего 57 вариантов, см. 4.2):

```json
{"id":"req_1","result":{"type":"pong"}}
```

**Ответ ошибки** (поля `code`, `message`):

```json
{
  "id":"req_1",
  "error":{"code":"not_found","message":"no pane with id p01"}
}
```

Типичные коды ошибок: `not_found`, `invalid_params`, `server_not_running`,
`agent_blocked` (см. грабли №11), `timeout`.

**Событие-нотификация** (без `id`):

```json
{"event":"pane_updated","data":{"pane":{...}}}
```

### 3.3 Версионирование и стабильность

- **protocol: 19**, **schema_version: 1** (0.8.0). Поле `protocol` присутствует в
  `SessionSnapshot` и используется при live-handoff.
- Неизвестные поля в ответах **игнорировать** (схема расширяется аддитивно).
- Схему можно экспортировать: `herdr api schema` (краткая справка), `herdr api schema --json`
  (полный JSON), `herdr api schema --output PATH`.
- Статус соединения: `herdr status` / метод `ping`.

Пример экспорта схемы (для регенерации этого справочника, раздел 10):

```bash
herdr api schema --json --output /tmp/herdr-schema.json
```

---

## 4. RPC-методы (реестр — 90 методов)

Все методы — запрос/ответ за одним `id`; `params` — объект (пустой `{}` для
`EmptyParams`; поля, помеченные `*` в схеме, обязательны).

### 4.1 Таблица методов по группам

**Server / общее**

| Метод | Параметры (тип) | Назначение |
|---|---|---|
| `ping` | `PingParams` | Проверка живости/контракта |
| `server.stop` | `EmptyParams` | Остановить сервер |
| `server.live_handoff` | `expected_protocol?, expected_version?, import_exe?` | Передача живого состояния между процессами сервера |
| `server.reload_config` | `EmptyParams` | Перезагрузить конфиг |
| `server.agent_manifests` | `EmptyParams` | Список манифестов агентов |
| `server.reload_agent_manifests` | `EmptyParams` | Перечитать манифесты агентов |

**Уведомления / клиент**

| Метод | Параметры (тип) | Назначение |
|---|---|---|
| `notification.show` | `title*`, `body?`, `position?` (enum top-left/top-right/bottom-left/bottom-right), `sound?` (none/done/request) | Системное уведомление (тост) на клиенте |
| `client.window_title.set` | `title*` | Заголовок окна клиента |
| `client.window_title.clear` | `EmptyParams` | Сбросить заголовок окна |

**Сессия**

| Метод | Параметры (тип) | Назначение |
|---|---|---|
| `session.snapshot` | `EmptyParams` | Полный снапшот состояния (bootstrap, см. 6.1) |

**Workspace** (в нашем релее ≈ «слот»/сессия агента)

| Метод | Параметры (тип) | Назначение |
|---|---|---|
| `workspace.create` | `cwd?, env?, focus?, label?` | Создать workspace |
| `workspace.list` | `EmptyParams` | Перечислить |
| `workspace.get` | `workspace_id*` | Получить по id |
| `workspace.focus` | `workspace_id*` | Сфокусировать |
| `workspace.rename` | — | Переименовать |
| `workspace.move` | — | Переместить в списке |
| `workspace.move_block` | — | Переместить блок workspace |
| `workspace.report_metadata` | `workspace_id*`, `source*`, `tokens*` (+map), `ttl_ms`, `seq` | Отчёт агента о метаданных (токены) |
| `workspace.close` | `workspace_id*` | Закрыть |

**Worktree** (git-worktree интеграция)

| Метод | Параметры (тип) | Назначение |
|---|---|---|
| `worktree.list` | `cwd?, workspace_id?` | Список worktree |
| `worktree.create` | `base?, branch?, cwd?, focus?, label?, path?, workspace_id?` | Создать worktree + workspace |
| `worktree.open` | `branch?, cwd?, focus?, label?, path?, workspace_id?` | Открыть существующий в workspace |
| `worktree.remove` | `workspace_id*`, `force?` | Удалить worktree (+workspace) |

**Tab**

| Метод | Параметры (тип) | Назначение |
|---|---|---|
| `tab.create` | `cwd?, env?, focus?, label?, workspace_id?` | Создать tab в workspace |
| `tab.list` | `workspace_id?` | Список |
| `tab.get` | `TabTarget` | По id |
| `tab.focus` | `TabTarget` | Сфокусировать |
| `tab.rename` | — | Переименовать |
| `tab.move` | — | Переместить |
| `tab.close` | `TabTarget` | Закрыть |

**Agent** (в нашем релее — целевой объект: агенты живут в pane)

| Метод | Параметры (тип) | Назначение |
|---|---|---|
| `agent.list` | `EmptyParams` | Список агентов |
| `agent.get` | `target*` | Инфо по агенту |
| `agent.read` | `target*`, `source*`, `lines?, format?, strip_ansi?` | Прочитать вывод агента |
| `agent.explain` | `target*` | Объяснить состояние агента |
| `agent.send_keys` | `target*`, `keys*`:[string] | Отправить нажатия клавиш |
| `agent.rename` | `target*`, `name?` | Переименовать |
| `agent.view.set` | `source*`, `label?, filter?, sort?` | Настроить «вид» агента (список в UI) |
| `agent.view.clear` | `source?` | Сбросить вид |
| `agent.focus` | `target*` | Сфокусировать |
| `agent.start` | `name*`, `kind*`, `pane_id*`, `args?`, `timeout_ms?` | Запустить агента в pane |
| `agent.prompt` | `target*`, `text*`, `wait?` | Отправить промпт (с опциональным ожиданием статуса) |
| `agent.wait` | `target*`, `until?:[AgentStatus]`, `timeout_ms?` | Дождаться статуса |

**Pane** (терминальная панель; в нашем релее pane — «раннер»)

| Метод | Параметры (тип) | Назначение |
|---|---|---|
| `pane.split` | `cwd?, direction*` (right/down), `env?, focus?, ratio?, target_pane_id?, workspace_id?` | Разделить pane |
| `pane.swap` | `direction?, pane_id?, source_pane_id?, target_pane_id?` | Поменять местами |
| `pane.move` | `pane_id*`, `destination*` (tab/new_tab/new_workspace), `focus?` | Переместить pane |
| `pane.zoom` | `mode?` (toggle/on/off), `pane_id?` | Зум панели |
| `pane.layout` | `pane_id?` | Текущий layout pane |
| `pane.process_info` | `pane_id?` | Инфо о процессе в pane |
| `pane.neighbor` | `direction*` (left/right/up/down), `pane_id?` | Соседний pane |
| `pane.edges` | `pane_id?` | Границы pane |
| `pane.focus_direction` | `direction*`, `pane_id?` | Фокус в направлении |
| `pane.resize` | `direction*`, `amount?:float`, `pane_id?` | Изменить размер |
| `pane.list` | `workspace_id?` | Список panes |
| `pane.current` | `caller_pane_id?` | Текущий (сфокусированный) pane |
| `pane.get` | `pane_id*` | Инфо по pane |
| `pane.focus` | `pane_id*` | Сфокусировать |
| `pane.rename` | `pane_id*`, `label?` | Переименовать |
| `pane.send_text` | `pane_id*`, `text*` | Вставить текст как input, не Enter |
| `pane.send_keys` | `pane_id*`, `keys*`:[string] | Нажатия клавиш |
| `pane.send_input` | `pane_id*`, `text` (строка!), `keys?` | Комбинированный input |
| `pane.read` | `pane_id*`, `source*`, `lines?, format?, strip_ansi?` | Прочитать вывод (основа `agent.read`) |
| `pane.graphics.set` | `pane_id*`, `format*` (png/rgb/rgba), `image_width*`, `image_height*`, `data_base64*`, `placement?` | Показать картинку в терминале (kitty/OSC) |
| `pane.graphics.clear` | `pane_id*` | Убрать картинку |
| `pane.graphics.info` | `pane_id*` | Инфо о graphics |
| `pane.report_agent` | `pane_id*`, `source*`, `agent*`, `state*` (idle/working/blocked/unknown), `message?, agent_session_id?, agent_session_path?, seq?` | Агент сообщает о своём состоянии |
| `pane.report_agent_session` | `pane_id*`, `source*`, `agent*`, `agent_session_id?, agent_session_path?, session_start_source?, seq?` | Сообщить о сессии агента |
| `pane.report_metadata` | `pane_id*`, `source*`, `agent?, display_agent?, title?, state_labels?(+string), tokens?(+string), clear_*, applies_to_source?, ttl_ms? (1..86400000), seq?` | Метаданные pane (токены, статус-лейблы) |
| `pane.clear_agent_authority` | `pane_id*`, `source?, seq?` | Снять привязку агента |
| `pane.release_agent` | `pane_id*`, `source*`, `agent*`, `seq?` | Открепить агента |
| `pane.close` | `pane_id*` | Закрыть pane |
| `pane.wait_for_output` | `pane_id*`, `match*` (OutputMatch: substring/regex), `source*, lines?, strip_ansi?, timeout_ms?` | **Блокирующее ожидание** совпадения в выводе |

**Popup / Layout**

| Метод | Параметры (тип) | Назначение |
|---|---|---|
| `popup.close` | `EmptyParams` | Закрыть всплывающий popup |
| `layout.export` | `pane_id?, tab_id?` | Экспорт layout (дерево) |
| `layout.apply` | `root*` (LayoutNode), `workspace_id?, tab_id?, tab_label?, focus?` | Применить layout (дерево pane/split) |
| `layout.set_split_ratio` | `tab_id?, pane_id?, path*:[bool], ratio*` | Установить пропорцию сплита по пути в дереве |

**Events**

| Метод | Параметры (тип) | Назначение |
|---|---|---|
| `events.subscribe` | `subscriptions*`:[Subscription] | Подписка на поток событий (см. 5) |
| `events.wait` | `match_event*` (EventMatch), `timeout_ms?` | Одноразовое блокирующее ожидание события |

**Интеграции / Плагины**

| Метод | Параметры (тип) | Назначение |
|---|---|---|
| `integration.install` | `target*` (enum: pi,omp,claude,codex,copilot,devin,droid,**kimi**,opencode,kilo,hermes,qodercli,cursor,mastracode,antigravity_cli,grok) | Установить интеграцию для CLI-агента |
| `integration.uninstall` | `target*` (тот же enum) | Удалить интеграцию |
| `plugin.link` | `path*`, `enabled?, source?` | Подключить плагин |
| `plugin.list` | `plugin_id?` | Список плагинов |
| `plugin.unlink` | — | Отключить плагин |
| `plugin.enable` / `plugin.disable` | `plugin_id*` | Вкл/выкл плагин |
| `plugin.action.list` | `plugin_id?` | Список экшенов |
| `plugin.action.invoke` | `action_id*`, `plugin_id?, context?` (PluginInvocationContext) | Вызвать экшен плагина |
| `plugin.log.list` | `plugin_id?, limit?` | Логи плагина |
| `plugin.pane.open` | `plugin_id*`, `entrypoint*`, `placement?` (overlay/popup/split/tab/zoomed), `target_pane_id?, workspace_id?, cwd?, env?, focus?, direction?, width?/height?` | Открыть панель-UI плагина |
| `plugin.pane.focus` | `pane_id*` | Сфокусировать панель плагина |
| `plugin.pane.close` | `pane_id*` | Закрыть панель плагина |

### 4.2 Возможные значения `result.type` (57 kind'ов)

`pong`, `session_snapshot`, `workspace_info`, `workspace_created`, `workspace_list`,
`worktree_list`, `worktree_created`, `worktree_opened`, `worktree_removed`, `tab_info`,
`tab_created`, `tab_list`, `agent_info`, `agent_started`, `agent_prompted`, `agent_list`,
`agent_view`, `pane_info`, `pane_list`, `pane_current`, `pane_swap`, `pane_move`,
`pane_zoom`, `pane_layout`, `pane_process_info`, `layout_export`, `layout_apply`,
`layout_split_ratio_set`, `pane_neighbor`, `pane_edges`, `pane_focus_direction`,
`pane_resize`, `pane_read`, `pane_graphics_info`, `agent_explain`, `subscription_started`,
`wait_matched`, `output_matched`, `notification_show`, `client_window_title`,
`integration_install`, `integration_uninstall`, `agent_manifest_reload`,
`agent_manifest_status`, `plugin_linked`, `plugin_list`, `plugin_unlinked`,
`plugin_enabled`, `plugin_disabled`, `plugin_action_list`, `plugin_action_invoked`,
`plugin_log_list`, `plugin_pane_opened`, `plugin_pane_focused`, `plugin_pane_closed`,
`config_reload`, `ok`.

Безрезультатные/простые методы (send_keys, send_text, move, focus, resize, close и т.п.)
возвращают `{"type":"ok"}`; профильные методы — свой kind (например `pane.read` →
`pane_read`, `events.wait` → `wait_matched`, `pane.wait_for_output` → `output_matched`,
`events.subscribe` → `subscription_started`, `session.snapshot` → `session_snapshot`).

---

## 5. События

### 5.1 Два механизма

| Механизм | Запрос | Поведение |
|---|---|---|
| **Потоковая подписка** | `events.subscribe` с `subscriptions:[…]` | Сервер шлёт нотификации всё время, пока соединение живо |
| **Одноразовое ожидание** | `events.wait` (EventMatch) | Блокирует запрос до совпадения или `timeout_ms`; удобно для коротких «дождаться статуса» |
| **Ожидание вывода** | `pane.wait_for_output` (match: substring/regex) | Специализированное ожидание совпадения в выводе pane; не требует подписки вообще |

### 5.2 Типы подписок (`Subscription`, 25 вариантов)

Без дополнительных полей (22):

`workspace.created`, `workspace.updated`, `workspace.metadata_updated`,
`workspace.renamed`, `workspace.moved`, `workspace.reordered`, `workspace.closed`,
`workspace.focused`, `worktree.created`, `worktree.opened`, `worktree.removed`,
`tab.created`, `tab.closed`, `tab.focused`, `tab.renamed`, `tab.moved`, `pane.created`,
`pane.closed`, `pane.updated`, `pane.focused`, `pane.moved`, `pane.exited`,
`pane.agent_detected`, `layout.updated`.

С полями (3, scoped на pane):

| Подписка | Поля | Что приходит |
|---|---|---|
| `pane.output_matched` | `pane_id*`, `match*` (OutputMatch), `source*`, `lines?, strip_ansi?` | Совпадение в выводе pane |
| `pane.agent_status_changed` | `pane_id*`, `agent_status?:AgentStatus\|null` | Смена статуса агента в pane |
| `pane.scroll_changed` | `pane_id*` | Скролл/вывод pane изменился |

Обратите внимание: **в подписках (`events.subscribe`) имена событий пишутся с точками**
(`pane.updated`), а **в нотификациях на проводе** lifecycle-события приходят с подчёркиванием
(`pane_updated`), см. 5.3. Три «scoped» подписки на проводе тоже приходят с точкой
(`pane.scroll_changed`).

### 5.3 Формат нотификаций на проводе

**Lifecycle-событие** (проверено живьём; схема `EventEnvelope` = `{data, event}`,
`EventKind` — enum с подчёркиваниями):

```json
{"event":"pane_updated","data":{"pane":{...PaneInfo}}}
```

**Scoped-подписка** (схема `SubscriptionEventKind`, точки):

```json
{"event":"pane.scroll_changed","data":{"pane_id":"p01","scroll":{"offset_from_bottom":0,"max_offset_from_bottom":100,"viewport_rows":24},"workspace_id":"w01"}}
```

```json
{"event":"pane.agent_status_changed","data":{"pane_id":"p01","agent":"claude","agent_status":"working","title":null,"display_agent":null,"state_labels":[],"workspace_id":"w01"}}
```

```json
{"event":"pane.output_matched","data":{"pane_id":"p01","matched_line":"...","read":{...PaneReadResult}}}
```

> ⚠ На приёме надо нормализовывать оба написания имён событий (`pane.updated` ⇄ `pane_updated`):
> на разных версиях/каналах возможны оба. Наш обработчик принимает оба, см. грабли №4.

### 5.4 Полный список EventKind (26, enum из схемы)

`workspace_created`, `workspace_updated`, `workspace_metadata_updated`, `workspace_closed`,
`workspace_renamed`, `workspace_moved`, `workspace_reordered`, `workspace_focused`,
`worktree_created`, `worktree_opened`, `worktree_removed`, `tab_created`, `tab_closed`,
`tab_renamed`, `tab_moved`, `tab_focused`, `pane_created`, `pane_closed`, `pane_updated`,
`pane_focused`, `pane_moved`, `pane_output_changed`, `pane_exited`, `pane_agent_detected`,
`pane_agent_status_changed`, `layout_updated`.

**Semantics ключевых для нашего релея:**

- `pane_updated` — состояние pane изменилось (в `data.pane` полный `PaneInfo`); эмитится
  и для уже существующих panes в момент подписки (используем для «первого снапшота» панели).
- `pane_output_changed` — изменился вывод/ревизия pane (удобно ждать через `events.wait`
  с `min_revision`).
- `pane_agent_status_changed` — смена `agent_status` (в es6 формате приходит и из хуков,
  см. раздел 7 и грабли №1).
- `pane_exited` — процесс в панели завершился.
- `pane_moved` — pane переехал между workspace/tab (id pane **меняется** при
  cross-workspace move — грабли №7).

### 5.5 SubscriptionEventKind (3)

`pane.output_matched`, `pane.agent_status_changed`, `pane.scroll_changed` — те же, что
scoped-подписки в 5.2; это нотификации, которые сервер шлёт в ответ на такие подписки.

---

## 6. Данные и состояния

### 6.1 `SessionSnapshot` — bootstrap-снапшот

Возвращает `session.snapshot`; CLI-обёртка `herdr api snapshot` печатает JSON напрямую
(наш релей парсит `{"result":{"snapshot":...}}`). Это **не подписка** — после переподключения
снапшот нужно перечитывать заново.

```json
{
  "protocol": 19,
  "version": "0.8.0",
  "focused_workspace_id": "w01",
  "focused_tab_id": "t01",
  "focused_pane_id": "p01",
  "workspaces": [ {...WorkspaceInfo}, ... ],
  "tabs": [ {...TabInfo}, ... ],
  "panes": [ {...PaneInfo}, ... ],
  "layouts": [ {...PaneLayoutSnapshot}, ... ],
  "agents": [ {...AgentInfo}, ... ]
}
```

`focused_*` — nullable (может быть `null`, если ничего не сфокусировано).

**Structure:**

- **WorkspaceInfo:** `workspace_id*`, `label*`, `number*`, `active_tab_id*`, `tab_count*`,
  `pane_count*`, `focused*`, `agent_status*`, `tokens?(+string)`,
  `worktree ?: WorkspaceWorktreeInfo | null`
  (`repo_key*`, `repo_name*`, `repo_root*`, `checkout_path*`, `is_linked_worktree*`).
- **TabInfo:** `tab_id*`, `workspace_id*`, `label*`, `number*`, `pane_count*`, `focused*`,
  `agent_status*`.
- **PaneInfo:** `pane_id*`, `terminal_id*`, `workspace_id*`, `tab_id*`, `focused*`,
  `revision*` (int; растёт при изменении вывода), `agent_status*`,
  `agent?:string|null`, `display_agent?`, `agent_session?:AgentSessionInfo|null`
  (`source*`, `agent*`, `kind*` (id|path), `value*`), `label?`, `cwd?`, `foreground_cwd?`,
  `title?`, `terminal_title?`, `terminal_title_stripped?`,
  `scroll?:PaneScrollInfo|null`, `tokens?(+string)`, `state_labels?(+string)`.
- **AgentInfo:** = PaneInfo без `label`, плюс `name?`, `interactive_ready`,
  `launch_pending`, `screen_detection_skipped`, `state_change_seq`.
- **PaneLayoutSnapshot:** `workspace_id*`, `tab_id*`, `zoomed*`, `focused_pane_id*`,
  `area*` (Rect x/y/width/height), `panes*:[{pane_id, focused, rect}]`,
  `splits*:[{id, direction (right|down), ratio, rect}]`.
- **LayoutDescription** (`layout.export`): дерево
  `root: LayoutNode` = oneOf `{type:"pane", pane_id?, label?, cwd?, command?[string], env?}`
  | `{type:"split", direction(right|down), ratio, first, second}`.

### 6.2 `AgentStatus` — семантика статусов

`enum: idle, working, blocked, done, unknown`.

| Статус | Значение |
|---|---|
| `idle` | Агент готов; «ready» — после того как его таб показан в UI |
| `working` | Агент активно работает |
| `blocked` | Агент ждёт пользователя: approval/вопрос/диалог в UI |
| `done` | Агент закончил подписку/фоновую работу; приходит как «idle» после того, как результат увидят |
| `unknown` | Не классифицирован |

Нюанс для ожиданий (`agent.wait` / `agent.prompt` с `wait`): `until:[AgentStatus]` —
массив статусов, которых ждём; `timeout_ms` ограничивает ожидание.

### 6.3 Чтение вывода

**`source`** (ReadSource): `visible` (что на экране), `recent` (последние строки),
`recent_unwrapped`, `detection`.

**`format`** (ReadFormat): `text` (экранирование убрано, дефолт), `ansi` (raw/с ANSI).

**`strip_ansi`**: дополнительно убрать ANSI-последовательности из `text`.

**`PaneReadResult`:**

```json
{
  "pane_id":"p01","tab_id":"t01","workspace_id":"w01",
  "source":"visible","format":"text","revision":42,
  "text":"...","truncated":false
}
```

**Scroll-метрики** (`PaneScrollInfo`): `offset_from_bottom*`, `max_offset_from_bottom*`,
`viewport_rows*`; `offset_from_bottom == 0` — вывод у дна (агент в конце вывода).

**Разрешение target** (`agent.*`): target — это имя агента **или** `pane_id`; имя агента
не уникально (один агент может вести несколько панелей) — для точности таргетиться по
`pane_id` (грабли №6).

---

## 7. Плагины

Плагин — директория с `herdr-plugin.toml` (манифест) + скрипты-хуки. Сервер herdr
исполняет их при событиях; наш `plugin/` — обёртка поверх протокола для хуков релея
(см. `plugin/README.md`, `plugin/herdr-plugin.toml`).

### 7.1 Манифест

Обязательные поля: `id` (ASCII: буквы/цифры/`.`/`:`/`_`/`-`), `name`, `version`,
`min_herdr_version`. Без `min_herdr_version` или с слишком новой — линковка отклоняется.

Опционально: `description`, `platforms = ["linux","macos","windows"]`.

Секции: `[[build]]`, `[[startup]]`, `[[actions]] {id, title, contexts, command}`,
`[[events]] {on, command}` (on проверяется при линковке: неизвестное имя → warning,
см. грабли №1), `[[panes]] {id, title, placement, command}`,
`[[link_handlers]] {id, title, pattern, action}`.

Action id квалифицируется как `<plugin_id>.<action_id>`.

**Placement панелей:** `overlay` (дефолт; zoomed-оверлей, после закрытия возвращает фокус),
`popup` (singleton, **без** pane_id, не получает события), `split`/`tab`/`zoomed` —
обычные panes.

### 7.2 Переменные окружения (env), которые herdr инжектит в команды

**Всем runtime-командам:**

| Переменная | Назначение |
|---|---|
| `HERDR_SOCKET_PATH` | Путь к сокету (для API) |
| `HERDR_BIN_PATH` | Путь к бинарю herdr |
| `HERDR_ENV=1` | Маркер: запущено внутри herdr |
| `HERDR_PLUGIN_ID` | id плагина |
| `HERDR_PLUGIN_ROOT` | Корень плагина |
| `HERDR_PLUGIN_CONFIG_DIR` | Конфигурационная директория |
| `HERDR_PLUGIN_STATE_DIR` | Директория состояния плагина |
| `HERDR_PLUGIN_CONTEXT_JSON` | JSON-контекст вызова (инвоукции) |
| `HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`, `HERDR_PANE_ID` | Доступны, если применимо (контекстный таргет) |

**Дополнительно по типу команды:**

| Команда | Доп. переменные |
|---|---|
| Action | `HERDR_PLUGIN_ACTION_ID` |
| Startup-хук | `HERDR_PLUGIN_EVENT` (у startup = `"startup"`) |
| Event-хук | + `HERDR_PLUGIN_EVENT` (имя события), `HERDR_PLUGIN_EVENT_JSON` — JSON переданного события, у нас формат `{"data":{...}}` |
| Pane-команда | `HERDR_PLUGIN_ENTRYPOINT_ID` |
| Link handler | `HERDR_PLUGIN_CLICKED_URL`, `HERDR_PLUGIN_LINK_HANDLER_ID` (в `CONTEXT_JSON` `invocation_source="link_click"`) |

Кроме того, манифест-панели инжектят в pane-процессы: `HERDR_SOCKET_PATH`, `HERDR_ENV=1`,
`HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`, `HERDR_PANE_ID` (при конфликте авторитетны значения
от манифеста).

---

## 8. Как наш релей использует herdr (карта «фича → механизм»)

| Фича релея | Механизм herdr | Где в коде |
|---|---|---|
| Стартовый снапшот сессии | `herdr api snapshot` → `{"result":{"snapshot":…}}` | `internal/infrastructure/herdr/cli_repository.go` → `Snapshot()` |
| Чтение вывода агента | `agent read <target> --lines N --format <text\|ansi>` | там же → `ReadOutput(target, lines, format)` |
| Отправка клавиш | `agent send-keys <target> <key...>` | там же → `SendKeys(target, keys)` |
| Отправка промпта | `agent prompt <target> <text>` | там же → `SendPrompt(target, text)` |
| Живой статус/вывод агентов | socket: `events.subscribe` (`pane.updated` глобально + per-pane `pane.scroll_changed`, `pane.agent_status_changed`) → нотификации | `internal/infrastructure/herdr/socket_event_repository.go` |
| Ремап в наш протокол | `pane.scroll_changed` → клиентское событие `pane.output_changed` (c revision из `pane.updated`, строго растущим) | там же, emit с таймаутом 5s |

Про подключение и цикл жизни socket-репозитория (проверено живьём, 0.8.0):

1. `net.Dial("unix", <socket>)`; reconnect с backoff 2s → ×2 → max 30s.
2. Один `events.subscribe` с полным набором подписок; **повторный `events.subscribe`
   на живом соединении роняет его** (сервер закрывает), подписки кумулятивны —
   поэтому: один subscribe + reconnect при необходимости.
3. При `pane_updated`/`pane.updated`: достать `pane_id` (data бывает плоская
   `{"pane_id":…}` или вложенная `{"pane":{…}}`), нормализовать имя события,
   новый pane → запомнить и переподключиться (получить актуальный набор pane).
4. Кадры с пустым `event` (response `subscription_started`, keepalive) — пропускать.

---

## 9. Грабли (проверенные нюансы 0.8.0)

1. **Хуки/плагин не дают событий вывода** (`pane.updated`, `pane.output_changed`,
   `pane.scroll_changed` линковщик отвергает как unknown event для `[[events]]`).
   Живой вывод — только через socket-подписку.
2. **`id` запроса — строка.** Числовой id может не пройти валидацию схемы.
3. **Пропускать служебные кадры** без `event` (ответы на subscribe, keepalive).
4. **Второй `events.subscribe` на живом соединении роняет его** → один subscribe
   на соединение, полный набор, reconnect при смене набора panes. Подписки кумулятивны.
5. **`pane.scroll_changed` не несёт `revision`** → дебаунс на клиенте, если нужен
   «последний» вывод.
6. **Имя агента не уникально** → таргетиться по `pane_id`.
7. **`pane_id` меняется при cross-workspace move** (событие `pane.moved`); herdr не
   эмитит фейковых close/create — подписываться на `pane.moved` и обновлять маппинг.
8. **`pane.updated` не эмитится при spinner-only изменениях заголовка**, когда
   `terminal_title_stripped` не меняется; следить за `revision`/состоянием панели целиком.
9. **Doc/schema drift:** в socket-api доке есть `pane.graphics.stream` и `pane.input.set` —
   в схеме 0.8.0 их **нет** (только `pane.graphics.set/clear/info` и `pane.send_input`).
   Сверяться со схемой, а не с докой.
10. **`HERDR_SOCKET` игнорируется CLI; работает только `HERDR_SOCKET_PATH`**
    (проверено живьём, `HERDR_SOCKET=/nonexistent/foo.sock herdr api snapshot` вернул
    снапшот с дефолтного сокета; с `HERDR_SOCKET_PATH` → `server_not_running`).
    Исправлено: `cli_repository.go` шлёт `HERDR_SOCKET_PATH`, named-session работает.
11. **`agent.prompt` с `wait` при уже заблокированном агенте** возвращает
    `agent_blocked`, не отправляя ввод. Проверять статус перед промптом или обрабатывать
    ошибку.
12. Output-события (`pane.updated`/`pane.scroll_changed`) наблюдались при живом клиенте;
    гарантия эмиссии без подключённого клиента **не проверялась** — не полагаться без теста.
13. **Подписка на мёртвый `pane_id` → JSON-RPC error `pane_not_found` и закрытие
    соединения.** Происходит, когда пэйн/таб закрыт, а id остался в подписках (в т.ч.
    из-за №7). Раньше relay игнорировал error-кадр, видел «чистый EOF» и переподключался
    с тем же мёртвым id — вечный reconnect-цикл раз в секунду и неконтролируемый рост
    `relay.err.log`. Теперь error-кадр разбирается, мёртвый pane удаляется из набора
    подписок, и соединение перезапускается без него (см. `socket_event_repository.go`).

---

## 10. Версии, регенерация справочника, ссылки

**Проверенная конфигурация:** herdr **0.8.0** (channel `stable`), **protocol 19**,
**schema_version 1** (бинарь `relay`/системный `herdr`).

Схема живёт внутри бинаря и регенерируется одной командой:

```bash
herdr api schema --json --output /tmp/herdr-schema.json   # полная схема
herdr api schema                                          # краткая справка по API
herdr status                                              # протокол/версия/сокет
herdr --skill                                             # инструкции для агентов
```

Структура экспортированного JSON (`/tmp/herdr-schema.json`):

- верх: `{title:"Herdr API", protocol:19, schema_version:1,
  schemas:{error_response, event, request, subscription_event, success_response}}`;
- `$defs`: request (~105 типов — параметры), success_response (~67 — ответы/данные),
  event (16), subscription_event (10), error_response (1).

**Ссылки:**

- https://herdr.dev/docs/socket-api/ — JSON-RPC поверх сокета (внимание: drift, см. №9)
- https://herdr.dev/docs/cli-reference/ — CLI-команды
- https://herdr.dev/docs/plugins/ — манифест, хуки, env
- https://herdr.dev/docs/agents/ — агенты и их lifecycle/статусы
- https://herdr.dev/docs/session-state/ — снапшоты/состояние сессии
- https://herdr.dev/docs/concepts/ , https://herdr.dev/docs/how-to-work/
- Репозиторий: https://github.com/herdrdev/herdr