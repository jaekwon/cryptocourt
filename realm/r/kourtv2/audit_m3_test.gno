package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// WHAT THIS FILE LOST WITH THE QUALITY LANE, recorded rather than dropped.
//
// Seven adversarial cases here were about the flag/slash mechanism, and they die
// with it — not because they were wrong, but because the thing they attacked no
// longer exists. Named so that a future reader can tell a finding that was
// RETIRED from one that was never found:
//
//	M3-HIGH-1  TestSlashSurvivesSettle, TestSlashSurvivesFinalize — the reserve
//	           had to survive both terminal paths, which is why settleAnswerBond
//	           carved it. No reserve now; the bond simply refunds.
//	M3-HIGH-2  TestSettleRetainsNothingAfterConsumedSlot,
//	           TestSettleRetainsNothingAfterDustLowNoSlash,
//	           TestFinalizeRetainsNothingAfterDustLowNoSlash — retention had to be
//	           conditional on an adjudication. It is now unconditionally nothing,
//	           and TestSettleRefundsTheWholeAnswerBond below pins that directly.
//	M3-MED-1   TestCrystallizeGriefThrottled — a griefer re-flagging to stall
//	           Crystallize. The vector required OpenFlag; there is no flag to
//	           re-open, so the cooldown that bounded it is gone too.
//	M3-LOW-1   TestReopenSupersedesCounter — a reopen landing on a pending slash
//	           and an open counter re-vote. Both states are unreachable.
//
// THE ONE TO WATCH. M3-MED-1 was a liveness finding: something cheap could delay
// Crystallize. Removing the flag removed that particular lever, but disputes are
// still openable and still delay crystallization, so if a stall vector is ever
// looked for again, that is where it will be — not here.

// SETTLE RETURNS THE WHOLE ANSWER BOND. Three tests above used to assert this
// conditionally, because settle carved a slash reserve out of the bond first and
// the carve depended on whether the claim had been adjudicated. With the lane
// gone the reserve is provably always zero, so the property is unconditional and
// is worth one direct assertion rather than three fixtures approaching it.
func TestSettleRefundsTheWholeAnswerBond(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sb-alice")
	c := testCourt(cur, "sb1", alice, 50_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "sb1", "Does settle return the bond?")
	matureOI(cur, "sb1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "sb1", id, sideYES)

	cs := mustClaim(c, id)
	bond := cs.answerBond
	if bond <= 0 {
		t.Fatal("fixture is vacuous: no answer bond was posted")
	}
	before := c.coin.BalanceOf(alice)

	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "sb1", id)

	uassert.Equal(t, before+bond, c.coin.BalanceOf(alice))
	uassert.Equal(t, int64(0), cs.answerBond)
}

// M3-CRITICAL-1: a senior entitlement enqueued AFTER a junior draw must not be
// paid from accrual the junior already minted. The load-bearing invariant is
// emittedTotal ≤ cumAccrual (the 20%/yr ceiling). Direct-call unit test in the
// reservoir-limited regime the bug needed (D drains R to 0, then a carrot-style
// senior enqueues and is fully pulled).
func TestReservoirNoOvermintJuniorThenSenior(cur realm, t *testing.T) {
	alice := testutils.TestAddress("m3c-alice")
	c := testCourt(cur, "m3c1", alice, 50_000_000_000)
	// Roll one period so a budget accrues, then advance a little into the next.
	testing.SkipHeights(periodBlocks + 5_000)
	touch(c)
	if c.cumAccrual <= 0 {
		t.Fatal("need accrual to exercise the reservoir")
	}

	// Junior draws the whole reservoir.
	r0 := c.reservoirR()
	d := reserveJunior(c, r0)
	if d != r0 || c.reservoirR() != 0 {
		t.Fatalf("junior should drain R: d=%d r0=%d left=%d", d, r0, c.reservoirR())
	}
	mintEmission(c, alice, d) // the eager junior mint (as crystallize's pulls do)

	// A senior (carrot/comp/bounty) enqueued AFTER the junior. Before the fix
	// it started at reservedTail (== 0 here) and PullSenior re-paid the drained
	// accrual. It must instead sit past juniorReserved and pay only NEW accrual.
	seq := enqueueSenior(c, alice, d, "carrot")
	paidNow := PullSenior(cross(cur), "m3c1", seq)
	if paidNow != 0 {
		t.Fatalf("a post-junior senior must not pay from junior-consumed accrual: paid %d", paidNow)
	}
	if c.emittedTotal > c.cumAccrual {
		t.Fatalf("OVERMINT: emittedTotal=%d > cumAccrual=%d", c.emittedTotal, c.cumAccrual)
	}
	// Once fresh accrual covers it, the senior pays — and never past the ceiling.
	testing.SkipHeights(periodBlocks)
	PullSenior(cross(cur), "m3c1", seq)
	if c.emittedTotal > c.cumAccrual {
		t.Fatalf("OVERMINT after accrual: emittedTotal=%d > cumAccrual=%d", c.emittedTotal, c.cumAccrual)
	}
}

// Audit-final MED: an OVERTURNED answerer draws NO answerer emission slice —
// the answer never stood (bond burned, record reset). The winning (NO) side
// must carry conviction so D>0, isolating the answerer-slice gate.
func TestOverturnedAnswererDrawsNoSlice(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mf-alice") // author + answerer (wrong)
	ned := testutils.TestAddress("mf-ned")     // stakes NO early: the winning conviction
	bob := testutils.TestAddress("mf-bob")     // disputer
	carol := testutils.TestAddress("mf-carol") // overturns
	c := testCourt(cur, "mf1", alice, 50_000_000_000)
	c.coin.Mint(ned, 10_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "mf1", "A wrong answer that gets overturned")
	// NO side builds real conviction over time (the eventual winners).
	testing.SetRealm(testing.NewUserRealm(ned))
	Stake(cross(cur), "mf1", id, sideNO, 400_000_000)
	testing.SkipHeights(epochBlocks * 3)
	matureOI(cur, "mf1", id, alice, 200_000_000) // answerability on total stake
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "mf1", id, sideYES) // the WRONG answer

	// Dispute → overturn to NO.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "mf1", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "mf1", id, "yes")
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "mf1", id)
	if Provisional("mf1", id) != sideNO {
		t.Fatal("the answer must be overturned to NO")
	}
	testing.SkipHeights(EscrowUntil("mf1", id) - heightNow())
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "mf1", id)
	if AnswerRecord("mf1", alice) != 0 {
		t.Fatal("an overturn resets the record")
	}

	// Cross a period so the reservoir has a budget, then crystallize.
	testing.SkipHeights(periodBlocks)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "mf1", id)
	_, _, ans, _ := DrawSlices("mf1", id)
	if ans != 0 {
		t.Fatalf("an overturned answer draws NO answerer slice: got %d", ans)
	}
	// The winning (NO) side still draws — D>0, so this isolates the gate.
	w, _, _, _ := DrawSlices("mf1", id)
	if w <= 0 {
		t.Fatal("the winning side must still have a live draw (D>0)")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	if got := AnswererBonus(cross(cur), "mf1", id); got != 0 {
		t.Fatalf("the overturned answerer's bonus must be zero: got %d", got)
	}
}
