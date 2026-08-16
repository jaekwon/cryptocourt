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

	// Carol upholds (votes "no" on OVERTURN) with quorum-clearing weight.
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "dp1", id, "no")
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
	if c.coin.BalanceOf(alice) != aliceBefore+ab {
		t.Fatal("the upheld answer bond returns at VERDICT_FINAL")
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
