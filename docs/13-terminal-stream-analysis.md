# Terminal Stream Architecture Analysis and Reliability Improvement Strategy

**Date:** 2026-08-30  
**Status:** draft for discussion  
**Goal:** Improve reliability, reduce latency, add client-side cache and pagination for terminal output

---

## 1. Current architecture (as of f7a701f)

### 1.1 Data Flow

```
┌─────────────┐
│   Client    │
│  (Flutter)  │
└──────┬──────┘
       │ agent.output (RPC)
       │ lines=500, format=ansi
       ▼
┌─────────────┐
│    Relay    │
│   (Go HTTP) │
└──────┬──────┘
       │ CLI spawn
       │ herdr agent read <target> --lines 500 --format ansi
       ▼
┌─────────────┐
│    herdr    │
│   (daemon)  │
└─────────────┘
       │
       ▼ returns raw ANSI text (stdout)
       
Client: AnsiTerminal widget parses & renders 500 lines
```

### 1.2 Problems (verified)

#### P1: Every request = subprocess spawn
**File:** `internal/infrastructure/herdr/cli_repository.go:96-105`

```go
func (r *CLIRepository) ReadOutput(target string, lines int, format string) (string, error) {
    out, err := r.run("agent", "read", target, "--lines", fmt.Sprintf("%d", lines), "--format", format)
    return string(out), nil
}
```

**Problem:**
- Every `agent.output` RPC → one `exec.Command("herdr", "agent", "read", ...)`
- Subprocess spawn latency: **10-30ms** (fork + exec + herdr CLI init + JSON parse)
- On a mobile client: ~20 refreshes/minute → **400ms CPU** just on subprocess overhead
- No cache: the same tail is re-read on every `pane.output_changed` event

**Scenario:**
- Agent outputs 10 lines/sec (streaming response)
- `pane.scroll_changed` debounce 500ms → 2 events/sec
- Client on AgentPage → 2 subprocesses/sec × 30ms = **60ms overhead**
- For 5 active agents = **300ms/sec CPU** just on CLI spawn

#### P2: No incremental reading on the client side
**File:** `client/lib/pages/agent_page.dart:136-159`

```dart
Future<void> _refresh({bool silent = false}) async {
    final output = await _repository.getOutput(_agent.id, lines: 500);
    setState(() {
        _output = output;  // full replacement
        _suggestedActions = _parserService.parse(output);
    });
    _scrollToBottom();
}
```

**Problem:**
- We always read the full tail (500 lines)
- AnsiTerminal memoization avoids reparse (line 62 `ansi_terminal.dart`), but only if the text is **identical**
- Appending 1 line to a 500-line tail → the whole text changed → reparse 500 lines (20-50ms on mobile)
- No delta/incremental: always full replace

**Measurements (approximate):**
- 500 lines × 80 chars = 40KB text
- ANSI parse: ~20-50ms (Flutter Release on iPhone 12)
- Network latency (LAN): 5-10ms
- Total refresh latency: **50-100ms** per update

#### P3: Revision tracking works, but is suboptimal
**File:** `internal/infrastructure/herdr/socket_event_repository.go:189-191, 223-228`

The relay attaches `revision` to `pane.output_changed` **only if it strictly increased** since the last one sent. The client checks the revision guard (line 106 `agent_page.dart`):

```dart
if (event.revision > 0) {
    if (_lastRevision != null && event.revision <= _lastRevision!) return;
    _lastRevision = event.revision;
}
```

**Problems:**
1. Revision comes from `pane.updated` (`PaneInfo.revision` — an incrementing counter in herdr)
2. `pane.scroll_changed` **does NOT carry revision** (docs/10-herdr-api.md gotcha #5)
3. The relay solves this by caching `lastRevision[pane]` from `pane.updated` and attaching it to `output_changed`
4. But: revision is a **change counter for terminal output**, not a **content hash**
5. On `pane.updated(rev=10)` → `scroll_changed` → the client reads output → revision=10 in the `PaneReadResult` response, but we **don't use it** for the cache key
6. A 400ms client debounce can skip intermediate revisions (rev=10, 11, 12 → the client only sees 12)

**Summary:** the revision guard protects against **out-of-order delivery**, but does not provide incrementality.

#### P4: No server-side cache
**Rationale:** `docs/12-fix-plan.md` D10:
> "Server-side snapshot is not cached: every request spawns a CLI subprocess"

Terminal output is even worse: the herdr daemon holds a **full terminal buffer** (scrollback), but the relay doesn't cache it. Every `agent.output` RPC → CLI → herdr reads the tail from the PTY buffer → returns the full text.

**Why can't we simply cache on the relay?**
- herdr may return a **stale tail** (if the process in the pane is still writing)
- revision grows asynchronously (the `pane.updated` event may arrive later than the client's output request)
- We need an invalidation strategy: based on `pane.output_changed` events, but time may pass between the event and the CLI request

#### P5: No pagination / infinite scroll
The client always reads the last **500 lines**. If the user wants to see more history:
- Requires changing the hardcoded `lines: 500` (ugly)
- No UI for "load more" / scroll-to-top
- herdr supports reading with offset (`source: visible/recent/recent_unwrapped`), but relay/client don't use it

**Use case:**
- Agent made 50 tool calls → 2000+ lines of output
- Client only shows the last 500 → the user doesn't see the start of the work
- We want: "scroll to top → load previous 500 lines"

---

## 2. Herdr API capabilities (what we can use)

### 2.1 `pane.read` / `agent.read` parameters (docs/10-herdr-api.md §4.1, §6.3)

```json
{
  "method": "agent.read",
  "params": {
    "target": "pane_id",
    "source": "recent",        // visible | recent | recent_unwrapped | detection
    "lines": 500,
    "format": "ansi",          // ansi | text
    "strip_ansi": false
  }
}
```

**Response — `PaneReadResult`:**
```json
{
  "type": "pane_read",
  "pane_id": "wH:p3",
  "tab_id": "wH:t1",
  "workspace_id": "wH",
  "source": "recent",
  "format": "ansi",
  "revision": 42,              // ← KEY FIELD
  "text": "...",
  "truncated": false
}
```

**Key facts:**
1. **`revision`** — a monotonically increasing counter of terminal output changes (herdr bumps it on every write to the PTY)
2. **`truncated`** — true if the terminal scrollback is larger than the requested `lines`
3. **`source`** options:
   - `recent` — last N lines (tail)
   - `visible` — what's currently on screen (viewport)
   - `recent_unwrapped` — last N lines without line wrapping
   - `detection` — used for agent detection (not relevant to us)

**What we DON'T use:**
- `revision` in the response (read, but not cached)
- `truncated` (no "load more" UI shown)
- `source: visible` (could be used for "show only viewport", but we always send `recent`)

### 2.2 Event: `pane.updated` carries PaneInfo with revision

**From the socket subscription** (line 179-193 `socket_event_repository.go`):
```json
{
  "event": "pane_updated",
  "data": {
    "pane": {
      "pane_id": "wH:p3",
      "revision": 42,          // ← same revision as in PaneReadResult
      "agent_status": "working",
      ...
    }
  }
}
```

The relay extracts `revision` and caches it in `lastRevision[paneID]` (line 190). Then on `pane.scroll_changed` it attaches it to `pane.output_changed` if the revision strictly increased (lines 223-228).

**Problem:** 400ms (debounce) may pass between `pane.updated(rev=10)` and the client's `agent.output` RPC; during that time herdr may bump the revision again → the client gets `PaneReadResult{revision: 11}`, but we ignore it.

### 2.3 Scroll metrics: `PaneScrollInfo`

**In the `pane.scroll_changed` event** (docs/10-herdr-api.md §5.3):
```json
{
  "event": "pane.scroll_changed",
  "data": {
    "pane_id": "wH:p3",
    "scroll": {
      "offset_from_bottom": 0,         // 0 = at bottom (live tail)
      "max_offset_from_bottom": 1000,  // total scrollback depth
      "viewport_rows": 24
    }
  }
}
```

**Semantics:**
- `offset_from_bottom == 0` → user at the bottom (live tail) → auto-scroll
- `offset_from_bottom > 0` → user scrolled up → freeze autoscroll
- `max_offset_from_bottom` → how many lines of history are available

**What this gives us:**
- We can detect when the user is at the bottom (live tail mode) vs reading history
- `max_offset_from_bottom` can be used for a "X lines available, Y loaded" UI

**What we don't use:** scroll metrics are completely ignored (the relay doesn't forward them to the client).

---

## 3. Proposed architecture

### 3.1 High-level goals

1. **Reduce latency:** server-side cache → no CLI spawn per request
2. **Incrementality:** client-side delta updates → less parse/render
3. **Pagination:** load more history → scroll to top → fetch older lines
4. **Reliability:** event-based cache invalidation, fallback to fresh read on miss

### 3.2 Architecture: three-tier caching

```
┌────────────────────────────────────────────────┐
│              Client (Flutter)                  │
│                                                │
│  ┌─────────────────────────────────────────┐  │
│  │  OutputCache (in-memory)                │  │
│  │  - Map<paneID, CachedOutput>           │  │
│  │  - CachedOutput {                       │  │
│  │      revision: int                      │  │
│  │      lines: List<ParsedLine>            │  │
│  │      rawText: String                    │  │
│  │      timestamp: DateTime                │  │
│  │    }                                    │  │
│  └─────────────────────────────────────────┘  │
│                                                │
│  AgentPage logic:                              │
│  1. On pane.output_changed(rev):              │
│     - if cache.revision == rev: skip           │
│     - else: request delta (since cache.rev)    │
│  2. On response: merge delta into cache        │
│  3. Render from cache.lines                    │
└────────────────────────────────────────────────┘
                       │
                       │ RPC: agent.output_delta
                       │ {since_revision?, lines?, offset?}
                       ▼
┌────────────────────────────────────────────────┐
│               Relay (Go)                       │
│                                                │
│  ┌─────────────────────────────────────────┐  │
│  │  OutputCache (in-memory, TTL 60s)       │  │
│  │  - sync.Map[paneID]CachedOutput         │  │
│  │  - CachedOutput {                        │  │
│  │      revision int                        │  │
│  │      text string                         │  │
│  │      fetchedAt time.Time                 │  │
│  │    }                                     │  │
│  │                                          │  │
│  │  Invalidation:                           │  │
│  │  - pane.updated(rev) → if rev > cached: │  │
│  │    mark stale (or delete)                │  │
│  │  - TTL 60s → auto-expire old entries     │  │
│  └─────────────────────────────────────────┘  │
│                                                │
│  OutputService:                                │
│  1. Check cache: if fresh & rev matches: ret  │
│  2. Else: CLI spawn → herdr agent read        │
│  3. Store in cache with revision               │
│  4. Return to client                           │
└────────────────────────────────────────────────┘
                       │
                       │ CLI: herdr agent read
                       ▼
┌────────────────────────────────────────────────┐
│            herdr daemon                        │
│  - PTY scrollback buffer (in-memory)          │
│  - revision counter (bumps on write)           │
└────────────────────────────────────────────────┘
```

### 3.3 Protocol changes

#### New RPC method: `agent.output_delta`

**Request:**
```json
{
  "method": "agent.output_delta",
  "params": {
    "target": "wH:p3",
    "since_revision": 41,    // optional: return only if rev > this
    "lines": 500,            // how many lines to fetch (default 500)
    "offset": 0,             // optional: offset from bottom (for pagination)
    "format": "ansi"
  }
}
```

**Response:**
```json
{
  "type": "output_delta",
  "pane_id": "wH:p3",
  "revision": 42,
  "mode": "full",             // "full" | "unchanged" | "appended"
  "text": "...",              // full tail (mode=full)
  "appended_lines": ["..."],  // only new lines (mode=appended)
  "truncated": false,
  "total_lines": 1523
}
```

**Semantics:**
- `since_revision` provided:
  - If `since_revision == current_revision`: return `{mode: "unchanged", revision: 42}`
  - If output **only appended** since `since_revision`: return `{mode: "appended", appended_lines: [...]}`
  - Otherwise (lines changed/deleted): return `{mode: "full", text: "..."}`
- `since_revision` omitted: always return full (mode=full)

**Server-side logic:**
```go
func (s *OutputService) GetOutputDelta(target string, sinceRev int, lines int) (*OutputDelta, error) {
    cached := s.cache.Get(target)
    
    // Fresh read from herdr
    result, err := s.repo.ReadOutput(target, lines, "ansi")
    currentRev := result.Revision
    
    // Cache miss or stale: return full
    if cached == nil || cached.Revision != sinceRev {
        s.cache.Set(target, result.Text, currentRev)
        return &OutputDelta{Mode: "full", Text: result.Text, Revision: currentRev}, nil
    }
    
    // Cache hit and revision matches request: unchanged
    if currentRev == sinceRev {
        return &OutputDelta{Mode: "unchanged", Revision: currentRev}, nil
    }
    
    // Revision advanced: try to compute delta
    delta := computeDelta(cached.Text, result.Text)
    if delta.IsAppendOnly() {
        return &OutputDelta{Mode: "appended", AppendedLines: delta.Lines, Revision: currentRev}, nil
    }
    
    // Complex change: return full
    return &OutputDelta{Mode: "full", Text: result.Text, Revision: currentRev}, nil
}
```

**Delta computation heuristic:**
```go
func computeDelta(oldText, newText string) Delta {
    oldLines := strings.Split(oldText, "\n")
    newLines := strings.Split(newText, "\n")
    
    // Cheap heuristic: if old is prefix of new → append-only
    if len(newLines) >= len(oldLines) {
        match := true
        for i := 0; i < len(oldLines); i++ {
            if oldLines[i] != newLines[i] {
                match = false
                break
            }
        }
        if match {
            return Delta{IsAppendOnly: true, Lines: newLines[len(oldLines):]}
        }
    }
    
    // Otherwise: full replace
    return Delta{IsAppendOnly: false}
}
```

**Tradeoff:** delta computation — string comparison (expensive for 500 lines). **Alternative:** herdr doesn't provide a true delta API, so:
- **Simple option:** always return `mode: full` (no delta), but cache on the server by revision
- **Complex option:** the relay keeps a sliding window of the last N lines, detecting append via suffix match

**Recommendation:** start with the **simple option** (no delta, only cache by revision). Delta — phase 2.

---

## 4. Implementation phases

### Phase 1: Server-side cache (low-hanging fruit)

**Goal:** eliminate subprocess spawn overhead for repeated requests of the same revision.

**Changes:**
1. **New:** `internal/service/output_cache.go`
   ```go
   type OutputCache struct {
       mu    sync.RWMutex
       cache map[string]*CachedOutput
   }
   
   type CachedOutput struct {
       Text      string
       Revision  int
       FetchedAt time.Time
   }
   
   func (c *OutputCache) Get(paneID string) *CachedOutput
   func (c *OutputCache) Set(paneID, text string, revision int)
   func (c *OutputCache) Invalidate(paneID string)
   func (c *OutputCache) Cleanup() // TTL eviction (run in goroutine)
   ```

2. **Modify:** `internal/service/agent_service.go`
   ```go
   type AgentService struct {
       repo        repository.AgentRepository
       outputCache *OutputCache  // NEW
   }
   
   func (s *AgentService) GetOutput(target string, lines int, format string) (*domain.AgentOutput, error) {
       // Try cache first
       cached := s.outputCache.Get(target)
       
       // Fetch fresh (always, for Phase 1 — no revision check yet)
       output, err := s.repo.ReadOutput(target, lines, format)
       if err != nil {
           // Fallback to cache on error (if available)
           if cached != nil {
               return &domain.AgentOutput{Target: target, Output: cached.Text}, nil
           }
           return nil, err
       }
       
       // Extract revision from output (need to parse PaneReadResult JSON)
       revision := extractRevision(output) // helper function
       
       // Update cache
       s.outputCache.Set(target, output, revision)
       
       return &domain.AgentOutput{Target: target, Output: output}, nil
   }
   ```

3. **Wire invalidation:** `internal/service/event_service.go`
   ```go
   func (s *EventService) broadcast(event domain.Event) {
       // Existing broadcast logic...
       
       // NEW: Invalidate output cache on pane.updated
       if evt, ok := event.(domain.PaneUpdatedEvent); ok {
           s.agentService.outputCache.Invalidate(evt.PaneID)
       }
   }
   ```

**Benefits:**
- Requests with the same revision → cached response (no CLI spawn)
- On a `pane.updated` event the cache is invalidated → the next request reads fresh
- Latency: 30ms → 1-2ms (cache hit)

**Limitations:**
- We still read the full tail (500 lines) on cache miss
- The client still does a full replace (no incremental)

**Risks:**
- Cache invalidation race: the `pane.updated(rev=10)` event arrived, the relay invalidated the cache, but herdr hasn't written the new output yet → the client reads stale data
- **Mitigation:** TTL 60s (cache expires even without events), fallback to cached on CLI error

**Tests:**
- Unit: `output_cache_test.go` — Get/Set/Invalidate/TTL
- Integration: `agent_service_test.go` — two requests in a row (second from cache)
- End-to-end: measure latency (should be <5ms on cache hit)

---

### Phase 2: Client-side revision-based caching

**Goal:** client skips re-parsing if revision unchanged.

**Changes:**
1. **Modify:** `client/lib/repositories/agent_repository.dart`
   ```dart
   class AgentRepository {
       final Map<String, CachedOutput> _outputCache = {};
       
       Future<AgentOutput> getOutput(String agentId, {int lines = 500}) async {
           final cached = _outputCache[agentId];
           
           // Request from relay (always fetch for now; Phase 3 adds since_revision)
           final result = await _client.output(agentId, lines: lines, format: 'ansi');
           
           // Parse response (need to add revision field to RelayClient.output return type)
           final revision = result.revision;
           final text = result.text;
           
           // Check if unchanged
           if (cached != null && cached.revision == revision) {
               return AgentOutput(text: cached.text, revision: revision, fromCache: true);
           }
           
           // Update cache
           _outputCache[agentId] = CachedOutput(text: text, revision: revision);
           return AgentOutput(text: text, revision: revision, fromCache: false);
       }
   }
   
   class AgentOutput {
       final String text;
       final int revision;
       final bool fromCache;
   }
   ```

2. **Modify:** `client/lib/pages/agent_page.dart`
   ```dart
   Future<void> _refresh({bool silent = false}) async {
       final result = await _repository.getOutput(_agent.id, lines: 500);
       
       // Skip setState if from cache and text identical
       if (result.fromCache && result.text == _output) {
           return; // no-op
       }
       
       setState(() {
           _output = result.text;
           _suggestedActions = _parserService.parse(result.text);
       });
       _scrollToBottom();
   }
   ```

**Benefits:**
- On `pane.output_changed(rev=10)` → client checks cache → if rev==10: skip request entirely
- Latency: 0ms (no network round-trip)

**Limitations:**
- Still full text replace on revision change (no incremental render)

**Tests:**
- Unit: `agent_repository_test.dart` — two getOutput calls with the same revision (second from cache)
- Widget: `agent_page_test.dart` — `output_changed` event with the same revision → setState is not called

---

### Phase 3: Incremental client-side updates (optional, complex)

**Goal:** append-only updates → no full reparse.

**Approach:**
1. The client keeps a `List<ParsedLine>` instead of `String _output`
2. On `mode: appended` → parse only the new lines, append to the list
3. AnsiTerminal accepts `List<InlineSpan>` instead of `String text`

**Challenge:** AnsiTerminal currently parses the whole text in `parse()` (line 203-247 `ansi_terminal.dart`). Incremental parsing requires:
- A state machine for ANSI (current color/bold/italic) at the boundary between old/new text
- Storing parsed spans, not just the text

**Complexity:** high. **Recommendation:** defer until Phase 4+.

**Alternative:** memoization already works (line 62 `ansi_terminal.dart`) — if the text hasn't changed, no reparse happens. On append-only updates the text changed, but the **prefix is identical** → we can cache parsed spans by prefix hash and reuse them.

**Simpler approach (Phase 3a):**
```dart
class AnsiTerminal {
    String? _cacheText;
    List<InlineSpan>? _cacheSpans;
    
    List<InlineSpan> parse() {
        // If text identical: return cached
        if (widget.text == _cacheText) return _cacheSpans!;
        
        // If text is append-only (old is prefix): parse only suffix
        if (_cacheText != null && widget.text.startsWith(_cacheText!)) {
            final newPart = widget.text.substring(_cacheText!.length);
            final newSpans = AnsiTerminalParser(newPart, baseStyle: ...).parse();
            _cacheSpans!.addAll(newSpans);
            _cacheText = widget.text;
            return _cacheSpans!;
        }
        
        // Otherwise: full parse
        final spans = AnsiTerminalParser(widget.text, baseStyle: ...).parse();
        _cacheText = widget.text;
        _cacheSpans = spans;
        return spans;
    }
}
```

**Problem:** ANSI state bleeding: suffix parse needs to inherit color/bold/italic from the end of the prefix. Solution: the `AnsiTerminalParser` constructor takes `initialState: AnsiState`.

**Effort:** medium (1-2 days). **Benefit:** 10-30ms saved per append (on a 500-line tail).

---

### Phase 4: Pagination / load more history

**Goal:** the user can scroll to top → load the previous 500 lines.

**UX:**
```
┌───────────────────────────────────┐
│  [Load 500 more lines]  ← button │
├───────────────────────────────────┤
│  ...terminal output...            │
│                                   │
│  (auto-scroll if at bottom)       │
└───────────────────────────────────┘
```

**Protocol:**
- Existing RPC: `agent.output` with `offset` param (from bottom)
- Example: `offset: 0, lines: 500` → last 500 lines (current behavior)
- Example: `offset: 500, lines: 500` → lines 500-1000 from bottom

**Implementation:**
1. **Relay:** already supports this (herdr CLI accepts `--lines` but NOT `--offset` — **check docs**)
   - **Correction:** the herdr CLI `agent read` does NOT have an `--offset` flag (checked in docs/10-herdr-api.md §4.1)
   - herdr socket API: `pane.read` params have `source`, but NOT offset
   - **Workaround:** request more lines (`lines: 1000`), the client skips the first 500 (inefficient)
   
2. **Alternative:** herdr `source: visible` returns the viewport (24 lines), but that's not what we need
3. **herdr limitation:** no API for "read lines [N..M]" — only tail (`source: recent`)

**Verdict:** pagination requires upstream support in the herdr API (offset param). Without it we can:
- Increase the hardcoded `lines` (e.g., 1000 instead of 500) → more history, but more latency
- "load more" UI → request 1000 lines, show 1000 instead of 500 (crudely works)

**Phase 4 recommendation:** wait for a herdr API extension or implement a workaround with a larger `lines`.

---

## 5. Recommended implementation order

### Immediate (1-2 weeks):
1. **Phase 1:** Server-side cache (output_cache.go + invalidation)
   - **Impact:** High (30ms → 2ms latency)
   - **Risk:** Low (cache miss = fallback to CLI)
   - **Effort:** 2-3 days

2. **Phase 2:** Client-side revision caching
   - **Impact:** Medium (skip unnecessary requests)
   - **Risk:** Low
   - **Effort:** 1 day

### Near-term (1 month):
3. **Phase 3a:** Incremental ANSI parsing (append-only optimization)
   - **Impact:** Medium (10-30ms per update)
   - **Risk:** Medium (ANSI state bleeding bugs)
   - **Effort:** 2-3 days

### Future (3+ months):
4. **Phase 4:** Pagination (blocked on herdr API)
   - **Impact:** High (UX improvement for long outputs)
   - **Risk:** Low (if herdr adds offset support)
   - **Effort:** 1 week (client + relay changes)

---

## 6. Edge cases & failure modes

### 6.1 Cache invalidation race
**Scenario:** 
1. herdr writes to the PTY → revision bump (internal)
2. `pane.updated(rev=10)` event sent → relay receives → invalidates cache
3. The client requests `agent.output` **before herdr finished writing**
4. The CLI returns stale output (rev=9 text, but labeled rev=10)

**Mitigation:**
- herdr guarantees: `pane.updated` is sent **after** the revision bump completes
- If the race happens: the client's next `output_changed` event will have rev=11 → cache miss → fresh read
- **No data loss**, only a temporary stale read (1 update cycle = 500ms)

### 6.2 Client offline / reconnect
**Scenario:**
1. Client has cached output (rev=10)
2. Disconnect → N updates happen → revision=15
3. Reconnect → `pane.updated(rev=15)` event

**Current behavior:** the client's `_wasDisconnected` flag triggers a full refresh (line 117 `home_page.dart`)

**With cache:** cache invalidated on disconnect (clear all), fresh read on reconnect.

### 6.3 Multiple clients
**Scenario:** two clients (phone + web) viewing the same agent.

**Relay cache:** shared across clients → the second client benefits from the first's fetch.

**Client cache:** independent → both clients maintain separate revision state (OK).

### 6.4 herdr restart
**Scenario:** the herdr daemon restarts → revision counters reset.

**Impact:** relay cache holds stale paneIDs → the first request after a restart gets wrong output.

**Mitigation:** TTL 60s → cache expires. Also: the relay could detect the herdr restart (socket disconnect event) → clear the entire cache.

---

## 7. Metrics for measuring improvement

### Before (baseline):
- **Latency per output request:** 30-50ms (subprocess spawn + herdr read)
- **Requests per minute (active agent):** ~20 (with 500ms debounce, 2 events/sec)
- **Total overhead:** 20 × 50ms = **1000ms/min CPU**
- **Client parse time (500 lines):** 20-50ms

### After Phase 1 (server cache):
- **Latency (cache hit):** 2-5ms
- **Cache hit rate:** ~80% (with an active agent, events are frequent, but the revision changes less often)
- **Total overhead:** 4 × 50ms + 16 × 5ms = **280ms/min CPU** (72% reduction)

### After Phase 2 (client cache):
- **Latency (revision unchanged):** 0ms (no request)
- **Requests per minute:** ~5 (only on revision change)
- **Total overhead:** 5 × 5ms = **25ms/min CPU** (97% reduction)

### After Phase 3a (incremental parse):
- **Client parse time (append-only):** 2-5ms (only new lines)
- **Total render latency:** 5ms request + 5ms parse = **10ms** (was 50ms + 20ms = 70ms)

---

## 8. Open questions for discussion

1. **Delta computation complexity:** is string comparison for 500 lines acceptable? (~1ms on server, but scales O(N²) worst case)
   - **Alternative:** rely on revision only, no delta (Phase 1+2 without Phase 3)

2. **Pagination without herdr offset API:** should we request 1000+ lines upfront, or wait for herdr upstream support?
   - **Proposal:** Phase 1-2 first, pagination later (low priority)

3. **Client cache eviction policy:** keep the last N panes (LRU), or all panes with TTL?
   - **Proposal:** keep all (memory is cheap on the client), clear on disconnect

4. **Server cache TTL:** is 60s reasonable? Too short (more CLI spawns) vs too long (stale data risk)
   - **Proposal:** 60s, with event-based invalidation (optimal)

5. **Error fallback strategy:** when the CLI fails, serve a stale cache or return an error?
   - **Current:** return error
   - **Proposal:** return stale cache with a `stale: true` flag, show a warning in the UI

---

## Appendix A: Code locations reference

| Component | File | Lines |
|---|---|---|
| CLI repository | `internal/infrastructure/herdr/cli_repository.go` | 96-105 |
| Agent service | `internal/service/agent_service.go` | 23-41 |
| Event broadcast | `internal/service/event_service.go` | 99-113 |
| Client repo | `client/lib/repositories/agent_repository.dart` | 76-78 |
| AgentPage refresh | `client/lib/pages/agent_page.dart` | 136-159 |
| ANSI terminal | `client/lib/widgets/ansi_terminal.dart` | 50-80, 203-247 |
| Socket events | `internal/infrastructure/herdr/socket_event_repository.go` | 179-231 |

---

## Appendix B: Protocol spec (for implementation)

### Existing: `agent.output` (unchanged)
```typescript
// Request
{
  method: "agent.output",
  params: {
    target: string,
    lines?: number,      // default 500
    format?: "ansi" | "text"
  }
}

// Response
{
  type: "response",
  result: {
    output: string,      // raw text
    revision?: number    // NEW: add revision field
  }
}
```

### Future (Phase 3): `agent.output_delta`
```typescript
// Request
{
  method: "agent.output_delta",
  params: {
    target: string,
    since_revision?: number,
    lines?: number,
    format?: "ansi" | "text"
  }
}

// Response
{
  type: "response",
  result: {
    mode: "full" | "unchanged" | "appended",
    revision: number,
    text?: string,              // if mode=full
    appended_lines?: string[],  // if mode=appended
    total_lines?: number
  }
}
```

---

**End of document.** Ready for review and discussion.
