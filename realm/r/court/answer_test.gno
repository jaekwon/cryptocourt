package court

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// matureOI mints a set at three consecutive hourly buckets so the answerability
// X̄ (over a 3-bucket window) reads mature, leaving the height at the third bucket.
func matureOI(cur realm, slug string, cid uint64, who address) {
	testing.SetRealm(testing.NewUserRealm(who))
	MintSet(cross(cur), slug, cid, 1000)
	testing.SkipHeights(epochBlocks)
	testing.SetRealm(testing.NewUserRealm(who))
	MintSet(cross(cur), slug, cid, 1000)
	testing.SkipHeights(epochBlocks)
	testing.SetRealm(testing.NewUserRealm(who))
	MintSet(cross(cur), slug, cid, 1000)
}

func TestPostAnswerBondsAndSnapshots(cur realm, t *testing.T) {
	who := testutils.TestAddress("answerer")
	fundAndBuy(cur, "an-eg", "Answer Court", who, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	cid := OpenClaim(cross(cur), "an-eg", "Claim to answer")
	matureOI(cur, "an-eg", cid, who)

	before := CoinBalanceOf("an-eg", who)
	testing.SetRealm(testing.NewUserRealm(who))
	PostAnswer(cross(cur), "an-eg", cid, outcomeYES)

	if !HasAnswer("an-eg", cid) {
		t.Fatal("the claim should be answered")
	}
	if AnswerVerdict("an-eg", cid) != outcomeYES {
		t.Fatal("the verdict should be YES")
	}
	if Answerer("an-eg", cid) != who {
		t.Fatal("the answerer should be recorded")
	}
	bond := before - CoinBalanceOf("an-eg", who)
	if bond <= 0 || AnswerBond("an-eg", cid) != bond {
		t.Fatalf("a positive bond should be escrowed and recorded, moved %d recorded %d", bond, AnswerBond("an-eg", cid))
	}
	// No trades yet, so the pre-answer price is the 50/50 split.
	if PreAnswerPrice("an-eg", cid) != priceScale/2 {
		t.Fatalf("no-trade pre-answer price should be %d, got %d", priceScale/2, PreAnswerPrice("an-eg", cid))
	}

	// A second answer is refused.
	testing.SetRealm(testing.NewUserRealm(who))
	uassert.AbortsContains(t, cur, "already has an answer", func() {
		PostAnswer(cross(cur), "an-eg", cid, outcomeNO)
	})
}

func TestAnswerNeedsMatureOpenInterest(cur realm, t *testing.T) {
	who := testutils.TestAddress("hasty")
	fundAndBuy(cur, "an-hasty", "Hasty Court", who, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	cid := OpenClaim(cross(cur), "an-hasty", "Fresh claim")
	// A single observation is not a trailing average — the gate must refuse.
	testing.SetRealm(testing.NewUserRealm(who))
	MintSet(cross(cur), "an-hasty", cid, 1000)
	testing.SetRealm(testing.NewUserRealm(who))
	uassert.AbortsContains(t, cur, "not enough open-interest history", func() {
		PostAnswer(cross(cur), "an-hasty", cid, outcomeYES)
	})
}

// TestPreAnswerPriceResistsShortWindowPin is the regression for the price-TWAP
// manipulation MED. A self-trader pins the traded price at the top of the grid
// across three consecutive buckets — enough that the OLD 3-bucket window would read
// mature-and-pinned and set preAnswerPrice to ~99. Because the pre-answer price now
// reads the full week (priceWindow), which a hours-old market cannot fill, the
// snapshot falls back to the safe 50/50 default and the pin is ignored. This is what
// forces a would-be manipulator to sustain the pin for a week against arbitrage.
func TestPreAnswerPriceResistsShortWindowPin(cur realm, t *testing.T) {
	alice := testutils.TestAddress("pin-alice")
	bob := testutils.TestAddress("pin-bob")
	fundAndBuy(cur, "pin", "Pin Court", alice, 500_000_000)
	buyCoin(cur, "pin", bob, 500_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	cid := OpenClaim(cross(cur), "pin", "Can a flash pin move the close price?")
	matureOI(cur, "pin", cid, alice) // 3 buckets of OI; alice holds 3000 YES + 3000 NO

	// Pin the traded price at tick 98 (grid price 99) across three consecutive
	// buckets, so the price ring is filled=3 and the OLD 3-bucket window is mature.
	for i := 0; i < 3; i++ {
		testing.SetRealm(testing.NewUserRealm(bob))
		RestBid(cross(cur), "pin", cid, 98, 1000)
		testing.SetRealm(testing.NewUserRealm(alice))
		if filled, _ := TakeSell(cross(cur), "pin", cid, 98, 1000); filled != 1000 {
			t.Fatalf("round %d: alice should fill bob's pin bid, filled %d", i, filled)
		}
		if i < 2 {
			testing.SkipHeights(epochBlocks)
		}
	}

	// The short window is pinned and mature — this is exactly what the old code read.
	if avg, mature := TrailingPrice("pin", cid, answerWindow); !mature || avg < 90 {
		t.Fatalf("short-window price should be mature and pinned high, got %d,%v", avg, mature)
	}
	// The week-long window is NOT mature on a market only hours old.
	if avg, mature := TrailingPrice("pin", cid, priceWindow); mature {
		t.Fatalf("a market a few hours old must not have a mature week-long price, got %d,%v", avg, mature)
	}
	// So the snapshotted pre-answer price is the safe 50/50 default, not the pin.
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "pin", cid, outcomeYES)
	if got := PreAnswerPrice("pin", cid); got != priceScale/2 {
		t.Fatalf("a short-window pin must NOT set the pre-answer price; want %d (50/50), got %d", priceScale/2, got)
	}
}

// TestPreAnswerPriceUsesRealPriceWhenTheWeekIsMature is the positive companion: a
// market with a full, stable week of price history yields that REAL price as the
// pre-answer snapshot, not the 50/50 fallback. Without it, a future off-by-one that
// made the week window permanently immature would silently pin every pre-answer price
// to 50/50 and every other court test would still pass. It also documents the residual
// the vetter surfaced — the twap carries the last value across idle buckets, so TWO
// takes a week apart (here, honest ones at 70) are enough to mature the window; the
// same mechanic is what a manipulator would need, and why the week window is an
// economic deterrent (week of latency + real counterparties + 3 failed rounds), not a
// mechanical block.
func TestPreAnswerPriceUsesRealPriceWhenTheWeekIsMature(cur realm, t *testing.T) {
	alice := testutils.TestAddress("wk-alice")
	bob := testutils.TestAddress("wk-bob")
	fundAndBuy(cur, "wk", "Week Court", alice, 500_000_000)
	buyCoin(cur, "wk", bob, 500_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	cid := OpenClaim(cross(cur), "wk", "A market with a real weekly price")
	matureOI(cur, "wk", cid, alice) // OI answerable; alice holds 3000 YES + 3000 NO

	trade70 := func() {
		testing.SetRealm(testing.NewUserRealm(bob))
		RestBid(cross(cur), "wk", cid, 69, 1000) // bid to buy YES at grid price 70
		testing.SetRealm(testing.NewUserRealm(alice))
		if filled, _ := TakeSell(cross(cur), "wk", cid, 69, 1000); filled != 1000 {
			t.Fatalf("alice should fill bob's bid at price 70, filled %d", filled)
		}
	}
	trade70()
	testing.SkipHeights(twapBuckets * epochBlocks) // a full week of silence — the twap carries 70 forward
	trade70()

	if avg, mature := TrailingPrice("wk", cid, priceWindow); !mature || avg != 70 {
		t.Fatalf("a stable week at price 70 should read mature 70, got %d,%v", avg, mature)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "wk", cid, outcomeYES)
	if got := PreAnswerPrice("wk", cid); got != 70 {
		t.Fatalf("a mature week-long price must set preAnswerPrice to the real 70, got %d", got)
	}
}
