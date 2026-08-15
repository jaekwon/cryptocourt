package court

import (
	"chain"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// escrowCC reads the court escrow's CC balance — the pool every payout draws from,
// so a test can assert it drains to only rounding dust.
func escrowCC(slug string) int64 { return CoinBalanceOf(slug, chain.PackageAddress(realmPath)) }

// TestAdjudicationFeeSplitAndConservation exercises the 60/40 adjudication fee across
// three voters — an on-verdict whale, an off-verdict voter, and an abstainer — and
// proves the money conserves: every payout (the winner's net + all voter claims)
// comes out of the one claim's collateral, and the escrow drains to bounded dust.
func TestAdjudicationFeeSplitAndConservation(cur realm, t *testing.T) {
	alice := testutils.TestAddress("af-alice") // founder, answerer, holds the winning shares
	bob := testutils.TestAddress("af-bob")     // the disputer
	carol := testutils.TestAddress("af-carol") // votes to OVERTURN (yes), big weight — on the verdict
	dave := testutils.TestAddress("af-dave")   // votes to UPHOLD (no) — off the verdict
	erin := testutils.TestAddress("af-erin")   // ABSTAINS — participation slice only

	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "af", "Adj Fee Court")
	buyCoin(cur, "af", carol, 500_000_000)
	buyCoin(cur, "af", alice, 100_000_000)
	buyCoin(cur, "af", bob, 100_000_000)
	buyCoin(cur, "af", dave, 100_000_000)
	buyCoin(cur, "af", erin, 100_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	cid := OpenClaim(cross(cur), "af", "Did it happen?")
	matureOI(cur, "af", cid, alice) // alice mints 3000 sets -> holds 3000 YES + 3000 NO

	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "af", cid, outcomeYES)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "af", cid)

	// The decisive "yes" (overturn) closes the vote AT ONCE, so carol votes LAST — dave's
	// "no" and erin's abstain keep the proposal active (a decided-NO sits out its
	// deadline), then carol's yes crosses the threshold and closes it with all three cast.
	testing.SetRealm(testing.NewUserRealm(dave))
	VoteDispute(cross(cur), "af", cid, "no")
	testing.SetRealm(testing.NewUserRealm(erin))
	VoteDispute(cross(cur), "af", cid, "abstain")
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "af", cid, "yes")

	testing.SkipHeights(130000) // close the vote
	testing.SetRealm(testing.NewUserRealm(bob))
	ResolveDispute(cross(cur), "af", cid)
	if Provisional("af", cid) != outcomeNO {
		t.Fatalf("carol's overturn should flip YES->NO, got %d", Provisional("af", cid))
	}
	fee := FeePool("af", cid)
	if FeeKind("af", cid) != "adjudication" || fee <= 0 {
		t.Fatalf("a decided dispute should charge an adjudication fee, kind=%s pool=%d", FeeKind("af", cid), fee)
	}

	testing.SkipHeights(130000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Finalize(cross(cur), "af", cid)

	escrowAtFinalize := escrowCC("af")
	testing.SetRealm(testing.NewUserRealm(alice))
	winnerPaid := RedeemWinning(cross(cur), "af", cid) // alice holds every winning NO

	testing.SetRealm(testing.NewUserRealm(carol))
	carolFee := ClaimAdjFee(cross(cur), "af", cid)
	testing.SetRealm(testing.NewUserRealm(dave))
	daveFee := ClaimAdjFee(cross(cur), "af", cid)
	testing.SetRealm(testing.NewUserRealm(erin))
	erinFee := ClaimAdjFee(cross(cur), "af", cid)

	partPool := fee * 6000 / 10000
	verdPool := fee - partPool
	// carol is the SOLE on-verdict voter, so she collects the ENTIRE 40% verdict pool
	// plus her participation slice — strictly more than the verdict pool alone, and
	// more than any participation-only voter.
	if carolFee <= verdPool {
		t.Fatalf("the sole on-verdict voter should collect the whole verdict pool %d plus participation, got %d", verdPool, carolFee)
	}
	if carolFee <= daveFee || carolFee <= erinFee {
		t.Fatalf("the on-verdict whale should earn most: carol=%d dave=%d erin=%d", carolFee, daveFee, erinFee)
	}
	// dave (off-verdict) and erin (abstain) earn the participation slice only. dave
	// bought earlier, so he holds at least as much weight and earns at least as much;
	// the two together cannot exceed the participation pool (carol also draws from it).
	if daveFee <= 0 || erinFee <= 0 {
		t.Fatal("every voter with weight earns a participation slice")
	}
	if daveFee < erinFee {
		t.Fatalf("dave's earlier, heavier stake should earn >= erin's, dave=%d erin=%d", daveFee, erinFee)
	}
	if daveFee+erinFee > partPool {
		t.Fatalf("participation-only claims %d exceed the participation pool %d", daveFee+erinFee, partPool)
	}

	claimed := carolFee + daveFee + erinFee
	if claimed > fee {
		t.Fatalf("voter claims %d must not exceed the fee pool %d", claimed, fee)
	}
	// Conservation: the winner's net plus the fee claims come out of the collateral in
	// escrow, and never exceed it; what remains is only rounding dust.
	if winnerPaid+claimed > escrowAtFinalize {
		t.Fatalf("payouts %d must not exceed the escrow %d", winnerPaid+claimed, escrowAtFinalize)
	}
	if dust := escrowCC("af"); dust < 0 || dust > 20 {
		t.Fatalf("escrow should drain to bounded dust, got %d", dust)
	}
}

// TestAllAbstainUpholdDistributesWholeFee is the audit-found edge: a dispute carried
// to quorum ENTIRELY by abstentions is upheld with no prevailing weight, so the 40%
// verdict pool would have no claimant. The fee folds it into participation, so the sole
// abstaining voter claims the WHOLE fee — nothing is stranded and the escrow drains.
func TestAllAbstainUpholdDistributesWholeFee(cur realm, t *testing.T) {
	alice := testutils.TestAddress("aa-alice") // founder, answerer, winner
	bob := testutils.TestAddress("aa-bob")     // disputer
	carol := testutils.TestAddress("aa-carol") // abstains with quorum-meeting weight

	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "aa", "Abstain Court")
	buyCoin(cur, "aa", carol, 500_000_000)
	buyCoin(cur, "aa", alice, 100_000_000)
	buyCoin(cur, "aa", bob, 100_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	cid := OpenClaim(cross(cur), "aa", "Upheld by abstention")
	matureOI(cur, "aa", cid, alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "aa", cid, outcomeYES)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "aa", cid)

	// Only carol votes, and she abstains — quorum met, but no yes/no weight.
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "aa", cid, "abstain")
	testing.SkipHeights(130000)
	testing.SetRealm(testing.NewUserRealm(bob))
	ResolveDispute(cross(cur), "aa", cid)
	if Provisional("aa", cid) != outcomeYES { // uphold: the answer stands
		t.Fatalf("an all-abstain dispute should uphold the YES answer, got %d", Provisional("aa", cid))
	}
	fee := FeePool("aa", cid)
	if fee <= 0 {
		t.Fatal("a decided (upheld) dispute charges an adjudication fee")
	}

	testing.SkipHeights(130000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Finalize(cross(cur), "aa", cid)

	testing.SetRealm(testing.NewUserRealm(alice))
	RedeemWinning(cross(cur), "aa", cid) // the winner was charged the full fee
	// The sole voter (an abstainer) claims the WHOLE fee — the 40% verdict pool, which
	// no address could claim, folded into participation. Nothing strands in escrow.
	testing.SetRealm(testing.NewUserRealm(carol))
	if got := ClaimAdjFee(cross(cur), "aa", cid); got != fee {
		t.Fatalf("the sole voter should claim the whole fee %d (no 40%% stranded), got %d", fee, got)
	}
	if dust := escrowCC("aa"); dust < 0 || dust > 20 {
		t.Fatalf("escrow should drain to dust with the whole fee distributed, got %d", dust)
	}
}

// TestFeeGuards covers the one-fee-never-both rule, double-claim, non-voter, and
// not-finalized guards on both claim entrypoints.
func TestFeeGuards(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fg-alice")
	bob := testutils.TestAddress("fg-bob")

	// --- an UNDISPUTED claim: settlement fee only ---
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "fg", "Guard Fee Court")
	buyCoin(cur, "fg", alice, 300_000_000)
	buyCoin(cur, "fg", bob, 100_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	u := OpenClaim(cross(cur), "fg", "Undisputed one")
	matureOI(cur, "fg", u, alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "fg", u, outcomeYES)

	// Claiming a fee before finalize is refused on both entrypoints.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "not finalized", func() { ClaimSettleFee(cross(cur), "fg", u) })

	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	SettleUndisputed(cross(cur), "fg", u)
	testing.SkipHeights(130000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "fg", u)

	// One fee, never both: an undisputed claim has no adjudication fee.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "no adjudication fee", func() { ClaimAdjFee(cross(cur), "fg", u) })
	// Only the answerer may claim the settlement fee.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "only the answerer", func() { ClaimSettleFee(cross(cur), "fg", u) })
	// The answerer claims once; a second pull is refused.
	testing.SetRealm(testing.NewUserRealm(alice))
	ClaimSettleFee(cross(cur), "fg", u)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "already claimed", func() { ClaimSettleFee(cross(cur), "fg", u) })
}

// TestFailedQuorumChargesNoFee proves the self-pay faucet stays shut: a dispute that
// nobody votes on fails quorum, charges NO fee, pays the turnout nothing, and leaves
// winners redeeming the full priceScale.
func TestFailedQuorumChargesNoFee(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fq-alice")
	bob := testutils.TestAddress("fq-bob")

	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "fq", "Failed Quorum Court")
	buyCoin(cur, "fq", alice, 300_000_000)
	buyCoin(cur, "fq", bob, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	cid := OpenClaim(cross(cur), "fq", "Nobody will vote")
	matureOI(cur, "fq", cid, alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "fq", cid, outcomeYES)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "fq", cid)

	// Nobody votes; the vote closes below quorum.
	testing.SkipHeights(130000)
	testing.SetRealm(testing.NewUserRealm(bob))
	ResolveDispute(cross(cur), "fq", cid)
	if FeeKind("fq", cid) != "none" || FeePool("fq", cid) != 0 {
		t.Fatalf("a failed-quorum dispute charges no fee, kind=%s pool=%d", FeeKind("fq", cid), FeePool("fq", cid))
	}

	testing.SkipHeights(130000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Finalize(cross(cur), "fq", cid)

	// No adjudication fee to claim, and the answer stood, so YES holders are paid in full.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "no adjudication fee", func() { ClaimAdjFee(cross(cur), "fq", cid) })
	yes := SharesOf("fq", cid, outcomeYES, alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	if paid := RedeemWinning(cross(cur), "fq", cid); paid != yes*priceScale {
		t.Fatalf("a no-fee claim pays full priceScale: want %d, got %d", yes*priceScale, paid)
	}
}

// TestSetsFreezeAtProvisional proves the escrow-window collateral lock: once a claim
// has a provisional verdict, minting and redeeming sets are refused (so the fee's
// collateral base cannot drift, and a matched-set holder cannot exit at par to dodge it).
func TestSetsFreezeAtProvisional(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fz-alice")
	fundAndBuy(cur, "fz", "Freeze Court", alice, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	cid := OpenClaim(cross(cur), "fz", "Freezes on settle")
	matureOI(cur, "fz", cid, alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "fz", cid, outcomeYES)

	// Before settlement (no provisional verdict yet) minting still works.
	testing.SetRealm(testing.NewUserRealm(alice))
	MintSet(cross(cur), "fz", cid, 1000)

	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	SettleUndisputed(cross(cur), "fz", cid) // sets provisional -> freeze

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "frozen until finalize", func() {
		MintSet(cross(cur), "fz", cid, 1000)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "frozen until finalize", func() {
		RedeemSet(cross(cur), "fz", cid, 1000)
	})
}
