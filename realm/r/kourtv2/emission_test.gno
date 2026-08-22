package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// rollTo advances k full periods from creation (tests poke via touch).
func rollTo(c *Court, k int64) {
	target := c.createdAt + k*periodBlocks
	testing.SkipHeights(target - heightNow())
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

// P10 — "flooring never loses a unit across a period" — which the source states in
// accrueSegment's own comment and nothing checked. Both halves of the carry survived
// the harness: not adding the carried remainder back in, and discarding it instead of
// keeping it.
//
// TestAccrualIsExactOverAPeriod looks like it covers this and does not, for a reason
// worth writing down: rollTo jumps a WHOLE period in ONE segment, so the numerator is
// budget x periodBlocks, divides exactly, and the remainder machinery never runs. The
// invariant is about PARTIAL segments — the case every real court is in, since any
// state-changing call touches the clock mid-period.
//
// Walked in uneven segments, the carry is what makes the total exact: the numerators
// sum to budget x periodBlocks, so the floors plus the carry chain come to exactly
// budget with nothing left over. Discard the remainder and each segment floors on its
// own, so the period pays SHORT — a slow leak against everyone the accrual owes,
// invisible per segment and permanent in aggregate.
func TestAccrualCarriesItsRemainderAcrossSegments(cur realm, t *testing.T) {
	alice := testutils.TestAddress("p10-alice")
	c := testCourt(cur, "p10", alice, 10_000_000_000)
	rollTo(c, 1)
	budget := c.curPeriodBudget
	if budget <= 0 {
		t.Fatalf("setup: period 1 must carry a live budget, got %d", budget)
	}
	if c.accrualRem != 0 {
		t.Fatalf("setup: period 0 pays nothing, so the carry starts empty: %d",
			c.accrualRem)
	}
	acc0 := c.cumAccrual

	// One period, in three UNEVEN segments instead of one jump.
	spans := []int64{40_321, 40_321, periodBlocks - 2*40_321}
	sawRemainder := false
	for _, span := range spans {
		testing.SkipHeights(span)
		touch(c)
		if c.accrualRem != 0 {
			sawRemainder = true
		}
	}
	// Without this the arms below would pass on spans that all divided exactly,
	// which is the same nothing the whole-period jump proves.
	if !sawRemainder {
		t.Fatal("setup: every span divided exactly, so the carry was never exercised " +
			"— choose spans where budget*blocks is not a multiple of periodBlocks")
	}
	if got := c.cumAccrual - acc0; got != budget {
		t.Fatalf("a period walked in segments must accrue exactly its budget, not %d "+
			"of %d (short by %d)", got, budget, budget-got)
	}
	// And the chain closes: an exact period leaves nothing carried.
	if c.accrualRem != 0 {
		t.Fatalf("a period that came out exact must carry nothing forward: %d",
			c.accrualRem)
	}
}

// The senior QUOTE is what is actually PAID, and the payable figure is correct at
// every stage of an entitlement's life.
//
// PullSenior and SeniorEntitlement are two separate copies of the same four lines
// — `covered = cumAccrual - start`, clamped to the amount, minus what is already
// paid — one to pay and one to quote. The mutation harness found the duplication by
// reporting four of my rows as matching TWICE.
//
// Nothing held the quote side: the only existing assertion reads `to` and `amount`
// and discards the payable with `_, _`. So a claimant asking how much they are owed
// got a number no test had ever checked, from a copy that can drift from the one
// that pays. Inverting `covered - paid` and dropping the zero floor both survived
// the whole suite.
func TestTheSeniorQuoteIsWhatGetsPaid(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sqp-alice")
	carol := testutils.TestAddress("sqp-carol")
	c := testCourt(cur, "sqp", alice, 50_000_000_000)
	rollTo(c, 1)
	budget := c.curPeriodBudget
	// Larger than one period's accrual, so the partial-coverage arm is live and the
	// clamp has something to clamp.
	seq := enqueueSenior(c, carol, budget+budget/2, "comp")

	// Nothing accrued for it yet: nothing owed, nothing paid.
	if _, _, paid, payable := SeniorEntitlement("sqp", seq); paid != 0 || payable != 0 {
		t.Errorf("a fresh entitlement quotes paid=%d payable=%d, want 0/0", paid, payable)
	}

	// One period of accrual. The quote must equal what the payment then hands over —
	// that equality is the whole point, because the two are separate copies of the
	// same arithmetic.
	rollTo(c, 2)
	_, _, _, quoted := SeniorEntitlement("sqp", seq)
	if quoted != budget {
		t.Fatalf("after one period the quote is %d, want the %d budget", quoted, budget)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	got := PullSenior(cross(cur), "sqp", seq)
	if got != quoted {
		t.Errorf("the quote said %d and the payment was %d — the two copies of the "+
			"entitlement arithmetic disagree", quoted, got)
	}

	// Straight after paying, nothing further is owed. Without the zero floor the
	// quote goes NEGATIVE once paid catches up with coverage, and a negative owed
	// figure on a page reads as a claim on the court.
	_, _, paidNow, payableNow := SeniorEntitlement("sqp", seq)
	if payableNow != 0 {
		t.Errorf("straight after payment the quote is %d, want 0", payableNow)
	}
	if paidNow != got {
		t.Errorf("the entitlement records %d paid, want the %d just transferred", paidNow, got)
	}

	// And however long the reservoir runs past it, the quote never carries the
	// entitlement past its own amount.
	rollTo(c, 12)
	_, amount, paidLate, payableLate := SeniorEntitlement("sqp", seq)
	if paidLate+payableLate != amount {
		t.Errorf("paid %d + payable %d is not the %d entitlement — coverage is not "+
			"clamped to what was promised", paidLate, payableLate, amount)
	}
}

// The R_max pause is a CEILING and not a floor: at the cap the period's budget is
// forgone forever rather than banked. accrueSegment decides that with `reservoirR()
// >= rMax()`, and the operator in it is the whole policy — `>` would bank one more
// segment at the cap, `>=` forgoes it.
//
// NOTHING VISITED THE EDGE. TestRMaxPausesAccrual looks like it covers this and
// cannot: it allows R up to `rMax + curPeriodBudget`, a whole period's slack, so the
// `>=`-to-`>` flip stays inside its tolerance. And the tolerance is not sloppiness —
// natural accrual OVERSHOOTS the cap and can never land on it. rollTo banks a whole
// period in ONE segment, and the cap shrinks with the step-down every roll, so R
// arrives at the pause already past it and then sits frozen while rMax keeps falling.
// Measured on this fixture at period 12: R = 149,492,558 against rMax = 140,317,044,
// an overshoot of 9,175,514 — a quarter of the 35,079,261 period budget. The
// exact-equality state is not reachable by waiting.
//
// It IS reachable by SPENDING. A junior draw of exactly the overshoot lands R on the
// cap, and reserveJunior is the same call crystallize makes — so this is a state a
// real court reaches whenever a draw happens to clear the bank exactly.
//
// TWO ORDERINGS CARRY THE TEST. The draw must come after the overshoot exists, or it
// clamps to R and lands somewhere arbitrary; and the one-unit draw must come after
// the pause has been asserted, or the edge is never occupied. The pair is the point:
// AT the cap nothing accrues, ONE UNIT below it the same advance accrues — which is
// also what proves the first half is not passing because the advance was too short to
// accrue anything.
func TestTheReservoirPauseHoldsAtExactlyTheCap(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rmx-alice")
	c := testCourt(cur, "rmx", alice, 10_000_000_000)
	rollTo(c, 1)
	if c.curPeriodBudget <= 0 {
		t.Fatalf("setup: period 1 must carry a live budget, got %d", c.curPeriodBudget)
	}
	// Quiet periods, until the pause has fired on its own and R is past the cap.
	rollTo(c, 12)
	over := c.reservoirR() - c.rMax()
	if over <= 0 {
		t.Fatalf("setup: quiet accrual must overshoot the cap (that is why the edge "+
			"needs a draw to reach): R=%d rMax=%d", c.reservoirR(), c.rMax())
	}

	// Spend exactly the overshoot. R now sits ON the cap.
	if got := reserveJunior(c, over); got != over {
		t.Fatalf("setup: the draw must take the whole %d overshoot, took %d", over, got)
	}
	if r, m := c.reservoirR(), c.rMax(); r != m {
		t.Fatalf("setup: R must sit exactly on the cap, R=%d rMax=%d", r, m)
	}

	// AT the cap: a period's worth of blocks accrues nothing, forever forgone.
	acc0, rem0 := c.cumAccrual, c.accrualRem
	testing.SkipHeights(100)
	touch(c)
	if c.cumAccrual != acc0 {
		t.Fatalf("at exactly the cap accrual must pause: %d units accrued, and the "+
			"reservoir is a ceiling, not a floor", c.cumAccrual-acc0)
	}
	if c.accrualRem != rem0 {
		t.Errorf("a paused segment must not consume the carry either: %d vs %d",
			c.accrualRem, rem0)
	}

	// ONE UNIT below the cap: the same advance accrues. Without this half the
	// assertion above would hold for a fixture that could not accrue at all.
	if got := reserveJunior(c, 1); got != 1 {
		t.Fatalf("setup: a one-unit draw must be taken from a full bank, got %d", got)
	}
	if r, m := c.reservoirR(), c.rMax(); r != m-1 {
		t.Fatalf("setup: R must sit one unit under the cap, R=%d rMax=%d", r, m)
	}
	acc1 := c.cumAccrual
	testing.SkipHeights(100)
	touch(c)
	if c.cumAccrual <= acc1 {
		t.Fatalf("one unit under the cap the same 100 blocks must accrue, got %d",
			c.cumAccrual-acc1)
	}
}
