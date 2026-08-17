package kourtv1

import (
	"chain"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// fundAndBuy starts a court and buys the caller enough CC to act. Returns the slug.
func fundAndBuy(cur realm, slug, name string, who address, gnot int64) {
	testing.SetRealm(testing.NewUserRealm(who))
	StartCourt(cross(cur), slug, name)
	testing.IssueCoins(chain.PackageAddress(realmPath), chain.Coins{{Denom: "ugnot", Amount: gnot}})
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: gnot}})
	testing.SetRealm(testing.NewUserRealm(who))
	Buy(cross(cur), slug)
}

func TestOpenClaimTakesDepositAndAppendsBody(cur realm, t *testing.T) {
	who := testutils.TestAddress("author")
	fundAndBuy(cur, "cl-eg", "Claims Court", who, 10_000_000)

	before := CoinBalanceOf("cl-eg", who)
	testing.SetRealm(testing.NewUserRealm(who))
	cid := OpenClaim(cross(cur), "cl-eg", "Did X happen?")
	if cid == 0 {
		t.Fatal("a claim id should be non-zero")
	}
	if ClaimTitle("cl-eg", cid) != "Did X happen?" {
		t.Fatalf("title mismatch: %q", ClaimTitle("cl-eg", cid))
	}
	if ClaimDepositor("cl-eg", cid) != who {
		t.Fatal("the depositor should be the opener")
	}
	if d := before - CoinBalanceOf("cl-eg", who); d != 1_000_000 {
		t.Fatalf("the 1e6 CC deposit should be taken, moved %d", d)
	}

	testing.SetRealm(testing.NewUserRealm(who))
	AppendBody(cross(cur), "cl-eg", cid, "First: ")
	testing.SetRealm(testing.NewUserRealm(who))
	AppendBody(cross(cur), "cl-eg", cid, "the evidence.")
	if got := ClaimBody("cl-eg", cid); got != "First: the evidence." {
		t.Fatalf("body should concatenate the chunks in order, got %q", got)
	}
}

func TestOnlyAuthorMayAppend(cur realm, t *testing.T) {
	who := testutils.TestAddress("author2")
	fundAndBuy(cur, "cl-auth", "Auth Court", who, 10_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	cid := OpenClaim(cross(cur), "cl-auth", "A claim")

	stranger := testutils.TestAddress("stranger")
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only the claim's author", func() {
		AppendBody(cross(cur), "cl-auth", cid, "hijack")
	})
}

func TestOpenClaimNeedsTheDeposit(cur realm, t *testing.T) {
	poor := testutils.TestAddress("poor")
	testing.SetRealm(testing.NewUserRealm(poor))
	StartCourt(cross(cur), "cl-poor", "Poor Court")
	// No CC bought, so the deposit transfer must abort on an insufficient balance.
	testing.SetRealm(testing.NewUserRealm(poor))
	uassert.AbortsContains(t, cur, "insufficient", func() {
		OpenClaim(cross(cur), "cl-poor", "Cannot afford")
	})
}
