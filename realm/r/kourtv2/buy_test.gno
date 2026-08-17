package kourtv2

import (
	"chain"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

const realmPath = "gno.land/r/kourt/kourtv2"

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

// Two guards the mutation harness found surviving on the money-IN path. IsUserCall is
// the one AGENTS.md names explicitly: with OriginSend payments the caller check must be
// IsUserCall, not IsUser, because a `maketx run` ephemeral realm can consume the
// origin-send envelope before calling in and so bypass the payment. Weakening it to
// `if false` failed no test — the whole payment-bypass protection was unpinned.
//
// THREE other survivors on this path are UNREACHABLE at this curve's granularity and
// are documented in buy.gno rather than faked here: the remainder refund (Minted spends
// the payment EXACTLY for every amount probed, so no remainder exists to misdirect), the
// "too small to mint" guard (1 ugnot already mints 20,000 base units, so delta > 0 for
// any accepted payment — reachable only once the curve is at cap), and the self-buy
// check (the buyer is prev.Address() behind this IsUserCall gate, so it is never the
// realm). Naming them here so the next reader does not mistake the survivor report for
// a list of holes.
//
// AND ONE THAT IS NOT TESTABLE HERE AT ALL, which matters more than the rest: swapping
// IsUserCall for IsUser survives this fixture, and that is exactly the downgrade
// AGENTS.md warns about — IsUser ACCEPTS a `maketx run` ephemeral realm, which can
// consume the origin-send envelope and call in with the payment already spent. The
// distinguishing caller is an /e/<addr>/run realm, and testing.NewCodeRealm REFUSES
// such a path ("should only be called for Realms"), so the harness cannot construct
// one. This assertion therefore catches DELETING the guard but not WEAKENING it.
// Enforcement of that one rests on code review, which is why AGENTS.md states it as a
// reading rule rather than a test. Recorded in PLAN §13 v0.62; do not read the survivor
// as a gap a fixture can close.
func TestBuyRefusesNonUserCallsSelfBuysAndDustPayments(cur realm, t *testing.T) {
	alice := testutils.TestAddress("byg2-alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "byg2", "More guards")

	// A call arriving from a REALM rather than a user is refused, even with GNOT
	// attached — otherwise the envelope could be spent by an intermediary.
	testing.IssueCoins(chain.PackageAddress(realmPath),
		chain.Coins{{Denom: "ugnot", Amount: 300_000_000}})
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 300_000_000}})
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/kourt/notacourt"))
	uassert.AbortsContains(t, cur, "must be a direct user call", func() {
		Buy(cross(cur), "byg2")
	})
	testing.SetOriginSend(nil)

	// The control: the SAME payment from a user call succeeds, so the guard rejects
	// the caller kind and not the payment.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{Denom: "ugnot", Amount: 300_000_000}})
	if got := Buy(cross(cur), "byg2"); got <= 0 {
		t.Fatalf("a direct user call with the same payment must mint: %d", got)
	}
	testing.SetOriginSend(nil)
}

