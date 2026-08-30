# Анализ архитектуры terminal stream и стратегия улучшения надёжности

**Дата:** 2026-08-30  
**Статус:** черновик для обсуждения  
**Цель:** Улучшить reliability, снизить latency, добавить client-side cache и pagination для терминального вывода

---

## 1. Текущая архитектура (as of f7a701f)

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

### 1.2 Проблемы (verified)

#### P1: Каждый запрос = subprocess spawn
**Файл:** `internal/infrastructure/herdr/cli_repository.go:96-105`

```go
func (r *CLIRepository) ReadOutput(target string, lines int, format string) (string, error) {
    out, err := r.run("agent", "read", target, "--lines", fmt.Sprintf("%d", lines), "--format", format)
    return string(out), nil
}
```

**Проблема:**
- Каждый `agent.output` RPC → один `exec.Command("herdr", "agent", "read", ...)`
- Subprocess spawn latency: **10-30ms** (fork + exec + herdr CLI init + JSON parse)
- На мобильном клиенте: ~20 refreshes/minute → **400ms CPU** только на subprocess overhead
- Нет кэша: читаем тот же tail повторно при каждом `pane.output_changed` событии

**Сценарий:**
- Агент выводит 10 строк/сек (streaming response)
- `pane.scroll_changed` debounce 500ms → 2 события/сек
- Клиент на AgentPage → 2 subprocess/сек × 30ms = **60ms overhead**
- Для 5 активных агентов = **300ms/sec CPU** только на CLI spawn

#### P2: Client-side нет инкрементального чтения
**Файл:** `client/lib/pages/agent_page.dart:136-159`

```dart
Future<void> _refresh({bool silent = false}) async {
    final output = await _repository.getOutput(_agent.id, lines: 500);
    setState(() {
        _output = output;  // полная замена
        _suggestedActions = _parserService.parse(output);
    });
    _scrollToBottom();
}
```

**Проблема:**
- Всегда читаем полный tail (500 строк)
- AnsiTerminal memoization спасает от reparse (строка 62 `ansi_terminal.dart`), но только если текст **идентичен**
- При append 1 строки к 500-строчному tail → весь текст изменился → reparse 500 строк (20-50ms на мобиле)
- Нет delta/incremental: всегда full replace

**Измерения (примерные):**
- 500 строк × 80 символов = 40KB текст
- ANSI parse: ~20-50ms (Flutter Release на iPhone 12)
- Network latency (LAN): 5-10ms
- Total refresh latency: **50-100ms** per update

#### P3: Revision tracking работает, но неоптимально
**Файл:** `internal/infrastructure/herdr/socket_event_repository.go:189-191, 223-228`

Relay прикрепляет `revision` к `pane.output_changed`, **только если он строго увеличился** с последнего отправленного. Клиент проверяет revision guard (строка 106 `agent_page.dart`):

```dart
if (event.revision > 0) {
    if (_lastRevision != null && event.revision <= _lastRevision!) return;
    _lastRevision = event.revision;
}
```

**Проблемы:**
1. Revision приходит из `pane.updated` (`PaneInfo.revision` — инкрементный счётчик в herdr)
2. `pane.scroll_changed` **НЕ несёт revision** (docs/10-herdr-api.md gotcha #5)
3. Relay решает это, кэшируя `lastRevision[pane]` из `pane.updated` и прикрепляя к `output_changed`
4. Но: revision — это **счётчик изменений terminal output**, не **content hash**
5. При `pane.updated(rev=10)` → `scroll_changed` → клиент читает output → revision=10 в ответе `PaneReadResult`, но мы его **не используем** для cache key
6. Client debounce 400ms может пропустить промежуточные ревизии (rev=10, 11, 12 → клиент видит только 12)

**Итого:** revision guard защищает от **out-of-order delivery**, но не даёт инкрементальность.

#### P4: Нет server-side кэша
**Обоснование:** `docs/12-fix-plan.md` D10:
> "Server-side snapshot не кэшируется: каждый запрос спавнит CLI-подпроцесс"

Terminal output ещё хуже: herdr daemon держит **full terminal buffer** (scrollback), но relay его не кэширует. Каждый `agent.output` RPC → CLI → herdr читает tail из PTY buffer → возвращает полный текст.

**Почему нельзя просто кэшировать на relay?**
- herdr может отдать **устаревший tail** (если процесс в pane ещё пишет)
- revision растёт асинхронно (событие `pane.updated` может придти позже, чем клиент запросил output)
- Нужна стратегия инвалидации: по `pane.output_changed` событию, но между событием и CLI-запросом может пройти время

#### P5: No pagination / infinite scroll
Клиент всегда читает последние **500 строк**. Если пользователь хочет увидеть больше истории:
- Надо менять hardcoded `lines: 500` (некрасиво)
- Нет UI для «load more» / scroll-to-top
- herdr поддерживает чтение с offset (`source: visible/recent/recent_unwrapped`), но relay/клиент не используют

**Use case:**
- Агент сделал 50 tool calls → 2000+ строк вывода
- Клиент показывает только последние 500 → пользователь не видит начало работы
- Хочется: «scroll to top → load previous 500 lines»

---

## 2. Herdr API capabilities (что мы можем использовать)

### 2.1 `pane.read` / `agent.read` параметры (docs/10-herdr-api.md §4.1, §6.3)

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

**Ответ — `PaneReadResult`:**
```json
{
  "type": "pane_read",
  "pane_id": "wH:p3",
  "tab_id": "wH:t1",
  "workspace_id": "wH",
  "source": "recent",
  "format": "ansi",
  "revision": 42,              // ← КЛЮЧЕВОЕ ПОЛЕ
  "text": "...",
  "truncated": false
}
```

**Ключевые факты:**
1. **`revision`** — монотонно растущий счётчик изменений terminal output (herdr bump'ит его при каждом write в PTY)
2. **`truncated`** — true, если terminal scrollback больше, чем запрошено `lines`
3. **`source`** варианты:
   - `recent` — последние N строк (tail)
   - `visible` — что сейчас на экране (viewport)
   - `recent_unwrapped` — последние N строк без line wrapping
   - `detection` — используется для agent detection (нас не интересует)

**Что мы НЕ используем:**
- `revision` в ответе (читаем, но не кэшируем)
- `truncated` (не показываем UI для «load more»)
- `source: visible` (могли бы использовать для «show only viewport», но всегда шлём `recent`)

### 2.2 Event: `pane.updated` несёт PaneInfo с revision

**Из socket подписки** (строка 179-193 `socket_event_repository.go`):
```json
{
  "event": "pane_updated",
  "data": {
    "pane": {
      "pane_id": "wH:p3",
      "revision": 42,          // ← тот же revision, что в PaneReadResult
      "agent_status": "working",
      ...
    }
  }
}
```

Relay извлекает `revision` и кэширует в `lastRevision[paneID]` (строка 190). Затем при `pane.scroll_changed` прикрепляет его к `pane.output_changed`, если revision строго вырос (строка 223-228).

**Проблема:** между `pane.updated(rev=10)` и клиентским `agent.output` RPC может пройти 400ms (debounce), за это время herdr может ещё bump'нуть revision → клиент получит `PaneReadResult{revision: 11}`, но мы его игнорируем.

### 2.3 Scroll metrics: `PaneScrollInfo`

**В `pane.scroll_changed` event** (docs/10-herdr-api.md §5.3):
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

**Семантика:**
- `offset_from_bottom == 0` → пользователь на дне (live tail) → автоскролл
- `offset_from_bottom > 0` → пользователь прокрутил вверх → freeze autoscroll
- `max_offset_from_bottom` → сколько строк истории доступно

**Что это даёт:**
- Можно детектировать, когда пользователь на дне (live tail mode) vs читает историю
- `max_offset_from_bottom` можно использовать для UI «X строк доступно, загружено Y»

**Мы не используем:** scroll metrics полностью игнорируются (relay их не форвардит клиенту).

---

## 3. Предлагаемая архитектура

### 3.1 High-level goals

1. **Снизить latency:** server-side cache → без CLI spawn на каждый запрос
2. **Инкрементальность:** client-side delta updates → меньше parse/render
3. **Pagination:** load more history → scroll to top → fetch older lines
4. **Reliability:** cache invalidation по событиям, fallback на fresh read при miss

### 3.2 Архитектура: three-tier caching

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

**Tradeoff:** Delta computation — строковое сравнение (дорого для 500 строк). **Альтернатива:** herdr не даёт истинного delta API, поэтому:
- **Простой вариант:** всегда возвращать `mode: full` (без delta), но кэшировать на сервере по revision
- **Сложный вариант:** relay держит sliding window последних N строк, при append детектирует по suffix match

**Recommendation:** Начать с **простого варианта** (no delta, только cache by revision). Delta — фаза 2.

---

## 4. Implementation phases

### Phase 1: Server-side cache (low-hanging fruit)

**Goal:** Eliminate subprocess spawn overhead для повторных запросов того же revision.

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
- Запросы с тем же revision → cached response (no CLI spawn)
- При `pane.updated` событии cache инвалидируется → следующий запрос читает fresh
- Latency: 30ms → 1-2ms (cache hit)

**Limitations:**
- Всё ещё читаем full tail (500 строк) при cache miss
- Клиент всё ещё делает full replace (no incremental)

**Risks:**
- Cache invalidation race: событие `pane.updated(rev=10)` пришло, relay инвалидировал cache, но herdr ещё не записал новый output → клиент читает stale
- **Mitigation:** TTL 60s (cache expire даже без событий), fallback на cached при ошибке CLI

**Tests:**
- Unit: `output_cache_test.go` — Get/Set/Invalidate/TTL
- Integration: `agent_service_test.go` — два запроса подряд (второй из cache)
- End-to-end: измерить latency (должно быть <5ms при cache hit)

---

### Phase 2: Client-side revision-based caching

**Goal:** Client skips re-parsing if revision unchanged.

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
- При `pane.output_changed(rev=10)` → client checks cache → if rev==10: skip request entirely
- Latency: 0ms (no network round-trip)

**Limitations:**
- Всё ещё full text replace при revision change (no incremental render)

**Tests:**
- Unit: `agent_repository_test.dart` — два getOutput с тем же revision (второй из cache)
- Widget: `agent_page_test.dart` — output_changed событие с тем же revision → setState не вызывается

---

### Phase 3: Incremental client-side updates (optional, complex)

**Goal:** Append-only updates → no full reparse.

**Approach:**
1. Client держит `List<ParsedLine>` вместо `String _output`
2. При `mode: appended` → парсим только новые строки, append к списку
3. AnsiTerminal принимает `List<InlineSpan>` вместо `String text`

**Challenge:** AnsiTerminal сейчас парсит весь текст в `parse()` (строка 203-247 `ansi_terminal.dart`). Incremental parsing требует:
- State machine для ANSI (current color/bold/italic) на границе старого/нового текста
- Сохранять parsed spans, не только text

**Complexity:** Высокая. **Recommendation:** Отложить до Phase 4+.

**Alternative:** Memoization уже работает (строка 62 `ansi_terminal.dart`) — если текст не изменился, reparse не происходит. При append-only updates текст изменился, но **prefix идентичен** → можно кэшировать parsed spans по prefix hash и переиспользовать.

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

**Problem:** ANSI state bleeding: suffix parse needs to inherit color/bold/italic from end of prefix. Solution: `AnsiTerminalParser` constructor takes `initialState: AnsiState`.

**Effort:** Medium (1-2 days). **Benefit:** 10-30ms saved per append (on 500-line tail).

---

### Phase 4: Pagination / load more history

**Goal:** User can scroll to top → load previous 500 lines.

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
1. **Relay:** Already supports this (herdr CLI accepts `--lines` but NOT `--offset` — **check docs**)
   - **Correction:** herdr CLI `agent read` does NOT have `--offset` flag (проверено в docs/10-herdr-api.md §4.1)
   - herdr socket API: `pane.read` params имеют `source`, но NOT offset
   - **Workaround:** request more lines (`lines: 1000`), client skips first 500 (inefficient)
   
2. **Alternative:** herdr `source: visible` возвращает viewport (24 строки), но это не то
3. **herdr limitation:** нет API для «read lines [N..M]» — только tail (`source: recent`)

**Verdict:** Pagination требует upstream support в herdr API (offset param). Без этого можно:
- Увеличить `lines` hardcoded (например, 1000 вместо 500) → больше истории, но больше latency
- UI «load more» → запросить 1000 строк, показать 1000 вместо 500 (crudely works)

**Phase 4 recommendation:** Wait for herdr API extension или implement workaround с большим `lines`.

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
1. herdr writes to PTY → revision bump (internal)
2. `pane.updated(rev=10)` event sent → relay receives → invalidates cache
3. Client requests `agent.output` **before herdr finished writing**
4. CLI returns stale output (rev=9 text, but labeled rev=10)

**Mitigation:**
- herdr guarantees: `pane.updated` sent **after** revision bump complete
- If race happens: client's next `output_changed` event will have rev=11 → cache miss → fresh read
- **No data loss**, только временный stale read (1 update cycle = 500ms)

### 6.2 Client offline / reconnect
**Scenario:**
1. Client has cached output (rev=10)
2. Disconnect → N updates happen → revision=15
3. Reconnect → `pane.updated(rev=15)` event

**Current behavior:** Client's `_wasDisconnected` flag triggers full refresh (строка 117 `home_page.dart`)

**With cache:** Cache invalidated on disconnect (clear all), fresh read on reconnect.

### 6.3 Multiple clients
**Scenario:** Two clients (phone + web) viewing same agent.

**Relay cache:** Shared across clients → second client benefits from first's fetch.

**Client cache:** Independent → both clients maintain separate revision state (OK).

### 6.4 herdr restart
**Scenario:** herdr daemon restarts → revision counters reset.

**Impact:** Relay cache holds stale paneIDs → first request after restart gets wrong output.

**Mitigation:** TTL 60s → cache expires. Also: relay could detect herdr restart (socket disconnect event) → clear all cache.

---

## 7. Метрики для измерения улучшения

### Before (baseline):
- **Latency per output request:** 30-50ms (subprocess spawn + herdr read)
- **Requests per minute (active agent):** ~20 (при 500ms debounce, 2 events/sec)
- **Total overhead:** 20 × 50ms = **1000ms/min CPU**
- **Client parse time (500 lines):** 20-50ms

### After Phase 1 (server cache):
- **Latency (cache hit):** 2-5ms
- **Cache hit rate:** ~80% (при активном агенте, события часто, но revision меняется реже)
- **Total overhead:** 4 × 50ms + 16 × 5ms = **280ms/min CPU** (72% reduction)

### After Phase 2 (client cache):
- **Latency (revision unchanged):** 0ms (no request)
- **Requests per minute:** ~5 (только при revision change)
- **Total overhead:** 5 × 5ms = **25ms/min CPU** (97% reduction)

### After Phase 3a (incremental parse):
- **Client parse time (append-only):** 2-5ms (только новые строки)
- **Total render latency:** 5ms request + 5ms parse = **10ms** (было 50ms + 20ms = 70ms)

---

## 8. Open questions for discussion

1. **Delta computation complexity:** Is string comparison for 500 lines acceptable? (~1ms on server, but scales O(N²) worst case)
   - **Alternative:** Rely on revision only, no delta (Phase 1+2 без Phase 3)

2. **Pagination without herdr offset API:** Should we request 1000+ lines upfront, or wait for herdr upstream support?
   - **Proposal:** Phase 1-2 first, pagination later (low priority)

3. **Client cache eviction policy:** Keep last N panes (LRU), or all panes with TTL?
   - **Proposal:** Keep all (memory is cheap on client), clear on disconnect

4. **Server cache TTL:** 60s reasonable? Too short (more CLI spawns) vs too long (stale data risk)
   - **Proposal:** 60s, with event-based invalidation (optimal)

5. **Error fallback strategy:** When CLI fails, serve stale cache or return error?
   - **Current:** Return error
   - **Proposal:** Return stale cache with `stale: true` flag, show warning in UI

---

## Приложение A: Code locations reference

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

## Приложение B: Protocol spec (для реализации)

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

**Конец документа.** Ready for review and discussion.
