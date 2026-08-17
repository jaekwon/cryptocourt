package courtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// rollTo advances k full periods from creation (tests poke via touch).
func rollTo(c *Court, k int64) {
	target := c.createdAt + k*periodBlocks
	testing.SkipHeights(target - runtimeHeight())
	touch(c)
}

func TestAccrualIsExactOverAPeriod(cur realm, t *testing.T) {
	alice := testutils.TestAddress("em-alice")
	c := testCourt(cur, "em1", alice, 10_000_000_000) // supply = 1e10
	// Period 0 has budget 0 (set at the roll AFTER supply exists). Roll once:
	rollTo(c, 1)
	budget := c.curPeriodBudget
	// Period 1 carries one amortized step-down (the decay applies at the roll,
	// so no period ever pays the un-decayed rate — no cliff exists, 2A-T3).
	steppedFP := budgetBpsFPStart * stepDownNum / stepDownDen
	want := int64(uint64(10_000_000_000) * uint64(steppedFP) / (10_000 * 1_000_000))
	if budget != want {
		t.Fatalf("period-1 budget = %d, want %d (one decay step)", budget, want)
	}
	acc0 := c.cumAccrual
	rollTo(c, 2) // one full period at that budget
	if got := c.cumAccrual - acc0; got != budget {
		t.Fatalf("a full period must accrue exactly its budget: %d vs %d", got, budget)
	}
}

func TestSeniorsFillBeforeJuniors(cur realm, t *testing.T) {
	alice := testutils.TestAddress("em-sen")
	carol := testutils.TestAddress("em-carol")
	c := testCourt(cur, "em2", alice, 10_000_000_000)
	rollTo(c, 1)
	budget := c.curPeriodBudget

	// Enqueue a senior LARGER than one period's accrual.
	seq := enqueueSenior(c, carol, budget+budget/2, "comp")
	rollTo(c, 2)
	// Everything accrued is senior-reserved: the junior pool is empty.
	if r := c.reservoirR(); r != 0 {
		t.Fatalf("juniors must wait for seniors, R = %d", r)
	}
	if got := reserveJunior(c, 1000); got != 0 {
		t.Fatal("a junior reservation under senior debt must clamp to zero")
	}
	// Partial pull: exactly one period's accrual is payable.
	testing.SetRealm(testing.NewUserRealm(alice))
	paid := PullSenior(cross(cur), "em2", seq)
	if paid != budget {
		t.Fatalf("partial senior fill = %d, want %d", paid, budget)
	}
	if c.coin.BalanceOf(carol) != budget {
		t.Fatal("the pull mints to the entitlement's address")
	}
	// More accrual completes it; junior pool then grows.
	rollTo(c, 3)
	testing.SetRealm(testing.NewUserRealm(alice))
	paid2 := PullSenior(cross(cur), "em2", seq)
	if paid2 <= 0 || c.seniorOwed != 0 {
		t.Fatalf("the remainder must become payable (paid2=%d owed=%d)", paid2, c.seniorOwed)
	}
	if c.reservoirR() <= 0 {
		t.Fatal("past the senior tail, accrual is the junior pool")
	}
	// Double-pull pays nothing (exactly-once).
	testing.SetRealm(testing.NewUserRealm(alice))
	if PullSenior(cross(cur), "em2", seq) != 0 {
		t.Fatal("a settled entitlement pays zero forever")
	}
}

func TestRMaxPausesAccrual(cur realm, t *testing.T) {
	alice := testutils.TestAddress("em-rmax")
	c := testCourt(cur, "em3", alice, 10_000_000_000)
	rollTo(c, 1)
	// A long quiet stretch: the junior pool must cap near rMax, not grow forever.
	rollTo(c, 12)
	if r := c.reservoirR(); r > c.rMax()+c.curPeriodBudget {
		t.Fatalf("quiet accrual must pause at the bank cap: R=%d rMax=%d", r, c.rMax())
	}
	if c.reservoirR() < c.rMax()/2 {
		t.Fatal("the bank should have filled meaningfully before pausing")
	}
}

func TestEmissionFeedsRealizedD(cur realm, t *testing.T) {
	alice := testutils.TestAddress("em-deff")
	carol := testutils.TestAddress("em-deff2")
	c := testCourt(cur, "em4", alice, 10_000_000_000)
	rollTo(c, 1)
	if c.dEffBpsFP != 0 {
		t.Fatal("with no emission history the rate prices the pure-r floor")
	}
	seq := enqueueSenior(c, carol, c.curPeriodBudget, "bounty")
	rollTo(c, 2)
	testing.SetRealm(testing.NewUserRealm(alice))
	PullSenior(cross(cur), "em4", seq)
	rollTo(c, 3)
	if c.dEffBpsFP <= 0 {
		t.Fatal("realized minting must raise d_eff at the next roll")
	}
	if c.dEffBpsFP > c.curBudgetBpsFP {
		t.Fatal("d_eff is capped at the budget ceiling")
	}
}

// TestBudgetAtRealCourtScale is the C1 wrap regression: the naive uint64
// product wrapped at ~485k CC of supply (any real court), silently computing a
// 34x under-budget at 1M CC. 128-bit mulDiv must survive curve-cap scale.
func TestBudgetAtRealCourtScale(cur realm, t *testing.T) {
	alice := testutils.TestAddress("em-big")
	c := testCourt(cur, "em5", alice, 1_000_000_000_000) // 1,000,000 CC
	rollTo(c, 1)
	steppedFP := budgetBpsFPStart * stepDownNum / stepDownDen
	want := mulDiv128(1_000_000_000_000, steppedFP, 10_000*1_000_000)
	if c.curPeriodBudget != want || c.curPeriodBudget < 3_700_000_000 {
		t.Fatalf("1M-CC court budget = %d, want %d (~3,774 CC/wk)", c.curPeriodBudget, want)
	}
	// And at the curve-cap extreme the math must not wrap or panic.
	c2 := testCourt(cur, "em6", alice, curveCap)
	rollTo(c2, 1)
	if c2.curPeriodBudget <= 0 {
		t.Fatal("curve-cap-scale budget must be positive and unwrapped")
	}
}

// THE LOCKED CEILING's enforcement point, found SURVIVING by the mutation harness.
// rollPeriod computes d_eff = min(budget ceiling, 4-period EMA of minted/supply), and
// replacing that comparison with `if true` — so d_eff tracks realized dilution with no
// cap — failed no test. d_eff feeds rateBpsFP, which drives conviction accrual, which
// drives cumAccrual and therefore reservoirR: an uncapped d_eff raises the emission
// ceiling itself, which is the one constraint the owner has locked.
//
// Reachable, not theoretical: curBudgetBpsFP steps DOWN on every roll while emaMinted
// is a 4-period EMA that decays only 3/4 per roll, so realized dilution above the
// (now lower) ceiling is exactly the state the min() exists for. Crafted here the way
// TestP2CarrotClampBindsForASoleVoter crafts carrotTotal, because driving it by
// natural emission would take more periods than a harness can run.
func TestDEffIsCappedByTheWeeklyBudget(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cap-alice")
	c := testCourt(cur, "dcap", alice, 50_000_000_000)

	// Realized dilution far above the ceiling: emaMinted at ~100% of supply.
	c.curBudgetBpsFP = 1_000_000 // a deliberately low ceiling
	c.emaMinted = c.coin.TotalSupply()
	if c.emaMinted <= 0 {
		t.Fatal("setup: the court must have supply to dilute")
	}

	rollPeriod(c)

	// rollPeriod steps the ceiling down first, then caps d_eff to it. Either way
	// d_eff must EQUAL the ceiling here, never the realized rate.
	if c.dEffBpsFP != c.curBudgetBpsFP {
		t.Fatalf("d_eff must be capped by the budget ceiling: dEff=%d budget=%d",
			c.dEffBpsFP, c.curBudgetBpsFP)
	}
	// And the cap is doing real work: realized dilution is orders above it.
	dReal := mulDiv128(c.emaMinted, 10_000*1_000_000, c.coin.TotalSupply())
	if dReal <= c.curBudgetBpsFP {
		t.Fatalf("fixture must place realized dilution ABOVE the ceiling: "+
			"dReal=%d budget=%d", dReal, c.curBudgetBpsFP)
	}

	// The complement: when realized dilution is BELOW the ceiling, d_eff tracks it
	// rather than sitting at the ceiling — so the min() is a min, not a clamp to one
	// side. Without this the mutation "d_eff is always the budget" would survive.
	c.curBudgetBpsFP = 38_000_000
	c.emaMinted = c.coin.TotalSupply() / 1_000_000
	rollPeriod(c)
	if c.dEffBpsFP >= c.curBudgetBpsFP {
		t.Fatalf("below the ceiling d_eff must track realized dilution: dEff=%d budget=%d",
			c.dEffBpsFP, c.curBudgetBpsFP)
	}
}

// The senior QUEUE's own invariants, called DIRECTLY because these are internal —
// the approach settled in v0.60 for mulDiv128 and capBonus and used again in v0.69
// for Params.mustSane. Three guards here survived the harness, and the middle one is
// the expensive kind.
//
// Without the seq bump, the second Set lands on the FIRST entitlement's key. The
// first payee's claim disappears, while reservedTail and seniorOwed still count
// both amounts — a debt the court believes it owes and nobody can ever pull. Note
// what makes it invisible: the queue has no removal (paid entitlements stay with
// paid==amount), so there is no "missing entry" to notice, only a wrong one.
//
// The other two are cheap to hold and awkward to reason about later. A non-positive
// entitlement would sit in the queue forever emitting an event for nothing, and a
// NEGATIVE junior reservation would REDUCE juniorReserved — dragging a later
// senior's start cursor back under the junior stretch, which is precisely the
// overlap M3-CRITICAL-1 exists to prevent.
func TestSeniorQueueRefusesJunkAndNeverOverwrites(cur realm, t *testing.T) {
	mustPanicWith := func(want string, fn func()) {
		t.Helper()
		defer func() {
			r := recover()
			if r == nil {
				t.Fatalf("expected a panic saying %q; nothing panicked", want)
			}
			got, ok := r.(string)
			if !ok || !containsSub(got, want) {
				t.Fatalf("panic %v, want one saying %q", r, want)
			}
		}()
		fn()
	}

	alice := testutils.TestAddress("sq1-alice")
	bob := testutils.TestAddress("sq1-bob")
	c := testCourt(cur, "sq1", alice, 50_000_000_000)

	before := QueueLen("sq1")
	s1 := enqueueSenior(c, alice, 1_000, "comp")
	s2 := enqueueSenior(c, bob, 2_000, "bounty")
	if s1 == s2 {
		t.Fatalf("two entitlements must take distinct seqs, got %d twice", s1)
	}
	if got := QueueLen("sq1"); got != before+2 {
		t.Fatalf("the queue must grow by two: %d vs %d", got, before+2)
	}
	// Both must still be there, each with its OWN payee and amount — the assertion
	// an overwrite fails, since the survivor would answer for both seqs.
	if to, amt, _, _ := SeniorEntitlement("sq1", s1); to != alice || amt != 1_000 {
		t.Fatalf("the first entitlement was lost: to=%s amount=%d", to, amt)
	}
	if to, amt, _, _ := SeniorEntitlement("sq1", s2); to != bob || amt != 2_000 {
		t.Fatalf("the second entitlement is wrong: to=%s amount=%d", to, amt)
	}

	// Junk is refused rather than parked in a queue that never forgets.
	mustPanicWith("must be positive", func() { enqueueSenior(c, alice, 0, "comp") })
	mustPanicWith("must be positive", func() { enqueueSenior(c, alice, -1, "comp") })

	// reserveJunior CLAMPS rather than aborting (F4 — it is on a shared settlement
	// path), and it clamps from below as well as above.
	jr := c.juniorReserved
	if got := reserveJunior(c, -5_000); got != 0 {
		t.Fatalf("a negative junior reservation must reserve nothing, got %d", got)
	}
	if c.juniorReserved != jr {
		t.Fatalf("and must not move juniorReserved: %d vs %d", c.juniorReserved, jr)
	}
}
