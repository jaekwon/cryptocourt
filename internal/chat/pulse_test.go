package chat

import "testing"

// The wake-up half of the long poll, tested at the pulse rather than through an
// HTTP request. TestLongPollHoldsUntilSomethingHappens already proves a GET holds
// and then answers; what it cannot show is WHICH channel did the waking, and the
// rules about that are the whole of this file's design — fireAll was at 0.0% of
// statements, measured.
//
// A closed channel is what "woken" means here, so these read the channels
// directly instead of racing goroutines against a timeout. Nothing sleeps.

func closed(ch <-chan struct{}) bool {
	select {
	case <-ch:
		return true
	default:
		return false
	}
}

func TestFireWakesOneCourtAndLeavesTheOthersAsleep(t *testing.T) {
	p := newPulse()
	orem, _ := p.watch(pulseKey("dev", "orem"))
	ledger, _ := p.watch(pulseKey("dev", "ledger"))

	p.fire(pulseKey("dev", "orem"))
	if !closed(orem) {
		t.Fatal("the court that changed was not woken")
	}
	/* A POST IS EXACT, which is the reason posts fire per court at all: they are
	   the common case, and waking every room for each one is the cost this design
	   is avoiding. */
	if closed(ledger) {
		t.Fatal("a post in one court woke a waiter in another")
	}
}

func TestTheSameCourtOnTwoChainsIsTwoRooms(t *testing.T) {
	p := newPulse()
	dev, _ := p.watch(pulseKey("dev", "orem"))
	live, _ := p.watch(pulseKey("kourt-1", "orem"))

	p.fire(pulseKey("dev", "orem"))
	if !closed(dev) {
		t.Fatal("dev/orem was not woken")
	}
	// pulseKey's own comment: "orem" on dev and "orem" on kourt-1 are two rooms.
	// Without the chain in the key they would be one, and a dev post would wake
	// every reader on the live chain.
	if closed(live) {
		t.Fatal("a post on one chain woke the same court's readers on another")
	}
}

func TestFireAllWakesEveryWaiterThroughTheGlobalChannelOnly(t *testing.T) {
	p := newPulse()
	orem, g1 := p.watch(pulseKey("dev", "orem"))
	ledger, g2 := p.watch(pulseKey("dev", "ledger"))

	p.fireAll()
	if !closed(g1) || !closed(g2) {
		t.Fatal("a global change did not reach every waiter")
	}
	/* THE PER-COURT CHANNELS ARE LEFT ALONE, and fireAll says why: a waiter
	   selects on both, so closing both wakes it TWICE for one change. The second
	   wake is not harmless — the waiter re-reads its court, finds the same rows,
	   and answers a long poll that should still be holding, which is the interval
	   this design exists to remove.
	   This is the assertion that would fail if somebody "fixed" fireAll by
	   closing the per-court map too, which reads like thoroughness. */
	if closed(orem) || closed(ledger) {
		t.Fatal("a global wake also closed a per-court channel; every waiter wakes twice")
	}
}

func TestAWaiterArrivingAfterAWakeGetsTheNextOneNotASpentChannel(t *testing.T) {
	p := newPulse()
	key := pulseKey("dev", "orem")
	first, firstG := p.watch(key)

	p.fire(key)
	p.fireAll()
	if !closed(first) || !closed(firstG) {
		t.Fatal("setup: the first waiter should have been woken by both")
	}

	/* THE CHANNEL IS REPLACED IN THE SAME LOCK AS THE CLOSE. Without that, a
	   waiter arriving one instruction later would take a channel that is already
	   spent, return at once, re-read a court nothing had changed, and do it again
	   — a long poll that no longer holds, which is a busy loop wearing the shape
	   of a feature. */
	next, nextG := p.watch(key)
	if closed(next) {
		t.Fatal("a waiter arriving after a court wake got the spent channel")
	}
	if closed(nextG) {
		t.Fatal("a waiter arriving after a global wake got the spent channel")
	}

	// ...and the fresh pair still works, which is what makes the replacement a
	// replacement rather than a way to drop the signal.
	p.fire(key)
	if !closed(next) {
		t.Fatal("the replacement court channel never fires")
	}
	p.fireAll()
	if !closed(nextG) {
		t.Fatal("the replacement global channel never fires")
	}
}

func TestWatchingAnUnknownCourtIsSafeAndFirable(t *testing.T) {
	p := newPulse()
	// watch creates the per-court channel on first ask, so the first reader of a
	// court nobody has posted in does not get a nil channel — a nil receive
	// blocks for ever, which here is a request that never answers.
	ch, g := p.watch(pulseKey("dev", "brand-new"))
	if ch == nil || g == nil {
		t.Fatal("watch handed back a nil channel; a receive on it never returns")
	}
	if closed(ch) || closed(g) {
		t.Fatal("a fresh watcher was woken before anything happened")
	}
	p.fire(pulseKey("dev", "brand-new"))
	if !closed(ch) {
		t.Fatal("a court created by watch cannot be fired")
	}
}

// fire on a court nobody is watching is a no-op rather than a panic: moderation
// and posting both fire without asking whether anyone is listening.
func TestFiringACourtNobodyWatchesDoesNothing(t *testing.T) {
	p := newPulse()
	p.fire(pulseKey("dev", "empty"))
	if _, ok := p.per[pulseKey("dev", "empty")]; ok {
		t.Fatal("firing an unwatched court created an entry for it")
	}
}
