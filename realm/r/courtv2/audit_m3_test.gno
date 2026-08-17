package courtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

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

// M3-HIGH-1: a conclusive-low flag landing AFTER SettleUndisputed must still
// slash — the reserve retained at settle is the slash's source.
func TestSlashSurvivesSettle(cur realm, t *testing.T) {
	alice := testutils.TestAddress("m3h-alice")
	bob := testutils.TestAddress("m3h-bob")
	carol := testutils.TestAddress("m3h-carol")
	c := testCourt(cur, "m3h1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "m3h1", "Junk that settles then gets flagged")
	matureOI(cur, "m3h1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "m3h1", id, sideYES)
	xbar := XBarFrozen("m3h1", id)
	reserve := xbar * slashXBps / 10000

	// Settle undisputed at 72h: most of the bond returns, the reserve stays.
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "m3h1", id)
	cs := mustClaim(c, id)
	if cs.answerBond != reserve {
		t.Fatalf("the slash reserve must survive settle: answerBond=%d want %d", cs.answerBond, reserve)
	}

	// Now a conclusive-low flag lands (full bar + 2/3 low, undisputed). The
	// slash reserves from the retained bond and burns at the window close.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "m3h1", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "m3h1", id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "m3h1", id)
	if cs.pendingSlash != reserve {
		t.Fatalf("the slash must reserve the retained bond: pendingSlash=%d want %d", cs.pendingSlash, reserve)
	}
	testing.SkipHeights(cs.pendingSlashUntil - runtimeHeight() + 1)
	supplyBefore := c.coin.TotalSupply()
	ResolveSlashWindow(cross(cur), "m3h1", id)
	if got := supplyBefore - c.coin.TotalSupply(); got != reserve {
		t.Fatalf("the slash must burn the retained reserve: burned %d want %d", got, reserve)
	}
}

// TestSlashSurvivesFinalize is the Finalize twin of TestSlashSurvivesSettle
// (audit convergence v0.43). SettleUndisputed retains a slash reserve
// (M3-HIGH-1) but Finalize refunded the WHOLE answer bond — so a claim that
// reaches Finalize via a FAILED dispute round (decidedRounds==0, still
// slash-eligible) and is flagged conclusive-low AFTERWARD (the common case:
// votingBlocks > the escrow window) slashed nothing. Finalize now retains the
// same reserve, so the deterrent holds on the Finalize path too.
func TestSlashSurvivesFinalize(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fbz-alice")
	bob := testutils.TestAddress("fbz-bob")
	carol := testutils.TestAddress("fbz-carol")
	c := testCourt(cur, "fbz1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)
	// Tiny escrow so Finalize is reachable before the flag's window — and so the
	// escrow lapses long before votingBlocks, matching the real ordering.
	c.params.escrowMinBlocks = 10
	c.params.escrowMaxBlocks = 10

	// Staked + answered, then ONE failed dispute round: provisional defaults to
	// the answer with decidedRounds==0 (still slash-eligible) and verdictAt==0
	// (Finalize-able); the answer bond survives intact.
	id := stakeAnswerDispute(cur, "fbz1", alice, bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "fbz1", id)
	testing.SkipHeights(c.params.votingBlocks + 1) // nobody votes → failed quorum
	ResolveDispute(cross(cur), "fbz1", id)
	cs := mustClaim(c, id)
	wantReserve := slashSizeFor(cs) // frozen conviction → stable; ≤ bond (deploy invariant)

	// Finalize after escrow: most of the bond returns, the slash reserve stays.
	if runtimeHeight() < cs.escrowUntil {
		testing.SkipHeights(cs.escrowUntil - runtimeHeight() + 1)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "fbz1", id)
	if cs.answerBond != wantReserve {
		t.Fatalf("the slash reserve must survive Finalize: answerBond=%d want %d", cs.answerBond, wantReserve)
	}

	// A conclusive-low flag lands AFTER finalize. The slash reserves from the
	// retained bond and burns at the counter-window close — the deterrent holds.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "fbz1", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "fbz1", id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "fbz1", id)
	if cs.pendingSlash != wantReserve {
		t.Fatalf("the slash must reserve the retained bond: pendingSlash=%d want %d", cs.pendingSlash, wantReserve)
	}
	testing.SkipHeights(cs.pendingSlashUntil - runtimeHeight() + 1)
	supplyBefore := c.coin.TotalSupply()
	ResolveSlashWindow(cross(cur), "fbz1", id)
	if got := supplyBefore - c.coin.TotalSupply(); got != wantReserve {
		t.Fatalf("the slash must burn the retained reserve: burned %d want %d", got, wantReserve)
	}
}

// M3-MED-1: an inconclusive-low re-flag cannot block Crystallize for free —
// the cooldown after the first inconclusive cycle opens a settle window before
// the griefer can re-flag.
func TestCrystallizeGriefThrottled(cur realm, t *testing.T) {
	alice := testutils.TestAddress("m3m-alice")
	griefer := testutils.TestAddress("m3m-grief")
	c := testCourt(cur, "m3m1", alice, 50_000_000_000)
	c.coin.Mint(griefer, 50_000_000) // dust weight, sealed at qualityEpoch

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "m3m1", "A claim someone wants to stall")
	matureOI(cur, "m3m1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "m3m1", id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "m3m1", id)

	// One dust-low flag cycle (inconclusive-low, bond returned).
	testing.SetRealm(testing.NewUserRealm(griefer))
	OpenFlag(cross(cur), "m3m1", id)
	testing.SetRealm(testing.NewUserRealm(griefer))
	VoteQuality(cross(cur), "m3m1", id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "m3m1", id)

	// The griefer CANNOT immediately re-flag (cooldown), and after the 24h
	// quiet window Crystallize proceeds — the stall is bounded, not free.
	testing.SetRealm(testing.NewUserRealm(griefer))
	uassert.AbortsContains(t, cur, "cooldown after an inconclusive", func() {
		OpenFlag(cross(cur), "m3m1", id)
	})
	testing.SkipHeights(priorityWindowBlocks + 1) // 24h quiet
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "m3m1", id)
	if !Crystallized("m3m1", id) {
		t.Fatal("Crystallize must proceed in the cooldown gap the griefer cannot fill")
	}
}

// M3-LOW-1: a reopen dispute during a pending slash / open counter re-vote must
// supersede it cleanly — the reserve refunds into the bond, the counter closes,
// and no tally is left dangling. Exactly-once on the reserve.
func TestReopenSupersedesCounter(cur realm, t *testing.T) {
	alice := testutils.TestAddress("m3l-alice")
	bob := testutils.TestAddress("m3l-bob")
	carol := testutils.TestAddress("m3l-carol")
	c := testCourt(cur, "m3l1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "m3l1", "Failed round then slash then reopen")
	matureOI(cur, "m3l1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "m3l1", id, sideYES)
	ab := AnswerBond("m3l1", id)
	c.params.escrowMinBlocks = 900_000
	c.params.escrowMaxBlocks = 900_000

	// Round 1 fails quorum → decidedRounds stays 0 (slashable), escrow open.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "m3l1", id)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "m3l1", id)

	// Flag → conclusive slash-low reserves from the (full) bond.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "m3l1", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "m3l1", id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "m3l1", id)
	cs := mustClaim(c, id)
	slash := cs.pendingSlash
	if slash <= 0 {
		t.Fatal("the slash must reserve")
	}

	// Answerer opens the counter re-vote, then a reopen dispute supersedes it.
	testing.SetRealm(testing.NewUserRealm(alice))
	CounterFlag(cross(cur), "m3l1", id)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "m3l1", id)
	if cs.pendingSlash != 0 || cs.counterOpen {
		t.Fatal("a reopen dispute must refund the slash into the bond and close the counter")
	}
	if cs.answerBond != ab {
		t.Fatalf("the reserve must rejoin the bond: answerBond=%d want %d", cs.answerBond, ab)
	}
	// The abandoned counter cannot be resolved against the dispute's tally.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "dispute supersedes", func() {
		ResolveCounter(cross(cur), "m3l1", id)
	})
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
	testing.SkipHeights(EscrowUntil("mf1", id) - runtimeHeight())
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
