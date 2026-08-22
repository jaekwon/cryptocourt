package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// THE ENTITLEMENT QUEUE'S OWN INVARIANT, which nothing walked.
//
// enqueueSenior states it in prose: "Placing it past juniorReserved keeps the whole
// number line disjoint: seniors and juniors tile [0, reservedTail+juniorReserved)
// without overlap." That sentence is the repair for audit M3-CRITICAL-1 — juniors mint
// eagerly and occupy accrual at [reservedTail, reservedTail+juniorReserved) without
// advancing reservedTail, so a senior placed at the bare tail would be paid accrual a
// junior had already minted, driving emittedTotal past cumAccrual and breaking the
// ceiling.
//
// WHAT THIS ADDS, stated honestly, because the first draft of this comment overclaimed.
// It is true that no test walks c.queue — measured by grepping the suite for c.queue,
// .queue.Iterate and queueSeq: nothing. It is NOT true that "any other way of breaking
// the tiling was free": the corpus already carries five caught rows over these cursors
// (the M3 start, the tail not advancing, seniorOwed not growing, the seq not advancing,
// and PullSenior not reducing seniorOwed). So this test buys no new mutation coverage
// today. What it buys is a DIRECT assertion, walked over the queue as a whole, that
// holds for enqueue paths which do not exist yet — the five rows each catch their
// mutation through some downstream consequence, and a future writer who adds a second
// way to seat an entitlement gets no row for free.
//
// AND THE PLACEMENT ASSERTION IS THE ONE THAT NAMES M3. A first draft asserted only
// senior-vs-senior disjointness, and under the M3 mutation that passes: with
// start = reservedTail the seniors tile CONTIGUOUSLY, start == prevEnd exactly, and
// nothing overlaps — among seniors. What M3 breaks is the senior/JUNIOR boundary, which
// senior-vs-senior ordering cannot see. That draft still went red, but via a gap
// counter it also carried, reporting "this fixture cannot tell disjoint from
// contiguous" — a message about the fixture, for a defect in the money path. The
// placement check is therefore written as the arithmetic the invariant claims:
//
//	start_i  ==  (senior amounts enqueued before i)  +  (juniorReserved at i)
//
// Under M3 the second term vanishes and the assertion fires with the consequence named.
func TestTheEntitlementQueueTilesTheAccrualLineWithoutOverlap(cur realm, t *testing.T) {
	alice := testutils.TestAddress("qtile-alice")
	bob := testutils.TestAddress("qtile-bob")
	c := testCourt(cur, "qtile", alice, 60_000_000_000)

	// Accrue something, or reserveJunior clamps every request to an empty reservoir
	// and juniorReserved never moves — the placement assertion would be vacuous.
	testing.SkipHeights(periodBlocks * 2)
	touch(c)

	sums := func() (total, owed, paid int64, seen int) {
		c.queue.Iterate("", "", func(_ string, v any) bool {
			if e, ok := v.(*entitlement); ok {
				total = mustAdd(total, e.amount)
				seen++
			}
			return false
		})
		return total, c.seniorOwed, c.seniorPaid, seen
	}

	// Baselines: this realm is shared, so neither cursor starts at zero and the
	// expected placements below are relative to whatever they hold now.
	tail0, jr0 := c.reservedTail, c.juniorReserved

	// Interleave: senior, junior draw, senior, junior draw, senior. The draws are what
	// make the placement assertion discriminating — with no junior draw at all the
	// second term is zero and M3 is unobservable.
	const a1, a2, a3 = int64(3_000_000), int64(5_000_000), int64(2_000_000)
	s1 := enqueueSenior(c, alice, a1, "comp")
	j1 := reserveJunior(c, 1_500_000)
	s2 := enqueueSenior(c, bob, a2, "bounty")
	j2 := reserveJunior(c, 900_000)
	s3 := enqueueSenior(c, alice, a3, "carrot")

	if j1 <= 0 || j2 <= 0 {
		t.Fatalf("setup: both junior draws must reserve something, or the placement "+
			"assertion cannot see M3: j1=%d j2=%d", j1, j2)
	}

	// PLACEMENT — the M3 property itself. Each senior must start past every junior
	// draw banked when it was seated, not merely past the previous senior.
	placed := []struct {
		seq   uint64
		want  int64
		after string
	}{
		{s1, tail0 + 0 + jr0, "no draw yet"},
		{s2, tail0 + a1 + jr0 + j1, "one junior draw"},
		{s3, tail0 + a1 + a2 + jr0 + j1 + j2, "two junior draws"},
	}
	for _, p := range placed {
		v := c.queue.Get(beClaimKey(p.seq))
		if v == nil {
			t.Fatalf("setup: entitlement %d is not in the queue", p.seq)
		}
		if got := v.(*entitlement).start; got != p.want {
			t.Fatalf("entitlement %d (%s) starts at %d, must start at %d — it is "+
				"short by %d, which is accrual the juniors already minted. A senior "+
				"paid from that stretch is paid twice and drives emittedTotal past "+
				"cumAccrual (audit M3-CRITICAL-1)",
				p.seq, p.after, got, p.want, p.want-got)
		}
	}

	// NO SEPARATE DISJOINTNESS WALK, and that is a decision rather than an omission.
	// A draft carried one — `e.start >= prevEnd` in seq order, plus a counter proving
	// at least one real gap existed. It cannot fail on its own: placement above pins
	// each start to an exact value, so any mutation that puts two seniors over each
	// other changes a start and fires there first. An assertion that can never be the
	// one to go red is the test-side twin of a mutation that cannot change behaviour —
	// it reads as coverage and measures nothing. The amounts it also touched are
	// covered by the conservation identity below.

	// CONSERVED before a pull.
	total, owed, paid, seen := sums()
	if seen != 3 {
		t.Fatalf("setup: three entitlements were enqueued, the queue holds %d", seen)
	}
	if total != owed+paid {
		t.Fatalf("the queue holds %d but the ledger says owed %d + paid %d = %d",
			total, owed, paid, owed+paid)
	}

	// ...and after one. A pull moves mass from owed to paid and must move nothing else.
	testing.SkipHeights(periodBlocks * 3)
	testing.SetRealm(testing.NewUserRealm(bob))
	got := PullSenior(cross(cur), "qtile", s1)
	if got <= 0 {
		t.Fatalf("setup: the first entitlement must be payable after three periods, "+
			"paid %d", got)
	}
	total2, owed2, paid2, _ := sums()
	if total2 != total {
		t.Fatalf("a pull changed the queue's total amount from %d to %d", total, total2)
	}
	if total2 != owed2+paid2 {
		t.Fatalf("after paying %d the ledger no longer adds up: queue %d, owed %d, "+
			"paid %d", got, total2, owed2, paid2)
	}
	if paid2-paid != got || owed-owed2 != got {
		t.Fatalf("a pull of %d moved paid by %d and owed by %d; both must be exactly "+
			"the amount paid", got, paid2-paid, owed-owed2)
	}
}
