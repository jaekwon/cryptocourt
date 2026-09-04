package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// THE DRAW CAP BOUNDS WHAT A SNIPED CLAIM CAN DESTROY, AND IT MUST NOT TOUCH THE
// PUBLISHED MID RATE.
//
// Those are two assertions, not one, and they need opposite fixtures.
//
// WHY THE CAP IS INERT TODAY, stated carefully because an earlier version of this
// comment got it wrong in a way that would have shipped a 22% cut. There are two
// regimes and only the second is live on this tree:
//
//   floor binds:    answerBond0 >= 1.6·mg_max >= 1.6·mg_win, so capd >= 1.53·mg_win
//                   against a MID want of 1.00·mg_win. Uses only 1.60-0.07 > 1, so
//                   it carries no X̄, no age, no rate, no bond level. This is the
//                   POST-re-keying guarantee — the floor keys on the ANSWERED side
//                   today, so it does NOT deliver mg_max yet.
//   base arm binds: the 5000 bps arm against maxMidGrossBps = 1927. The cap could
//                   only bind above mg = 2415.5 bps·X̄ — 25% of margin. THIS is what
//                   carries the shipped tree, and it is a calibration rather than a
//                   proof, exactly as court.gno's "CALIBRATION, NOT A SAFETY
//                   PROOF" note says of its own neighbour.
//
// So a fixture that DRIVES the draw up cannot reach the cap; it would test the
// emission budget instead, since P8 clamps first. The cap has to be squeezed down
// onto a natural draw, which is `openrewards_test.gno`'s own idiom for the
// AnswererBonus bound. Every fixture below asserts the natural state FIRST, so none
// can pass vacuously if the arithmetic later moves — and the bystander asserts the
// 1.53× MARGIN, not merely `capd > mg`, because at this fixture's scale the bare
// inequality is slack by four orders of magnitude and would not have caught the
// regression the cap's own comment promised it would.

// The bystander, and it is the more important of the two: an ordinary MID claim
// must be paid EXACTLY what it was paid before the cap existed. If this fails,
// the cap is cutting the rate a staker was promised.
func TestDrawCapIsInertEvenAtTheSizeCeiling(cur realm, t *testing.T) {
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
	OpenRewards(cross(cur), "dc1", id)

	cs := mustClaim(mustCourt("dc1"), id)
	// THE CEILING, AND THAT IS THE POINT — the strongest place to claim the cap is
	// inert, because the multiplier is as large as this court will ever make it.
	//
	// The precondition here used to read `cs.tier != tierMidX` and it was VACUOUS:
	// SettleUndisputed wrote tierMidX into that field on every undisputed claim, so
	// the check passed by construction while the draw was actually being multiplied
	// by 2. Dropping the dead field is what exposed it. This fixture is a single
	// large claim in a court whose running average is still at its supply floor, so
	// size rates it on the ceiling.
	if bps := tierBpsFor(cs); bps != tierCeilBps {
		t.Fatalf("precondition: this fixture sits on the size ceiling, multiplier is %d bps", bps)
	}
	mg := cs.winPoolConvCC
	if mg <= 0 {
		t.Fatalf("precondition: the winning pool must have conviction, got %d", mg)
	}

	// THE PRECONDITION THAT MAKES THE ASSERTION MEAN SOMETHING, and it asserts the
	// MARGIN rather than the mere inequality. An earlier version of this fixture
	// checked only `capd > mg`, which on this fixture's scale is slack by four
	// orders of magnitude — so it would have passed on a 600-bps tree that was
	// cutting overturn winners by 22%, while its own comment claimed such a change
	// "fails loudly". Demanding the full 1.53× is what makes it discriminate.
	carrot := mulDiv128(mg, splitCarrot, 100)
	capd := cs.answerBond0 - carrot
	if capd < mustMul(mg, 153)/100 {
		t.Fatalf("precondition FAILED — the cap is not slack by the 1.53x the proof "+
			"claims: capd %d, mid want %d, 1.53x want %d, bond0 %d, carrot %d. Either "+
			"the collateralization floor stopped guaranteeing 1.6*mg_win, or the base "+
			"arm shrank below it. Both mean the cap is now able to cut the published "+
			"rate, which is the alarm this line exists to raise.",
			capd, mg, mustMul(mg, 153)/100, cs.answerBond0, carrot)
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
	// THE ACTUAL MULTIPLIER, not an assumed MID. This test is about the draw
	// CAP, so it must not also assert what the multiplier is — that moved to a
	// size derivation (tier.gno) and is pinned by tier_test.gno. Reading it here
	// keeps this test measuring the one thing it is named for.
	uncapped := mulDiv128(mg, tierBpsFor(cs), tierParBps)
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
	if cs.answerBond0-carrot <= mulDiv128(mg, tierBpsFor(cs), tierParBps) {
		t.Fatalf("this fixture assumes the cap is slack and squeezes it; it now binds "+
			"on its own (bond0 %d, carrot %d, want %d). Assert the natural value "+
			"instead of squeezing.", cs.answerBond0, carrot, mulDiv128(mg, tierBpsFor(cs), tierParBps))
	}

	// Squeeze: a bond that collateralized only HALF the mid draw. This is the
	// snipe's shape — dust declared against a large opposing pool — expressed
	// directly on the one field the cap reads.
	cs.answerBond0 = mg/2 + carrot
	wantCapped := cs.answerBond0 - carrot
	if wantCapped <= 0 || wantCapped >= mulDiv128(mg, tierBpsFor(cs), tierParBps) {
		t.Fatalf("the squeeze must land strictly between 0 and the uncapped draw: "+
			"capped %d, uncapped %d", wantCapped, mulDiv128(mg, tierBpsFor(cs), tierParBps))
	}

	testing.SkipHeights(100_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	OpenRewards(cross(cur), "dc2", id)

	// The reserved D is the capped figure, not tier×midGross.
	got := cs.drawWinners + cs.drawAuthor + cs.drawAnswerer
	if got > wantCapped {
		t.Fatalf("the cap must hold the whole draw at or under what the bond "+
			"collateralized: drew %d, cap %d (uncapped would be %d)",
			got, wantCapped, mulDiv128(mg, tierBpsFor(cs), tierParBps))
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

// AN OVERTURN MUST NOT BE CAPPED, and this is the regime the cap's first version
// had no fixture for — which is how it shipped with a proof that did not hold here.
//
// On an overturn the floor keys on the ANSWERED side, which is the LOSING side, so
// `answerBond0` carries no information about the winning pool: a dust-answered
// overturn was measured giving 40% of the 1.6·mg_win the cap's proof assumes. The
// gate exists because the bond has already burned in full on this path, so the
// collateral was consumed and there is nothing left to bound. Without the gate this
// fixture fails on a 600-bps tree; with it, it passes at any bond level.
func TestDrawCapDoesNotTouchAnOverturnedClaim(cur realm, t *testing.T) {
	alice := testutils.TestAddress("dc4-alice")
	bob := testutils.TestAddress("dc4-bob")
	whale := testutils.TestAddress("dc4-whale")
	c := testCourt(cur, "dc4", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(whale, 20_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "dc4", "An overturn pays the vindicated pool in full")
	// ORDER MATTERS. Conviction is capital x TIME, so the pool that must end up
	// vindicated has to be staked BEFORE the clock moves. matureOI stakes YES and
	// advances two epochs, so bob's NO goes in first and accrues across that same
	// window; alice's YES is the dust the answerer then declares. Staking NO after
	// matureOI leaves it with zero conviction at the freeze, which the precondition
	// below catches rather than silently measuring nothing.
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "dc4", id, sideNO, 4_000_000_000)
	matureOI(cur, "dc4", id, alice, 1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "dc4", id, sideYES)

	cs := mustClaim(mustCourt("dc4"), id)
	bond0 := cs.answerBond0

	// Overturn it: a non-participant whale opens the dispute and carries the round.
	testing.SetRealm(testing.NewUserRealm(whale))
	OpenDispute(cross(cur), "dc4", id)
	VoteDispute(cross(cur), "dc4", id, "yes")
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "dc4", id)

	if int(cs.provisional) == int(cs.answer) {
		t.Fatalf("precondition: this fixture needs an OVERTURN, provisional %d answer %d",
			cs.provisional, cs.answer)
	}
	if cs.answerBond != 0 {
		t.Fatalf("precondition: an overturn burns the answer bond in full, %d left",
			cs.answerBond)
	}

	testing.SkipHeights(escrowWindow(c, cs) + 1)
	// Finalize and OpenRewards are both participant-only for their first week
	// (A13 — a stranger must not pick the reservoir moment), and the DISPUTER is
	// not a participant. Alice is: she authored and answered it.
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "dc4", id)

	mg := convToCC(cs.noConvHi, cs.noConvLo)
	if mg <= 0 {
		t.Fatalf("precondition: the vindicated pool must carry conviction, got %d", mg)
	}
	// THE ACTUAL MULTIPLIER, not an assumed MID. This test is about the draw
	// CAP, so it must not also assert what the multiplier is — that moved to a
	// size derivation (tier.gno) and is pinned by tier_test.gno. Reading it here
	// keeps this test measuring the one thing it is named for.
	uncapped := mulDiv128(mg, tierBpsFor(cs), tierParBps)
	carrot := mulDiv128(mg, splitCarrot, 100)

	// SQUEEZE, exactly as the binding fixture does. On the shipped tree the cap
	// cannot bind naturally here — the 5000 bps base arm dwarfs mg by 6600x on a
	// short claim — so driving the pool wider would only measure the period budget.
	// Squeezing answerBond0 onto the natural draw is what isolates the GATE: with
	// the gate removed this bond WOULD halve the vindicated pool's payout.
	if bond0-carrot < uncapped {
		t.Fatalf("this fixture assumes the cap is naturally slack and squeezes it; it "+
			"now binds on its own (bond0 %d, carrot %d, want %d)", bond0, carrot, uncapped)
	}
	cs.answerBond0 = mg/2 + carrot
	if would := cs.answerBond0 - carrot; would >= uncapped || would <= 0 {
		t.Fatalf("the squeeze must make the cap strictly bite: would-cap %d against "+
			"want %d", would, uncapped)
	}

	// OUTLAST THE COMP DROUGHT. The overturn that vindicated this pool also
	// enqueued a SENIOR comp to the disputer, and reservedTail is monotone — so
	// reserveJunior clamps this claim's draw to an empty reservoir until accrual
	// catches up (GAMETHEORY.md §11.8, and §16.4 for exactly this shape: a
	// provClose after a DECIDED round restores an entitlement worth nothing until
	// C0 lands). Measured here: opening the rewards straight after Finalize paid the
	// winners 0 rather than the capped figure, so without this wait the fixture
	// would have "passed" against the wrong zero. That is a separate open item,
	// not this cap — the wait isolates the cap from it.
	// `reservoirR() > 0` is NOT a sufficient precondition and that was a real bug
	// in the first version of this fixture: reserveJunior CLAMPS want to r, so a
	// reservoir of 1 passes a `> 0` check and still pays drawWinners = 0, and the
	// assertion below would then be measuring the drought rather than the gate.
	// The reservoir must cover the whole uncapped draw. Loop rather than guess a
	// constant — the comp here is 2x the dispute bond, which scales with X̄, so a
	// fixed wait that suffices at this court's size silently stops sufficing when
	// anyone re-scales the fixture. (Measured while finding this: 40 periods was
	// short at one scale, 80 sufficed.)
	for i := 0; i < 200 && c.reservoirR() < uncapped; i++ {
		testing.SkipHeights(periodBlocks)
		touch(c)
	}
	if c.reservoirR() < uncapped {
		t.Fatalf("precondition: the comp drought must clear the WHOLE draw before this "+
			"can measure the cap; reservoir %d, need %d", c.reservoirR(), uncapped)
	}
	OpenRewards(cross(cur), "dc4", id)

	if uncapped > c.curPeriodBudget {
		t.Fatalf("re-scale: the period budget bound this claim (want %d, budget %d)",
			uncapped, c.curPeriodBudget)
	}
	// THE POINT: paid in full despite a bond that would not have collateralized it,
	// because that bond already burned.
	if want := uncapped * splitWinners / 93; cs.drawWinners != want {
		t.Fatalf("an overturn must pay the vindicated pool in full: winners got %d, "+
			"want %d. The cap is cutting a draw whose collateral already burned.",
			cs.drawWinners, want)
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
	OpenRewards(cross(cur), "dc3", id)

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
