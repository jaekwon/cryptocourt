package courtv2

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
	testCourt(cur, "an2", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "an2", "Thin claim")
	matureOI(cur, "an2", id, alice, 10_000_000) // 10 CC << the 100 CC floor
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

// The F9 drain, pinned. xBarFrozen = max(3h trailing, lifeAvgStake) is what makes
// `midGross <= 19.27%·X̄frozen` a RUNTIME guarantee rather than a deploy-time
// calibration: conviction survives unstake (F9), so a pool that banks capital-time and
// then drains just before the answer would otherwise carry a large prize while every
// %-of-X̄ bar — the answer bond, the slash floor, the flag bond, both quality bars, the
// dispute bond, the quorum floor, the carrot clamp — priced off a tiny trailing read.
// answer.gno's own comment block describes that attack; the `max()` on the line below
// it is the fix. Neither lifeAvgStake nor that max() had any test.
//
// Drives the exact shape answer.gno names: bank at 100k CC for a week, then "drain to
// minAnswerX two hours before answering". The drain is bounded BELOW by that gate —
// line 50 checks the RAW trailing average against minAnswerX (100 CC) and is
// deliberately left reading the raw value, because the 3h window is the answerability
// question, a liveness check. So the attacker's maximum drain factor is
// banked/minAnswerX, and the lifetime arm is what neutralises it.
func TestXBarFrozenSurvivesAPreAnswerDrain(cur realm, t *testing.T) {
	alice := testutils.TestAddress("f9d-alice")
	c := testCourt(cur, "f9d", alice, 500_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "f9d", "banked then drained")

	// Bank capital-time: 100k CC held across a week of hourly buckets.
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "f9d", id, sideYES, 100_000_000_000)
	testing.SkipHeights(epochBlocks * 24 * 7)

	// Drain to just above minAnswerX, then mature the ring there so the 3h trailing
	// arm reads the DRAINED size — the attacker's whole play. Draining FURTHER is not
	// available: PostAnswer's liveness gate refuses below minAnswerX.
	testing.SetRealm(testing.NewUserRealm(alice))
	Unstake(cross(cur), "f9d", id, sideYES, 99_899_000_000) // leaves 101 CC
	matureOI(cur, "f9d", id, alice, 1_000_000)

	cs := mustClaim(c, id)
	trailing, mature := cs.oi.Average(runtimeHeight(), answerWindow)
	if !mature {
		t.Fatal("setup: the trailing ring must be mature")
	}
	life := lifeAvgStake(cs, runtimeHeight())
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "f9d", id, sideYES)

	// The lifetime arm must win, and by a wide margin: this is the drain factor.
	if cs.xBarFrozen != life {
		t.Fatalf("the lifetime arm must set X̄ after a drain: xBar=%d life=%d trailing=%d",
			cs.xBarFrozen, life, trailing)
	}
	if cs.xBarFrozen <= trailing*100 {
		t.Fatalf("the drain must be neutralised, not merely dented: xBar=%d trailing=%d",
			cs.xBarFrozen, trailing)
	}
	// And every %-of-X̄ consumer now prices off the honest lifetime size. The answer
	// bond is the one with a closed form (50%·X̄, min 1, capped by params).
	if got := AnswerBond("f9d", id); got < cs.xBarFrozen*answerBondBps/10000/2 {
		t.Fatalf("the answer bond must price off the undrained X̄: bond=%d xBar=%d",
			got, cs.xBarFrozen)
	}
	// No withdrawal can lower the lifetime arm — past capital-time is immutable. The
	// integrals are frozen at the answer, so a later read is identical.
	if again := lifeAvgStake(cs, runtimeHeight()); again != life {
		t.Fatalf("the frozen lifetime average must not drift: %d vs %d", again, life)
	}
}

// The other half of P6's base: max(), never REPLACE. On a claim whose stake RAMPED UP
// the lifetime average is BELOW the trailing read, and taking the lifetime arm there
// would let an answerer on a growing claim post a bond — and face bars — priced off
// capital that is no longer representative, weakening every %-of-X̄ quantity exactly
// when the claim is largest. answer.gno calls the max "a provable no-op off the drain
// path"; without this fixture that claim is unverified, and swapping max for a plain
// assignment passes the whole suite.
func TestXBarFrozenTakesTheTrailingArmOnAGrowingClaim(cur realm, t *testing.T) {
	alice := testutils.TestAddress("f9g-alice")
	c := testCourt(cur, "f9g", alice, 500_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "f9g", "small then large")

	// A long thin head drags the LIFETIME average down...
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "f9g", id, sideYES, 1_000_000) // 1 CC
	testing.SkipHeights(epochBlocks * 24 * 7)

	// ...then the claim grows, and the recent trailing read is what represents it.
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "f9g", id, sideYES, 100_000_000_000)
	matureOI(cur, "f9g", id, alice, 1_000_000)

	cs := mustClaim(c, id)
	trailing, mature := cs.oi.Average(runtimeHeight(), answerWindow)
	if !mature {
		t.Fatal("setup: the trailing ring must be mature")
	}
	life := lifeAvgStake(cs, runtimeHeight())
	if life >= trailing {
		t.Fatalf("fixture must ramp UP so the lifetime arm is the smaller one: "+
			"life=%d trailing=%d", life, trailing)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "f9g", id, sideYES)
	if cs.xBarFrozen != trailing {
		t.Fatalf("max() must keep the trailing arm on a growing claim: xBar=%d "+
			"trailing=%d life=%d", cs.xBarFrozen, trailing, life)
	}
}
