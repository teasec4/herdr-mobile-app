package service

import (
	"testing"
	"time"

	"herdrelay/internal/domain"
)

// stubAgentRepo is a fake agent repository that counts CLI reads.
type stubAgentRepo struct {
	readCount int
	output    string
}

func (r *stubAgentRepo) ReadOutput(target string, lines int, format string) (string, error) {
	r.readCount++
	return r.output, nil
}

func (r *stubAgentRepo) ReadPaneOutput(paneID string, lines int, format string) (string, error) {
	r.readCount++
	return r.output, nil
}

func (r *stubAgentRepo) Snapshot() (*domain.Snapshot, error) { return nil, nil }
func (r *stubAgentRepo) SendKeys(target string, keys []string) error {
	return nil
}
func (r *stubAgentRepo) SendPrompt(target, text string) error { return nil }
func (r *stubAgentRepo) SendText(paneID, text string) error   { return nil }
func (r *stubAgentRepo) StartAgent(name, kind, paneID string) error {
	return nil
}
func (r *stubAgentRepo) CreateWorkspace(label, cwd string) (string, string, error) {
	return "", "", nil
}

func TestAgentService_GetOutput_CacheHit(t *testing.T) {
	repo := &stubAgentRepo{output: "hello"}
	svc := NewAgentService(repo)

	out1, err := svc.GetOutput("p1", 200, "text")
	if err != nil {
		t.Fatalf("first GetOutput: %v", err)
	}
	out2, err := svc.GetOutput("p1", 200, "text")
	if err != nil {
		t.Fatalf("second GetOutput: %v", err)
	}

	if repo.readCount != 1 {
		t.Fatalf("expected 1 read, got %d", repo.readCount)
	}
	if out1.Output != "hello" || out2.Output != "hello" {
		t.Fatalf("expected cached output 'hello', got %q / %q", out1.Output, out2.Output)
	}
}

func TestAgentService_GetOutput_Invalidation(t *testing.T) {
	repo := &stubAgentRepo{output: "old"}
	svc := NewAgentService(repo)

	if _, err := svc.GetOutput("p1", 200, "text"); err != nil {
		t.Fatalf("first GetOutput: %v", err)
	}

	svc.outputCache.Invalidate("p1")
	repo.output = "new"
	out, err := svc.GetOutput("p1", 200, "text")
	if err != nil {
		t.Fatalf("second GetOutput: %v", err)
	}

	if repo.readCount != 2 {
		t.Fatalf("expected 2 reads after invalidation, got %d", repo.readCount)
	}
	if out.Output != "new" {
		t.Fatalf("expected 'new' after invalidation, got %q", out.Output)
	}
}

func TestAgentService_GetOutput_TTL(t *testing.T) {
	repo := &stubAgentRepo{output: "old"}
	svc := NewAgentService(repo)
	svc.outputCache.ttl = 50 * time.Millisecond

	if _, err := svc.GetOutput("p1", 200, "text"); err != nil {
		t.Fatalf("first GetOutput: %v", err)
	}

	time.Sleep(60 * time.Millisecond)
	repo.output = "new"
	out, err := svc.GetOutput("p1", 200, "text")
	if err != nil {
		t.Fatalf("second GetOutput: %v", err)
	}

	if repo.readCount != 2 {
		t.Fatalf("expected 2 reads after TTL expiry, got %d", repo.readCount)
	}
	if out.Output != "new" {
		t.Fatalf("expected 'new' after TTL expiry, got %q", out.Output)
	}
}