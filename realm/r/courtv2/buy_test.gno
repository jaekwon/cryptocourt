package courtv2

import (
	"chain"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

const realmPath = "gno.land/r/cryptocourt/courtv2"

// fundAndBuy starts a court (if needed) and buys CC with real GNOT through the
// full payment path — the V1 test idiom.
func fundAndBuy(cur realm, slug string, who address, gnot int64) {
	if !Exists(slug) {
		testing.SetRealm(testing.NewUserRealm(who))
		StartCourt(cross(cur), slug, "Buy Court "+slug)
	}
	testing.IssueCoins(chain.PackageAddress(realmPath), chain.Coins{{Denom: "ugnot", Amount: gnot}})
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: gnot}})
	testing.SetRealm(testing.NewUserRealm(who))
	Buy(cross(cur), slug)
	testing.SetOriginSend(nil)
}

func TestBuyMintsAndBurnsGNOT(cur realm, t *testing.T) {
	alice := testutils.TestAddress("buy-alice")
	fundAndBuy(cur, "buy1", alice, 300_000_000)

	c := mustCourt("buy1")
	minted := c.coin.BalanceOf(alice)
	if minted <= 0 || c.minted != minted {
		t.Fatalf("the curve mints to the buyer and tracks its position: %d vs %d", minted, c.minted)
	}
	// The spent GNOT sits at the keyless sink (burned): the realm keeps none.
	spent, _ := c.crv.Cost(0, minted)
	if sink := BurnedGNOT(); sink != spent {
		t.Fatalf("the sink must hold exactly the spent GNOT: %d vs %d", sink, spent)
	}
	// A second buy continues up the curve — strictly more expensive per coin.
	fundAndBuy(cur, "buy1", alice, 300_000_000)
	if c.minted <= minted {
		t.Fatal("the position is monotonic")
	}
}

func TestBuyGuards(cur realm, t *testing.T) {
	alice := testutils.TestAddress("buy-guards")
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "buy2", "Guards")
	// No GNOT attached.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(nil)
	uassert.AbortsContains(t, cur, "send GNOT", func() {
		Buy(cross(cur), "buy2")
	})
}
