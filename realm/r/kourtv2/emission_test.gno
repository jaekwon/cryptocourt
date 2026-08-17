package kourtv2

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
