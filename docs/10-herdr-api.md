# 10 — Complete herdr API reference (for developers)

> Document purpose: a single reference on the **herdr** API for developers of our relay —
> what herdr provides, what we can get from it, what we pass to it, and how it all connects and works.
> This is a "reference document": consult it as needed, don't keep it in your head.
>
> Verified live against **herdr 0.8.0** (channel `stable`, protocol 19, schema_version 1).
> Everything marked "verified live" was reproduced on the real binary via
> `herdr api snapshot` / a raw-socket connection. The rest was captured from the schema via `herdr api schema --json`.

---

## 1. What herdr is and why we need it

**herdr** is a terminal multiplexer + agent runtime for AI agents (a screen/tmux analogue,
but with a "state machine" for agents). It consists of two parts:

- **server** — a daemon that holds workspace/tab/pane (terminals), agent processes, subscriptions;
- **client** — CLI/TUI (`herdr`) that connects to the server.

We (the herdr_relay relay) are an **external consumer**: neither a plugin nor an agent, but a separate process
that connects to the herdr server as a client and orchestrates agents inside its panes.
All integration happens over a single Unix socket (see section 3).

Architecturally (see `docs/01-architecture.md`) our relay:

- starts herdr and agents inside its panes;
- receives live agent status via socket subscriptions;
- manages agents: reads output, sends keys/prompts, waits for a response;
- layers a meta-level on top: slots/sessions/its own HTTP API (its own protocol over herdr).

Official sources: the `herdrdev/herdr` repository, docs at `herdr.dev/docs/…` (socket-api,
cli-reference, plugins, agents, session-state, concepts, how-to-work), `herdr --skill`.

---

## 2. Three layers of access to herdr (and a fourth — plugins)

| Layer | What it is | When we use it | Our status |
|---|---|---|---|
| **1. Agent skill** | Prompt files (`herdr --skill`) that herdr injects into agent context and that explain how to work with herdr | For agents inside panes | Source of knowledge; our code does not use it |
| **2. CLI wrappers** | The `herdr-lib.sh` library + `herdr api …` / `herdr agent …` commands | Simple one-shot operations (snapshot, read, send-keys, prompt) | **Primary path** for actions (see section 8) |
| **3. Raw socket (JSON-RPC/NDJSON)** | Direct connection to the server's Unix socket, request/response + event stream | Long-lived/live things: event subscriptions, waiting | **Primary path** for events (socket_event_repository) |
| **4. Plugins** | Manifest + hooks/actions executed by the server on events | Alternative/addition; we have a plugin wrapper | Used partially (see section 7) |

**Selection rule:** one-shot action → CLI wrapper (simple and cheap).
Long-lived stream/event/wait → raw socket. Complex logic on the herdr side
(event hooks, UI actions) → plugin.

---

## 3. Transport and protocol

### 3.1 Sockets

- **Default:** `~/.config/herdr/herdr.sock`
- **Named session:** `~/.config/herdr/sessions/<name>/herdr.sock`

**Socket resolution order** (priority top to bottom):

1. CLI flag `--session <name>`;
2. env `HERDR_SOCKET_PATH` (direct path to the socket);
3. env `HERDR_SESSION=<name>`;
4. default `~/.config/herdr/herdr.sock`.

> ⚠ **Verified live:** our implementation (`cli_repository.go`) passes
> `HERDR_SOCKET=…` to the subprocess, but the CLI **ignores this variable** and silently uses the default socket.
> Only `HERDR_SOCKET_PATH` has an effect. This is a potential relay bug for named sessions
> (see section 9, rake #10).

Windows: named pipe instead of a Unix socket. We're on macOS/Linux, so Unix from here on.

### 3.2 Message format

On top of the socket is **newline-delimited JSON** (NDJSON): each frame is one JSON line,
separator `\n`. The client reads the socket line by line.

**Request** (required fields: `id` — string, `method`, `params`):

```json
{"id":"req_1","method":"ping","params":{}}
```

- `id` **is required and must be a string** (in the request base schema: `required:["id"]`,
  `id.type=string`).
- There is **no `jsonrpc` field in the schema at all**. Our client sends `"jsonrpc":"2.0"` — an extra field,
  the server ignores it, harmless. New code may omit it.

**Success response** — `result` is discriminated by the `type` field (57 variants in total, see 4.2):

```json
{"id":"req_1","result":{"type":"pong"}}
```

**Error response** (fields `code`, `message`):

```json
{
  "id":"req_1",
  "error":{"code":"not_found","message":"no pane with id p01"}
}
```

Typical error codes: `not_found`, `invalid_params`, `server_not_running`,
`agent_blocked` (see rake #11), `timeout`.

**Event notification** (no `id`):

```json
{"event":"pane_updated","data":{"pane":{...}}}
```

### 3.3 Versioning and stability

- **protocol: 19**, **schema_version: 1** (0.8.0). The `protocol` field is present in
  `SessionSnapshot` and is used during live-handoff.
- Unknown fields in responses **must be ignored** (the schema grows additively).
- The schema can be exported: `herdr api schema` (brief summary), `herdr api schema --json`
  (full JSON), `herdr api schema --output PATH`.
- Connection status: `herdr status` / the `ping` method.

Example of schema export (for regenerating this reference, section 10):

```bash
herdr api schema --json --output /tmp/herdr-schema.json
```

---

## 4. RPC methods (registry — 90 methods)

All methods are request/response under a single `id`; `params` is an object (empty `{}` for
`EmptyParams`; fields marked `*` in the schema are required).

### 4.1 Method table by group

**Server / general**

| Method | Params (type) | Purpose |
|---|---|---|
| `ping` | `PingParams` | Liveness/contract check |
| `server.stop` | `EmptyParams` | Stop the server |
| `server.live_handoff` | `expected_protocol?, expected_version?, import_exe?` | Hand over live state between server processes |
| `server.reload_config` | `EmptyParams` | Reload config |
| `server.agent_manifests` | `EmptyParams` | List agent manifests |
| `server.reload_agent_manifests` | `EmptyParams` | Re-read agent manifests |

**Notifications / client**

| Method | Params (type) | Purpose |
|---|---|---|
| `notification.show` | `title*`, `body?`, `position?` (enum top-left/top-right/bottom-left/bottom-right), `sound?` (none/done/request) | System notification (toast) on the client |
| `client.window_title.set` | `title*` | Client window title |
| `client.window_title.clear` | `EmptyParams` | Clear the window title |

**Session**

| Method | Params (type) | Purpose |
|---|---|---|
| `session.snapshot` | `EmptyParams` | Full state snapshot (bootstrap, see 6.1) |

**Workspace** (in our relay ≈ "slot"/agent session)

| Method | Params (type) | Purpose |
|---|---|---|
| `workspace.create` | `cwd?, env?, focus?, label?` | Create a workspace |
| `workspace.list` | `EmptyParams` | List |
| `workspace.get` | `workspace_id*` | Get by id |
| `workspace.focus` | `workspace_id*` | Focus |
| `workspace.rename` | — | Rename |
| `workspace.move` | — | Move in the list |
| `workspace.move_block` | — | Move a workspace block |
| `workspace.report_metadata` | `workspace_id*`, `source*`, `tokens*` (+map), `ttl_ms`, `seq` | Agent metadata report (tokens) |
| `workspace.close` | `workspace_id*` | Close |

**Worktree** (git-worktree integration)

| Method | Params (type) | Purpose |
|---|---|---|
| `worktree.list` | `cwd?, workspace_id?` | List worktrees |
| `worktree.create` | `base?, branch?, cwd?, focus?, label?, path?, workspace_id?` | Create worktree + workspace |
| `worktree.open` | `branch?, cwd?, focus?, label?, path?, workspace_id?` | Open an existing one in a workspace |
| `worktree.remove` | `workspace_id*`, `force?` | Remove worktree (+workspace) |

**Tab**

| Method | Params (type) | Purpose |
|---|---|---|
| `tab.create` | `cwd?, env?, focus?, label?, workspace_id?` | Create a tab in a workspace |
| `tab.list` | `workspace_id?` | List |
| `tab.get` | `TabTarget` | By id |
| `tab.focus` | `TabTarget` | Focus |
| `tab.rename` | — | Rename |
| `tab.move` | — | Move |
| `tab.close` | `TabTarget` | Close |

**Agent** (in our relay — the target object: agents live in a pane)

| Method | Params (type) | Purpose |
|---|---|---|
| `agent.list` | `EmptyParams` | List agents |
| `agent.get` | `target*` | Agent info |
| `agent.read` | `target*`, `source*`, `lines?, format?, strip_ansi?` | Read agent output |
| `agent.explain` | `target*` | Explain agent state |
| `agent.send_keys` | `target*`, `keys*`:[string] | Send key presses |
| `agent.rename` | `target*`, `name?` | Rename |
| `agent.view.set` | `source*`, `label?, filter?, sort?` | Configure the agent "view" (list in the UI) |
| `agent.view.clear` | `source?` | Reset the view |
| `agent.focus` | `target*` | Focus |
| `agent.start` | `name*`, `kind*`, `pane_id*`, `args?`, `timeout_ms?` | Start an agent in a pane |
| `agent.prompt` | `target*`, `text*`, `wait?` | Send a prompt (with optional status waiting) |
| `agent.wait` | `target*`, `until?:[AgentStatus]`, `timeout_ms?` | Wait for a status |

**Pane** (terminal panel; in our relay a pane is a "runner")

| Method | Params (type) | Purpose |
|---|---|---|
| `pane.split` | `cwd?, direction*` (right/down), `env?, focus?, ratio?, target_pane_id?, workspace_id?` | Split a pane |
| `pane.swap` | `direction?, pane_id?, source_pane_id?, target_pane_id?` | Swap |
| `pane.move` | `pane_id*`, `destination*` (tab/new_tab/new_workspace), `focus?` | Move a pane |
| `pane.zoom` | `mode?` (toggle/on/off), `pane_id?` | Pane zoom |
| `pane.layout` | `pane_id?` | Current pane layout |
| `pane.process_info` | `pane_id?` | Info about the process in the pane |
| `pane.neighbor` | `direction*` (left/right/up/down), `pane_id?` | Neighboring pane |
| `pane.edges` | `pane_id?` | Pane edges |
| `pane.focus_direction` | `direction*`, `pane_id?` | Focus in a direction |
| `pane.resize` | `direction*`, `amount?:float`, `pane_id?` | Resize |
| `pane.list` | `workspace_id?` | List panes |
| `pane.current` | `caller_pane_id?` | Current (focused) pane |
| `pane.get` | `pane_id*` | Pane info |
| `pane.focus` | `pane_id*` | Focus |
| `pane.rename` | `pane_id*`, `label?` | Rename |
| `pane.send_text` | `pane_id*`, `text*` | Insert text as input, no Enter |
| `pane.send_keys` | `pane_id*`, `keys*`:[string] | Key presses |
| `pane.send_input` | `pane_id*`, `text` (string!), `keys?` | Combined input |
| `pane.read` | `pane_id*`, `source*`, `lines?, format?, strip_ansi?` | Read output (basis of `agent.read`) |
| `pane.graphics.set` | `pane_id*`, `format*` (png/rgb/rgba), `image_width*`, `image_height*`, `data_base64*`, `placement?` | Show an image in the terminal (kitty/OSC) |
| `pane.graphics.clear` | `pane_id*` | Remove the image |
| `pane.graphics.info` | `pane_id*` | Graphics info |
| `pane.report_agent` | `pane_id*`, `source*`, `agent*`, `state*` (idle/working/blocked/unknown), `message?, agent_session_id?, agent_session_path?, seq?` | Agent reports its state |
| `pane.report_agent_session` | `pane_id*`, `source*`, `agent*`, `agent_session_id?, agent_session_path?, session_start_source?, seq?` | Report an agent session |
| `pane.report_metadata` | `pane_id*`, `source*`, `agent?, display_agent?, title?, state_labels?(+string), tokens?(+string), clear_*, applies_to_source?, ttl_ms? (1..86400000), seq?` | Pane metadata (tokens, status labels) |
| `pane.clear_agent_authority` | `pane_id*`, `source?, seq?` | Clear agent binding |
| `pane.release_agent` | `pane_id*`, `source*`, `agent*`, `seq?` | Detach an agent |
| `pane.close` | `pane_id*` | Close the pane |
| `pane.wait_for_output` | `pane_id*`, `match*` (OutputMatch: substring/regex), `source*, lines?, strip_ansi?, timeout_ms?` | **Blocking wait** for a match in the output |

**Popup / Layout**

| Method | Params (type) | Purpose |
|---|---|---|
| `popup.close` | `EmptyParams` | Close the popup |
| `layout.export` | `pane_id?, tab_id?` | Export layout (tree) |
| `layout.apply` | `root*` (LayoutNode), `workspace_id?, tab_id?, tab_label?, focus?` | Apply layout (pane/split tree) |
| `layout.set_split_ratio` | `tab_id?, pane_id?, path*:[bool], ratio*` | Set split ratio by path in the tree |

**Events**

| Method | Params (type) | Purpose |
|---|---|---|
| `events.subscribe` | `subscriptions*`:[Subscription] | Subscribe to the event stream (see 5) |
| `events.wait` | `match_event*` (EventMatch), `timeout_ms?` | One-shot blocking event wait |

**Integrations / Plugins**

| Method | Params (type) | Purpose |
|---|---|---|
| `integration.install` | `target*` (enum: pi,omp,claude,codex,copilot,devin,droid,**kimi**,opencode,kilo,hermes,qodercli,cursor,mastracode,antigravity_cli,grok) | Install an integration for a CLI agent |
| `integration.uninstall` | `target*` (same enum) | Remove an integration |
| `plugin.link` | `path*`, `enabled?, source?` | Link a plugin |
| `plugin.list` | `plugin_id?` | List plugins |
| `plugin.unlink` | — | Unlink a plugin |
| `plugin.enable` / `plugin.disable` | `plugin_id*` | Enable/disable a plugin |
| `plugin.action.list` | `plugin_id?` | List actions |
| `plugin.action.invoke` | `action_id*`, `plugin_id?, context?` (PluginInvocationContext) | Invoke a plugin action |
| `plugin.log.list` | `plugin_id?, limit?` | Plugin logs |
| `plugin.pane.open` | `plugin_id*`, `entrypoint*`, `placement?` (overlay/popup/split/tab/zoomed), `target_pane_id?, workspace_id?, cwd?, env?, focus?, direction?, width?/height?` | Open a plugin UI pane |
| `plugin.pane.focus` | `pane_id*` | Focus a plugin pane |
| `plugin.pane.close` | `pane_id*` | Close a plugin pane |

### 4.2 Possible `result.type` values (57 kinds)

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

Resultless/simple methods (send_keys, send_text, move, focus, resize, close, etc.)
return `{"type":"ok"}`; specialized methods return their own kind (e.g. `pane.read` →
`pane_read`, `events.wait` → `wait_matched`, `pane.wait_for_output` → `output_matched`,
`events.subscribe` → `subscription_started`, `session.snapshot` → `session_snapshot`).

---

## 5. Events

### 5.1 Two mechanisms

| Mechanism | Request | Behavior |
|---|---|---|
| **Streaming subscription** | `events.subscribe` with `subscriptions:[…]` | The server sends notifications the whole time the connection is alive |
| **One-shot wait** | `events.wait` (EventMatch) | Blocks the request until a match or `timeout_ms`; handy for short "wait for status" |
| **Output wait** | `pane.wait_for_output` (match: substring/regex) | Specialized wait for a match in pane output; needs no subscription at all |

### 5.2 Subscription types (`Subscription`, 25 variants)

Without extra fields (22):

`workspace.created`, `workspace.updated`, `workspace.metadata_updated`,
`workspace.renamed`, `workspace.moved`, `workspace.reordered`, `workspace.closed`,
`workspace.focused`, `worktree.created`, `worktree.opened`, `worktree.removed`,
`tab.created`, `tab.closed`, `tab.focused`, `tab.renamed`, `tab.moved`, `pane.created`,
`pane.closed`, `pane.updated`, `pane.focused`, `pane.moved`, `pane.exited`,
`pane.agent_detected`, `layout.updated`.

With fields (3, scoped to a pane):

| Subscription | Fields | What arrives |
|---|---|---|
| `pane.output_matched` | `pane_id*`, `match*` (OutputMatch), `source*`, `lines?, strip_ansi?` | A match in pane output |
| `pane.agent_status_changed` | `pane_id*`, `agent_status?:AgentStatus\|null` | Agent status change in a pane |
| `pane.scroll_changed` | `pane_id*` | Pane scroll/output changed |

Note: **in subscriptions (`events.subscribe`) event names are written with dots**
(`pane.updated`), while **on the wire in notifications** lifecycle events arrive with underscores
(`pane_updated`), see 5.3. The three "scoped" subscriptions also arrive on the wire with dots
(`pane.scroll_changed`).

### 5.3 Notification format on the wire

**Lifecycle event** (verified live; schema `EventEnvelope` = `{data, event}`,
`EventKind` — an enum with underscores):

```json
{"event":"pane_updated","data":{"pane":{...PaneInfo}}}
```

**Scoped subscription** (schema `SubscriptionEventKind`, dots):

```json
{"event":"pane.scroll_changed","data":{"pane_id":"p01","scroll":{"offset_from_bottom":0,"max_offset_from_bottom":100,"viewport_rows":24},"workspace_id":"w01"}}
```

```json
{"event":"pane.agent_status_changed","data":{"pane_id":"p01","agent":"claude","agent_status":"working","title":null,"display_agent":null,"state_labels":[],"workspace_id":"w01"}}
```

```json
{"event":"pane.output_matched","data":{"pane_id":"p01","matched_line":"...","read":{...PaneReadResult}}}
```

> ⚠ On receive, both spellings of event names must be normalized (`pane.updated` ⇄ `pane_updated`):
> both are possible on different versions/channels. Our handler accepts both, see rake #4.

### 5.4 Full EventKind list (26, enum from the schema)

`workspace_created`, `workspace_updated`, `workspace_metadata_updated`, `workspace_closed`,
`workspace_renamed`, `workspace_moved`, `workspace_reordered`, `workspace_focused`,
`worktree_created`, `worktree_opened`, `worktree_removed`, `tab_created`, `tab_closed`,
`tab_renamed`, `tab_moved`, `tab_focused`, `pane_created`, `pane_closed`, `pane_updated`,
`pane_focused`, `pane_moved`, `pane_output_changed`, `pane_exited`, `pane_agent_detected`,
`pane_agent_status_changed`, `layout_updated`.

**Semantics of the ones key for our relay:**

- `pane_updated` — pane state changed (full `PaneInfo` in `data.pane`); it is emitted
  also for already-existing panes at the moment of subscription (we use it for the "first snapshot" of a pane).
- `pane_output_changed` — pane output/revision changed (handy to wait for via `events.wait`
  with `min_revision`).
- `pane_agent_status_changed` — `agent_status` change (also arrives in es6 format from hooks,
  see section 7 and rake #1).
- `pane_exited` — the process in the pane has finished.
- `pane_moved` — a pane moved between workspace/tab (the pane id **changes** on a
  cross-workspace move — rake #7).

### 5.5 SubscriptionEventKind (3)

`pane.output_matched`, `pane.agent_status_changed`, `pane.scroll_changed` — the same as the
scoped subscriptions in 5.2; these are the notifications the server sends in response to such subscriptions.

---

## 6. Data and states

### 6.1 `SessionSnapshot` — bootstrap snapshot

Returned by `session.snapshot`; the CLI wrapper `herdr api snapshot` prints the JSON directly
(our relay parses `{"result":{"snapshot":...}}`). This is **not a subscription** — after a reconnect
the snapshot must be re-read from scratch.

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

`focused_*` is nullable (can be `null` if nothing is focused).

**Structure:**

- **WorkspaceInfo:** `workspace_id*`, `label*`, `number*`, `active_tab_id*`, `tab_count*`,
  `pane_count*`, `focused*`, `agent_status*`, `tokens?(+string)`,
  `worktree ?: WorkspaceWorktreeInfo | null`
  (`repo_key*`, `repo_name*`, `repo_root*`, `checkout_path*`, `is_linked_worktree*`).
- **TabInfo:** `tab_id*`, `workspace_id*`, `label*`, `number*`, `pane_count*`, `focused*`,
  `agent_status*`.
- **PaneInfo:** `pane_id*`, `terminal_id*`, `workspace_id*`, `tab_id*`, `focused*`,
  `revision*` (int; grows as output changes), `agent_status*`,
  `agent?:string|null`, `display_agent?`, `agent_session?:AgentSessionInfo|null`
  (`source*`, `agent*`, `kind*` (id|path), `value*`), `label?`, `cwd?`, `foreground_cwd?`,
  `title?`, `terminal_title?`, `terminal_title_stripped?`,
  `scroll?:PaneScrollInfo|null`, `tokens?(+string)`, `state_labels?(+string)`.
- **AgentInfo:** = PaneInfo without `label`, plus `name?`, `interactive_ready`,
  `launch_pending`, `screen_detection_skipped`, `state_change_seq`.
- **PaneLayoutSnapshot:** `workspace_id*`, `tab_id*`, `zoomed*`, `focused_pane_id*`,
  `area*` (Rect x/y/width/height), `panes*:[{pane_id, focused, rect}]`,
  `splits*:[{id, direction (right|down), ratio, rect}]`.
- **LayoutDescription** (`layout.export`): tree
  `root: LayoutNode` = oneOf `{type:"pane", pane_id?, label?, cwd?, command?[string], env?}`
  | `{type:"split", direction(right|down), ratio, first, second}`.

### 6.2 `AgentStatus` — status semantics

`enum: idle, working, blocked, done, unknown`.

| Status | Meaning |
|---|---|
| `idle` | Agent is ready; "ready" — after its tab is shown in the UI |
| `working` | Agent is actively working |
| `blocked` | Agent is waiting for the user: approval/question/dialog in the UI |
| `done` | Agent finished a subscription/background work; comes in as "idle" after the result is seen |
| `unknown` | Not classified |

Nuance for waits (`agent.wait` / `agent.prompt` with `wait`): `until:[AgentStatus]` —
an array of statuses to wait for; `timeout_ms` bounds the wait.

### 6.3 Reading output

**`source`** (ReadSource): `visible` (what's on screen), `recent` (recent lines),
`recent_unwrapped`, `detection`.

**`format`** (ReadFormat): `text` (escaping removed, default), `ansi` (raw/with ANSI).

**`strip_ansi`**: additionally strip ANSI sequences from `text`.

**`PaneReadResult`:**

```json
{
  "pane_id":"p01","tab_id":"t01","workspace_id":"w01",
  "source":"visible","format":"text","revision":42,
  "text":"...","truncated":false
}
```

**Scroll metrics** (`PaneScrollInfo`): `offset_from_bottom*`, `max_offset_from_bottom*`,
`viewport_rows*`; `offset_from_bottom == 0` — output is at the bottom (agent at the end of the output).

**Target resolution** (`agent.*`): target is an agent name **or** a `pane_id`; the agent name
is not unique (one agent can run several panes) — for precision, target by
`pane_id` (rake #6).

---

## 7. Plugins

A plugin is a directory with `herdr-plugin.toml` (manifest) + hook scripts. The herdr server
executes them on events; our `plugin/` is a wrapper over the protocol for relay hooks
(see `plugin/README.md`, `plugin/herdr-plugin.toml`).

### 7.1 Manifest

Required fields: `id` (ASCII: letters/digits/`.`/`:`/`_`/`-`), `name`, `version`,
`min_herdr_version`. Without `min_herdr_version`, or with too new a one — linking is rejected.

Optional: `description`, `platforms = ["linux","macos","windows"]`.

Sections: `[[build]]`, `[[startup]]`, `[[actions]] {id, title, contexts, command}`,
`[[events]] {on, command}` (on is checked at link time: unknown name → warning,
see rake #1), `[[panes]] {id, title, placement, command}`,
`[[link_handlers]] {id, title, pattern, action}`.

Action id is qualified as `<plugin_id>.<action_id>`.

**Pane placement:** `overlay` (default; zoomed overlay, returns focus after closing),
`popup` (singleton, **no** pane_id, doesn't receive events), `split`/`tab`/`zoomed` —
regular panes.

### 7.2 Environment variables (env) that herdr injects into commands

**Into all runtime commands:**

| Variable | Purpose |
|---|---|
| `HERDR_SOCKET_PATH` | Path to the socket (for the API) |
| `HERDR_BIN_PATH` | Path to the herdr binary |
| `HERDR_ENV=1` | Marker: running inside herdr |
| `HERDR_PLUGIN_ID` | Plugin id |
| `HERDR_PLUGIN_ROOT` | Plugin root |
| `HERDR_PLUGIN_CONFIG_DIR` | Config directory |
| `HERDR_PLUGIN_STATE_DIR` | Plugin state directory |
| `HERDR_PLUGIN_CONTEXT_JSON` | JSON call context (of the invocation) |
| `HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`, `HERDR_PANE_ID` | Available when applicable (contextual target) |

**Additionally, by command type:**

| Command | Extra variables |
|---|---|
| Action | `HERDR_PLUGIN_ACTION_ID` |
| Startup hook | `HERDR_PLUGIN_EVENT` (for startup = `"startup"`) |
| Event hook | + `HERDR_PLUGIN_EVENT` (event name), `HERDR_PLUGIN_EVENT_JSON` — JSON of the passed event, in our format `{"data":{...}}` |
| Pane command | `HERDR_PLUGIN_ENTRYPOINT_ID` |
| Link handler | `HERDR_PLUGIN_CLICKED_URL`, `HERDR_PLUGIN_LINK_HANDLER_ID` (in `CONTEXT_JSON` `invocation_source="link_click"`) |

Additionally, manifest panes inject into pane processes: `HERDR_SOCKET_PATH`, `HERDR_ENV=1`,
`HERDR_WORKSPACE_ID`, `HERDR_TAB_ID`, `HERDR_PANE_ID` (on conflict, manifest values
take precedence).

---

## 8. How our relay uses herdr (feature → mechanism map)

| Relay feature | herdr mechanism | Where in code |
|---|---|---|
| Startup session snapshot | `herdr api snapshot` → `{"result":{"snapshot":…}}` | `internal/infrastructure/herdr/cli_repository.go` → `Snapshot()` |
| Reading agent output | `agent read <target> --lines N --format <text\|ansi>` | same file → `ReadOutput(target, lines, format)` |
| Sending keys | `agent send-keys <target> <key...>` | same file → `SendKeys(target, keys)` |
| Sending a prompt | `agent prompt <target> <text>` | same file → `SendPrompt(target, text)` |
| Live agent status/output | socket: `events.subscribe` (`pane.updated` globally + per-pane `pane.scroll_changed`, `pane.agent_status_changed`) → notifications | `internal/infrastructure/herdr/socket_event_repository.go` |
| Remap into our protocol | `pane.scroll_changed` → client event `pane.output_changed` (with revision from `pane.updated`, strictly increasing) | same file, emit with 5s timeout |

About connecting and the socket repository lifecycle (verified live, 0.8.0):

1. `net.Dial("unix", <socket>)`; reconnect with backoff 2s → ×2 → max 30s.
2. One `events.subscribe` with the full set of subscriptions; **a repeated `events.subscribe`
   on a live connection drops it** (the server closes it), subscriptions are cumulative —
   hence: one subscribe + reconnect when needed.
3. On `pane_updated`/`pane.updated`: extract `pane_id` (data can be flat
   `{"pane_id":…}` or nested `{"pane":{…}}`), normalize the event name,
   a new pane → remember it and reconnect (to get the current set of panes).
4. Frames with an empty `event` (response `subscription_started`, keepalive) — skip.

---

## 9. Rakes (verified 0.8.0 gotchas)

1. **Hooks/plugin don't deliver output events** (`pane.updated`, `pane.output_changed`,
   `pane.scroll_changed` are rejected by the linker as unknown events for `[[events]]`).
   Live output — only via socket subscription.
2. **Request `id` is a string.** A numeric id may fail schema validation.
3. **Skip service frames** without `event` (subscribe responses, keepalive).
4. **A second `events.subscribe` on a live connection drops it** → one subscribe
   per connection, full set, reconnect when the pane set changes. Subscriptions are cumulative.
5. **`pane.scroll_changed` carries no `revision`** → debounce on the client if you need
   the "latest" output.
6. **Agent names are not unique** → target by `pane_id`.
7. **`pane_id` changes on a cross-workspace move** (event `pane.moved`); herdr doesn't
   emit fake close/create — subscribe to `pane.moved` and update the mapping.
8. **`pane.updated` is not emitted on spinner-only title changes** when
   `terminal_title_stripped` doesn't change; watch `revision`/pane state as a whole.
9. **Doc/schema drift:** the socket-api docs have `pane.graphics.stream` and `pane.input.set` —
   in the 0.8.0 schema they **don't exist** (only `pane.graphics.set/clear/info` and `pane.send_input`).
   Trust the schema, not the docs.
10. **`HERDR_SOCKET` is ignored by the CLI; only `HERDR_SOCKET_PATH` works**
    (verified live, `HERDR_SOCKET=/nonexistent/foo.sock herdr api snapshot` returned
    a snapshot from the default socket; with `HERDR_SOCKET_PATH` → `server_not_running`).
    Fixed: `cli_repository.go` sends `HERDR_SOCKET_PATH`, named sessions work.
11. **`agent.prompt` with `wait` on an already-blocked agent** returns
    `agent_blocked` without sending input. Check the status before prompting, or handle
    the error.
12. Output events (`pane.updated`/`pane.scroll_changed`) were observed with a live client;
    the guarantee of emission without a connected client **was not verified** — don't rely on it without a test.
13. **Subscribing to a dead `pane_id` → JSON-RPC error `pane_not_found` and the connection
    closes.** This happens when a pane/tab is closed but the id remains in the subscriptions (also
    due to #7). Previously the relay ignored the error frame, saw "clean EOF" and reconnected
    with the same dead id — an endless reconnect loop once a second and uncontrolled growth of
    `relay.err.log`. Now the error frame is parsed, the dead pane is removed from the subscription
    set, and the connection restarts without it (see `socket_event_repository.go`).

---

## 10. Versions, reference regeneration, links

**Verified configuration:** herdr **0.8.0** (channel `stable`), **protocol 19**,
**schema_version 1** (the `relay` binary / system `herdr`).

The schema lives inside the binary and is regenerated with a single command:

```bash
herdr api schema --json --output /tmp/herdr-schema.json   # full schema
herdr api schema                                          # brief API summary
herdr status                                              # protocol/version/socket
herdr --skill                                             # instructions for agents
```

Structure of the exported JSON (`/tmp/herdr-schema.json`):

- top: `{title:"Herdr API", protocol:19, schema_version:1,
  schemas:{error_response, event, request, subscription_event, success_response}}`;
- `$defs`: request (~105 types — params), success_response (~67 — responses/data),
  event (16), subscription_event (10), error_response (1).

**Links:**

- https://herdr.dev/docs/socket-api/ — JSON-RPC over the socket (caution: drift, see #9)
- https://herdr.dev/docs/cli-reference/ — CLI commands
- https://herdr.dev/docs/plugins/ — manifest, hooks, env
- https://herdr.dev/docs/agents/ — agents and their lifecycle/statuses
- https://herdr.dev/docs/session-state/ — snapshots/session state
- https://herdr.dev/docs/concepts/ , https://herdr.dev/docs/how-to-work/
- Repository: https://github.com/herdrdev/herdr
