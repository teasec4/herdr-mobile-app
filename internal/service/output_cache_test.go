package service

import (
	"testing"
	"time"
)

func TestOutputCache_GetSet(t *testing.T) {
	cache := NewOutputCache(time.Hour)

	// Cache miss
	if got := cache.Get("p1", 200, "text"); got != nil {
		t.Errorf("expected nil, got %v", got)
	}

	// Store
	cache.Set("p1", 200, "text", "hello\nworld\n", 42)

	// Cache hit
	got := cache.Get("p1", 200, "text")
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

func TestOutputCache_KeyScopedByLinesAndFormat(t *testing.T) {
	cache := NewOutputCache(time.Hour)
	cache.Set("p1", 500, "ansi", "ansi-content", 1)
	cache.Set("p1", 200, "text", "text-content", 1)

	if got := cache.Get("p1", 500, "ansi"); got == nil || got.Text != "ansi-content" {
		t.Errorf("ansi/500 entry not served correctly: %v", got)
	}
	if got := cache.Get("p1", 200, "text"); got == nil || got.Text != "text-content" {
		t.Errorf("text/200 entry not served correctly: %v", got)
	}
}

func TestOutputCache_Invalidate(t *testing.T) {
	cache := NewOutputCache(time.Hour)
	cache.Set("p1", 200, "text", "text", 10)
	cache.Set("p1", 500, "ansi", "ansi", 10)

	cache.Invalidate("p1")

	if got := cache.Get("p1", 200, "text"); got != nil {
		t.Errorf("expected nil after invalidate, got %v", got)
	}
	if got := cache.Get("p1", 500, "ansi"); got != nil {
		t.Errorf("expected nil for other variants after invalidate, got %v", got)
	}
}

func TestOutputCache_TTL(t *testing.T) {
	cache := NewOutputCache(100 * time.Millisecond)
	cache.Set("p1", 200, "text", "text", 10)

	// Immediate: hit
	if got := cache.Get("p1", 200, "text"); got == nil {
		t.Error("expected hit immediately after Set")
	}

	// After TTL: miss
	time.Sleep(150 * time.Millisecond)
	if got := cache.Get("p1", 200, "text"); got != nil {
		t.Errorf("expected miss after TTL, got %v", got)
	}
}

func TestOutputCache_EvictExpired(t *testing.T) {
	cache := NewOutputCache(50 * time.Millisecond)
	cache.Set("p1", 200, "text", "old", 1)
	time.Sleep(60 * time.Millisecond)
	cache.Set("p2", 200, "text", "fresh", 2)

	cache.evictExpired()

	if cache.Size() != 1 {
		t.Errorf("expected 1 entry after eviction, got %d", cache.Size())
	}
	if got := cache.Get("p1", 200, "text"); got != nil {
		t.Error("old entry should be evicted")
	}
	if got := cache.Get("p2", 200, "text"); got == nil {
		t.Error("fresh entry should remain")
	}
}

func TestOutputCache_Clear(t *testing.T) {
	cache := NewOutputCache(time.Hour)
	cache.Set("p1", 200, "text", "a", 1)
	cache.Set("p2", 200, "text", "b", 2)

	cache.Clear()

	if cache.Size() != 0 {
		t.Errorf("expected 0 entries after Clear, got %d", cache.Size())
	}
}