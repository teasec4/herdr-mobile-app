package herdr

import "testing"

// setRevision never moves backwards (out-of-order delivery across reconnects
// must not roll the revision back — audit P3.1).
func TestRevisionStateMax(t *testing.T) {
	rs := newRevisionState()
	rs.setRevision("p1", 10)
	rs.setRevision("p1", 11)
	rs.setRevision("p1", 10) // stale, out-of-order — must not roll back
	if got := rs.last("p1"); got != 11 {
		t.Fatalf("expected revision 11, got %d", got)
	}
}

// markSent only forwards strictly increasing revisions.
func TestRevisionStateMarkSent(t *testing.T) {
	rs := newRevisionState()
	rs.setRevision("p1", 5)
	if !rs.markSent("p1", 5) {
		t.Fatal("first send of a new revision should be forwarded")
	}
	if rs.markSent("p1", 5) {
		t.Fatal("equal revision must not be forwarded again")
	}
	rs.setRevision("p1", 7)
	if !rs.markSent("p1", 7) {
		t.Fatal("increased revision must be forwarded")
	}
}
