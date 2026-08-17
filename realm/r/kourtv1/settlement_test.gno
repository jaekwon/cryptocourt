package kourtv1

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// These are the regressions for the money-conservation audit's three stranding
// findings — value that should return to a user was getting trapped in the (always
// over-funded) escrow. Each fails CLOSED, so none is a theft; each is nonetheless a
// real loss of funds or of liveness, and each is fixed here with a test that would
// go red if the fix were reverted.

// TestFilledBidRedeemsAfterFinalize is the HIGH finding: a bid-maker whose order
// filled but who never collected must still be able to pull those shares out of
// escrow — and redeem them — AFTER the claim resolves. The book's share-settlement
// legs were cshares.Transfer, which refuses a resolved claim (mustOpen), so the
// instant the permissionless Finalize ran, an honest winner's shares were stranded
// in escrow forever. The legs are now cshares.Reclaim (settlement, not trading).
func TestFilledBidRedeemsAfterFinalize(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fb-alice") // founder, answerer, the seller
	bob := testutils.TestAddress("fb-bob")     // the bid-maker who forgets to collect

	fundAndBuy(cur, "fb", "Filled Bid Court", alice, 300_000_000)
	buyCoin(cur, "fb", bob, 300_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	cid := OpenClaim(cross(cur), "fb", "Will it resolve YES?")
	matureOI(cur, "fb", cid, alice) // alice mints 3000 sets → holds 3000 YES + 3000 NO

	// Bob rests a bid to buy 2000 YES at tick 49 (price 50); alice sells into it.
	testing.SetRealm(testing.NewUserRealm(bob))
	oid := RestBid(cross(cur), "fb", cid, 49, 2000)
	testing.SetRealm(testing.NewUserRealm(alice))
	filled, _ := TakeSell(cross(cur), "fb", cid, 49, 2000)
	if filled != 2000 {
		t.Fatalf("alice should fill bob's 2000-share bid, filled %d", filled)
	}
	// Bob's 2000 bought YES sit in escrow, UNCOLLECTED. He deliberately does not collect.
	if SharesOf("fb", cid, outcomeYES, bob) != 0 {
		t.Fatal("bob's bought shares should be in escrow, not his balance, before he collects")
	}

	// Alice answers YES; nobody disputes; it settles and finalizes to YES.
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "fb", cid, outcomeYES)
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	SettleUndisputed(cross(cur), "fb", cid)
	testing.SkipHeights(130000) // past the 1-week escrow window
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "fb", cid)
	if !Finalized("fb", cid) {
		t.Fatal("the claim should be finalized")
	}

	// THE REGRESSION: bob collects his filled bid AFTER finalize. With Transfer this
	// aborted ("claim is not open") and his winning shares were lost; with Reclaim it
	// works, and RedeemWinning then pays him priceScale per YES.
	testing.SetRealm(testing.NewUserRealm(bob))
	Collect(cross(cur), "fb", cid, oid)
	if SharesOf("fb", cid, outcomeYES, bob) != 2000 {
		t.Fatalf("bob should hold his 2000 collected YES, has %d", SharesOf("fb", cid, outcomeYES, bob))
	}
	// The undisputed settlement fee (0.5% of the winning collateral) is skimmed from
	// the winners, so bob's 2000 YES pay a pro-rata slice of collateral − fee. Read the
	// winning supply and fee before anyone redeems.
	sup := ClaimSupply("fb", cid)
	want := mulDivFloor(2000, sup*priceScale-FeePool("fb", cid), sup)
	testing.SetRealm(testing.NewUserRealm(bob))
	paid := RedeemWinning(cross(cur), "fb", cid)
	if paid != want || paid >= 2000*priceScale {
		t.Fatalf("bob's 2000 winning YES should redeem %d (netted by the settlement fee), got %d", want, paid)
	}
}

// TestUnsoldAskReclaimsAfterFinalize is the same HIGH finding from the ask side: an
// ask-maker's UNSOLD shares (resting in escrow) must be cancellable after the claim
// resolves, or they strand identically. The cancel share-leg is now Reclaim too.
func TestUnsoldAskReclaimsAfterFinalize(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ua-alice") // founder, answerer, the ask-maker

	fundAndBuy(cur, "ua", "Unsold Ask Court", alice, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	cid := OpenClaim(cross(cur), "ua", "Resolve me")
	matureOI(cur, "ua", cid, alice) // alice holds 3000 YES + 3000 NO

	// Alice rests a sell of 2000 YES that nobody ever takes; the shares are escrowed.
	testing.SetRealm(testing.NewUserRealm(alice))
	oid := RestSell(cross(cur), "ua", cid, 60, 2000)
	if SharesOf("ua", cid, outcomeYES, alice) != 1000 {
		t.Fatalf("2000 YES should be escrowed, alice keeps 1000, has %d", SharesOf("ua", cid, outcomeYES, alice))
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "ua", cid, outcomeYES)
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	SettleUndisputed(cross(cur), "ua", cid)
	testing.SkipHeights(130000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "ua", cid)

	// THE REGRESSION: cancel the never-filled ask after finalize and get the shares
	// back (Transfer would have aborted, stranding them).
	testing.SetRealm(testing.NewUserRealm(alice))
	CancelOrder(cross(cur), "ua", cid, oid)
	if SharesOf("ua", cid, outcomeYES, alice) != 3000 {
		t.Fatalf("alice should have her 3000 YES back after cancelling, has %d", SharesOf("ua", cid, outcomeYES, alice))
	}
	// Alice holds every winning YES, so her payout is collateral − fee (the settlement
	// fee's whole slice). She is also the answerer, so she can pull that fee back.
	fee := FeePool("ua", cid)
	testing.SetRealm(testing.NewUserRealm(alice))
	paid := RedeemWinning(cross(cur), "ua", cid)
	if want := 3000*priceScale - fee; paid != want {
		t.Fatalf("alice's 3000 winning YES should redeem collateral−fee = %d, got %d", want, paid)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	if got := ClaimSettleFee(cross(cur), "ua", cid); got != fee {
		t.Fatalf("the answerer should claim the settlement fee %d, got %d", fee, got)
	}
}

// TestFinalizeReleasesOIAndRefundsDeposit is the two MED findings: at Finalize the
// court must (1) release the claim's open interest — the counter only ever went up
// (RedeemSet dropped it, resolution never did), so a court eventually could mint no
// new sets on any claim — and (2) refund the opener's anti-spam deposit, which had
// no return path at all.
func TestFinalizeReleasesOIAndRefundsDeposit(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fo-alice")
	fundAndBuy(cur, "fo", "Finalize Court", alice, 200_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	cid := OpenClaim(cross(cur), "fo", "A claim that resolves")
	matureOI(cur, "fo", cid, alice)

	oiMinted := ClaimX("fo", cid) // 3000 sets × priceScale
	if OpenInterest("fo") != oiMinted {
		t.Fatalf("court OI should equal the one claim's OI %d, got %d", oiMinted, OpenInterest("fo"))
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "fo", cid, outcomeYES)
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	SettleUndisputed(cross(cur), "fo", cid)
	testing.SkipHeights(130000)

	oiBefore := OpenInterest("fo")
	aliceBefore := CoinBalanceOf("fo", alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "fo", cid)

	if OpenInterest("fo") != oiBefore-oiMinted {
		t.Fatalf("finalize should release the claim's OI (%d − %d), got %d", oiBefore, oiMinted, OpenInterest("fo"))
	}
	if OpenInterest("fo") != 0 {
		t.Fatalf("the only claim's OI released should leave the court at 0, got %d", OpenInterest("fo"))
	}
	if got := CoinBalanceOf("fo", alice) - aliceBefore; got != 1_000_000 {
		t.Fatalf("finalize should refund the 1_000_000 deposit; alice gained %d", got)
	}
}

// TestMintUnbricksAfterFinalize proves the OI-release finding end to end: mint on a
// second claim after finalizing the first must not see the first claim's OI still on
// the court-wide counter. We assert the counter directly (a crossing-fn breach is an
// abort we can't recover from, so we verify the released figure, not a would-panic).
func TestMintUnbricksAfterFinalize(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mu-alice")
	fundAndBuy(cur, "mu", "Unbrick Court", alice, 400_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	a := OpenClaim(cross(cur), "mu", "Claim A")
	matureOI(cur, "mu", a, alice) // OI now carries claim A

	// Resolve A undisputed, which must drop A's OI back off the court counter.
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "mu", a, outcomeYES)
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	SettleUndisputed(cross(cur), "mu", a)
	testing.SkipHeights(130000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "mu", a)
	if OpenInterest("mu") != 0 {
		t.Fatalf("A's OI must be off the counter after finalize, court shows %d", OpenInterest("mu"))
	}

	// A second claim mints against a counter that starts clean — the whole point of
	// the release: the court is not permanently consumed by a resolved claim.
	testing.SetRealm(testing.NewUserRealm(alice))
	b := OpenClaim(cross(cur), "mu", "Claim B")
	testing.SetRealm(testing.NewUserRealm(alice))
	MintSet(cross(cur), "mu", b, 1000)
	if OpenInterest("mu") != 1000*priceScale {
		t.Fatalf("B's fresh OI should be 1000×priceScale on a released counter, got %d", OpenInterest("mu"))
	}
}

// TestTradingClosesOnResolvedClaim proves the explicit market-closed guard: a bid
// (whose escrow leg has no cshares status check of its own) is refused once the
// claim has resolved, instead of resting where it can never fill.
func TestTradingClosesOnResolvedClaim(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-alice")
	fundAndBuy(cur, "tc", "Trading Close Court", alice, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	cid := OpenClaim(cross(cur), "tc", "Resolves then closes")
	matureOI(cur, "tc", cid, alice)

	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "tc", cid, outcomeYES)
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	SettleUndisputed(cross(cur), "tc", cid)
	testing.SkipHeights(130000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "tc", cid)

	// A bid on the resolved claim is refused explicitly (not left to rest uselessly).
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "market is closed", func() {
		RestBid(cross(cur), "tc", cid, 50, 1000)
	})
}
