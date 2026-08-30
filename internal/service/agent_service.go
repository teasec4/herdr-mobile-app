package service

import (
	"sync"
	"time"

	"herdrelay/internal/domain"
	"herdrelay/internal/repository"
)

// AgentService provides business logic for agent operations.
type AgentService struct {
	repo repository.AgentRepository
	// outputCache avoids repeated CLI spawns for terminal reads; entries are
	// invalidated by EventService on pane events (docs/14-terminal-stream-implementation-plan.md §1.5).
	outputCache *OutputCache
	// lastKnownRevision maps pane id -> latest revision observed on pane
	// events. herdr's CLI returns raw text (no revision), so the revision is
	// tracked from the event stream instead (docs/14-terminal-stream-implementation-plan.md §2.4).
	lastKnownRevision map[string]int
	revisionMu        sync.RWMutex
}

// NewAgentService creates a new agent service.
func NewAgentService(repo repository.AgentRepository) *AgentService {
	return &AgentService{
		repo:              repo,
		outputCache:       NewOutputCache(60 * time.Second),
		lastKnownRevision: make(map[string]int),
	}
}

// UpdateRevision records the pane's latest output revision, observed from a
// pane event. Monotonic: a lower/equal revision never moves the value back.
func (s *AgentService) UpdateRevision(paneID string, revision int) {
	if revision <= 0 {
		return
	}
	s.revisionMu.Lock()
	defer s.revisionMu.Unlock()
	if revision > s.lastKnownRevision[paneID] {
		s.lastKnownRevision[paneID] = revision
	}
}

func (s *AgentService) lastRevision(paneID string) int {
	s.revisionMu.RLock()
	defer s.revisionMu.RUnlock()
	return s.lastKnownRevision[paneID]
}

// GetSnapshot returns the current snapshot of all agents.
func (s *AgentService) GetSnapshot() (*domain.Snapshot, error) {
	return s.repo.Snapshot()
}

// GetOutput retrieves the terminal output of an agent.
func (s *AgentService) GetOutput(target string, lines int, format string) (*domain.AgentOutput, error) {
	if lines <= 0 {
		lines = 200
	}
	if format == "" {
		format = "text"
	}

	// Cache hit (fresh): return immediately, no CLI spawn.
	if cached := s.outputCache.Get(target, lines, format); cached != nil {
		return &domain.AgentOutput{
			Target:   target,
			Output:   cached.Text,
			Revision: s.lastRevision(target),
		}, nil
	}

	output, err := s.repo.ReadOutput(target, lines, format)
	if err != nil {
		return nil, err
	}

	// herdr's CLI returns raw text, so the revision always comes from the
	// event stream (UpdateRevision), not from this read.
	s.outputCache.Set(target, lines, format, output, 0)

	return &domain.AgentOutput{
		Target:   target,
		Output:   output,
		Revision: s.lastRevision(target),
	}, nil
}

// SendKeys sends key sequences to an agent.
func (s *AgentService) SendKeys(target string, keys []string) error {
	if target == "" {
		return ErrInvalidTarget
	}
	if len(keys) == 0 {
		return ErrInvalidKeys
	}
	return s.repo.SendKeys(target, keys)
}

// SendPrompt sends a text prompt to an agent.
func (s *AgentService) SendPrompt(target, text string) error {
	if target == "" {
		return ErrInvalidTarget
	}
	if text == "" {
		return ErrInvalidPrompt
	}
	return s.repo.SendPrompt(target, text)
}

// GetPaneOutput reads a pane's terminal output (plain terminals included).
func (s *AgentService) GetPaneOutput(paneID string, lines int, format string) (*domain.AgentOutput, error) {
	if lines <= 0 {
		lines = 200
	}
	if format == "" {
		format = "text"
	}
	if cached := s.outputCache.Get(paneID, lines, format); cached != nil {
		return &domain.AgentOutput{
			Target:   paneID,
			Output:   cached.Text,
			Revision: s.lastRevision(paneID),
		}, nil
	}
	output, err := s.repo.ReadPaneOutput(paneID, lines, format)
	if err != nil {
		return nil, err
	}
	s.outputCache.Set(paneID, lines, format, output, 0)
	return &domain.AgentOutput{
		Target:   paneID,
		Output:   output,
		Revision: s.lastRevision(paneID),
	}, nil
}

// SendText writes literal text into a pane (plain terminal input).
func (s *AgentService) SendText(paneID, text string) error {
	if paneID == "" {
		return ErrInvalidTarget
	}
	return s.repo.SendText(paneID, text)
}

// StartAgent launches an agent of the given kind into an existing pane.
func (s *AgentService) StartAgent(name, kind, paneID string) error {
	if name == "" {
		return ErrInvalidName
	}
	if kind == "" {
		return ErrInvalidKind
	}
	if paneID == "" {
		return ErrInvalidTarget
	}
	return s.repo.StartAgent(name, kind, paneID)
}

// CreateWorkspace creates a new workspace; label/cwd are optional.
func (s *AgentService) CreateWorkspace(label, cwd string) (string, string, error) {
	return s.repo.CreateWorkspace(label, cwd)
}
