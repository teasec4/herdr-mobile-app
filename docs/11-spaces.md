# 11 — Spaces (workspaces): accessing workspaces and launching agents from the phone

> Status: **Phases A–C implemented** (server + client, 155 tests) · Related: [10 — herdr API](10-herdr-api.md),
> [05 — Flutter app](05-flutter-app.md).

## 0. Agreed decisions (30.08)

1. **Main screen** — bottom navigation `Spaces | Agents | Run`:
   Spaces — list of workspaces (main), Agents — flat list, Run — launch.
2. **Show all panes** — both agents and empty terminals (terminal access).
3. **Agent launch** — into the first free empty pane of the selected workspace;
   pane creation (`pane.split`) — later.
4. **Scope** — staged: A. protocol (server) → live verification → B–C. UI.

## 1. Current state (verified live)

The client only sees a **flat list of agents** (`agents.snapshot`): these are the panes
where herdr detected an agent. Everything else — workspaces, tabs, "empty"
terminals — is hidden.

A live herdr snapshot (`herdr api snapshot`) contains the full hierarchy:

```
workspaces (4): awake · pi · ai-chat-2 · herdr_relay(working)
  └─ tabs (4)
      └─ panes (6)
          ├─ wH:p8  agent=kimi  working   ← currently visible (agent)
          ├─ wH:pA  agent=kimi  working   ← currently visible (agent)
          └─ w7:p1  agent=None  unknown   ← "empty" terminal (hidden)
             wE:p2  agent=None  unknown   ← "empty" terminal (hidden)
             wF:p5  agent=None  unknown   ← "empty" terminal (hidden)
```

CLI available to the relay (verified):
- `herdr agent start <name> --kind <kind> --pane <id>` — kinds: pi, claude,
  codex, gemini, cursor, devin, agy, cline, omp, mastracode, opencode, copilot,
  kimi, kiro, droid, amp, grok, hermes, kilo, qodercli, maki;
- `herdr workspace create --label <text> --cwd <path>` — create a workspace;
- reading/input of any pane: `agent read/keys/prompt` already work via `pane_id`
  (verified: herdr accepts pane_id as the target).

## 2. Target UX: three pillars

1. **Spaces** — see the whole space: list of workspaces, inside — panes
   (agents with statuses + empty terminals). The "project → terminals" hierarchy.
2. **Terminal of any pane** — open a pane (with or without an agent) and work with it
   as a terminal: output, text input, keys. This is the "terminal access"
   that is currently hidden.
3. **Launching an agent from the phone** — wizard: pick a kind (codex/kimi/…),
   workspace (existing or create), name → `agent.start` → immediately open
   the pane terminal.

## 3. What to add to the relay (Go)

The relay protocol is extended with new `dispatch` methods (+ CLI wrappers in
`cli_repository`), the format — the same request/response frame:

| Method | Parameters | Returns | Implementation |
| --- | --- | --- | --- |
| `session.snapshot` | `{}` | `{workspaces:[…], panes:[…], agents:[…], focused_*}` | parse the full `SessionSnapshot` (currently only `agents` is parsed) |
| `agent.start` | `name, kind, pane_id` | `{ok}` | `herdr agent start <name> --kind <kind> --pane <id>` |
| `workspace.create` | `label?, cwd?` | `{workspace_id, label}` | `herdr workspace create …` |
| `pane.send_text` | `pane_id, text` | `{ok}` | `herdr agent send-keys` has nothing for text → CLI `agent prompt`? for an empty pane — `pane.send_input` via socket (see docs/10 §4) |

Domain models: `Workspace{id,label,agentStatus,tabs,panes}`,
`Pane{id,workspaceId,tabId,agent,agentStatus,cwd,title}`; the client's
`RelayAgent` is extended with `workspaceId`/`tabId` (the relay already returns these fields,
the client just didn't read them).

## 4. UI and mobile flow (proposal)

### 4.1 Navigation: bottom tabs

```
┌─────────────────────────────┐
│  Spaces   Agents   +Run     │   ← bottom navigation (replaces flat-list)
└─────────────────────────────┘
```

- **Spaces** — main screen: list of workspaces (label, aggregate status,
  number of panes). Tap → workspace screen: panes (agents with status chips +
  empty terminals), tap on a pane → terminal. "+" button → create workspace.
- **Agents** — the current flat list (all agents from all spaces), for those
  who are used to it. Keeps the blocked-first ordering.
- **Run** — agent launch wizard (steps): kind → workspace → name → start.
- **Connection** — stays in the "⋮" menu (already exists).

### 4.2 Terminal of any pane (extension of AgentPage)

`AgentPage` becomes the universal `PanePage`:
- pane with an agent: output + prompt + keys (as now);
- empty pane: output + `send_text` (line input into the terminal) + keys;
- header: `workspace/label · pane_id`, status, "⋮" menu (launch an agent in
  this pane, close/rename, change cwd — as the server becomes ready).

### 4.3 "Launched an agent from the phone" flow

1. **Run** → pick a kind (icon grid / list of 20 kinds).
2. Pick a workspace: list of existing ones or "create new" (label + cwd).
3. Agent name (default: kind).
4. `agent.start` into the first free empty pane of the workspace (or create a pane)
   → auto-navigation to the pane terminal.
5. Then as usual: output, statuses, blocked → reply.

## 5. Implementation phases

| Phase | Content | Criterion |
| --- | --- | --- |
| **A. Protocol** | `session.snapshot` (full), `agent.start`, `workspace.create`, `pane.send_text` in the relay + CLI wrappers + Go tests | ✅ `curl /api/rpc` returns workspaces (verified live) |
| **B. Models and navigation** | `RelayWorkspace`/`RelayPane`, `session()`; bottom tabs Spaces/Agents/Run; workspace screen | ✅ 4 workspaces and all panes visible on the phone |
| **C. Pane terminal** | `PanePage` input (`send_text` for empty ones), agent launch from Run | ✅ input into an empty pane — `pane.send_text` (verified live: `ok:true`); launch from Run into a free pane |

Live protocol verification: `session.snapshot` → 4 workspaces / 6 panes;
`pane.send_text` → ok; `agent.start` with an empty kind → a clear error
(validation). Full agent launch from the phone — manual test on a device.
| **B. Models and navigation** | `RelayWorkspace`/`RelayPane`, `RelayAgent.workspaceId`; bottom tabs Spaces/Agents/Run; workspace screen | 4 workspaces and all panes visible on the phone |
| **C. Pane terminal** | `PanePage` (send_text for empty ones), agent launch from Run and from the pane menu | an agent launched from the phone into a new/existing workspace |
| **D. Polish** | workspace creation in the UI, errors/retries, workspace.* events, tests | full flow without a laptop |

## 6. Open questions (to discuss)

1. **Hierarchy vs flat**: main screen — Spaces (hierarchy) or keep
   the flat agent list + a separate Spaces tab? (proposal: Spaces
   main, Agents — a tab).
2. **Empty terminals**: show them in the workspace list right away (terminals
   as objects) or only when you open a workspace? (proposal: show them,
   this is exactly the "terminal access").
3. **Launch into a pane vs new**: `agent.start` requires an existing pane —
   launch into the first free pane of the workspace, or add `pane.split`/
   pane creation? (proposal: free pane; split — later).
4. **send_text for an empty pane**: check the CLI/socket path
   (`pane.send_input`/`pane.send_text` from docs/10 §4) — if the CLI can't,
   do it via socket.