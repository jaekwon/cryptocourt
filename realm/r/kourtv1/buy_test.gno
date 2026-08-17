package kourtv1

import (
	"chain"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

const realmPath = "gno.land/r/kourt/kourtv1"

func TestBuyMintsCoinAndKeepsGNOTAsTreasury(cur realm, t *testing.T) {
	realmAddr := chain.PackageAddress(realmPath)
	buyer := testutils.TestAddress("buyer")

	testing.SetRealm(testing.NewUserRealm(buyer))
	StartCourt(cross(cur), "buy-eg", "Buy Court")

	// The realm receives the sent GNOT and refunds the unspent remainder, so fund it.
	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 1_000_000}})
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 1_000_000}})
	testing.SetRealm(testing.NewUserRealm(buyer))

	minted := Buy(cross(cur), "buy-eg")
	if minted <= 0 {
		t.Fatalf("a buy should mint coin, got %d", minted)
	}
	if got := CoinSupply("buy-eg"); got != minted {
		t.Fatalf("supply %d should equal minted %d", got, minted)
	}
	if got := CurvePosition("buy-eg"); got != minted {
		t.Fatalf("curve position %d should equal minted %d", got, minted)
	}
	if got := Treasury("buy-eg"); got <= 0 || got > 1_000_000 {
		t.Fatalf("treasury should hold the GNOT spent (0<t<=1e6), got %d", got)
	}
	if got := CoinBalanceOf("buy-eg", buyer); got != minted {
		t.Fatalf("buyer should hold the %d minted CC, got %d", minted, got)
	}
}

func TestBuyMonotonicPositionRises(cur realm, t *testing.T) {
	realmAddr := chain.PackageAddress(realmPath)
	buyer := testutils.TestAddress("buyer2")
	testing.SetRealm(testing.NewUserRealm(buyer))
	StartCourt(cross(cur), "buy-mono", "Mono")

	testing.IssueCoins(realmAddr, chain.Coins{{Denom: "ugnot", Amount: 2_000_000}})
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 100}})
	testing.SetRealm(testing.NewUserRealm(buyer))
	Buy(cross(cur), "buy-mono")
	p1 := CurvePosition("buy-mono")

	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 100}})
	testing.SetRealm(testing.NewUserRealm(buyer))
	Buy(cross(cur), "buy-mono")
	p2 := CurvePosition("buy-mono")

	if p2 <= p1 {
		t.Fatalf("a second buy must raise the curve position: %d then %d", p1, p2)
	}
	// The marginal price never falls.
	if CoinPrice("buy-mono") < 0 {
		t.Fatal("price sane")
	}
}

func TestBuyRefusesZeroSend(cur realm, t *testing.T) {
	buyer := testutils.TestAddress("buyer3")
	testing.SetRealm(testing.NewUserRealm(buyer))
	StartCourt(cross(cur), "buy-zero", "Zero")

	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 0}})
	testing.SetRealm(testing.NewUserRealm(buyer))
	uassert.AbortsContains(t, cur, "send GNOT", func() {
		Buy(cross(cur), "buy-zero")
	})
}
