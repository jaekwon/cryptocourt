package court

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

func TestUndisputedSettlement(cur realm, t *testing.T) {
	who := testutils.TestAddress("un-alice")
	fundAndBuy(cur, "ses", "Session Court", who, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	cid := OpenClaim(cross(cur), "ses", "An uncontested claim")
	matureOI(cur, "ses", cid, who) // who holds YES + NO
	testing.SetRealm(testing.NewUserRealm(who))
	PostAnswer(cross(cur), "ses", cid, outcomeYES)

	answerBond := AnswerBond("ses", cid)
	afterAnswer := CoinBalanceOf("ses", who)

	// Too early: the answer must age the 72h minimum.
	testing.SetRealm(testing.NewUserRealm(who))
	uassert.AbortsContains(t, cur, "72h settlement minimum", func() {
		SettleUndisputed(cross(cur), "ses", cid)
	})

	// Age past 72h and settle undisputed.
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(who))
	SettleUndisputed(cross(cur), "ses", cid)
	if Provisional("ses", cid) != outcomeYES {
		t.Fatalf("undisputed settlement should set provisional=answer YES, got %d", Provisional("ses", cid))
	}
	// The answerer got their bond back.
	if CoinBalanceOf("ses", who)-afterAnswer != answerBond {
		t.Fatalf("the answer bond should be returned, delta %d want %d", CoinBalanceOf("ses", who)-afterAnswer, answerBond)
	}

	// Finalize after escrow; the YES holder redeems.
	testing.SkipHeights(130000)
	testing.SetRealm(testing.NewUserRealm(who))
	Finalize(cross(cur), "ses", cid)
	if !Finalized("ses", cid) {
		t.Fatal("the claim should be finalized")
	}
	// The YES holder (also the answerer) holds every winning share, so the 0.5%
	// settlement fee comes out of their own payout: they redeem collateral−fee, then
	// pull the fee itself, netting the whole collateral back.
	yes := SharesOf("ses", cid, outcomeYES, who)
	fee := FeePool("ses", cid)
	if fee <= 0 {
		t.Fatal("an undisputed settlement should have charged a settlement fee")
	}
	testing.SetRealm(testing.NewUserRealm(who))
	if paid := RedeemWinning(cross(cur), "ses", cid); paid != yes*priceScale-fee {
		t.Fatalf("the YES holder should be paid collateral−fee = %d, got %d", yes*priceScale-fee, paid)
	}
	testing.SetRealm(testing.NewUserRealm(who))
	if got := ClaimSettleFee(cross(cur), "ses", cid); got != fee {
		t.Fatalf("the answerer should claim the settlement fee %d, got %d", fee, got)
	}
}

// TestEscrowWindowScalesWithOpenInterest proves a larger claim earns a longer escrow
// window (clamp(1 week + 1 day / 500 GNOT of X, 1 week, 3 weeks)). A big curve position
// gives CC a high marginal price, so a normal-sized claim's open interest is worth
// enough GNOT to push the window past its 1-week floor — finalizing at one week is then
// refused, and only the scaled window (still ≤ 3 weeks) lets it through.
func TestEscrowWindowScalesWithOpenInterest(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ew-alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "ew", "Escrow Window Court")
	buyCoin(cur, "ew", alice, 50_000_000_000_000_000) // 5e16 µGNOT -> minted ~1e13, price ~1e4

	testing.SetRealm(testing.NewUserRealm(alice))
	cid := OpenClaim(cross(cur), "ew", "A valuable claim")
	matureOI(cur, "ew", cid, alice) // 3000 sets -> X = 3e5 CC, ~3000 GNOT at this price

	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "ew", cid, outcomeYES)
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	SettleUndisputed(cross(cur), "ew", cid)

	p := defaultParams()
	// The window scaled beyond one week, so finalizing just past the 1-week floor fails.
	testing.SkipHeights(p.escrowMinBlocks + oneDayBlocks)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "escrow window has not passed", func() {
		Finalize(cross(cur), "ew", cid)
	})
	// Wait out the full three-week maximum and it finalizes.
	testing.SkipHeights(p.escrowMaxBlocks)
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "ew", cid)
	if !Finalized("ew", cid) {
		t.Fatal("the claim should finalize once its scaled escrow window passes")
	}
}
