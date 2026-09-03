# Implementation Plan: Terminal Stream Optimization

**Date:** 2026-08-30  
**Basis:** docs/13-terminal-stream-analysis.md  
**Goal:** Reduce latency by 97%, eliminate subprocess overhead, enable client-side caching

---

## Overview

Three sequential phases, each delivering measurable value:

1. **Phase 1:** Server-side output cache (2-3 days) → 72% latency reduction
2. **Phase 2:** Client-side revision cache (1-2 days) → 97% total reduction
3. **Phase 3:** Incremental parsing (optional, 2-3 days) → further UX improvement

**Total effort:** 5-8 days for Phases 1-2 (core value)

---

## Phase 1: Server-side Output Cache

### 1.1 Goal
Eliminate subprocess spawn overhead for repeated requests within same revision.

### 1.2 Success Criteria
- [ ] Cache hit rate >70% for active agents (measured)
- [ ] Latency <5ms for cache hit (vs 30-50ms baseline)
- [ ] Zero stale data shown to users (verified by tests)
- [ ] Memory usage <50MB for 100 cached panes

### 1.3 Architecture

```
Request flow:
  agent.output RPC
    ↓
  AgentService.GetOutput()
    ↓
  Check OutputCache.Get(paneID)
    ↓
  ├─ Cache HIT + fresh → return cached
  ├─ Cache MISS → CLI spawn → store → return
  └─ Cache STALE → CLI spawn → update → return

Invalidation:
  EventService.broadcast()
    ↓
  if event == pane.updated:
    ↓
  OutputCache.Invalidate(paneID)
```

### 1.4 Files to Create

#### `internal/service/output_cache.go`
```go
package service

import (
	"sync"
	"time"
)

// OutputCache holds recently fetched terminal output to avoid repeated CLI spawns.
// Entries are invalidated on pane.updated events and expire after TTL.
type OutputCache struct {
	mu      sync.RWMutex
	entries map[string]*CachedOutput
	ttl     time.Duration
}

// CachedOutput stores one pane's terminal output snapshot.
type CachedOutput struct {
	Text      string
	Revision  int       // from PaneReadResult
	FetchedAt time.Time
}

// NewOutputCache creates a cache with the given TTL (recommended: 60s).
func NewOutputCache(ttl time.Duration) *OutputCache {
	c := &OutputCache{
		entries: make(map[string]*CachedOutput),
		ttl:     ttl,
	}
	go c.cleanupLoop()
	return c
}

// Get retrieves cached output if present and fresh.
// Returns nil if not found or expired.
func (c *OutputCache) Get(paneID string) *CachedOutput {
	c.mu.RLock()
	defer c.mu.RUnlock()
	
	entry := c.entries[paneID]
	if entry == nil {
		return nil
	}
	
	// Check TTL
	if time.Since(entry.FetchedAt) > c.ttl {
		return nil
	}
	
	return entry
}

// Set stores output in the cache.
func (c *OutputCache) Set(paneID string, text string, revision int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	
	c.entries[paneID] = &CachedOutput{
		Text:      text,
		Revision:  revision,
		FetchedAt: time.Now(),
	}
}

// Invalidate removes an entry (called on pane.updated events).
func (c *OutputCache) Invalidate(paneID string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.entries, paneID)
}

// Clear removes all entries (called on herdr restart).
func (c *OutputCache) Clear() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.entries = make(map[string]*CachedOutput)
}

// Size returns the number of cached entries (for metrics).
func (c *OutputCache) Size() int {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return len(c.entries)
}

// cleanupLoop runs in a goroutine, evicting expired entries every minute.
func (c *OutputCache) cleanupLoop() {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	
	for range ticker.C {
		c.evictExpired()
	}
}

func (c *OutputCache) evictExpired() {
	c.mu.Lock()
	defer c.mu.Unlock()
	
	now := time.Now()
	for paneID, entry := range c.entries {
		if now.Sub(entry.FetchedAt) > c.ttl {
			delete(c.entries, paneID)
		}
	}
}
```

#### `internal/service/output_cache_test.go`
```go
package service

import (
	"testing"
	"time"
)

func TestOutputCache_GetSet(t *testing.T) {
	cache := NewOutputCache(time.Hour)
	
	// Cache miss
	if got := cache.Get("p1"); got != nil {
		t.Errorf("expected nil, got %v", got)
	}
	
	// Store
	cache.Set("p1", "hello\nworld\n", 42)
	
	// Cache hit
	got := cache.Get("p1")
	if got == nil {
		t.Fatal("expected cache hit, got nil")
	}
	if got.Text != "hello\nworld\n" {
		t.Errorf("text mismatch: got %q", got.Text)
	}
	if got.Revision != 42 {
		t.Errorf("revision mismatch: got %d", got.Revision)
	}
}

func TestOutputCache_Invalidate(t *testing.T) {
	cache := NewOutputCache(time.Hour)
	cache.Set("p1", "text", 10)
	
	cache.Invalidate("p1")
	
	if got := cache.Get("p1"); got != nil {
		t.Errorf("expected nil after invalidate, got %v", got)
	}
}

func TestOutputCache_TTL(t *testing.T) {
	cache := NewOutputCache(100 * time.Millisecond)
	cache.Set("p1", "text", 10)
	
	// Immediate: hit
	if got := cache.Get("p1"); got == nil {
		t.Error("expected hit immediately after Set")
	}
	
	// After TTL: miss
	time.Sleep(150 * time.Millisecond)
	if got := cache.Get("p1"); got != nil {
		t.Errorf("expected miss after TTL, got %v", got)
	}
}

func TestOutputCache_EvictExpired(t *testing.T) {
	cache := NewOutputCache(50 * time.Millisecond)
	cache.Set("p1", "old", 1)
	time.Sleep(60 * time.Millisecond)
	cache.Set("p2", "fresh", 2)
	
	cache.evictExpired()
	
	if cache.Size() != 1 {
		t.Errorf("expected 1 entry after eviction, got %d", cache.Size())
	}
	if got := cache.Get("p1"); got != nil {
		t.Error("old entry should be evicted")
	}
	if got := cache.Get("p2"); got == nil {
		t.Error("fresh entry should remain")
	}
}

func TestOutputCache_Clear(t *testing.T) {
	cache := NewOutputCache(time.Hour)
	cache.Set("p1", "a", 1)
	cache.Set("p2", "b", 2)
	
	cache.Clear()
	
	if cache.Size() != 0 {
		t.Errorf("expected 0 entries after Clear, got %d", cache.Size())
	}
}
```

### 1.5 Files to Modify

#### `internal/service/agent_service.go`
**Location:** Line 9-16 (struct definition)

**Change 1: Add outputCache field**
```go
// AgentService provides business logic for agent operations.
type AgentService struct {
	repo        repository.AgentRepository
	outputCache *OutputCache  // NEW: cache for terminal output
}

// NewAgentService creates a new agent service.
func NewAgentService(repo repository.AgentRepository) *AgentService {
	return &AgentService{
		repo:        repo,
		outputCache: NewOutputCache(60 * time.Second),  // NEW: 60s TTL
	}
}
```

**Change 2: Modify GetOutput method**
**Location:** Line 23-41

**Before:**
```go
func (s *AgentService) GetOutput(target string, lines int, format string) (*domain.AgentOutput, error) {
	if lines <= 0 {
		lines = 200
	}
	if format == "" {
		format = "text"
	}

	output, err := s.repo.ReadOutput(target, lines, format)
	if err != nil {
		return nil, err
	}

	return &domain.AgentOutput{
		Target: target,
		Output: output,
	}, nil
}
```

**After:**
```go
func (s *AgentService) GetOutput(target string, lines int, format string) (*domain.AgentOutput, error) {
	if lines <= 0 {
		lines = 200
	}
	if format == "" {
		format = "text"
	}

	// Try cache first
	cached := s.outputCache.Get(target)
	
	// Always fetch fresh (we need revision from response)
	output, err := s.repo.ReadOutput(target, lines, format)
	if err != nil {
		// On error: fall back to cached if available
		if cached != nil {
			log.Printf("agent service: CLI error, serving cached output for %s: %v", target, err)
			return &domain.AgentOutput{
				Target: target,
				Output: cached.Text,
			}, nil
		}
		return nil, err
	}

	// Parse revision from output
	// herdr CLI returns JSON: {"result":{"type":"pane_read","revision":N,"text":"..."}}
	revision := extractRevisionFromCLIOutput(output)
	
	// Update cache
	s.outputCache.Set(target, output, revision)

	return &domain.AgentOutput{
		Target: target,
		Output: output,
	}, nil
}

// extractRevisionFromCLIOutput parses the herdr CLI JSON response to get revision.
// If parsing fails, returns 0 (cache will still work, just without revision tracking).
func extractRevisionFromCLIOutput(output string) int {
	// herdr CLI wraps pane_read result: {"result":{"type":"pane_read","revision":42,...}}
	var envelope struct {
		Result struct {
			Revision int `json:"revision"`
		} `json:"result"`
	}
	
	if err := json.Unmarshal([]byte(output), &envelope); err != nil {
		// Not JSON or unexpected format; skip revision
		return 0
	}
	
	return envelope.Result.Revision
}
```

**Problem discovered:** `repo.ReadOutput` returns `string`, not structured JSON. Need to check actual CLI output format.

**Investigation needed:**
```bash
herdr agent read <pane_id> --lines 10 --format ansi
```

Check if it returns:
- **Option A:** Raw text (just the terminal output)
- **Option B:** JSON envelope with metadata

**Looking at cli_repository.go:96-105:**
```go
func (r *CLIRepository) ReadOutput(target string, lines int, format string) (string, error) {
	out, err := r.run("agent", "read", target, "--lines", fmt.Sprintf("%d", lines), "--format", format)
	return string(out), nil  // returns raw stdout
}
```

It returns **raw stdout** from `herdr agent read`. Need to check herdr CLI behavior.

**Checking docs/10-herdr-api.md §8:**
> `herdr api snapshot` → `{"result":{"snapshot":…}}`  
> `agent read <target> --lines N --format <text|ansi>` — **not specified** whether it returns JSON or raw text

**Action:** Need to test herdr CLI to confirm output format.

**Assumption for now:** CLI returns **raw text** (no JSON wrapper). This means:
- **No revision in CLI output** → cannot extract revision from response
- **Must use socket events for revision tracking**

**Updated approach:**
1. OutputCache stores text, but **no revision** (we don't have it from CLI)
2. Invalidation on **any** `pane.updated` event (we don't check revision)
3. Cache simply reduces CLI spawns, but doesn't do semantic caching by revision

**Revised GetOutput:**
```go
func (s *AgentService) GetOutput(target string, lines int, format string) (*domain.AgentOutput, error) {
	if lines <= 0 {
		lines = 200
	}
	if format == "" {
		format = "text"
	}

	// Try cache first (simple time-based + event-based invalidation)
	cached := s.outputCache.Get(target)
	if cached != nil {
		// Cache hit: return immediately (no CLI spawn)
		return &domain.AgentOutput{
			Target: target,
			Output: cached.Text,
		}, nil
	}
	
	// Cache miss or expired: fetch fresh
	output, err := s.repo.ReadOutput(target, lines, format)
	if err != nil {
		return nil, err
	}

	// Store in cache (revision=0, only TTL-based expiry)
	s.outputCache.Set(target, output, 0)

	return &domain.AgentOutput{
		Target: target,
		Output: output,
	}, nil
}
```

**Trade-off:** Cache isn't semantic (no revision check), but still gives 70%+ hit rate thanks to:
- TTL 60s
- Event-based invalidation on `pane.updated`

#### `internal/service/event_service.go`
**Location:** Line 99-113 (broadcast method)

**Change: Add cache invalidation**

**Before:**
```go
func (s *EventService) broadcast(event domain.Event) {
	s.mu.RLock()
	listeners := make([]*eventListener, len(s.listeners))
	copy(listeners, s.listeners)
	s.mu.RUnlock()

	for _, listener := range listeners {
		select {
		case listener.ch <- event:
		default:
			log.Printf("event service: listener blocked, dropping event %s", event.EventName())
		}
	}
}
```

**After:**
```go
func (s *EventService) broadcast(event domain.Event) {
	s.mu.RLock()
	listeners := make([]*eventListener, len(s.listeners))
	copy(listeners, s.listeners)
	s.mu.RUnlock()

	for _, listener := range listeners {
		select {
		case listener.ch <- event:
		default:
			log.Printf("event service: listener blocked, dropping event %s", event.EventName())
		}
	}
	
	// NEW: Invalidate output cache on pane updates
	s.invalidateCacheOnEvent(event)
}

func (s *EventService) invalidateCacheOnEvent(event domain.Event) {
	// pane.updated → output may have changed → invalidate cache
	if evt, ok := event.(domain.PaneUpdatedEvent); ok {
		if s.agentService != nil && s.agentService.outputCache != nil {
			s.agentService.outputCache.Invalidate(evt.PaneID)
		}
		return
	}
	
	// agent_status_changed → output likely unchanged, but revision may advance
	// (we invalidate conservatively to ensure fresh read on next request)
	if evt, ok := event.(domain.AgentStatusChangedEvent); ok {
		if s.agentService != nil && s.agentService.outputCache != nil {
			s.agentService.outputCache.Invalidate(evt.PaneID)
		}
		return
	}
}
```

**Problem:** EventService doesn't have reference to AgentService (circular dependency risk).

**Solution:** Pass outputCache reference during EventService creation, or use an interface.

**Better approach:** EventService emits events, separate component subscribes and invalidates cache.

**Revised architecture:**
```go
// In cmd/relay/main.go, wire up cache invalidation:
eventService.OnEvent(func(event domain.Event) {
	if evt, ok := event.(domain.PaneUpdatedEvent); ok {
		agentService.outputCache.Invalidate(evt.PaneID)
	}
})
```

**But:** EventService doesn't have OnEvent callback mechanism.

**Cleanest solution:** EventService.broadcast() accepts optional callback, or AgentService subscribes to events.

**Pragmatic solution for Phase 1:** Add AgentService reference to EventService (acceptable, they're both in service layer).

**Updated EventService struct:**
```go
type EventService struct {
	eventRepo    repository.EventRepository
	agentService *AgentService  // NEW: for cache invalidation
	mu           sync.RWMutex
	listeners    []*eventListener
	started      bool
	stopCh       chan struct{}
}
```

**Constructor change:**
```go
func NewEventService(eventRepo repository.EventRepository, agentService *AgentService) *EventService {
	return &EventService{
		eventRepo:    eventRepo,
		agentService: agentService,  // NEW
		listeners:    make([]*eventListener, 0),
		stopCh:       make(chan struct{}),
	}
}
```

**Wire-up in cmd/relay/main.go:**
```go
agentService := service.NewAgentService(agentRepo)
eventService := service.NewEventService(eventRepo, agentService)  // pass agentService
```

#### `cmd/relay/main.go`
**Location:** Line 40-45 (service initialization)

**Before:**
```go
agentService := service.NewAgentService(agentRepo)
eventService := service.NewEventService(eventRepo)
pairingService := service.NewPairingService(...)
```

**After:**
```go
agentService := service.NewAgentService(agentRepo)
eventService := service.NewEventService(eventRepo, agentService)  // NEW: pass agentService
pairingService := service.NewPairingService(...)
```

### 1.6 Testing Strategy

#### Unit tests (internal/service/output_cache_test.go)
- [x] Get/Set/Invalidate basic operations
- [x] TTL expiration
- [x] Cleanup loop eviction
- [x] Clear all entries

#### Integration tests (internal/service/agent_service_test.go - NEW FILE)
```go
package service

import (
	"testing"
	"time"
	"herdrelay/internal/domain"
)

type stubAgentRepo struct {
	readCount int
	output    string
}

func (r *stubAgentRepo) ReadOutput(target string, lines int, format string) (string, error) {
	r.readCount++
	return r.output, nil
}

func (r *stubAgentRepo) Snapshot() (*domain.Snapshot, error) { return nil, nil }
func (r *stubAgentRepo) SendKeys(target string, keys []string) error { return nil }
func (r *stubAgentRepo) SendPrompt(target, text string) error { return nil }
func (r *stubAgentRepo) SendText(paneID, text string) error { return nil }
func (r *stubAgentRepo) StartAgent(name, kind, paneID string) error { return nil }
func (r *stubAgentRepo) CreateWorkspace(label, cwd string) (string, string, error) { return "", "", nil }
func (r *stubAgentRepo) ReadPaneOutput(paneID string, lines int, format string) (string, error) { return "", nil }

func TestAgentService_GetOutput_CacheHit(t *testing.T) {
	repo := &stubAgentRepo{output: "hello\nworld\n"}
	svc := NewAgentService(repo)
	
	// First call: cache miss → CLI
	out1, err := svc.GetOutput("p1", 10, "text")
	if err != nil {
		t.Fatal(err)
	}
	if repo.readCount != 1 {
		t.Errorf("expected 1 CLI call, got %d", repo.readCount)
	}
	
	// Second call: cache hit → no CLI
	out2, err := svc.GetOutput("p1", 10, "text")
	if err != nil {
		t.Fatal(err)
	}
	if repo.readCount != 1 {
		t.Errorf("expected still 1 CLI call (cache hit), got %d", repo.readCount)
	}
	
	if out1.Output != out2.Output {
		t.Error("cache should return same output")
	}
}

func TestAgentService_GetOutput_Invalidation(t *testing.T) {
	repo := &stubAgentRepo{output: "old"}
	svc := NewAgentService(repo)
	
	// First call
	svc.GetOutput("p1", 10, "text")
	
	// Invalidate
	svc.outputCache.Invalidate("p1")
	
	// Second call: cache miss → new CLI
	repo.output = "new"
	out, err := svc.GetOutput("p1", 10, "text")
	if err != nil {
		t.Fatal(err)
	}
	if out.Output != "new" {
		t.Errorf("expected fresh output after invalidation, got %q", out.Output)
	}
	if repo.readCount != 2 {
		t.Errorf("expected 2 CLI calls (miss + invalidate), got %d", repo.readCount)
	}
}

func TestAgentService_GetOutput_TTL(t *testing.T) {
	repo := &stubAgentRepo{output: "text"}
	svc := NewAgentService(repo)
	svc.outputCache.ttl = 50 * time.Millisecond
	
	// First call
	svc.GetOutput("p1", 10, "text")
	
	// Wait for TTL
	time.Sleep(60 * time.Millisecond)
	
	// Second call: expired → new CLI
	svc.GetOutput("p1", 10, "text")
	
	if repo.readCount != 2 {
		t.Errorf("expected 2 CLI calls (initial + after TTL), got %d", repo.readCount)
	}
}
```

#### End-to-end test (cmd/relay/server_test.go)
Add test case:
```go
func TestOutputCacheIntegration(t *testing.T) {
	// Start relay with real OutputCache
	// Make two agent.output RPC calls for same pane
	// Verify second call is faster (<10ms vs >20ms)
	// Emit pane.updated event
	// Verify third call refetches (readCount increments)
}
```

#### Manual testing checklist
- [ ] Start relay + herdr
- [ ] Client: open AgentPage
- [ ] Watch agent output stream (should see debounced updates)
- [ ] Check relay logs: cache hits logged
- [ ] Measure latency: `time curl -H "Authorization: Bearer $TOKEN" http://localhost:8080/api/agents/p1/output`
  - First call: >30ms
  - Second call (within 60s): <5ms
- [ ] Trigger pane.updated event (type in terminal) → verify cache invalidated (next call >30ms)

### 1.7 Metrics & Monitoring

Add to AgentService:
```go
type AgentServiceMetrics struct {
	OutputRequests     int64
	OutputCacheHits    int64
	OutputCacheMisses  int64
	OutputErrors       int64
}

func (s *AgentService) Metrics() AgentServiceMetrics {
	return AgentServiceMetrics{
		OutputRequests:    atomic.LoadInt64(&s.metrics.outputRequests),
		OutputCacheHits:   atomic.LoadInt64(&s.metrics.outputCacheHits),
		OutputCacheMisses: atomic.LoadInt64(&s.metrics.outputCacheMisses),
		OutputErrors:      atomic.LoadInt64(&s.metrics.outputErrors),
	}
}
```

Expose via `/metrics` endpoint (optional, for observability):
```go
// internal/transport/http/handler.go
func (h *Handler) HandleMetrics(w http.ResponseWriter, r *http.Request) {
	metrics := h.agentService.Metrics()
	hitRate := 0.0
	if metrics.OutputRequests > 0 {
		hitRate = float64(metrics.OutputCacheHits) / float64(metrics.OutputRequests) * 100
	}
	
	fmt.Fprintf(w, "output_requests_total %d\n", metrics.OutputRequests)
	fmt.Fprintf(w, "output_cache_hits_total %d\n", metrics.OutputCacheHits)
	fmt.Fprintf(w, "output_cache_misses_total %d\n", metrics.OutputCacheMisses)
	fmt.Fprintf(w, "output_cache_hit_rate %.2f\n", hitRate)
	fmt.Fprintf(w, "output_errors_total %d\n", metrics.OutputErrors)
}
```

### 1.8 Rollout Plan

1. **PR 1: Core cache implementation**
   - output_cache.go + tests
   - Merge, but not wired up yet (no behavior change)

2. **PR 2: Wire cache into AgentService**
   - Modify agent_service.go
   - Integration tests
   - Feature flag: `HERDRELAY_OUTPUT_CACHE=true` (default: false)

3. **PR 3: Event-based invalidation**
   - Modify event_service.go
   - Wire in main.go
   - Enable feature flag by default

4. **Monitoring & tuning**
   - Collect metrics for 1 week
   - Adjust TTL if needed (60s → 30s or 120s)
   - Document cache hit rate in CHANGELOG

### 1.9 Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Cache serves stale data | Users see old output | TTL 60s + event invalidation ensures max 60s staleness; acceptable for terminal output |
| Memory growth (many panes) | OOM on relay | Cleanup loop + TTL eviction; 100 panes × 50KB each = 5MB (negligible) |
| Race: invalidate before CLI completes | Stale cache entry | Next update cycle (500ms) will refetch; temporary staleness OK |
| Circular dependency EventService ↔ AgentService | Maintenance burden | Acceptable for Phase 1; refactor in Phase 3 if needed |

---

## Phase 2: Client-side Revision Cache

### 2.1 Goal
Client skips unnecessary RPC calls when revision unchanged.

### 2.2 Success Criteria
- [ ] Client makes 80% fewer RPC calls (measured)
- [ ] No visual glitches (output doesn't disappear during cache hit)
- [ ] Memory usage <10MB for 20 cached panes

### 2.3 Architecture

```
Client state:
  Map<paneID, CachedOutput>
    - revision: int
    - text: String
    - timestamp: DateTime

Flow:
  1. pane.output_changed(rev=10) event arrives
  2. Check cache: if cached.revision == 10 → skip RPC
  3. Else: RPC agent.output → store in cache
  4. Render from cache
```

### 2.4 Protocol Change

**Problem:** Current `agent.output` RPC response doesn't include revision.

**Solution:** Add revision to response.

#### Modify relay: `internal/domain/agent.go`
**NEW FILE:**
```go
package domain

// AgentOutput holds terminal output plus metadata.
type AgentOutput struct {
	Target   string
	Output   string
	Revision int  // NEW: from PaneReadResult or 0 if unavailable
}
```

Wait, `AgentOutput` already exists. Check current definition.

**Checking internal/service/agent_service.go:32-40:**
```go
return &domain.AgentOutput{
	Target: target,
	Output: output,
}, nil
```

So `domain.AgentOutput` already exists. Need to find its definition.

**Finding:** No separate file, it's inline in service. Let's check `internal/domain/` directory.

**Action:** Assume `AgentOutput` is defined somewhere. Need to add `Revision int` field.

**Creating domain file:**

#### `internal/domain/agent.go` (NEW or modify existing)
```go
package domain

// AgentOutput represents terminal output from an agent/pane.
type AgentOutput struct {
	Target   string `json:"target"`
	Output   string `json:"output"`
	Revision int    `json:"revision,omitempty"`  // NEW: 0 if unknown
}
```

#### Modify `internal/service/agent_service.go:GetOutput`

Change return type to populate Revision:
```go
func (s *AgentService) GetOutput(target string, lines int, format string) (*domain.AgentOutput, error) {
	// ... (cache check logic from Phase 1)
	
	// Fetch fresh
	output, err := s.repo.ReadOutput(target, lines, format)
	if err != nil {
		return nil, err
	}

	// Try to extract revision from output (if herdr CLI returns JSON)
	revision := 0  // default: unknown
	// TODO: parse revision if available
	
	// Store in cache
	s.outputCache.Set(target, output, revision)

	return &domain.AgentOutput{
		Target:   target,
		Output:   output,
		Revision: revision,  // NEW
	}, nil
}
```

**Problem:** We still don't have revision from CLI (herdr returns raw text).

**Alternative:** Get revision from last `pane.updated` event.

**Solution:** AgentService subscribes to events, tracks `lastKnownRevision[paneID]`.

#### Revised approach: Track revision from events

Add to `internal/service/agent_service.go`:
```go
type AgentService struct {
	repo              repository.AgentRepository
	outputCache       *OutputCache
	lastKnownRevision map[string]int  // NEW: paneID -> last revision from pane.updated
	revisionMu        sync.RWMutex
}

func NewAgentService(repo repository.AgentRepository) *AgentService {
	return &AgentService{
		repo:              repo,
		outputCache:       NewOutputCache(60 * time.Second),
		lastKnownRevision: make(map[string]int),
	}
}

// UpdateRevision is called by EventService when pane.updated arrives.
func (s *AgentService) UpdateRevision(paneID string, revision int) {
	s.revisionMu.Lock()
	defer s.revisionMu.Unlock()
	s.lastKnownRevision[paneID] = revision
}

func (s *AgentService) GetOutput(target string, lines int, format string) (*domain.AgentOutput, error) {
	// ... fetch logic ...
	
	// Get last known revision
	s.revisionMu.RLock()
	revision := s.lastKnownRevision[target]
	s.revisionMu.RUnlock()
	
	return &domain.AgentOutput{
		Target:   target,
		Output:   output,
		Revision: revision,
	}, nil
}
```

#### Wire in `internal/service/event_service.go`:
```go
func (s *EventService) invalidateCacheOnEvent(event domain.Event) {
	if evt, ok := event.(domain.PaneUpdatedEvent); ok {
		if s.agentService != nil {
			s.agentService.outputCache.Invalidate(evt.PaneID)
			s.agentService.UpdateRevision(evt.PaneID, evt.Revision)  // NEW
		}
		return
	}
	// ...
}
```

**But:** `PaneUpdatedEvent` doesn't have `Revision` field currently.

**Check internal/domain/event.go:34-46:**
```go
type PaneUpdatedEvent struct {
	PaneID string          `json:"pane_id"`
	Data   json.RawMessage `json:"data,omitempty"`
}
```

`Data` contains full PaneInfo JSON. Need to parse it.

**Solution:** Parse Data to extract revision.

```go
func (s *EventService) invalidateCacheOnEvent(event domain.Event) {
	if evt, ok := event.(domain.PaneUpdatedEvent); ok {
		// Parse PaneInfo from Data
		var paneInfo struct {
			Revision int `json:"revision"`
		}
		if err := json.Unmarshal(evt.Data, &paneInfo); err == nil {
			if s.agentService != nil {
				s.agentService.UpdateRevision(evt.PaneID, paneInfo.Revision)
			}
		}
		
		if s.agentService != nil {
			s.agentService.outputCache.Invalidate(evt.PaneID)
		}
		return
	}
	// ...
}
```

### 2.5 Client-side Changes

#### Modify `client/lib/services/relay_client.dart`

**Current signature:**
```dart
Future<String> output(String agentId, {int lines = 500, String format = 'ansi'});
```

**New signature:**
```dart
Future<AgentOutputResult> output(String agentId, {int lines = 500, String format = 'ansi'});

class AgentOutputResult {
  final String text;
  final int revision;  // 0 if unknown
  
  AgentOutputResult(this.text, this.revision);
}
```

#### Modify `client/lib/services/relay_client_impl.dart`

**Before:**
```dart
@override
Future<String> output(String agentId, {int lines = 500, String format = 'ansi'}) async {
  final result = await _rpc.request('agent.output', {
    'target': agentId,
    'lines': lines,
    'format': format,
  });
  return result['output'] as String;
}
```

**After:**
```dart
@override
Future<AgentOutputResult> output(String agentId, {int lines = 500, String format = 'ansi'}) async {
  final result = await _rpc.request('agent.output', {
    'target': agentId,
    'lines': lines,
    'format': format,
  });
  return AgentOutputResult(
    result['output'] as String,
    result['revision'] as int? ?? 0,
  );
}
```

#### Modify `client/lib/repositories/agent_repository.dart`

**Add cache:**
```dart
class AgentRepository {
  final RelayClient _client;
  final SharedPreferences _prefs;
  
  // NEW: in-memory output cache
  final Map<String, _CachedOutput> _outputCache = {};

  // ... existing code ...
  
  Future<String> getOutput(String agentId, {int lines = 500}) async {
    final cached = _outputCache[agentId];
    
    // Fetch from relay
    final result = await _client.output(agentId, lines: lines, format: 'ansi');
    
    // If revision matches cache: return cached (skip parse)
    if (cached != null && cached.revision == result.revision && result.revision > 0) {
      return cached.text;
    }
    
    // Update cache
    _outputCache[agentId] = _CachedOutput(result.text, result.revision);
    
    return result.text;
  }
}

class _CachedOutput {
  final String text;
  final int revision;
  
  _CachedOutput(this.text, this.revision);
}
```

#### Modify `client/lib/pages/agent_page.dart`

**No change needed** — `getOutput` now returns cached text automatically.

**But:** We want to skip the RPC entirely, not just skip parse.

**Better approach:** Check cache **before** RPC.

```dart
Future<String> getOutput(String agentId, {int lines = 500, int? knownRevision}) async {
  // If caller provides knownRevision and it matches cache: skip RPC
  final cached = _outputCache[agentId];
  if (knownRevision != null && cached != null && cached.revision == knownRevision) {
    return cached.text;  // no RPC, instant return
  }
  
  // Fetch from relay
  final result = await _client.output(agentId, lines: lines, format: 'ansi');
  
  // Update cache
  _outputCache[agentId] = _CachedOutput(result.text, result.revision);
  
  return result.text;
}
```

**AgentPage usage:**
```dart
void _onEvent(RelayEvent event) {
  if (event is OutputChanged) {
    if (event.paneId != _agent.id) return;
    
    // Check revision guard (existing logic, now actually works)
    if (event.revision > 0) {
      if (_lastRevision != null && event.revision <= _lastRevision!) return;
      _lastRevision = event.revision;
    }
    
    // Debounced refresh
    _outputDebounce?.cancel();
    _outputDebounce = Timer(const Duration(milliseconds: 400), () {
      // Pass known revision to skip RPC if cache matches
      _refresh(silent: true, knownRevision: event.revision);
    });
    return;
  }
  // ...
}

Future<void> _refresh({bool silent = false, int? knownRevision}) async {
  if (!silent) {
    setState(() => _loading = true);
  }
  try {
    final output = await _repository.getOutput(
      _agent.id,
      lines: 500,
      knownRevision: knownRevision,  // NEW
    );
    // ... render output ...
  } catch (e) {
    // ...
  }
}
```

### 2.6 Testing

#### Unit tests
```dart
// client/test/repositories/agent_repository_test.dart
test('getOutput skips RPC when revision matches', () async {
  final client = FakeRelayClient();
  final repo = AgentRepository(client, mockPrefs);
  
  // First call: cache miss
  await repo.getOutput('p1', lines: 10);
  expect(client.callCount, 1);
  
  // Second call with same revision: skip RPC
  await repo.getOutput('p1', lines: 10, knownRevision: 42);
  expect(client.callCount, 1);  // still 1 (no second RPC)
});
```

#### Integration test
- Client subscribes to events
- Receive `pane.output_changed(rev=10)`
- Call `getOutput(knownRevision: 10)`
- Verify no RPC sent (mock transport, check send() not called)

### 2.7 Rollout

1. **Server changes first** (relay returns revision)
   - Merge Phase 1 + revision tracking
   - Deploy to staging
   - Verify `/api/agents/p1/output` response includes `"revision": N`

2. **Client changes** (skip RPC on cache hit)
   - Update relay_client.dart signatures
   - Update agent_repository.dart caching
   - Ship app update

3. **Monitor metrics**
   - Server: `output_requests_total` should drop by 70-80%
   - Client: latency for output updates <10ms (was 50-100ms)

---

## Phase 3: Incremental ANSI Parsing (Optional)

### 3.1 Goal
When output appends (common case), parse only new lines instead of full 500-line tail.

### 3.2 Complexity Assessment

**Challenges:**
1. ANSI state continuity: color/bold at end of old text must carry into new text
2. Carriage returns (`\r`) can overwrite previous lines → not always append-only
3. Parser state is complex: `_AnsiState` (fg/bg/bold/italic/underline)

**Benefit:** 10-30ms saved per update on mobile (parse 10 new lines vs 500 total)

**Effort:** 2-3 days

**Recommendation:** Defer to Phase 4 after measuring actual parse times in production.

### 3.3 Implementation Sketch (if pursuing)

#### Modify `client/lib/widgets/ansi_terminal.dart`

**Add state preservation:**
```dart
class _AnsiTerminalState extends State<AnsiTerminal> {
  String? _cacheText;
  List<InlineSpan>? _cacheSpans;
  _AnsiState? _cacheFinalState;  // NEW: ANSI state at end of cached text
  
  @override
  Widget build(BuildContext context) {
    final base = widget.style ?? AnsiTerminal.defaultStyle;
    
    // Full cache hit: return cached widget
    if (widget.text == _cacheText && base == _cacheStyle) {
      return _cachedSelectable!;
    }
    
    // Append-only check: text is prefix + suffix
    if (_cacheText != null && widget.text.startsWith(_cacheText!)) {
      final suffix = widget.text.substring(_cacheText!.length);
      
      // Parse only suffix, starting with cached ANSI state
      final parser = AnsiTerminalParser(
        suffix,
        baseStyle: base,
        initialState: _cacheFinalState,  // NEW
      );
      final newSpans = parser.parse();
      
      // Append to cached spans
      final allSpans = [..._cacheSpans!, ...newSpans];
      
      // Update cache
      _cacheText = widget.text;
      _cacheSpans = allSpans;
      _cacheFinalState = parser.finalState;  // NEW: preserve state for next append
      _cachedSelectable = SelectableText.rich(TextSpan(children: allSpans), style: base);
      
      return _cachedSelectable!;
    }
    
    // Not append-only: full reparse
    final parser = AnsiTerminalParser(widget.text, baseStyle: base);
    final spans = parser.parse();
    _cacheText = widget.text;
    _cacheStyle = base;
    _cacheSpans = spans;
    _cacheFinalState = parser.finalState;
    _cachedSelectable = SelectableText.rich(TextSpan(children: spans), style: base);
    
    return Container(
      color: widget.backgroundColor,
      child: SingleChildScrollView(
        controller: widget.controller,
        padding: widget.padding,
        physics: const AlwaysScrollableScrollPhysics(),
        child: _cachedSelectable!,
      ),
    );
  }
}
```

**Add to AnsiTerminalParser:**
```dart
class AnsiTerminalParser {
  final String input;
  final TextStyle baseStyle;
  final _AnsiState? initialState;  // NEW: start from this state
  
  _AnsiState? finalState;  // NEW: exposed after parse()
  
  AnsiTerminalParser(this.input, {required this.baseStyle, this.initialState});
  
  List<InlineSpan> parse() {
    final st = initialState ?? _AnsiState();  // NEW: use initial state if provided
    // ... existing parse logic ...
    
    finalState = st;  // NEW: save final state
    return _buildSpans(lines);
  }
}
```

**Testing:**
```dart
test('incremental parse preserves ANSI state', () {
  // Parse prefix with red text
  final parser1 = AnsiTerminalParser('\x1b[31mRed', baseStyle: baseStyle);
  final spans1 = parser1.parse();
  
  // Parse suffix (should inherit red from prefix)
  final parser2 = AnsiTerminalParser(' Text', baseStyle: baseStyle, initialState: parser1.finalState);
  final spans2 = parser2.parse();
  
  // Verify " Text" is also red
  expect((spans2.first as TextSpan).style?.color, Colors.red);
});
```

### 3.4 Deferral Justification

**Reasons to defer:**
1. Memoization already works (text identical → no reparse)
2. Phase 1+2 give 97% latency reduction without touching parser
3. Parse time (20-50ms) is small compared to network (50ms) — not the bottleneck
4. Risk of ANSI state bugs (text renders with wrong colors)

**Proceed with Phase 3 only if:**
- Production metrics show parse time >100ms (unlikely)
- Users report visible lag when scrolling output (not seen in testing)

---

## Success Metrics & Acceptance Criteria

### Phase 1 Success:
- [ ] Cache hit rate >70% (measured via `/metrics`)
- [ ] p50 latency for cached requests <5ms (was 30-50ms)
- [ ] p99 latency for cache miss <100ms (unchanged from baseline)
- [ ] Zero stale data bugs reported in 2-week staging period
- [ ] Memory usage <10MB for relay process (100 cached panes)

### Phase 2 Success:
- [ ] Client RPC call rate drops by 80% (measured via relay logs)
- [ ] p50 end-to-end output update latency <10ms (was 50-100ms)
- [ ] No visual glitches reported (output doesn't flash/disappear)
- [ ] Client memory usage <5MB for output cache (20 agents)

### Overall Success:
- [ ] **97% total latency reduction** (baseline 70ms → 2ms)
- [ ] User-visible improvement: output updates feel instant
- [ ] Zero production incidents related to caching
- [ ] Code maintainability: tests pass, documented, reviewed

---

## Timeline

| Phase | Duration | Deliverables |
|---|---|---|
| Phase 1 | 3 days | output_cache.go, agent_service.go changes, tests, metrics |
| Phase 1 review | 1 day | Code review, address feedback |
| Phase 1 deploy | 1 day | Staging → production, monitor metrics |
| Phase 2 | 2 days | Revision tracking, client cache, protocol changes |
| Phase 2 review | 1 day | Code review |
| Phase 2 deploy | 1 day | Client app update, monitor |
| **Total** | **9 days** | **Phases 1-2 complete** |

Phase 3 (incremental parsing): Deferred, revisit in Q4 if needed.

---

## Open Questions & Decisions Needed

1. **CLI output format:** Does `herdr agent read` return JSON or raw text?
   - **Action:** Test manually: `herdr agent read <pane> --lines 10 --format ansi`
   - **Impact:** Determines if we can extract revision from CLI response

2. **Cache TTL:** 60s optimal, or tune to 30s/120s?
   - **Action:** Start with 60s, monitor hit rate, adjust if needed

3. **Event-based invalidation granularity:** Invalidate on `pane.updated` only, or also on `agent_status_changed`?
   - **Proposal:** Both (conservative, ensures freshness)

4. **Client cache eviction:** When to clear cache (memory pressure)?
   - **Proposal:** Never clear (memory is cheap), but could add LRU if needed

5. **Metrics endpoint:** Expose `/metrics` or keep internal logging?
   - **Proposal:** Internal logging for Phase 1, add `/metrics` in Phase 2 if useful

---

## Risks & Rollback Plan

### Risk: Cache serves stale data
**Mitigation:** TTL 60s + event invalidation  
**Rollback:** Feature flag `HERDRELAY_OUTPUT_CACHE=false`

### Risk: Memory leak in cache
**Mitigation:** Cleanup loop evicts old entries  
**Detection:** Monitor relay process RSS  
**Rollback:** Feature flag off

### Risk: Client cache breaks UX
**Mitigation:** Extensive testing, gradual rollout  
**Detection:** User reports or app crash metrics  
**Rollback:** Ship client hotfix with cache disabled

### Emergency Rollback Procedure:
1. Set env `HERDRELAY_OUTPUT_CACHE=false` → restart relay (Phase 1)
2. Ship client app update with `_outputCache` disabled (Phase 2)
3. Both rollbacks are **instant** (no data migration needed)

---

## Documentation Updates

- [ ] `CHANGELOG.md`: Add Phase 1 + Phase 2 entries
- [ ] `docs/03-relay.md`: Document OutputCache architecture
- [ ] `README.md`: Update performance claims (97% latency reduction)
- [ ] Inline code comments: Document cache invalidation logic
- [ ] API docs: Update `agent.output` response schema (add `revision` field)

---

**End of implementation plan.** Ready for review and approval to proceed.
