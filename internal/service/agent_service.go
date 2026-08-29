package service

import (
	"herdrelay/internal/domain"
	"herdrelay/internal/repository"
)

// AgentService provides business logic for agent operations.
type AgentService struct {
	repo repository.AgentRepository
}

// NewAgentService creates a new agent service.
func NewAgentService(repo repository.AgentRepository) *AgentService {
	return &AgentService{repo: repo}
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

	output, err := s.repo.ReadOutput(target, lines, format)
	if err != nil {
		return nil, err
	}

	return &domain.AgentOutput{
		Target: target,
		Output: output,
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
