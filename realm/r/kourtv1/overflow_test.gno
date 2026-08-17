package kourtv1

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// Regressions for the two integer-overflow theft vectors the holistic security audit
// found: the court multiplies caller-controlled qty by priceScale / a tick price in
// int64, which WRAPS (gno int64 does not trap), so a huge qty produced a tiny coin
// leg while crediting huge shares / resting a huge bid — draining the shared escrow.
// The fix uses checked overflow.Mul64 and bounds qty; these must now abort.

// 184467440737095517 * 100 == 18446744073709551700, which wraps mod 2^64 to 84.
const overflowQty = int64(184467440737095517)

func TestMintSetRejectsOverflowQty(cur realm, t *testing.T) {
	who := testutils.TestAddress("ov-mint")
	fundAndBuy(cur, "ov-mint", "Overflow Mint Court", who, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	cid := OpenClaim(cross(cur), "ov-mint", "overflow claim")

	testing.SetRealm(testing.NewUserRealm(who))
	uassert.AbortsContains(t, cur, "quantity", func() {
		MintSet(cross(cur), "ov-mint", cid, overflowQty)
	})
	// The claim's open interest must be untouched — no shares minted for a wrapped fee.
	if x := ClaimX("ov-mint", cid); x != 0 {
		t.Fatalf("an overflowing mint must credit nothing, ClaimX=%d", x)
	}
}

func TestRestBidRejectsOverflowQty(cur realm, t *testing.T) {
	who := testutils.TestAddress("ov-bid")
	fundAndBuy(cur, "ov-bid", "Overflow Bid Court", who, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	cid := OpenClaim(cross(cur), "ov-bid", "overflow bid claim")

	testing.SetRealm(testing.NewUserRealm(who))
	uassert.AbortsContains(t, cur, "quantity", func() {
		RestBid(cross(cur), "ov-bid", cid, 99, overflowQty)
	})
}
