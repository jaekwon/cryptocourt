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
