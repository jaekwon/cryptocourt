package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// matureOI stakes at three consecutive hourly buckets so the trailing X̄ over
// the 3-bucket answerWindow reads mature (the V1 test idiom).
func matureOI(cur realm, slug string, id uint64, who address, amt int64) {
	for i := 0; i < 3; i++ {
		testing.SetRealm(testing.NewUserRealm(who))
		Stake(cross(cur), slug, id, sideYES, amt)
		if i < 2 {
			testing.SkipHeights(epochBlocks)
		}
	}
}

func TestPostAnswerBondsAndFreezes(cur realm, t *testing.T) {
	alice := testutils.TestAddress("an-alice")
	c := testCourt(cur, "an1", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "an1", "Will it be answered?")

	// Too fresh: no trailing history.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "not enough stake history", func() {
		PostAnswer(cross(cur), "an1", id, sideYES)
	})
	matureOI(cur, "an1", id, alice, 200_000_000) // 3 x 200 CC

	before := c.coin.BalanceOf(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "an1", id, sideYES)

	if !HasAnswer("an1", id) || AnswerVerdict("an1", id) != sideYES || Answerer("an1", id) != alice {
		t.Fatal("the answer must be recorded")
	}
	bond := before - c.coin.BalanceOf(alice)
	if bond <= 0 || bond != AnswerBond("an1", id) {
		t.Fatalf("a positive bond must escrow and record: %d vs %d", bond, AnswerBond("an1", id))
	}
	x := XBarFrozen("an1", id)
	if x < 200_000_000 || bond != x*answerBondBps/10000 {
		t.Fatalf("bond = 50%% of the frozen X-bar: bond=%d x=%d", bond, x)
	}
	// Frozen: no stake flows, conviction pinned.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "frozen", func() {
		Stake(cross(cur), "an1", id, sideYES, 1)
	})
	conv := ConvictionOf("an1", id, sideYES, alice)
	testing.SkipHeights(periodBlocks)
	if ConvictionOf("an1", id, sideYES, alice) != conv {
		t.Fatal("frozen conviction is immutable")
	}
	// Second answer refused.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "already has an answer", func() {
		PostAnswer(cross(cur), "an1", id, sideNO)
	})
}

func TestAnswerBelowFloorRefused(cur realm, t *testing.T) {
	alice := testutils.TestAddress("an2-alice")
	c := testCourt(cur, "an2", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "an2", "Thin claim")
	// Staked BELOW THE FLOOR, derived — not "10 CC because the floor is 100".
	// The floor is a fraction of the court's own supply (v0.27), so a literal
	// here asserts against a number that moved: at 10 bps on a 10,000 CC court
	// the floor is 10 CC, and the old fixture's 20 CC trailing average would
	// have CLEARED the bar it was written to fail. matureOI's three buckets
	// average 2x their amount, so a sixth of the floor stays under it with
	// margin at any fraction.
	matureOI(cur, "an2", id, alice, effMinAnswerX(c)/6)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "below the minimum", func() {
		PostAnswer(cross(cur), "an2", id, sideYES)
	})
}

func TestPriorityWindowGates(cur realm, t *testing.T) {
	alice := testutils.TestAddress("an3-alice")
	pro := testutils.TestAddress("an3-pro")
	c := testCourt(cur, "an3", alice, 50_000_000_000)
	c.coin.Mint(pro, 10_000_000_000)
	// Arm the gate: three qualified answerers exist.
	for _, a := range []address{pro, testutils.TestAddress("an3-q2"), testutils.TestAddress("an3-q3")} {
		for i := 0; i < priorityNetRecord; i++ {
			creditUpheld(c, a)
		}
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "an3", "Priority claim")
	matureOI(cur, "an3", id, alice, 200_000_000)

	// Inside the age window: an unqualified answerer is refused …
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "priority window is open", func() {
		PostAnswer(cross(cur), "an3", id, sideYES)
	})
	// … a qualified one succeeds and now holds their one active slot.
	testing.SetRealm(testing.NewUserRealm(pro))
	PostAnswer(cross(cur), "an3", id, sideYES)
	if mayAnswerInPriority(c, pro) {
		t.Fatal("the priority slot must be held")
	}

	// A second fresh claim: the same pro is slot-blocked inside the window;
	// after the window, anyone (including unqualified) may answer.
	testing.SetRealm(testing.NewUserRealm(alice))
	id2 := OpenClaim(cross(cur), "an3", "Second claim")
	matureOI(cur, "an3", id2, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(pro))
	uassert.AbortsContains(t, cur, "priority window is open", func() {
		PostAnswer(cross(cur), "an3", id2, sideYES)
	})
	testing.SkipHeights(priorityWindowBlocks + answerWindow) // safely past id2's age window
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "an3", id2, sideNO)
	if AnswerVerdict("an3", id2) != sideNO {
		t.Fatal("past the window the answer slot is first-come")
	}
}

func TestQualityEpochPinnedAtAnswer(cur realm, t *testing.T) {
	alice := testutils.TestAddress("qe-alice")
	c := testCourt(cur, "qe1", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "qe1", "Epoch pin")
	matureOI(cur, "qe1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "qe1", id, sideYES)
	cs := mustClaim(c, id)
	if cs.qualityEpoch != c.coin.Epoch()-1 {
		t.Fatalf("qualityEpoch must pin the last sealed epoch at the answer: %d vs %d",
			cs.qualityEpoch, c.coin.Epoch()-1)
	}
	if cs.qualityEpoch < 1 {
		t.Fatal("after three matured buckets the sealed epoch is positive")
	}
	// The pin is immutable: epochs advance, the stored value does not.
	was := cs.qualityEpoch
	testing.SkipHeights(epochBlocks * 5)
	touch(c)
	if cs.qualityEpoch != was {
		t.Fatal("the quality epoch never moves after the answer")
	}
}
