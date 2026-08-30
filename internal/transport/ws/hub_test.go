package ws

import "testing"

// A client whose outgoing queue is full must not block the writer: Write
// returns an error and the client closes instead of accumulating lag.
func TestClientWriteQueueFull(t *testing.T) {
	// No real websocket conn needed for the queue logic — StartWriter is not
	// running, so the queue fills up and Write must fail fast.
	c := NewClient(nil)

	for i := 0; i < sendQueue; i++ {
		if err := c.Write([]byte("x")); err != nil {
			t.Fatalf("unexpected error while filling queue at %d: %v", i, err)
		}
	}
	if err := c.Write([]byte("overflow")); err == nil {
		t.Fatal("expected error when the queue is full")
	}
}

// Close must be idempotent and never panic on double close.
func TestClientCloseIdempotent(t *testing.T) {
	c := NewClient(nil)
	c.Close()
	c.Close() // second close must be a no-op
}
