package court

import (
	"chain"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// buyCoin funds the realm and buys `who` coin in an existing court.
func buyCoin(cur realm, slug string, who address, gnot int64) {
	testing.IssueCoins(chain.PackageAddress(realmPath), chain.Coins{{Denom: "ugnot", Amount: gnot}})
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: gnot}})
	testing.SetRealm(testing.NewUserRealm(who))
	Buy(cross(cur), slug)
}

func TestBookTradeMovesSharesAndCoin(cur realm, t *testing.T) {
	seller := testutils.TestAddress("seller")
	buyer := testutils.TestAddress("buyer-b")
	fundAndBuy(cur, "bk-eg", "Book Court", seller, 100_000_000)
	buyCoin(cur, "bk-eg", buyer, 100_000_000)

	testing.SetRealm(testing.NewUserRealm(seller))
	cid := OpenClaim(cross(cur), "bk-eg", "A tradeable claim")
	testing.SetRealm(testing.NewUserRealm(seller))
	MintSet(cross(cur), "bk-eg", cid, 3000) // 3000 YES + 3000 NO

	// Rest a sell of 2000 YES at tick 49 (price 50). The shares are escrowed.
	testing.SetRealm(testing.NewUserRealm(seller))
	oid := RestSell(cross(cur), "bk-eg", cid, 49, 2000)
	if SharesOf("bk-eg", cid, outcomeYES, seller) != 1000 {
		t.Fatalf("2000 YES should be escrowed, seller keeps 1000, has %d", SharesOf("bk-eg", cid, outcomeYES, seller))
	}

	// Buyer takes 1000 up to price 50.
	buyerBefore := CoinBalanceOf("bk-eg", buyer)
	testing.SetRealm(testing.NewUserRealm(buyer))
	filled, notional := TakeBuy(cross(cur), "bk-eg", cid, 49, 1000)
	if filled != 1000 {
		t.Fatalf("should fill 1000, got %d", filled)
	}
	if notional != 1000*50 { // price = tick+1 = 50
		t.Fatalf("notional should be 1000*50, got %d", notional)
	}
	if SharesOf("bk-eg", cid, outcomeYES, buyer) != 1000 {
		t.Fatal("buyer should hold the 1000 bought YES")
	}
	if buyerBefore-CoinBalanceOf("bk-eg", buyer) != notional {
		t.Fatal("buyer should have paid the notional CC")
	}

	// Seller collects the coin for the 1000 sold.
	sellerBefore := CoinBalanceOf("bk-eg", seller)
	testing.SetRealm(testing.NewUserRealm(seller))
	Collect(cross(cur), "bk-eg", cid, oid)
	if CoinBalanceOf("bk-eg", seller)-sellerBefore != notional {
		t.Fatalf("seller should collect the %d CC proceeds", notional)
	}

	// Seller cancels the unsold 1000 and gets the shares back.
	testing.SetRealm(testing.NewUserRealm(seller))
	CancelOrder(cross(cur), "bk-eg", cid, oid)
	if SharesOf("bk-eg", cid, outcomeYES, seller) != 2000 {
		t.Fatalf("seller should have 1000 kept + 1000 refunded = 2000 YES, has %d", SharesOf("bk-eg", cid, outcomeYES, seller))
	}
}

func TestRestBelowMinOrderSizeIsRefused(cur realm, t *testing.T) {
	who := testutils.TestAddress("dust")
	fundAndBuy(cur, "bk-min", "Min Court", who, 100_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	cid := OpenClaim(cross(cur), "bk-min", "claim")
	testing.SetRealm(testing.NewUserRealm(who))
	MintSet(cross(cur), "bk-min", cid, 5000)

	testing.SetRealm(testing.NewUserRealm(who))
	uassert.AbortsContains(t, cur, "minimum size", func() {
		RestSell(cross(cur), "bk-min", cid, 50, 10) // below the 1000 default
	})
}
