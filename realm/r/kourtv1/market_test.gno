package kourtv1

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

func TestMintAndRedeemSetsConserve(cur realm, t *testing.T) {
	who := testutils.TestAddress("trader")
	fundAndBuy(cur, "mk-eg", "Market Court", who, 100_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	cid := OpenClaim(cross(cur), "mk-eg", "Market claim")

	beforeCC := CoinBalanceOf("mk-eg", who)

	testing.SetRealm(testing.NewUserRealm(who))
	MintSet(cross(cur), "mk-eg", cid, 1000)
	if SharesOf("mk-eg", cid, outcomeYES, who) != 1000 || SharesOf("mk-eg", cid, outcomeNO, who) != 1000 {
		t.Fatal("a mint should give 1000 of each outcome")
	}
	if ClaimSupply("mk-eg", cid) != 1000 { // raw sets
		t.Fatalf("supply should be 1000 sets, got %d", ClaimSupply("mk-eg", cid))
	}
	if ClaimX("mk-eg", cid) != 1000*priceScale { // X in CC
		t.Fatalf("X should be 1000*priceScale CC, got %d", ClaimX("mk-eg", cid))
	}
	if OpenInterest("mk-eg") != 1000*priceScale {
		t.Fatalf("court OI should be 1000*priceScale CC, got %d", OpenInterest("mk-eg"))
	}
	if d := beforeCC - CoinBalanceOf("mk-eg", who); d != 1000*priceScale {
		t.Fatalf("1000 sets = 1000*priceScale CC collateral, moved %d", d)
	}

	testing.SetRealm(testing.NewUserRealm(who))
	RedeemSet(cross(cur), "mk-eg", cid, 400)
	if ClaimSupply("mk-eg", cid) != 600 {
		t.Fatalf("supply should be 600 sets after redeeming 400, got %d", ClaimSupply("mk-eg", cid))
	}
	if SharesOf("mk-eg", cid, outcomeYES, who) != 600 {
		t.Fatal("600 YES should remain")
	}
	if d := beforeCC - CoinBalanceOf("mk-eg", who); d != 600*priceScale {
		t.Fatalf("net 600 sets of collateral should sit in escrow, moved %d", d)
	}
	if OpenInterest("mk-eg") != 600*priceScale {
		t.Fatalf("court OI should be 600*priceScale CC, got %d", OpenInterest("mk-eg"))
	}
}

func TestOICeilingIsEnforced(cur realm, t *testing.T) {
	who := testutils.TestAddress("whale")
	fundAndBuy(cur, "mk-oi", "OI Court", who, 100_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	cid := OpenClaim(cross(cur), "mk-oi", "OI claim")

	ceilingCC := CoinSupply("mk-oi") * 2000 / 10000 // 20% of supply, in CC (default)
	maxSets := ceilingCC / priceScale
	testing.SetRealm(testing.NewUserRealm(who))
	uassert.AbortsContains(t, cur, "open-interest ceiling", func() {
		MintSet(cross(cur), "mk-oi", cid, maxSets+1)
	})
	// Right at the ceiling is allowed.
	testing.SetRealm(testing.NewUserRealm(who))
	MintSet(cross(cur), "mk-oi", cid, maxSets)
	if OpenInterest("mk-oi") != maxSets*priceScale {
		t.Fatalf("minting to the ceiling should succeed, OI %d want %d", OpenInterest("mk-oi"), maxSets*priceScale)
	}
}
