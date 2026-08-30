package service

import (
	"fmt"
	"strings"
	"sync"
	"time"
)

// OutputCache holds recently fetched terminal output to avoid repeated CLI
// spawns. Entries are invalidated on pane.updated / pane.output_changed /
// pane.agent_status_changed events and expire after TTL
// (docs/14-terminal-stream-implementation-plan.md §1.4).
type OutputCache struct {
	mu      sync.RWMutex
	entries map[string]*CachedOutput
	ttl     time.Duration
}

// CachedOutput stores one pane's terminal output snapshot.
type CachedOutput struct {
	Text      string
	Revision  int // last known revision, 0 if unknown
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

// key scopes an entry to (pane, lines, format): the HTTP endpoint accepts
// arbitrary lines/format per request, so an ansi/500 entry must never be
// served to a text/200 request.
func (c *OutputCache) key(paneID string, lines int, format string) string {
	return fmt.Sprintf("%s\x00%d\x00%s", paneID, lines, format)
}

// Get retrieves cached output if present and fresh.
// Returns nil if not found or expired.
func (c *OutputCache) Get(paneID string, lines int, format string) *CachedOutput {
	c.mu.RLock()
	defer c.mu.RUnlock()

	entry := c.entries[c.key(paneID, lines, format)]
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
func (c *OutputCache) Set(paneID string, lines int, format string, text string, revision int) {
	c.mu.Lock()
	defer c.mu.Unlock()

	c.entries[c.key(paneID, lines, format)] = &CachedOutput{
		Text:      text,
		Revision:  revision,
		FetchedAt: time.Now(),
	}
}

// Invalidate removes every entry for a pane, whatever the lines/format
// variant (called on pane.updated events).
func (c *OutputCache) Invalidate(paneID string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	prefix := paneID + "\x00"
	for k := range c.entries {
		if strings.HasPrefix(k, prefix) {
			delete(c.entries, k)
		}
	}
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
	for k, entry := range c.entries {
		if now.Sub(entry.FetchedAt) > c.ttl {
			delete(c.entries, k)
		}
	}
}