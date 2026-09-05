package scan

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/jaekwon/kourt/internal/chat"
)

// Run is the daemon loop, and it was at 0.0% of statements — measured. Tick has
// a dozen tests; the loop around it had none, and the two things the loop does
// that Tick does not are both stated in its comment and were both unheld.

// countingCls counts how many messages the loop has classified, so a test can
// tell a cycle that drained a backlog from one that waited.
type countingCls struct {
	mu sync.Mutex
	n  int
}

func (c *countingCls) Classify(_ context.Context, _ string, _ []string) (Verdict, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.n++
	return Verdict{Label: Clean, Confidence: 1}, nil
}

func (c *countingCls) count() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.n
}

func runStore(t *testing.T) *chat.Store {
	t.Helper()
	s, err := chat.Open(t.TempDir() + "/run.db")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

/*
A HEARTBEAT ON AN EMPTY CYCLE, which is the whole of Run's own comment: "the
scanner is alive" and "the scanner found nothing" must not look the same to an
operator. Writing it only when there was work is the obvious shortcut, and it
turns a quiet room into an outage on the health page — or worse, a dead scanner
into a quiet room.

The store is EMPTY here on purpose. Every other test in this package gives the
scanner something to find.
*/
func TestRunHeartbeatsOnACycleThatFoundNothing(t *testing.T) {
	s := runStore(t)
	before, err := s.Health(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if before.ScannerSeen != 0 {
		t.Fatal("setup: a fresh store should have no heartbeat")
	}

	sc := &Scanner{Store: s, Cls: &countingCls{}, Batch: 4, Interval: time.Hour}
	// One cycle, then out: Interval is an hour, so the loop is parked in its
	// select when the context ends and the heartbeat has already been written.
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- sc.Run(ctx) }()

	waitFor(t, func() bool {
		h, err := s.Health(context.Background())
		return err == nil && h.ScannerSeen != 0
	}, "the loop never wrote a heartbeat on an empty cycle")

	cancel()
	if err := <-done; err != context.Canceled {
		t.Fatalf("Run returned %v, want context.Canceled", err)
	}

	/* AND IT RECORDS WHETHER IT IS ENFORCING, because health reports that and the
	   page must not claim moderation that is not happening. This scanner is not,
	   which is the default. */
	h, err := s.Health(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if h.Enforcing {
		t.Fatal("a non-enforcing scanner reported itself as enforcing")
	}
	if h.SeenEvery != int64(time.Hour.Seconds()) {
		t.Fatalf("the heartbeat recorded a %ds interval, want %d", h.SeenEvery, int64(time.Hour.Seconds()))
	}
}

/*
A FULL BATCH MEANS A BACKLOG, so the loop does not wait — `wait = 0`. With the
interval at an hour, a scanner that slept between batches would clear four
messages and stop; the test asks for more than one batch and waits for all of
them, so it fails by TIMING OUT rather than by asserting a count, which is what
the defect would actually do to an operator with a queue.
*/
func TestRunDrainsABacklogWithoutWaitingOutTheInterval(t *testing.T) {
	s := runStore(t)
	ctx := context.Background()
	const batch, total = 4, 12
	/* ONE SENDER PER MESSAGE, because the throttle is per address and twelve from
	   one would be refused before the scanner ever saw them — which is also the
	   truer shape of a backlog: a queue builds when many people post, not when
	   one person posts twelve times. */
	for i := 0; i < total; i++ {
		who := fmt.Sprintf("poster%02d", i)
		if _, err := s.Post(ctx, chat.PostInput{
			Chain: "dev", Court: "orem", Moniker: who,
			Body: "a message that needs a look", IPHash: who, NetHash: "net",
		}); err != nil {
			t.Fatal(err)
		}
	}

	cls := &countingCls{}
	sc := &Scanner{Store: s, Cls: cls, Batch: batch, Interval: time.Hour}
	rctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go sc.Run(rctx)

	// Three full batches back to back. At one hour a cycle this cannot finish
	// unless a full batch really does set wait to zero.
	waitFor(t, func() bool { return cls.count() >= total },
		"the loop stopped after one batch instead of draining the backlog")
}

/*
AND IT WAITS WHEN THERE IS NO BACKLOG, which is the other half of the same line
and the half a test can forget. `wait = 0` unconditionally passes every
assertion above — the heartbeat still lands, the queue still drains — and turns
the daemon into a busy loop that burns a core for ever. Nothing about the output
would say so, which is why this counts CYCLES rather than watching for an
effect.

Store.Now is called once per heartbeat, so the count of Now calls is the count
of cycles. A parked loop makes one and stops; a spinning one makes thousands in
the same tenth of a second.
*/
func TestRunParksBetweenCyclesInsteadOfSpinning(t *testing.T) {
	s := runStore(t)
	var mu sync.Mutex
	cycles := 0
	s.Now = func() time.Time {
		mu.Lock()
		defer mu.Unlock()
		cycles++
		return time.Unix(1_700_000_000, 0)
	}
	read := func() int { mu.Lock(); defer mu.Unlock(); return cycles }

	sc := &Scanner{Store: s, Cls: &countingCls{}, Batch: 4, Interval: time.Hour}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go sc.Run(ctx)

	waitFor(t, func() bool { return read() > 0 }, "the loop never ran a cycle")
	time.Sleep(100 * time.Millisecond)
	/* GENEROUS ON PURPOSE: the point is orders of magnitude, not an exact count.
	   A loop honouring a one-hour interval runs once in this window; a spinning
	   one runs tens of thousands of times, so any small bound separates them and
	   a tight one would only buy flakiness. */
	if n := read(); n > 20 {
		t.Fatalf("the loop ran %d cycles in 100ms with a one-hour interval; it is spinning", n)
	}
}

// waitFor polls a condition for a bounded time. Polling rather than sleeping a
// fixed span: the pass is as fast as the loop is, and the failure is a message
// rather than a flake.
func waitFor(t *testing.T, ok func() bool, msg string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if ok() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal(msg)
}

// The defaults, which Run reads on every cycle and nothing else names.
func TestScannerDefaultsAreTheOnesRunUses(t *testing.T) {
	var zero Scanner
	if got := zero.interval(); got != 5*time.Second {
		t.Fatalf("default interval %v, want 5s", got)
	}
	if got := zero.batch(); got != 8 {
		t.Fatalf("default batch %d, want 8", got)
	}
	// A negative is not a smaller number here; it is a caller mistake, and both
	// helpers fall back rather than passing it on to a timer or a LIMIT.
	neg := Scanner{Interval: -time.Second, Batch: -3}
	if got := neg.interval(); got != 5*time.Second {
		t.Fatalf("a negative interval gave %v, want the 5s default", got)
	}
	if got := neg.batch(); got != 8 {
		t.Fatalf("a negative batch gave %d, want the default 8", got)
	}
}
