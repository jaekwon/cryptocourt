package court

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

func TestDisputeLifecycleOverturn(cur realm, t *testing.T) {
	alice := testutils.TestAddress("d-alice") // founder, answerer
	carol := testutils.TestAddress("d-carol") // the whale voter
	bob := testutils.TestAddress("d-bob")     // the disputer

	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "dp", "Dispute Court")
	// Carol buys the majority of the coin first (voting power), then alice and bob.
	buyCoin(cur, "dp", carol, 500_000_000)
	buyCoin(cur, "dp", alice, 100_000_000)
	buyCoin(cur, "dp", bob, 100_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	cid := OpenClaim(cross(cur), "dp", "Did it happen?")
	matureOI(cur, "dp", cid, alice) // mints across 3 buckets, alice holds YES+NO

	// Alice answers YES.
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "dp", cid, outcomeYES)

	// Bob disputes.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "dp", cid)
	if !DisputeOpen("dp", cid) {
		t.Fatal("a dispute should be open")
	}

	// Carol (the majority holder) votes to OVERTURN.
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "dp", cid, "yes")

	// The vote closes; resolve reads the frozen tally → overturn to NO.
	testing.SkipHeights(130000) // past the 7-day voting window
	testing.SetRealm(testing.NewUserRealm(bob))
	ResolveDispute(cross(cur), "dp", cid)
	if DisputeOpen("dp", cid) {
		t.Fatal("the dispute should be resolved (closed)")
	}
	if Provisional("dp", cid) != outcomeNO {
		t.Fatalf("a YES answer overturned should give a NO verdict, got %d", Provisional("dp", cid))
	}

	// After the escrow window, finalize resolves the shares.
	testing.SkipHeights(130000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Finalize(cross(cur), "dp", cid)
	if !Finalized("dp", cid) {
		t.Fatal("the claim should be finalized")
	}

	// Alice holds all the winning NO shares (she minted the sets); NO won. A decided
	// dispute charges the adjudication fee, skimmed from the winning collateral, so
	// she is paid the full backing MINUS her pro-rata slice of the fee. Holding every
	// winning share, her slice is the whole fee, so she receives collateral − fee.
	noShares := SharesOf("dp", cid, outcomeNO, alice)
	if noShares <= 0 {
		t.Fatal("alice should hold NO shares from her mints")
	}
	fee := FeePool("dp", cid)
	if fee <= 0 {
		t.Fatal("a decided dispute should have charged an adjudication fee")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	paid := RedeemWinning(cross(cur), "dp", cid)
	if want := noShares*priceScale - fee; paid != want {
		t.Fatalf("alice's %d winning NO should pay collateral−fee = %d, got %d", noShares, want, paid)
	}
}

func TestDisputeGuards(cur realm, t *testing.T) {
	who := testutils.TestAddress("dg")
	fundAndBuy(cur, "dp-g", "Guard Court", who, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	cid := OpenClaim(cross(cur), "dp-g", "Unanswered")

	// Disputing an unanswered claim is refused.
	testing.SetRealm(testing.NewUserRealm(who))
	uassert.AbortsContains(t, cur, "no answer to dispute", func() {
		OpenDispute(cross(cur), "dp-g", cid)
	})

	// Answer it, dispute it, then try to resolve while the vote is still active.
	matureOI(cur, "dp-g", cid, who)
	testing.SetRealm(testing.NewUserRealm(who))
	PostAnswer(cross(cur), "dp-g", cid, outcomeYES)
	testing.SetRealm(testing.NewUserRealm(who))
	OpenDispute(cross(cur), "dp-g", cid)
	testing.SetRealm(testing.NewUserRealm(who))
	uassert.AbortsContains(t, cur, "still open", func() {
		ResolveDispute(cross(cur), "dp-g", cid)
	})
}
