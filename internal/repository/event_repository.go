package repository

import "herdrelay/internal/domain"

// EventRepository defines operations for subscribing to herdr events.
type EventRepository interface {
	// Subscribe starts listening for events and sends them to the provided channel.
	// The channel will be closed when the subscription ends.
	Subscribe(events chan<- domain.Event) error

	// Close stops the event subscription.
	Close() error
}
