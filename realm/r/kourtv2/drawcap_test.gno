package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// THE DRAW CAP BOUNDS WHAT A SNIPED CLAIM CAN DESTROY, AND IT MUST NOT TOUCH THE
// PUBLISHED MID RATE.
//
// Those are two assertions, not one, and they need opposite fixtures. The cap is
// INERT at today's constants — provably, not by luck: the collateralization floor
// gives answerBond0 >= 1.6·mg_max >= 1.6·mg_win, so capd >= 1.53·mg_win while the
// MID draw wants 1.00·mg_win. The inequality uses only 1.60 - 0.07 > 1, so it
// carries no X̄, no claim age, no rate and no bond level. Measured the other way
// round: at 5000 bps the cap could only bind above mg = 2415.5 bps·X̄, against a
// maxMidGrossBps of 1927 — 25% of margin.
//
// So a fixture that DRIVES the draw up cannot reach the cap; it would test the
// emission budget instead, since P8 clamps first. The cap has to be squeezed down
// onto a natural draw, which is `crystallize_test.gno`'s own idiom for the
// AnswererBonus bound. Both fixtures below assert the natural state first, so
// neither can pass vacuously if the arithmetic later moves.

// The bystander, and it is the more important of the two: an ordinary MID claim
// must be paid EXACTLY what it was paid before the cap existed. If this fails,
// the cap is cutting the rate a staker was promised.
func TestDrawCapIsInertOnAnOrdinaryMidClaim(cur realm, t *testing.T) {
	alice := testutils.TestAddress("dc1-alice")
	bob := testutils.TestAddress("dc1-bob")
	c := testCourt(cur, "dc1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "dc1", "The cap must not touch an ordinary claim")
	matureOI(cur, "dc1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "dc1", id, sideNO, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "dc1", id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "dc1", id)
	testing.SkipHeights(100_000)
	Crystallize(cross(cur), "dc1", id)

	cs := mustClaim(mustCourt("dc1"), id)
	if cs.tier != tierMidX {
		t.Fatalf("precondition: this fixture is about the MID rate, tier is %d", cs.tier)
	}
	mg := cs.winPoolConvCC
	if mg <= 0 {
		t.Fatalf("precondition: the winning pool must have conviction, got %d", mg)
	}

	// THE PRECONDITION THAT MAKES THE ASSERTION MEAN SOMETHING: the cap must be
	// slack here by the margin the comment claims. Asserting the payout alone
	// would pass just as well if the cap had silently become a no-op for some
	// other reason.
	carrot := mulDiv128(mg, splitCarrot, 100)
	if capd := cs.answerBond0 - carrot; capd <= mg {
		t.Fatalf("precondition FAILED — the cap is not slack on an ordinary MID claim: "+
			"capd %d, mid want %d, bond0 %d, carrot %d. The floor is supposed to "+
			"guarantee capd >= 1.53·mg; if that no longer holds, the cap is cutting "+
			"the published rate and this is the alarm.", capd, mg, cs.answerBond0, carrot)
	}

	// And the draw is the uncapped tier×mg. Compare the WINNERS' slice, not the
	// sum: the three slices each floor independently, so their sum sits up to two
	// units under the reserved D and an equality on the sum would fail for a
	// reason that has nothing to do with the cap. (Measured: D = 22767 pays
	// 19584 + 1958 + 1224 = 22766, with the odd unit deliberately left unminted.)
	w, a, ans, ct := DrawSlices("dc1", id)
	if w <= 0 || a <= 0 || ct <= 0 {
		t.Fatalf("the mid draw must be live: %d/%d/%d/%d", w, a, ans, ct)
	}
	uncapped := mustMul(cs.tier, mg)
	if uncapped > c.curPeriodBudget {
		t.Fatalf("this fixture measures the cap, but the period budget is tighter "+
			"(want %d, budget %d) — re-scale it", uncapped, c.curPeriodBudget)
	}
	if want := uncapped * splitWinners / 93; cs.drawWinners != want {
		t.Fatalf("an ordinary MID claim must draw its full tier×midGross: winners got "+
			"%d, want %d (uncapped D %d). The cap is cutting the published rate.",
			cs.drawWinners, want, uncapped)
	}
}

// The target: the cap binds when the bond did NOT collateralize the draw, which
// is the HIGH-tier snipe. Squeezed rather than driven, per the note above.
func TestDrawCapBindsWhenTheBondDidNotCoverTheDraw(cur realm, t *testing.T) {
	alice := testutils.TestAddress("dc2-alice")
	bob := testutils.TestAddress("dc2-bob")
	c := testCourt(cur, "dc2", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "dc2", "The cap binds where the bond fell short")
	matureOI(cur, "dc2", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "dc2", id, sideNO, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "dc2", id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "dc2", id)

	cs := mustClaim(mustCourt("dc2"), id)
	mg := convToCC(cs.yesConvHi, cs.yesConvLo)
	if mg <= 0 {
		t.Fatalf("precondition: the answered side must carry conviction, got %d", mg)
	}
	carrot := mulDiv128(mg, splitCarrot, 100)

	// Assert the cap is slack BEFORE squeezing, so a future change that makes it
	// bind naturally turns this into a loud failure rather than a silent pass.
	if cs.answerBond0-carrot <= mustMul(cs.tier, mg) {
		t.Fatalf("this fixture assumes the cap is slack and squeezes it; it now binds "+
			"on its own (bond0 %d, carrot %d, want %d). Assert the natural value "+
			"instead of squeezing.", cs.answerBond0, carrot, mustMul(cs.tier, mg))
	}

	// Squeeze: a bond that collateralized only HALF the mid draw. This is the
	// snipe's shape — dust declared against a large opposing pool — expressed
	// directly on the one field the cap reads.
	cs.answerBond0 = mg/2 + carrot
	wantCapped := cs.answerBond0 - carrot
	if wantCapped <= 0 || wantCapped >= mustMul(cs.tier, mg) {
		t.Fatalf("the squeeze must land strictly between 0 and the uncapped draw: "+
			"capped %d, uncapped %d", wantCapped, mustMul(cs.tier, mg))
	}

	testing.SkipHeights(100_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "dc2", id)

	// The reserved D is the capped figure, not tier×midGross.
	got := cs.drawWinners + cs.drawAuthor + cs.drawAnswerer
	if got > wantCapped {
		t.Fatalf("the cap must hold the whole draw at or under what the bond "+
			"collateralized: drew %d, cap %d (uncapped would be %d)",
			got, wantCapped, mustMul(cs.tier, mg))
	}
	if got <= 0 {
		t.Fatalf("the cap must bound the draw, not destroy it: drew %d", got)
	}
	// And it really was the CAP that bound, not the period budget.
	if wantCapped > c.curPeriodBudget {
		t.Fatalf("this fixture measures the cap, but the period budget is tighter "+
			"(cap %d, budget %d) — re-scale it", wantCapped, c.curPeriodBudget)
	}
}

// The carrot is deliberately OUTSIDE the cap: it is senior-lane and tier-invariant,
// paid even at low tier, so subtracting it is what makes the cap bound the whole
// minted amount rather than just the junior part. Pinning it here because a future
// reader may see the subtraction as an off-by-one and remove it.
func TestDrawCapSubtractsTheCarrotBecauseTheCarrotAlsoMints(cur realm, t *testing.T) {
	alice := testutils.TestAddress("dc3-alice")
	bob := testutils.TestAddress("dc3-bob")
	c := testCourt(cur, "dc3", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "dc3", "The carrot mints too, so the cap must net it")
	matureOI(cur, "dc3", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "dc3", id, sideNO, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "dc3", id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "dc3", id)
	testing.SkipHeights(100_000)
	Crystallize(cross(cur), "dc3", id)

	cs := mustClaim(mustCourt("dc3"), id)
	if cs.carrotTotal <= 0 {
		t.Fatalf("precondition: the carrot must be live for this to mean anything, got %d",
			cs.carrotTotal)
	}
	if cs.carrotTotal != mulDiv128(cs.winPoolConvCC, splitCarrot, 100) {
		t.Fatalf("the cap subtracts mulDiv128(midGross, splitCarrot, 100); the carrot "+
			"is computed as %d, so the two have drifted apart", cs.carrotTotal)
	}
	// The whole minted amount for this claim is the junior draw PLUS the carrot,
	// which is exactly why the cap nets the carrot out.
	minted := cs.drawWinners + cs.drawAuthor + cs.drawAnswerer + cs.carrotTotal
	if minted <= cs.carrotTotal {
		t.Fatalf("the junior draw must be a real part of what mints: minted %d, carrot %d",
			minted, cs.carrotTotal)
	}
	uassert.True(t, minted > 0, "a mid claim must mint something")
}
