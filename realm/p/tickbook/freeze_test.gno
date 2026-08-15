package tickbook

import "testing"

// TestJoinFreezeIsRejected pins the survival-fraction invariant against the
// join-after-fill path the earlier fix missed: nibbling one tick down (Take most, then
// refill) without ever clearing it shrinks surv toward 1. Once surv has shrunk to the
// order-size magnitude, a further refill would push resting past surv and FREEZE the
// tick — later fills would then credit the joined maker nothing, stranding their coin.
// Place must refuse that join (before the fix it silently accepted it).
func TestJoinFreezeIsRejected(t *testing.T) {
	b := NewBook()
	const sz = int64(1_000_000)
	b.Place(Ask, 0, alice, sz) // fresh tick: surv = accScale
	shrink := func(m address) {
		b.Take(Bid, 0, sz-1)     // leave 1 resting; surv shrinks by ~1/sz
		b.Place(Ask, 0, m, sz-1) // refill without clearing — still fits under the (large) surv
	}
	shrink(bob)          // surv ~1e12 — fine
	shrink(carol)        // surv ~1e6 — fine
	b.Take(Bid, 0, sz-1) // surv now ~1: the tick's precision is exhausted
	shouldPanic(t, "a join that would exhaust the tick's precision", func() {
		b.Place(Ask, 0, dave, sz-1)
	})
}

// TestTakeNotionalOverflowPanics and TestCollectNotionalOverflowPanics confirm the
// notional products FAIL CLOSED (panic) rather than silently wrapping when a resting
// size near maxTickResting meets the top price. Unreachable at the court's supply cap
// (~9.2e14, so fill·100 ≪ MaxInt64), but a generic consumer resting near the 1e18 cap
// would hit it — and it must never wrap into a wrong notional.
func TestTakeNotionalOverflowPanics(t *testing.T) {
	b := NewBook()
	b.Place(Ask, 99, alice, 100_000_000_000_000_000) // 1e17 at tick 99 (price 100)
	shouldPanic(t, "take notional overflow", func() {
		b.Take(Bid, 99, 100_000_000_000_000_000) // fill 1e17 → notional 1e19 > MaxInt64
	})
}

func TestCollectNotionalOverflowPanics(t *testing.T) {
	b := NewBook()
	id := b.Place(Ask, 99, alice, 1_000_000_000_000_000_000) // 1e18 resting at price 100
	// Ten sub-overflow takes (each notional 1e16·100 = 1e18, fine) accumulate 1e17 of
	// uncollected fill; Collect's one notional = 1e17·100 = 1e19 then overflows.
	for i := 0; i < 10; i++ {
		b.Take(Bid, 99, 10_000_000_000_000_000) // 1e16 each
	}
	shouldPanic(t, "collect notional overflow", func() {
		b.Collect(alice, id)
	})
}
