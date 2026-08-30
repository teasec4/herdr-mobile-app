package service

import (
	"log"
	"sync"

	"herdrelay/internal/domain"
	"herdrelay/internal/repository"
)

// eventListener pairs the writable channel used for broadcasting with the
// read-only view handed to the subscriber (channel types are invariant, so
// the view is what we compare in Unsubscribe).
type eventListener struct {
	ch   chan domain.Event
	view <-chan domain.Event
}

// EventService manages event subscriptions and broadcasting.
type EventService struct {
	eventRepo repository.EventRepository
	// agentService is used to invalidate the output cache and to track per-pane
	// output revisions from the event stream (docs/14-terminal-stream-implementation-plan.md §1.5, §2.4).
	// Nil when constructed without one (e.g. some tests).
	agentService *AgentService
	mu           sync.RWMutex
	listeners    []*eventListener
	started      bool
	stopCh       chan struct{}
}

// NewEventService creates a new event service. agentService may be nil; when
// set, pane events invalidate its output cache and advance its revisions.
func NewEventService(eventRepo repository.EventRepository, agentService *AgentService) *EventService {
	return &EventService{
		eventRepo:    eventRepo,
		agentService: agentService,
		listeners:    make([]*eventListener, 0),
		stopCh:       make(chan struct{}),
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
	s.listeners = append(s.listeners, &eventListener{ch: ch, view: ch})
	s.mu.Unlock()
	return ch
}

// Unsubscribe removes a listener previously obtained from [EventService.Subscribe]
// and closes its channel. The broadcast loop uses a `select` with a `default`
// branch, so a send to a closed channel is never selected (it falls through to
// `default`); readers observe `ok == false` and must stop (HandleEventStream
// already does). Closing frees the buffered channel immediately instead of
// leaking it until GC.
func (s *EventService) Unsubscribe(view <-chan domain.Event) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i, l := range s.listeners {
		if l.view == view {
			s.listeners = append(s.listeners[:i], s.listeners[i+1:]...)
			close(l.ch)
			return
		}
	}
}

// Broadcast sends an event to all subscribed listeners.
// This is used by HTTP handlers to inject plugin events into the stream.
func (s *EventService) Broadcast(event domain.Event) {
	s.broadcast(event)
}

func (s *EventService) broadcast(event domain.Event) {
	s.mu.RLock()
	listeners := make([]*eventListener, len(s.listeners))
	copy(listeners, s.listeners)
	s.mu.RUnlock()

	for _, listener := range listeners {
		select {
		case listener.ch <- event:
		default:
			// Listener is blocked, skip to avoid blocking broadcast
			log.Printf("event service: listener blocked, dropping event %s", event.EventName())
		}
	}

	// Pane events mean terminal output may have changed: invalidate the
	// output cache so the next read refetches, and record the revision so
	// agent.output/pane.output responses carry it for client-side dedup.
	s.invalidateCacheOnEvent(event)
}

// invalidateCacheOnEvent drops cached output for panes whose output may have
// changed, and forwards each pane's latest revision to the agent service.
func (s *EventService) invalidateCacheOnEvent(event domain.Event) {
	if s.agentService == nil {
		return
	}
	switch evt := event.(type) {
	case domain.PaneUpdatedEvent:
		s.agentService.outputCache.Invalidate(evt.PaneID)
		if evt.Revision > 0 {
			s.agentService.UpdateRevision(evt.PaneID, evt.Revision)
		}
	case domain.OutputChangedEvent:
		s.agentService.outputCache.Invalidate(evt.PaneID)
		if evt.Revision > 0 {
			s.agentService.UpdateRevision(evt.PaneID, evt.Revision)
		}
	case domain.AgentStatusChangedEvent:
		// Conservative invalidation: status flips often accompany an output
		// flush (plan §1.5). Output itself is not revisioned by this event.
		s.agentService.outputCache.Invalidate(evt.PaneID)
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
