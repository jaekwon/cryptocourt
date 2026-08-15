package tickbook

import "testing"

const (
	alice = address("alice")
	bob   = address("bob")
	carol = address("carol")
	dave  = address("dave")
)

func shouldPanic(t *testing.T, name string, fn func()) {
	t.Helper()
	defer func() {
		if recover() == nil {
			t.Fatalf("%s should have panicked", name)
		}
	}()
	fn()
}

func TestPlaceRestsAndReports(t *testing.T) {
	b := NewBook()
	// tick 39 == price 40.
	b.Place(Ask, 39, alice, 100)
	if b.RestingAt(Ask, 39) != 100 {
		t.Fatalf("resting should be 100, got %d", b.RestingAt(Ask, 39))
	}
	ba, ok := b.BestAsk()
	if !ok || ba != 39 {
		t.Fatalf("best ask should be tick 39, got %d ok=%v", ba, ok)
	}
	if _, ok := b.BestBid(); ok {
		t.Fatal("no bids yet")
	}
}

func TestBestAskIsLowestBestBidIsHighest(t *testing.T) {
	b := NewBook()
	b.Place(Ask, 60, alice, 10)
	b.Place(Ask, 55, bob, 10)
	b.Place(Ask, 70, carol, 10)
	if ba, _ := b.BestAsk(); ba != 55 {
		t.Fatalf("best ask should be the lowest, 55, got %d", ba)
	}
	b.Place(Bid, 40, alice, 10)
	b.Place(Bid, 45, bob, 10)
	b.Place(Bid, 30, carol, 10)
	if bb, _ := b.BestBid(); bb != 45 {
		t.Fatalf("best bid should be the highest, 45, got %d", bb)
	}
}

func TestTakeCrossesOneLevel(t *testing.T) {
	b := NewBook()
	b.Place(Ask, 49, alice, 100) // price 50
	// A buyer willing to pay up to price 60 (tick 59) buys 40.
	filled, notional, crossed := b.Take(Bid, 59, 40)
	if filled != 40 {
		t.Fatalf("should fill 40, got %d", filled)
	}
	if notional != 40*50 {
		t.Fatalf("notional should be 40*50=2000, got %d", notional)
	}
	if crossed != 1 {
		t.Fatalf("should cross one level, got %d", crossed)
	}
	if b.RestingAt(Ask, 49) != 60 {
		t.Fatalf("60 should remain resting, got %d", b.RestingAt(Ask, 49))
	}
}

func TestTakeWalksBestFirstAcrossLevels(t *testing.T) {
	b := NewBook()
	b.Place(Ask, 49, alice, 30) // price 50
	b.Place(Ask, 54, bob, 30)   // price 55
	b.Place(Ask, 59, carol, 30) // price 60
	// Buy 50 up to price 60: takes 30@50 then 20@55.
	filled, notional, crossed := b.Take(Bid, 59, 50)
	if filled != 50 {
		t.Fatalf("should fill 50, got %d", filled)
	}
	if notional != 30*50+20*55 {
		t.Fatalf("notional should be 30*50+20*55=2600, got %d", notional)
	}
	if crossed != 2 {
		t.Fatalf("should cross two levels, got %d", crossed)
	}
	if b.RestingAt(Ask, 54) != 10 {
		t.Fatalf("10 should remain at 55, got %d", b.RestingAt(Ask, 54))
	}
	// The best ask is now tick 54 (50 was consumed).
	if ba, _ := b.BestAsk(); ba != 54 {
		t.Fatalf("best ask should move to 54, got %d", ba)
	}
}

func TestLimitStopsTheWalk(t *testing.T) {
	b := NewBook()
	b.Place(Ask, 49, alice, 30) // price 50
	b.Place(Ask, 54, bob, 30)   // price 55
	// Buyer will pay only up to price 50 (tick 49): should fill 30 and stop.
	filled, notional, crossed := b.Take(Bid, 49, 100)
	if filled != 30 || notional != 30*50 || crossed != 1 {
		t.Fatalf("limit should cap fill at 30@50; got filled=%d notional=%d crossed=%d", filled, notional, crossed)
	}
}

func TestSellerCrossesBidsHighestFirst(t *testing.T) {
	b := NewBook()
	b.Place(Bid, 40, alice, 30) // price 41
	b.Place(Bid, 44, bob, 30)   // price 45
	b.Place(Bid, 30, carol, 30) // price 31
	// Seller will accept down to price 41 (tick 40), sells 50: 30@45 then 20@41.
	filled, notional, crossed := b.Take(Ask, 40, 50)
	if filled != 50 {
		t.Fatalf("should fill 50, got %d", filled)
	}
	if notional != 30*45+20*41 {
		t.Fatalf("notional should be 30*45+20*41=2170, got %d", notional)
	}
	if crossed != 2 {
		t.Fatalf("should cross two levels, got %d", crossed)
	}
}

func TestProRataWithinTick(t *testing.T) {
	b := NewBook()
	// Two makers, same tick, sizes 60 and 40 (total 100).
	ida := b.Place(Ask, 49, alice, 60)
	idb := b.Place(Ask, 49, bob, 40)
	// A buyer takes 50 of the 100 -> each maker filled pro-rata: 30 and 20.
	b.Take(Bid, 59, 50)
	_, fa, na := b.Collect(alice, ida)
	_, fb, nb := b.Collect(bob, idb)
	if fa != 30 || fb != 20 {
		t.Fatalf("pro-rata should fill 30/20, got %d/%d", fa, fb)
	}
	if na != 30*50 || nb != 20*50 {
		t.Fatalf("maker coin should be 1500/1000, got %d/%d", na, nb)
	}
	// Their fills sum to exactly the taker's fill (exact division, no dust).
	if fa+fb != 50 {
		t.Fatalf("maker fills should sum to the taker's 50, got %d", fa+fb)
	}
}

func TestCollectIsIdempotentPerFill(t *testing.T) {
	b := NewBook()
	id := b.Place(Ask, 49, alice, 100)
	b.Take(Bid, 59, 40)
	_, f1, _ := b.Collect(alice, id)
	if f1 != 40 {
		t.Fatalf("first collect should be 40, got %d", f1)
	}
	// Nothing new filled: a second collect pays zero.
	_, f2, n2 := b.Collect(alice, id)
	if f2 != 0 || n2 != 0 {
		t.Fatalf("second collect with no new fill should be 0/0, got %d/%d", f2, n2)
	}
	// More fills, then collect only the increment.
	b.Take(Bid, 59, 30)
	_, f3, _ := b.Collect(alice, id)
	if f3 != 30 {
		t.Fatalf("third collect should be the 30 increment, got %d", f3)
	}
}

func TestFullyFilledOrderIsDropped(t *testing.T) {
	b := NewBook()
	id := b.Place(Ask, 49, alice, 50)
	b.Take(Bid, 59, 50)
	if !b.Exists(id) {
		t.Fatal("order should still exist until collected")
	}
	b.Collect(alice, id)
	if b.Exists(id) {
		t.Fatal("a fully filled, collected order should be dropped")
	}
}

func TestCancelRefundsRemainderAndSettlesFill(t *testing.T) {
	b := NewBook()
	id := b.Place(Ask, 49, alice, 100)
	b.Take(Bid, 59, 30) // 30 filled, 70 resting
	side, filled, refunded := b.Cancel(alice, id)
	if side != Ask {
		t.Fatal("side should be Ask")
	}
	if filled != 30 {
		t.Fatalf("filled part should be 30, got %d", filled)
	}
	if refunded != 70 {
		t.Fatalf("refund should be 70, got %d", refunded)
	}
	if b.RestingAt(Ask, 49) != 0 {
		t.Fatalf("resting should be 0 after cancel, got %d", b.RestingAt(Ask, 49))
	}
	if b.Exists(id) {
		t.Fatal("cancelled order should be gone")
	}
	if _, ok := b.BestAsk(); ok {
		t.Fatal("level emptied by cancel should clear occupancy")
	}
}

func TestCancelOneOfTwoLeavesTheOther(t *testing.T) {
	b := NewBook()
	ida := b.Place(Ask, 49, alice, 60)
	idb := b.Place(Ask, 49, bob, 40)
	// alice cancels her unfilled 60; bob's 40 stays and the level survives.
	_, f, refunded := b.Cancel(alice, ida)
	if f != 0 || refunded != 60 {
		t.Fatalf("alice cancel should refund 60, filled 0; got filled=%d refund=%d", f, refunded)
	}
	if b.RestingAt(Ask, 49) != 40 {
		t.Fatalf("bob's 40 should remain, got %d", b.RestingAt(Ask, 49))
	}
	// bob still fills fully against a taker.
	b.Take(Bid, 59, 40)
	_, fb, _ := b.Collect(bob, idb)
	if fb != 40 {
		t.Fatalf("bob should fill 40 after alice's cancel, got %d", fb)
	}
}

func TestNonCrossingGuard(t *testing.T) {
	b := NewBook()
	b.Place(Ask, 50, alice, 10) // best ask price 51
	// A bid at tick 50 (price 51) or above would cross -> panic.
	shouldPanic(t, "crossing bid", func() { b.Place(Bid, 50, bob, 10) })
	shouldPanic(t, "crossing bid above", func() { b.Place(Bid, 60, bob, 10) })
	// A bid strictly below is fine.
	b.Place(Bid, 49, bob, 10) // best bid price 50
	// An ask at or below the best bid would cross.
	shouldPanic(t, "crossing ask", func() { b.Place(Ask, 49, carol, 10) })
	shouldPanic(t, "crossing ask below", func() { b.Place(Ask, 30, carol, 10) })
}

func TestBidTakerCoinConservation(t *testing.T) {
	// The coin a buyer pays into the ask pool is exactly what ask-makers collect
	// out of it (here divisions are exact, so no dust).
	b := NewBook()
	ids := []uint64{
		b.Place(Ask, 49, alice, 40), // price 50
		b.Place(Ask, 49, bob, 60),   // price 50, same tick
		b.Place(Ask, 54, carol, 50), // price 55
	}
	_, takerNotional, _ := b.Take(Bid, 59, 150) // buys all 150
	makers := []address{alice, bob, carol}
	var paidOut, sharesOut int64
	for i, id := range ids {
		_, f, n := b.Collect(makers[i], id)
		paidOut += n
		sharesOut += f
	}
	if paidOut != takerNotional {
		t.Fatalf("coin paid to makers (%d) must equal taker notional (%d)", paidOut, takerNotional)
	}
	if sharesOut != 150 {
		t.Fatalf("shares delivered to makers (%d) must equal the 150 filled", sharesOut)
	}
}

func TestProRataDustNeverOverpays(t *testing.T) {
	// Inexact division: makers' fills must sum to AT MOST the taker's fill.
	b := NewBook()
	ids := []uint64{
		b.Place(Ask, 49, alice, 33),
		b.Place(Ask, 49, bob, 33),
		b.Place(Ask, 49, carol, 34),
	}
	filled, _, _ := b.Take(Bid, 59, 50) // 50 of 100, non-round split
	makers := []address{alice, bob, carol}
	var sum int64
	for i, id := range ids {
		_, f, _ := b.Collect(makers[i], id)
		sum += f
	}
	if sum > filled {
		t.Fatalf("makers over-filled: sum %d > taker filled %d", sum, filled)
	}
	if filled-sum > int64(len(ids)) {
		t.Fatalf("dust %d exceeds one unit per maker", filled-sum)
	}
}

func TestMakerJoiningMidStreamOnlyGetsLaterFills(t *testing.T) {
	b := NewBook()
	ida := b.Place(Ask, 49, alice, 100)
	b.Take(Bid, 59, 100) // alice fully filled
	// bob joins the now-empty tick and only sees the next fill.
	idb := b.Place(Ask, 49, bob, 50)
	b.Take(Bid, 59, 50)
	_, fb, _ := b.Collect(bob, idb)
	if fb != 50 {
		t.Fatalf("bob should get the whole later fill, got %d", fb)
	}
	// alice's fill is still exactly her 100, not inflated by bob's round.
	if f := b.OrderFilled(ida); f != 100 {
		t.Fatalf("alice should stay at 100, got %d", f)
	}
}

func TestDifferentJoinTimesFillByRemaining(t *testing.T) {
	// The case a per-original-unit accumulator gets wrong: alice fills partway,
	// bob joins, and the next take must split by REMAINING size, not original.
	b := NewBook()
	ida := b.Place(Ask, 49, alice, 100)
	b.Take(Bid, 59, 40) // alice: 40 filled, 60 remaining
	idb := b.Place(Ask, 49, bob, 100)
	// resting is now 60 (alice) + 100 (bob) = 160. Take 100 -> alice gets
	// 100*60/160 = 37 (floor of 37.5), bob 100*100/160 = 62 (floor of 62.5).
	b.Take(Bid, 59, 100)
	fa := b.OrderFilled(ida)
	fb := b.OrderFilled(idb)
	if fa != 77 { // 40 + 37
		t.Fatalf("alice should be 40+37=77 by remaining-weighted split, got %d", fa)
	}
	if fb != 62 {
		t.Fatalf("bob should be 62 by remaining-weighted split, got %d", fb)
	}
	// Never more than the 140 the takers actually filled.
	if fa+fb > 140 {
		t.Fatalf("makers over-filled: %d > 140", fa+fb)
	}
}

func TestTickReuseAcrossEpochs(t *testing.T) {
	// A tick emptied by a full fill, then reused, must not let the old order's
	// stale baseline corrupt the new order — the epoch bump handles it.
	b := NewBook()
	ida := b.Place(Ask, 49, alice, 100)
	b.Take(Bid, 59, 100) // alice fully filled, tick empties (surv -> 0, epoch ends)
	// Reuse the tick BEFORE alice collects.
	idb := b.Place(Ask, 49, bob, 40)
	b.Take(Bid, 59, 25)
	// alice is still owed her full 100 (epoch behind the tick's).
	if fa := b.OrderFilled(ida); fa != 100 {
		t.Fatalf("alice from the old epoch should read fully filled 100, got %d", fa)
	}
	// bob sees only his own epoch's fill.
	if fb := b.OrderFilled(idb); fb != 25 {
		t.Fatalf("bob should read 25, got %d", fb)
	}
	// And alice can still collect her 100.
	_, fa, _ := b.Collect(alice, ida)
	if fa != 100 {
		t.Fatalf("alice collect should pay 100, got %d", fa)
	}
}

func TestManySmallFillsStayConservative(t *testing.T) {
	// Drip a tick down in many small takes; the maker's total fill must never
	// exceed what was taken, and should land close to it.
	b := NewBook()
	id := b.Place(Ask, 49, alice, 1000)
	var taken int64
	for i := 0; i < 20; i++ {
		f, _, _ := b.Take(Bid, 59, 37) // 37 does not divide 1000 evenly
		taken += f
	}
	filled := b.OrderFilled(id)
	if filled > taken {
		t.Fatalf("maker fill %d exceeds taken %d", filled, taken)
	}
	if taken-filled > 20 {
		t.Fatalf("drift %d too large over 20 fills", taken-filled)
	}
}

func TestMaxLevelsBoundsTheWalk(t *testing.T) {
	b := NewBook()
	// One share on every one of the 40 lowest ask ticks.
	for tk := uint8(0); tk < 40; tk++ {
		b.Place(Ask, tk, alice, 1)
	}
	// Demand 40 but the walk is capped at maxLevels.
	filled, _, crossed := b.Take(Bid, 99, 40)
	if crossed > maxLevels {
		t.Fatalf("crossed %d exceeds the %d level budget", crossed, maxLevels)
	}
	if filled != int64(maxLevels) {
		t.Fatalf("one share per level, so fill should equal the budget %d, got %d", maxLevels, filled)
	}
}

func TestCancelCannotOverRefund(t *testing.T) {
	// The drain the audit found: a fractional fill floors to 0, so qty-filled
	// would refund the whole order while a taker already took a share. The refund
	// is capped at the resting the book tracks, so taker + refund never exceeds
	// the escrow.
	b := NewBook()
	id := b.Place(Ask, 49, alice, 3)
	filled, _, _ := b.Take(Bid, 59, 1) // 1 of the 3 taken
	if filled != 1 {
		t.Fatalf("taker should fill 1, got %d", filled)
	}
	_, _, refunded := b.Cancel(alice, id)
	if filled+refunded > 3 {
		t.Fatalf("taker(%d)+refund(%d) exceeds the 3-share escrow", filled, refunded)
	}
	if refunded != 2 {
		t.Fatalf("refund should be capped at the 2 still resting, got %d", refunded)
	}
}

func TestLargeTickDoesNotFreezeSurv(t *testing.T) {
	// Past the old 1e9 scale a one-share fill left surv unmoved, stranding makers
	// at filled=0 and making the over-refund unbounded. The wider scale resolves
	// single-share fills on a big tick and stays solvent.
	b := NewBook()
	big := int64(2_000_000_000) // 2e9, past the old uint32 1e9 scale
	id := b.Place(Ask, 49, alice, big)
	var taken int64
	for i := 0; i < 500; i++ {
		f, _, _ := b.Take(Bid, 59, 1)
		taken += f
	}
	if taken != 500 {
		t.Fatalf("500 one-share takes should fill 500, got %d", taken)
	}
	if got := b.OrderFilled(id); got <= 0 || got > 500 {
		t.Fatalf("maker fill should track the takes, not freeze at 0; got %d", got)
	}
	_, filled, refunded := b.Cancel(alice, id)
	if taken+refunded != big {
		t.Fatalf("taken(%d)+refund(%d) must equal the %d escrow", taken, refunded, big)
	}
	if filled <= 0 {
		t.Fatalf("maker's filled part should be positive, got %d", filled)
	}
}

func TestAskPoolSharesStaySolvent(t *testing.T) {
	// Mirror the realm's ask-share escrow pool: shares in on Place(Ask), out on a
	// bid-Take and on a Cancel refund. It must never go negative, and must drain
	// to exactly zero once every order is taken or cancelled. Mixes a tiny order
	// (the fractional-dust case) and a huge one (the freeze case).
	b := NewBook()
	var pool int64
	place := func(tick uint8, who address, qty int64) uint64 {
		pool += qty
		return b.Place(Ask, tick, who, qty)
	}
	take := func(qty int64) {
		f, _, _ := b.Take(Bid, 99, qty)
		pool -= f
		if pool < 0 {
			t.Fatalf("ask pool went negative on take: %d", pool)
		}
	}
	cancel := func(who address, id uint64) {
		_, _, r := b.Cancel(who, id)
		pool -= r
		if pool < 0 {
			t.Fatalf("ask pool went negative on cancel: %d", pool)
		}
	}
	i1 := place(49, alice, 100)
	i2 := place(49, bob, 3) // tiny — the fractional-dust order
	take(1)
	i3 := place(50, carol, 2_000_000_000) // huge — the old freeze case
	take(500)                             // clears tick 49, bites into tick 50
	cancel(alice, i1)
	cancel(bob, i2)
	take(1_000_000_000)
	cancel(carol, i3)
	if pool != 0 {
		t.Fatalf("ask pool should drain to exactly 0, got %d", pool)
	}
}

func TestGuards(t *testing.T) {
	b := NewBook()
	shouldPanic(t, "place non-positive", func() { b.Place(Ask, 10, alice, 0) })
	shouldPanic(t, "place bad tick", func() { b.Place(Ask, 100, alice, 1) })
	shouldPanic(t, "take non-positive", func() { b.Take(Bid, 50, 0) })
	shouldPanic(t, "take bad limit", func() { b.Take(Bid, 100, 1) })
	shouldPanic(t, "take bad side", func() { b.Take(Side(2), 50, 1) })
	shouldPanic(t, "place beyond precision bound", func() { b.Place(Ask, 20, alice, maxTickResting+1) })
	id := b.Place(Ask, 49, alice, 10)
	shouldPanic(t, "collect by stranger", func() { b.Collect(bob, id) })
	shouldPanic(t, "cancel by stranger", func() { b.Cancel(bob, id) })
	shouldPanic(t, "collect unknown", func() { b.Collect(alice, 9999) })
	shouldPanic(t, "price bad tick", func() { Price(100) })
}
