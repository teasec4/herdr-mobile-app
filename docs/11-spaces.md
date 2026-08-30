# 11 — Spaces (workspaces): доступ к пространствам и запуск агентов с телефона

> Статус: **Фазы A–C реализованы** (сервер + клиент, 155 тестов) · Связано: [10 — herdr API](10-herdr-api.md),
> [05 — Flutter-приложение](05-flutter-app.md).

## 0. Согласованные решения (30.08)

1. **Главный экран** — нижняя навигация `Spaces | Agents | Run`:
   Spaces — список workspace'ов (главный), Agents — плоский список, Run — запуск.
2. **Показывать все panes** — и агенты, и пустые терминалы (доступ к терминалу).
3. **Запуск агента** — в первый свободный пустой pane выбранного workspace;
   создание pane (`pane.split`) — позже.
4. **Объём** — поэтапно: A. протокол (сервер) → живая проверка → B–C. UI.

## 1. Что есть сейчас (проверено живьём)

Клиент видит только **плоский список агентов** (`agents.snapshot`): это panes,
в которых herdr обнаружил агента. Всё остальное — workspace'ы, вкладки, «пустые»
терминалы — скрыто.

Живой снапшот herdr (`herdr api snapshot`) содержит полную иерархию:

```
workspaces (4): awake · pi · ai-chat-2 · herdr_relay(working)
  └─ tabs (4)
      └─ panes (6)
          ├─ wH:p8  agent=kimi  working   ← сейчас видно (агент)
          ├─ wH:pA  agent=kimi  working   ← сейчас видно (агент)
          └─ w7:p1  agent=None  unknown   ← «пустой» терминал (скрыт)
             wE:p2  agent=None  unknown   ← «пустой» терминал (скрыт)
             wF:p5  agent=None  unknown   ← «пустой» терминал (скрыт)
```

CLI, доступный релею (проверено):
- `herdr agent start <name> --kind <kind> --pane <id>` — kinds: pi, claude,
  codex, gemini, cursor, devin, agy, cline, omp, mastracode, opencode, copilot,
  kimi, kiro, droid, amp, grok, hermes, kilo, qodercli, maki;
- `herdr workspace create --label <text> --cwd <path>` — создать workspace;
- чтение/ввод любого pane: `agent read/keys/prompt` уже работают по `pane_id`
  (проверено: herdr принимает pane_id как target).

## 2. Целевой UX: три кита

1. **Spaces** — видеть всё пространство: список workspace'ов, внутри — panes
   (агенты со статусами + пустые терминалы). Иерархия «проект → терминалы».
2. **Терминал любого pane** — открыть pane (с агентом или без) и работать как
   с терминалом: вывод, ввод текста, клавиши. Это «доступ к терминалу»,
   который сейчас скрыт.
3. **Запуск агента с телефона** — wizard: выбрать kind (codex/kimi/…),
   workspace (существующий или создать), имя → `agent.start` → сразу открыть
   терминал pane.

## 3. Что добавить в релей (Go)

Протокол релея расширяется новыми методами `dispatch` (+ CLI-обёртки в
`cli_repository`), формат — тот же request/response-фрейм:

| Метод | Параметры | Возвращает | Реализация |
| --- | --- | --- | --- |
| `session.snapshot` | `{}` | `{workspaces:[…], panes:[…], agents:[…], focused_*}` | парсить полный `SessionSnapshot` (сейчас парсится только `agents`) |
| `agent.start` | `name, kind, pane_id` | `{ok}` | `herdr agent start <name> --kind <kind> --pane <id>` |
| `workspace.create` | `label?, cwd?` | `{workspace_id, label}` | `herdr workspace create …` |
| `pane.send_text` | `pane_id, text` | `{ok}` | `herdr agent send-keys` нет для текста → CLI `agent prompt`? для пустого pane — `pane.send_input` через socket (см. docs/10 §4) |

Доменные модели: `Workspace{id,label,agentStatus,tabs,panes}`,
`Pane{id,workspaceId,tabId,agent,agentStatus,cwd,title}`; клиентский
`RelayAgent` дополняется `workspaceId`/`tabId` (релей уже отдаёт эти поля,
клиент их не читал).

## 4. UI и мобильный флоу (предложение)

### 4.1 Навигация: нижние вкладки

```
┌─────────────────────────────┐
│  Spaces   Agents   +Run     │   ← нижняя навигация (заменяет flat-список)
└─────────────────────────────┘
```

- **Spaces** — главный экран: список workspace'ов (label, статус агрегата,
  число panes). Тап → экран workspace: panes (агенты со статус-чипами +
  пустые терминалы), тап по pane → терминал. Кнопка «+» → создать workspace.
- **Agents** — текущий плоский список (все агенты из всех spaces), для тех,
  кому привычнее. Сохраняет сортировку blocked-сверху.
- **Run** — wizard запуска агента (шаги): kind → workspace → имя → старт.
- **Connection** — остаётся в меню «⋮» (уже есть).

### 4.2 Терминал любого pane (расширение AgentPage)

`AgentPage` становится универсальным `PanePage`:
- pane с агентом: вывод + prompt + keys (как сейчас);
- пустой pane: вывод + `send_text` (ввод строки в терминал) + keys;
- шапка: `workspace/label · pane_id`, статус, меню «⋮» (запустить агента в
  этом pane, закрыть/переименовать, сменить cwd — по мере готовности сервера).

### 4.3 Флоу «запустил агента с телефона»

1. **Run** → выбрать kind (сетка иконок/список 20 kinds).
2. Выбрать workspace: список существующих или «создать новый» (label + cwd).
3. Имя агента (default: kind).
4. `agent.start` в первый свободный пустой pane workspace'а (или создать pane)
   → авто-переход в терминал pane.
5. Дальше как обычно: вывод, статусы, blocked → ответить.

## 5. Этапы внедрения

| Фаза | Содержание | Критерий |
| --- | --- | --- |
| **A. Протокол** | `session.snapshot` (полный), `agent.start`, `workspace.create`, `pane.send_text` в релее + CLI-обёртки + Go-тесты | ✅ `curl /api/rpc` отдаёт workspaces (проверено живьём) |
| **B. Модели и навигация** | `RelayWorkspace`/`RelayPane`, `session()`; нижние вкладки Spaces/Agents/Run; экран workspace | ✅ видно 4 workspace и все panes на телефоне |
| **C. Терминал pane** | `PanePage`-ввод (`send_text` для пустых), запуск агента из Run | ✅ ввод в пустой pane — `pane.send_text`; запуск из Run в свободный pane |
| **B. Модели и навигация** | `RelayWorkspace`/`RelayPane`, `RelayAgent.workspaceId`; нижние вкладки Spaces/Agents/Run; экран workspace | видно 4 workspace и все panes на телефоне |
| **C. Терминал pane** | `PanePage` (send_text для пустых), запуск агента из Run и из меню pane | с телефона запущен агент в новом/существующем workspace |
| **D. Полировка** | создание workspace в UI, ошибки/ретраи, события workspace.*, тесты | полный флоу без ноутбука |

## 6. Открытые вопросы (обсудить)

1. **Иерархия vs плоскость**: главный экран — Spaces (иерархия) или оставить
   плоский список агентов + отдельная вкладка Spaces? (предложение: Spaces
   главный, Agents — вкладка).
2. **Пустые терминалы**: показывать их в списке workspace сразу (терминалы
   как объекты) или только когда открываешь workspace? (предложение: показывать,
   это и есть «доступ к терминалу»).
3. **Запуск в pane vs новый**: `agent.start` требует существующий pane —
   запускать в первом свободном pane workspace'а, или добавить `pane.split`/
   создание pane? (предложение: свободный pane; split — позже).
4. **send_text для пустого pane**: проверить CLI/socket-путь
   (`pane.send_input`/`pane.send_text` из docs/10 §4) — если CLI не умеет,
   сделать через socket.
