package courtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// stakeAnswerDispute builds the shared scenario: alice authors+stakes YES and
// answers YES, bob stakes NO. Returns the claim id.
func stakeAnswerDispute(cur realm, slug string, alice, bob address) uint64 {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), slug, "Disputed claim on "+slug)
	matureOI(cur, slug, id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), slug, id, sideNO, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), slug, id, sideYES)
	return id
}

func TestDisputeUpholdPath(cur realm, t *testing.T) {
	alice := testutils.TestAddress("dp1-alice")
	bob := testutils.TestAddress("dp1-bob")
	carol := testutils.TestAddress("dp1-carol")
	dave := testutils.TestAddress("dp1-dave")
	c := testCourt(cur, "dp1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)
	c.coin.Mint(dave, 8_000_000_000)

	id := stakeAnswerDispute(cur, "dp1", alice, bob)
	xbar := XBarFrozen("dp1", id)
	ab := AnswerBond("dp1", id)

	// The quote is the pinned formula: min(20%·X̄frozen, 40%·answer bond).
	wantBond := xbar * disputeBondXBps / 10000
	if arm := ab * disputeBondOfAnswerBps / 10000; arm < wantBond {
		wantBond = arm
	}
	if got := DisputeBondNext("dp1", id); got != wantBond {
		t.Fatalf("bond quote %d, want %d", got, wantBond)
	}

	bobBefore := c.coin.BalanceOf(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "dp1", id)
	if c.coin.BalanceOf(bob) != bobBefore-wantBond {
		t.Fatal("the dispute bond must escrow")
	}
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "already open", func() {
		OpenDispute(cross(cur), "dp1", id)
	})
	// A disputed claim cannot settle undisputed.
	uassert.AbortsContains(t, cur, "settles by vote", func() {
		SettleUndisputed(cross(cur), "dp1", id)
	})
	uassert.AbortsContains(t, cur, "still open", func() {
		ResolveDispute(cross(cur), "dp1", id)
	})

	// Carol upholds (votes "no" on OVERTURN) with quorum-clearing weight;
	// dave votes "yes" with real weight (>= floor/4) and loses — the contest
	// is GENUINE, so the uphold is credential-eligible (M2-1 bar).
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "dp1", id, "no")
	testing.SetRealm(testing.NewUserRealm(dave))
	VoteDispute(cross(cur), "dp1", id, "yes")
	testing.SkipHeights(c.params.votingBlocks + 1)

	supplyBefore := c.coin.TotalSupply()
	testing.SetRealm(testing.NewUserRealm(dave))
	ResolveDispute(cross(cur), "dp1", id) // permissionless
	// UPHOLD: the disputer's bond burned in full — supply deflates...
	if got := supplyBefore - c.coin.TotalSupply(); got != wantBond {
		t.Fatalf("burned %d, want the whole dispute bond %d", got, wantBond)
	}
	// ...and the answerer's comp mints later, senior-queued, capped at
	// min(2×own bond, floor(80%×the burn)) — here the 80% arm binds.
	if got, want := SeniorOwed("dp1"), wantBond*compOfBurnBps/10000; got != want {
		t.Fatalf("comp owed %d, want %d", got, want)
	}
	if Provisional("dp1", id) != sideYES || !Reopenable("dp1", id) {
		t.Fatal("an upheld answer stands provisionally, reopenable through escrow")
	}

	// Loser early-exit (F7): bob (NO) withdraws before finality; the winning
	// side still waits for VERDICT_FINAL.
	testing.SetRealm(testing.NewUserRealm(bob))
	if got := WithdrawStake(cross(cur), "dp1", id, sideNO); got != 300_000_000 {
		t.Fatal("the losing side exits 1x after a decided round")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "no verdict yet", func() {
		WithdrawStake(cross(cur), "dp1", id, sideYES)
	})

	// Finalize: not before escrow; stranger-refused during the grace week;
	// participant lands it. The answer bond returns and the record credits.
	uassert.AbortsContains(t, cur, "escrow window has not passed", func() {
		Finalize(cross(cur), "dp1", id)
	})
	testing.SkipHeights(EscrowUntil("dp1", id) - runtimeHeight())
	testing.SetRealm(testing.NewUserRealm(dave))
	uassert.AbortsContains(t, cur, "participant-only", func() {
		Finalize(cross(cur), "dp1", id)
	})
	aliceBefore := c.coin.BalanceOf(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "dp1", id)
	if !Settled("dp1", id) || Verdict("dp1", id) != sideYES || VerdictRoute("dp1", id) != "vote" {
		t.Fatal("the finalized verdict must record with the vote route")
	}
	// v0.47: an upheld round no longer confers slash immunity, so Finalize
	// retains the slash-sized reserve exactly as SettleUndisputed does — the
	// bond returns MINUS that reserve, and the remainder follows at crystallize
	// if no conclusive-low flag lands. (Before v0.47 a decided round returned
	// the bond whole, which is what made the immunity purchasable.)
	cs := mustClaim(c, id)
	reserve := slashSizeFor(cs)
	if reserve > ab {
		reserve = ab
	}
	if c.coin.BalanceOf(alice) != aliceBefore+ab-reserve {
		t.Fatalf("the upheld bond returns less the slash reserve: got %d want %d",
			c.coin.BalanceOf(alice), aliceBefore+ab-reserve)
	}
	if cs.answerBond != reserve {
		t.Fatalf("the reserve stays collateralized: answerBond=%d want %d", cs.answerBond, reserve)
	}
	if AnswerRecord("dp1", alice) != 1 {
		t.Fatal("contested-and-upheld must credit the difficulty record")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	WithdrawStake(cross(cur), "dp1", id, sideYES)
	uassert.AbortsContains(t, cur, "already final", func() {
		Finalize(cross(cur), "dp1", id)
	})
}

func TestDisputeOverturnPath(cur realm, t *testing.T) {
	alice := testutils.TestAddress("dp2-alice")
	bob := testutils.TestAddress("dp2-bob")
	carol := testutils.TestAddress("dp2-carol")
	c := testCourt(cur, "dp2", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)

	id := stakeAnswerDispute(cur, "dp2", alice, bob)
	ab := AnswerBond("dp2", id)

	bobBefore := c.coin.BalanceOf(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "dp2", id)
	db := bobBefore - c.coin.BalanceOf(bob)

	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "dp2", id, "yes") // OVERTURN
	testing.SkipHeights(c.params.votingBlocks + 1)

	supplyBefore := c.coin.TotalSupply()
	testing.SetRealm(testing.NewUserRealm(carol))
	ResolveDispute(cross(cur), "dp2", id)
	// The ANSWER bond burned in full; the disputer's own bond came back.
	if got := supplyBefore - c.coin.TotalSupply(); got != ab {
		t.Fatalf("burned %d, want the whole answer bond %d", got, ab)
	}
	if c.coin.BalanceOf(bob) != bobBefore {
		t.Fatal("the prevailing disputer's own bond returns whole")
	}
	// Comp = min(2×own bond, floor(80%×burn)), queued to the disputer.
	want := compOwnX * db
	if arm := ab * compOfBurnBps / 10000; arm < want {
		want = arm
	}
	if got := SeniorOwed("dp2"); got != want {
		t.Fatalf("comp owed %d, want %d", got, want)
	}
	if Provisional("dp2", id) != sideNO {
		t.Fatal("an overturn flips the provisional verdict")
	}

	testing.SkipHeights(EscrowUntil("dp2", id) - runtimeHeight())
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "dp2", id)
	if Verdict("dp2", id) != sideNO {
		t.Fatal("the flipped verdict must finalize")
	}
	if AnswerRecord("dp2", alice) != 0 {
		t.Fatal("an overturn resets the answer record")
	}
	// The burned bond never re-appears: alice gets nothing back.
	testing.SetRealm(testing.NewUserRealm(bob))
	WithdrawStake(cross(cur), "dp2", id, sideNO) // now the winning side
	testing.SetRealm(testing.NewUserRealm(alice))
	WithdrawStake(cross(cur), "dp2", id, sideYES)
}

// TestOverturnedVerdictCannotBeFlippedBack pins the two guards that stand between
// a DECIDED verdict and a silent flip back to the answer. Both were previously
// unpinned: their only fixtures satisfied every clause at once, so either guard
// could be deleted with the suite still green (audit convergence v0.45).
//
//   - session.gno: `disputeOpen || round > 0`. The existing fixture settles while
//     the dispute is OPEN, so both clauses hold. Since disputeOpen ⟹ round > 0,
//     `round > 0` is the load-bearing clause, and only a RESOLVED round isolates it.
//   - dispute.gno: `if firstResolution { provisional = answer }` in the failed-quorum
//     branch. Every existing fixture has provisional == answer already, so the
//     assignment is a no-op there and the guard is invisible.
//
// If either fails, provisional flips from the overturn winner back to the answer:
// the entire winners' slice pays the losing side and the true winners are refused.
func TestOverturnedVerdictCannotBeFlippedBack(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ovf-alice")
	bob := testutils.TestAddress("ovf-bob")
	carol := testutils.TestAddress("ovf-carol")
	c := testCourt(cur, "ovf1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)

	// alice answers YES; bob holds the NO side. Bob stakes BEFORE the maturation
	// window so the NO pool carries real conviction — otherwise the winners' draw
	// is zero and step (3) proves nothing about who got paid.
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "ovf1", "Overturned, and it must stay overturned")
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "ovf1", id, sideNO, 300_000_000)
	matureOI(cur, "ovf1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "ovf1", id, sideYES)

	// A decided round OVERTURNS to NO.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "ovf1", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "ovf1", id, "yes")
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "ovf1", id)
	if Provisional("ovf1", id) != sideNO || DisputeOpen("ovf1", id) {
		t.Fatal("setup: the overturn must stand with the dispute closed")
	}

	// (1) Settle must REFUSE. disputeOpen is already false here, so `round > 0` is
	// the only thing preventing settle from reassigning provisional = answer (YES).
	uassert.AbortsContains(t, cur, "settles by vote", func() {
		SettleUndisputed(cross(cur), "ovf1", id)
	})
	if Provisional("ovf1", id) != sideNO || Settled("ovf1", id) {
		t.Fatal("a refused settle must not touch the verdict")
	}

	// (2) A FAILED reopen must leave the decided verdict standing. Only the
	// firstResolution guard prevents the failed-quorum branch from re-defaulting
	// provisional back to the answer.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "ovf1", id)
	testing.SkipHeights(c.params.votingBlocks + 1) // nobody votes → failed quorum
	ResolveDispute(cross(cur), "ovf1", id)
	if Provisional("ovf1", id) != sideNO {
		t.Fatal("a failed reopen must not re-default a decided verdict to the answer")
	}

	// (3) The money follows the verdict: the NO side draws, the overturned YES
	// side is refused — the consequence both guards exist to protect.
	if now := runtimeHeight(); now < EscrowUntil("ovf1", id) {
		testing.SkipHeights(EscrowUntil("ovf1", id) - now)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "ovf1", id)
	if Verdict("ovf1", id) != sideNO {
		t.Fatal("the overturned verdict must finalize as NO")
	}
	testing.SkipHeights(priorityWindowBlocks + 1) // 24h quiet
	testing.SkipHeights(periodBlocks)             // a budget to draw from
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "ovf1", id)
	if w, _, ans, _ := DrawSlices("ovf1", id); w <= 0 || ans != 0 {
		t.Fatalf("winners must draw and the overturned answerer must not: w=%d ans=%d", w, ans)
	}
	testing.SetRealm(testing.NewUserRealm(bob))
	if got := WithdrawBonus(cross(cur), "ovf1", id, sideNO); got <= 0 {
		t.Fatalf("the overturn winner must draw a bonus, got %d", got)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "only the winning side draws", func() {
		WithdrawBonus(cross(cur), "ovf1", id, sideYES)
	})
}

func TestDisputeFailedRoundsToProvClose(cur realm, t *testing.T) {
	alice := testutils.TestAddress("dp3-alice")
	bob := testutils.TestAddress("dp3-bob")
	c := testCourt(cur, "dp3", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	preOpen := c.coin.BalanceOf(alice)
	id := stakeAnswerDispute(cur, "dp3", alice, bob)
	// Widen the escrow window in-test so three week-long rounds fit (on-chain
	// the same shape needs a larger claim's 3-week window; small claims cap at
	// failedRounds=2 and finalize the defaulted verdict — V1's behavior).
	c.params.escrowMinBlocks = 450_000
	c.params.escrowMaxBlocks = 450_000

	db1 := DisputeBondNext("dp3", id)
	for round := int64(1); round <= 3; round++ {
		wantBond := db1 << uint(round-1)
		if got := DisputeBondNext("dp3", id); got != wantBond {
			t.Fatalf("round %d bond %d, want doubled %d", round, got, wantBond)
		}
		bobBefore := c.coin.BalanceOf(bob)
		testing.SetRealm(testing.NewUserRealm(bob))
		OpenDispute(cross(cur), "dp3", id)
		testing.SkipHeights(c.params.votingBlocks + 1) // nobody votes
		ResolveDispute(cross(cur), "dp3", id)
		// Failed quorum: HALF returns, half burns — never to the answerer.
		if got := bobBefore - c.coin.BalanceOf(bob); got != wantBond-wantBond/2 {
			t.Fatalf("round %d cost %d, want the burned half %d", round, got, wantBond-wantBond/2)
		}
		if FailedRounds("dp3", id) != round {
			t.Fatalf("failedRounds after round %d: %d", round, FailedRounds("dp3", id))
		}
	}

	// Three failed rounds: closed without a decision — everyone 1×, deposit
	// AND fee refund, the answer bond returns, no record credit, no comp.
	if !ProvClose("dp3", id) || !Settled("dp3", id) {
		t.Fatal("three failed rounds must provClose")
	}
	shouldPanicV2(t, "without a decision", func() { Verdict("dp3", id) })
	if SeniorOwed("dp3") != 0 {
		t.Fatal("no comp mints on failed rounds")
	}
	if AnswerRecord("dp3", alice) != 0 {
		t.Fatal("a quorum-less default earns no difficulty point")
	}
	testing.SetRealm(testing.NewUserRealm(bob))
	WithdrawStake(cross(cur), "dp3", id, sideNO)
	testing.SetRealm(testing.NewUserRealm(alice))
	WithdrawStake(cross(cur), "dp3", id, sideYES)
	// Alice's full circle: deposit+fee refunded, answer bond returned, stake
	// back — she is exactly whole (she never lost a vote).
	if c.coin.BalanceOf(alice) != preOpen {
		t.Fatalf("author must be whole after provClose: %d vs %d", c.coin.BalanceOf(alice), preOpen)
	}
	// The claim's escrow fully drains: nothing is stranded.
	if got := c.coin.BalanceOf(c.escrow); got != 0 {
		t.Fatalf("escrow must drain to zero after provClose: %d", got)
	}
	// Reopen after finality is refused.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "verdict is final", func() {
		OpenDispute(cross(cur), "dp3", id)
	})
}

func TestDisputeWindowPartition(cur realm, t *testing.T) {
	alice := testutils.TestAddress("dp4-alice")
	bob := testutils.TestAddress("dp4-bob")
	c := testCourt(cur, "dp4", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)

	id := stakeAnswerDispute(cur, "dp4", alice, bob)
	// Past the 72h delay the first dispute is refused — settle owns it.
	testing.SkipHeights(settleDelay)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "dispute window has passed", func() {
		OpenDispute(cross(cur), "dp4", id)
	})
	SettleUndisputed(cross(cur), "dp4", id)
	uassert.AbortsContains(t, cur, "verdict is final", func() {
		OpenDispute(cross(cur), "dp4", id)
	})
}

// The audit-M2-1 regression: a manufactured contest must not mint the
// difficulty credential. The answerer cannot self-dispute at all; a sybil
// dispute whose uphold carries NO adversarial weight (honest voters upholding
// a true claim for free) finalizes with record = 0.
func TestWeightlessContestEarnsNoCredential(cur realm, t *testing.T) {
	alice := testutils.TestAddress("dp5-alice")
	bob := testutils.TestAddress("dp5-bob")
	carol := testutils.TestAddress("dp5-carol")
	c := testCourt(cur, "dp5", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)

	id := stakeAnswerDispute(cur, "dp5", alice, bob)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "cannot dispute their own", func() {
		OpenDispute(cross(cur), "dp5", id)
	})

	// The sybil route: bob (imagine alice's second wallet) disputes; the
	// honest electorate upholds the true answer for free; zero yes-weight.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "dp5", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "dp5", id, "no")
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "dp5", id)
	if Provisional("dp5", id) != sideYES {
		t.Fatal("the uphold itself must still work")
	}
	testing.SkipHeights(EscrowUntil("dp5", id) - runtimeHeight())
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "dp5", id)
	if Verdict("dp5", id) != sideYES {
		t.Fatal("verdict finalizes normally")
	}
	if AnswerRecord("dp5", alice) != 0 {
		t.Fatal("a weightless contest must NOT mint the difficulty credential (M2-1)")
	}
}

// escrowWindow's two arms, both unpinned: making it ignore extraDays entirely (always
// the minimum) failed no test. The window is min + one day per 500 GNOT of X̄·Price,
// clamped at max — so it is the reopen budget, and how fast it grows decides how many
// rounds fit inside one claim.
//
// This also makes PLAN §12 row 30 MEASURABLE instead of prose. That row's original
// premise was "3 failed rounds fit only inside >2-week escrows (large claims); small
// claims cap at 2 failed rounds", corrected in v0.49 to: the window pins at the 3-week
// max as soon as X̄·Price clears the room, which a modest claim reaches once the curve
// has any real price. The second case below pins exactly that — the cap arm binding on a
// claim that is not large — so a future change to the geometry fails here rather than
// silently changing how much griefing fits in a window.
func TestEscrowWindowGrowsThenPinsAtTheCap(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ewn-alice")
	// The curve must have been BOUGHT INTO for the window to grow at all: Price(0) is
	// zero, so extraDays is zero and every claim sits at escrowMin. That is not an
	// artefact — it is the cold-start half of §12 row 30's corrected premise, that the
	// window only starts growing "once the curve has any real price".
	// Price(s) = s/d with integer division and d ~= 1e9, so a small buy still floors
	// the price to zero. Buy enough to move it off zero.
	fundAndBuy(cur, "ewn", alice, 5_000_000_000)
	c := mustCourt("ewn")
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "ewn", "the reopen budget")
	cs := mustClaim(c, id)

	room := (c.params.escrowMaxBlocks - c.params.escrowMinBlocks) / oneDayBlocks
	if room <= 1 {
		t.Fatalf("setup: the default params must leave room to grow: %d days", room)
	}

	// A claim whose X̄·Price buys ZERO extra days sits exactly at the minimum.
	cs.xBarFrozen = 0
	if got := escrowWindow(c, cs); got != c.params.escrowMinBlocks {
		t.Fatalf("no X̄ buys no extra days: got %d want %d", got, c.params.escrowMinBlocks)
	}

	// One that buys SOME grows by whole days — the arm that "always the minimum" breaks.
	price := c.crv.Price(c.minted)
	if price <= 0 {
		t.Fatal("setup: the curve must quote a price")
	}
	cs.xBarFrozen = 500_000_000 / price * 2 // ~2 days' worth
	grown := escrowWindow(c, cs)
	if grown <= c.params.escrowMinBlocks {
		t.Fatalf("X̄·Price must buy extra days: got %d min %d (xBar=%d price=%d)",
			grown, c.params.escrowMinBlocks, cs.xBarFrozen, price)
	}
	if grown >= c.params.escrowMaxBlocks {
		t.Fatalf("fixture must sit strictly between the arms: got %d max %d",
			grown, c.params.escrowMaxBlocks)
	}
	if (grown-c.params.escrowMinBlocks)%oneDayBlocks != 0 {
		t.Fatalf("the window grows in WHOLE days: %d", grown-c.params.escrowMinBlocks)
	}

	// And one that buys more than the room pins at the cap, never past it (§12 row 30).
	cs.xBarFrozen = 500_000_000 / price * (room + 5)
	if got := escrowWindow(c, cs); got != c.params.escrowMaxBlocks {
		t.Fatalf("past the room the window pins at the cap: got %d want %d",
			got, c.params.escrowMaxBlocks)
	}
}

// The dispute bond's TWO ARMS — min(20%·X̄frozen, 40%·answer bond) — and its floor.
// Four of the five mutations over OpenDispute's copy of this formula survived, and the
// reason is one measurement: on an uncapped court the answer bond is exactly half of
// X̄, so 20%·X̄ and 40%·(X̄/2) are IDENTICALLY EQUAL and the min is a no-op. Every
// fixture in the suite is uncapped, so reversing the comparison, or deleting the
// second arm outright, changed nothing anywhere.
//
// The arm exists for the case the source names — a BOND-CAPPED court, where it "keeps
// round 1 at q > 1/3 on every claim" — and nothing built one. Capped, the arms differ
// by 20x here, so the min's direction is finally observable.
//
// Note this pins OPENDISPUTE's copy of the formula, not the quote's. The two are
// separate copies of the same arithmetic (disputeBond0 says "factored for
// DisputeBondNext" but is a duplicate), so the charge is asserted against the quote as
// well: that equality is what stops the two drifting apart.
func TestDisputeBondTakesTheSmallerArmOnACappedCourt(cur realm, t *testing.T) {
	alice := testutils.TestAddress("bcap-alice")
	bob := testutils.TestAddress("bcap-bob")
	c := testCourt(cur, "bcap", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	// Capping the answer bond pulls it off the X̄/2 identity that makes the two arms
	// equal. PostAnswer's collateralization floor then sets the final figure — the cap
	// is the lever, the floor is what it lands on — and either way the bond ends up
	// well under X̄/2, which is all this fixture needs.
	c.params.answerBondCapCC = 10_000_000

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "bcap", "a capped-bond claim")
	matureOI(cur, "bcap", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "bcap", id, sideYES)

	cs := mustClaim(c, id)
	armX := cs.xBarFrozen * disputeBondXBps / 10000
	armB := cs.answerBond0 * disputeBondOfAnswerBps / 10000
	if armB >= armX || armB <= 0 {
		t.Fatalf("setup: the answer-bond arm must bind and stay positive: armX=%d "+
			"armB=%d (bond0=%d xBar=%d)", armX, armB, cs.answerBond0, cs.xBarFrozen)
	}

	if got := DisputeBondNext("bcap", id); got != armB {
		t.Fatalf("the quote must take the SMALLER arm: got %d, arms %d/%d", got, armX, armB)
	}
	// And the CHARGE must agree with the quote — OpenDispute computes the figure over
	// again from its own copy, so this is the only thing holding the two together.
	before := c.coin.BalanceOf(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "bcap", id)
	if charged := before - c.coin.BalanceOf(bob); charged != armB {
		t.Fatalf("the charge must equal the quote on a capped court: charged %d, "+
			"quoted %d (the other arm is %d)", charged, armB, armX)
	}
}

// The REOPEN lane's escrow window, found surviving. It is the only thing that makes
// the lane finite before anybody finalizes.
//
// The neighbouring guard, `verdictAt != 0`, looks like it covers this and covers it
// only AFTER someone has called Finalize — and Finalize is permissionless, so nobody
// is obliged to. In the gap between the window lapsing and whoever gets round to
// finalizing, `verdictAt` is still zero, and with the window guard gone a reopen
// lands. Since each reopen resets nothing about the window (the escrow clock is set
// ONCE, at the first resolution) but does open a fresh round, the claim's draw can be
// held off indefinitely by a party willing to keep paying bonds — which is the bound
// the three-week window exists to impose, and the geometry §12 row 30 turns on.
//
// The fixture asserts `verdictAt == 0` at the point of refusal, so the arm cannot pass
// on the final-verdict guard by accident.
func TestReopenRefusedOnceTheEscrowWindowHasPassed(cur realm, t *testing.T) {
	alice := testutils.TestAddress("esw-alice")
	bob := testutils.TestAddress("esw-bob")
	c := testCourt(cur, "esw", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "esw", "a standing provisional verdict")
	matureOI(cur, "esw", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "esw", id, sideYES)

	// Round one fails quorum, which leaves a standing provisional verdict and starts
	// the escrow clock — set once here and never reset by a later round.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "esw", id)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "esw", id)

	cs := mustClaim(c, id)
	if cs.provisional < 0 || cs.escrowUntil <= runtimeHeight() || cs.verdictAt != 0 {
		t.Fatalf("setup: need a live reopen lane inside its window: provisional=%d "+
			"until=%d now=%d verdictAt=%d", cs.provisional, cs.escrowUntil,
			runtimeHeight(), cs.verdictAt)
	}

	// Past the window, and deliberately WITHOUT finalizing.
	testing.SkipHeights(cs.escrowUntil - runtimeHeight())
	if cs.verdictAt != 0 {
		t.Fatal("setup: nothing may have finalized this claim, or the wrong guard answers")
	}
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "the escrow window has passed", func() {
		OpenDispute(cross(cur), "esw", id)
	})
	if cs.disputeOpen {
		t.Fatal("and no round may have opened")
	}
}
