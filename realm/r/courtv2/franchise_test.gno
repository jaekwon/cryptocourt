package courtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// The meta court is a singleton and gno resets block height per test function,
// so everything that mints meta-CC lives in ONE function (see meta_test.gno).
func TestMetaFranchise(cur realm, t *testing.T) {
	fresh := testutils.TestAddress("fr-fresh")
	mature := testutils.TestAddress("fr-mature")
	direct := testutils.TestAddress("fr-direct")
	expensive := testutils.TestAddress("fr-expensive")

	// THE court-independence property, and the reason the accrual reads `spent`
	// µGNOT rather than CC minted: a fresh curve sells CC tens of thousands of
	// times cheaper per GNOT, and starting a court is free — so a per-CC rule
	// would be an unbounded free-mint of the platform's governance token. Equal
	// burns must buy equal appeals weight no matter which court they went into.
	fundAndBuy(cur, "fra", mature, 400_000_000)    // push fra well up its curve
	fundAndBuy(cur, "fra", expensive, 100_000_000) // burn on the EXPENSIVE part
	fundAndBuy(cur, "frb", fresh, 100_000_000)     // the same burn, BRAND-NEW court

	// The fresh-court buyer got far more court-CC for the identical spend...
	freshCC := mustCourt("frb").coin.BalanceOf(fresh)
	dearCC := mustCourt("fra").coin.BalanceOf(expensive)
	if freshCC <= dearCC {
		t.Fatalf("a fresh curve should mint more court-CC per GNOT (premise): %d vs %d",
			freshCC, dearCC)
	}
	// ...and yet EXACTLY the same appeals entitlement. This is the property that
	// makes shell courts pointless.
	if FranchiseOf(fresh) != FranchiseOf(expensive) {
		t.Fatalf("equal burns must accrue equal franchise: fresh=%d expensive=%d",
			FranchiseOf(fresh), FranchiseOf(expensive))
	}
	if FranchiseOf(fresh) != 100_000_000 {
		t.Fatalf("the entitlement is the µGNOT actually burned, got %d", FranchiseOf(fresh))
	}

	// Nothing is minted until it is CLAIMED — that is what keeps meta's supply
	// equal to its engaged electorate, so the quorum floor stays reachable.
	mc := mustCourt(metaSlug)
	if mc.coin.BalanceOf(fresh) != 0 {
		t.Fatal("burning must not airdrop meta-CC")
	}
	testing.SetRealm(testing.NewUserRealm(fresh))
	got := ClaimMetaFranchise(cross(cur))
	if got <= 0 || mc.coin.BalanceOf(fresh) != got {
		t.Fatalf("claiming should mint the accrued weight, got %d", got)
	}
	if FranchiseOf(fresh) != 0 {
		t.Fatal("a full claim clears the entitlement")
	}
	// Claiming again is a harmless no-op.
	testing.SetRealm(testing.NewUserRealm(fresh))
	if again := ClaimMetaFranchise(cross(cur)); again != 0 {
		t.Fatalf("a second claim must mint nothing, got %d", again)
	}

	// The mint advances META's own curve position — one monotone counter shared
	// with meta's Buy, so meta's curve can never be a parked side door selling a
	// capture bloc at genesis prices.
	posAfterFirst := mc.minted
	if posAfterFirst <= 0 {
		t.Fatal("claiming must advance meta's curve position")
	}
	testing.SetRealm(testing.NewUserRealm(expensive))
	ClaimMetaFranchise(cross(cur))
	if mc.minted <= posAfterFirst {
		t.Fatal("each claim advances the shared position monotonically")
	}
	// The escalator is real: the later claimant pays a higher price per unit, so
	// the same burn buys strictly less appeals weight than it would have earlier.
	if mc.coin.BalanceOf(expensive) >= mc.coin.BalanceOf(fresh) {
		t.Fatal("an equal burn claimed LATER buys less appeals weight — the curve escalates")
	}

	// Buying META itself does not double-dip: that GNOT already bought meta-CC
	// directly through the same curve.
	fundAndBuy(cur, metaSlug, direct, 50_000_000)
	if FranchiseOf(direct) != 0 {
		t.Fatalf("a direct meta buy must not also accrue franchise, got %d", FranchiseOf(direct))
	}
}
