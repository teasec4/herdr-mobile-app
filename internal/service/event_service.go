package service

import (
	"log"
	"sync"

	"herdrelay/internal/domain"
	"herdrelay/internal/repository"
)

// EventService manages event subscriptions and broadcasting.
type EventService struct {
	eventRepo  repository.EventRepository
	mu         sync.RWMutex
	listeners  []chan<- domain.Event
	started    bool
	stopCh     chan struct{}
}

// NewEventService creates a new event service.
func NewEventService(eventRepo repository.EventRepository) *EventService {
	return &EventService{
		eventRepo: eventRepo,
		listeners: make([]chan<- domain.Event, 0),
		stopCh:    make(chan struct{}),
	}
}

// Start begins listening for events from the repository and broadcasting them.
func (s *EventService) Start() error {
	s.mu.Lock()
	if s.started {
		s.mu.Unlock()
		return nil
	}
	s.started = true
	s.mu.Unlock()

	events := make(chan domain.Event, 100)

	go func() {
		if err := s.eventRepo.Subscribe(events); err != nil {
			log.Printf("event service: subscription error: %v", err)
		}
	}()

	go func() {
		for {
			select {
			case event, ok := <-events:
				if !ok {
					return
				}
				s.broadcast(event)
			case <-s.stopCh:
				return
			}
		}
	}()

	return nil
}

// Subscribe adds a new listener for events.
func (s *EventService) Subscribe() <-chan domain.Event {
	ch := make(chan domain.Event, 10)
	s.mu.Lock()
	s.listeners = append(s.listeners, ch)
	s.mu.Unlock()
	return ch
}

// Broadcast sends an event to all subscribed listeners.
// This is used by HTTP handlers to inject plugin events into the stream.
func (s *EventService) Broadcast(event domain.Event) {
	s.broadcast(event)
}

func (s *EventService) broadcast(event domain.Event) {
	s.mu.RLock()
	listeners := make([]chan<- domain.Event, len(s.listeners))
	copy(listeners, s.listeners)
	s.mu.RUnlock()

	for _, listener := range listeners {
		select {
		case listener <- event:
		default:
			// Listener is blocked, skip to avoid blocking broadcast
			log.Printf("event service: listener blocked, dropping event %s", event.EventName())
		}
	}
}

// Stop stops the event service.
func (s *EventService) Stop() error {
	s.mu.Lock()
	if !s.started {
		s.mu.Unlock()
		return nil
	}
	s.started = false
	s.mu.Unlock()

	close(s.stopCh)
	return s.eventRepo.Close()
}
