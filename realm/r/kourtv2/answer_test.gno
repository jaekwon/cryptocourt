package kourtv2

import (
	"testing"
	"time"

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

// THE HEAD START IS 24 HOURS, WHICH IS NOT 17,280 BLOCKS.
//
// TestPriorityWindowGates above walks the window with SkipHeights, which moves
// height and time together at exactly 5s a block, so it cannot say which clock
// the gate read. It reads the wall clock now, and the window is a SUM: the polish
// delay and the trailing ring's width — both block-denominated, converted at the
// call site — plus the 24h head start itself.
//
// The sum is why this is pinned to its exact second rather than approximately.
// An off-by-one in any term is an off-by-one in the deadline, and three terms
// give three chances to get it wrong; asserting "refused a day in, allowed two
// days in" would pass with any of them mis-added.
func TestThePriorityWindowClosesOnWallClockNotOnBlocks(cur realm, t *testing.T) {
	alice := testutils.TestAddress("an9-alice")
	pro := testutils.TestAddress("an9-pro")
	c := testCourt(cur, "an9", alice, 50_000_000_000)
	c.coin.Mint(pro, 10_000_000_000)
	for _, a := range []address{pro, testutils.TestAddress("an9-q2"), testutils.TestAddress("an9-q3")} {
		for i := 0; i < priorityNetRecord; i++ {
			creditUpheld(c, a)
		}
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "an9", "Priority on the clock")
	matureOI(cur, "an9", id, alice, 200_000_000)

	cs := mustClaim(c, id)
	if cs.openedAtTime == 0 {
		t.Fatal("fixture: no open stamp, so this would test the height fallback instead")
	}
	// The block arithmetic must still read "inside the window" throughout, or the
	// wall clock is not what ends it and this test proves nothing.
	blockEnd := cs.openedAt + c.params.stakeOpenDelayBlocks + answerWindow + priorityWindowBlocks
	if heightNow() >= blockEnd {
		t.Fatal("fixture: already past the window in blocks, nothing is being tested")
	}

	deadline := cs.openedAtTime +
		blocksToSecs(c.params.stakeOpenDelayBlocks+answerWindow) + priorityWindowSecs
	bumpTo := func(target int64) {
		d := target - nowTime()
		if d < 0 {
			t.Fatalf("fixture: %d is already behind us (now %d)", target, nowTime())
		}
		ctx := testing.GetContext()
		ctx.Time = ctx.Time.Add(time.Duration(d) * time.Second)
		testing.SetContext(ctx)
	}

	// One second short: unqualified alice is still held off.
	bumpTo(deadline - 1)
	frozenH := heightNow()
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "priority window is open", func() {
		PostAnswer(cross(cur), "an9", id, sideYES)
	})

	// The second itself: the head start is over and the slot is first-come, with
	// no block mined between the two assertions.
	bumpTo(deadline)
	uassert.Equal(t, frozenH, heightNow())
	uassert.True(t, heightNow() < blockEnd) // and blocks still say "inside"
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "an9", id, sideYES)
	if AnswerVerdict("an9", id) != sideYES {
		t.Fatal("past the window on the wall clock the answer slot is first-come")
	}

	// ---- AND A PRE-STAMP CLAIM STILL READS HEIGHT, TO ITS EXACT BLOCK ----
	testing.SetRealm(testing.NewUserRealm(alice))
	id2 := OpenClaim(cross(cur), "an9", "A claim from before the stamps")
	matureOI(cur, "an9", id2, alice, 200_000_000)
	cs2 := mustClaim(c, id2)
	cs2.openedAtTime = 0 // the pre-upgrade shape: a height, no stamp
	target := cs2.openedAt + c.params.stakeOpenDelayBlocks + answerWindow + priorityWindowBlocks
	if d := target - 1 - heightNow(); d > 0 {
		testing.SkipHeights(d)
	}
	uassert.Equal(t, target-1, heightNow())
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "priority window is open", func() {
		PostAnswer(cross(cur), "an9", id2, sideYES)
	})
	testing.SkipHeights(1)
	uassert.Equal(t, target, heightNow())
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "an9", id2, sideYES)
	if AnswerVerdict("an9", id2) != sideYES {
		t.Fatal("a pre-stamp claim's window must still end on its exact block")
	}
}
// TestQualityEpochPinnedAtAnswer went with the quality lane: there is no quality epoch to pin

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
	// DERIVED, not "101 CC". This test's own intent is "just above minAnswerX",
	// and v0.27 made that a fraction of the court's own supply — 10 bps, so
	// 1,000 CC on this 1,000,000 CC court, not 100. The literal was written
	// against the flat constant and would now drain BELOW the liveness gate the
	// comment above correctly says stops the attacker going further.
	keep := effMinAnswerX(c) * 2
	Unstake(cross(cur), "f9d", id, sideYES, 100_000_000_000-keep)
	matureOI(cur, "f9d", id, alice, 1_000_000)

	cs := mustClaim(c, id)
	trailing, mature := cs.oi.Average(heightNow(), answerWindow)
	if !mature {
		t.Fatal("setup: the trailing ring must be mature")
	}
	life := lifeAvgStake(cs, heightNow())
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "f9d", id, sideYES)

	// The lifetime arm must win, and by a wide margin: this is the drain factor.
	if cs.xBarFrozen != life {
		t.Fatalf("the lifetime arm must set X̄ after a drain: xBar=%d life=%d trailing=%d",
			cs.xBarFrozen, life, trailing)
	}
	// "Neutralised, not merely dented" — but the achievable factor is now BOUNDED
	// BY THE FLOOR, which is worth recording rather than papering over. The drain
	// cannot go below effMinAnswerX, so the best ratio anyone can construct is
	// life/floor: here 100,000 CC of lifetime against a 1,000 CC floor, i.e. 100x
	// at the theoretical limit. The original >100x was calibrated against a flat
	// 100 CC floor and is unsatisfiable by construction once the floor is 10 bps
	// of a 1,000,000 CC court. 40x still separates "neutralised" from "dented" by
	// a wide margin, and the equality above (xBar == life) is the real claim: the
	// lifetime arm ignores the drain entirely rather than being reduced by it.
	if cs.xBarFrozen <= trailing*40 {
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
	if again := lifeAvgStake(cs, heightNow()); again != life {
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
	trailing, mature := cs.oi.Average(heightNow(), answerWindow)
	if !mature {
		t.Fatal("setup: the trailing ring must be mature")
	}
	life := lifeAvgStake(cs, heightNow())
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

// The court's answer-bond cap, found SURVIVING: removing the clamp entirely failed no
// test. TestBondCollateralizesSlashUnderCourtCap covers the case where the
// collateralization FLOOR overrides a tiny cap — it asserts `bond >= bondFloorFor` — so
// an uncapped bond (50%·X̄, comfortably above the floor) satisfies it too. The half
// nothing covered is the cap actually BINDING, which is the knob's whole purpose.
//
// That ordering is the invariant answer.gno spells out: the floor is applied AFTER the
// cap deliberately, because an uncollateralized slash is worse than an over-large bond
// and "the cap must not re-open the hole". Both halves are needed to pin it: the cap
// binds when the floor is below it, and the floor wins when it is not.
func TestAnswerBondCapBindsWhenTheFloorIsBelowIt(cur realm, t *testing.T) {
	alice := testutils.TestAddress("acap-alice")
	c := testCourt(cur, "acap", alice, 500_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "acap", "the cap binds")
	// 350 CC per stake, giving a trailing X̄ of 700 CC. Calibrated against a
	// WINDOW, not picked: the two-lane answer floor (v0.27) demands X̄ >= 0.10% of
	// this court's 500k supply = 500 CC, while the cap below only BINDS while the
	// slash floor 4.5%·X̄ stays under it, i.e. X̄ < ~1111 CC. 200 CC per stake gave
	// X̄ = 400 and fell through the bottom of that window once the supply arm
	// replaced the dust arm at the first epoch seal.
	matureOI(cur, "acap", id, alice, 350_000_000)

	// A cap ABOVE the flat slash floor (4.5%·X̄) and BELOW the uncapped bond, so the
	// cap is the binding constraint and the floor is not.
	//
	// RE-SCALED with the bond base 5000 -> 600 bps. The window was (4.5%, 50%)·X̄ —
	// 11.1x wide, so 50_000_000 sat comfortably inside it. It is now (4.5%, 6%)·X̄ =
	// (31.5, 42) CC at this fixture's X̄ of 700 CC, only 1.33x wide. **That narrowness
	// is the thing to know before touching this fixture's stake sizes:** a tweak to
	// matureOI's amount that moves X̄ by more than a third silently pushes the cap out
	// of the window, and the guard below is what will tell you.
	c.params.answerBondCapCC = 36_000_000
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "acap", id, sideYES)

	cs := mustClaim(c, id)
	uncapped := cs.xBarFrozen * answerBondBps / 10000
	floor := bondFloorFor(cs)
	if !(floor < c.params.answerBondCapCC && c.params.answerBondCapCC < uncapped) {
		t.Fatalf("fixture must place the cap strictly between the floor and the "+
			"uncapped bond: floor=%d cap=%d uncapped=%d",
			floor, c.params.answerBondCapCC, uncapped)
	}
	if cs.answerBond != c.params.answerBondCapCC {
		t.Fatalf("the court cap must bind: bond=%d cap=%d (uncapped would be %d)",
			cs.answerBond, c.params.answerBondCapCC, uncapped)
	}
}

// THE FLOOR IS KEYED TO BOTH SIDES, AND THIS IS THE ONLY FIXTURE THAT CAN SEE IT.
//
// The snipe this prices leaves no on-chain trace: the sniper's own claim mints
// almost nothing, so there is no draw to measure and nothing for the draw cap to
// cut. What a wrong keying destroys is the VICTIM'S COUNTERFACTUAL — the draw the
// claim would have paid had it been answered honestly — and a counterfactual
// cannot be asserted. The bond is the only observable proxy, which is why this
// fixture asserts a bond and not a payout.
//
// Concretely it is what stops the bond base dropping to 6% while the floor still
// keys on the answered side. In that half-landed state a dust answer against a
// large aged pool posts the flat base and annihilates the pool's whole draw:
// destruction leverage 3.44 at MID, 5.14 at HIGH, against 0.669/1.000 when keyed
// to both sides. The whole suite is green in that state — measured, byte-identical
// to the complete one — so without this fixture the two halves can be split and
// nothing objects.
func TestAnswerBondFloorIsKeyedToBothSides(cur realm, t *testing.T) {
	alice := testutils.TestAddress("bk-alice")
	bob := testutils.TestAddress("bk-bob")
	c := testCourt(cur, "bk", alice, 50_000_000_000)
	c.coin.Mint(bob, 20_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "bk", "The floor must price the pool it could destroy")
	// The aged, well-funded pool goes on NO and accrues first; alice then declares
	// YES with dust behind it. Order matters — conviction is capital x TIME, so a
	// pool staked after the clock moves carries none of it.
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "bk", id, sideNO, 4_000_000_000)
	// AGE IT. The floor only outgrows the 6% base once k x the pool's conviction
	// exceeds it, i.e. once mg/X̄ > answerBondBps/k — and conviction is capital x
	// TIME, so the wait is set by k. At k=1.6 the crossover was 3.75% and this
	// court's cold rate of 63.75 bps/week reached it in ~6 weeks; at k=1.07 it is
	// 5.6% and takes ~8.8, so eight weeks stopped being margin and became a
	// failure. ELEVEN, not fourteen: the claim dies unanswered at twelve, so
	// lowering k narrowed the window this fixture can sit in from [6,12] weeks to
	// [8.8,12]. Fourteen was tried and panicked on the dead-claim timeout, which
	// is the tighter constraint announcing itself.
	// Measured without any wait: oppFloor 180_090_000 against a base of
	// 240_120_000, and the precondition below correctly refused to pretend the
	// keying was observable — which is exactly how the k change announced itself.
	testing.SkipHeights(epochBlocks * 24 * 7 * 11)
	matureOI(cur, "bk", id, alice, 1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "bk", id, sideYES)

	cs := mustClaim(c, id)
	base := cs.xBarFrozen * answerBondBps / 10000
	ownHi, ownLo := cs.sideConv(int(cs.answer))
	oppHi, oppLo := cs.sideConv(oppositeSide(int(cs.answer)))
	ownFloor := bondFloorAt(cs.xBarFrozen, ownHi, ownLo)
	oppFloor := bondFloorAt(cs.xBarFrozen, oppHi, oppLo)

	// PRECONDITIONS. Both are required or the assertion is vacuous: the two keyings
	// must actually disagree, and the opposing arm must actually be the binding one.
	// At the old 5000 bps base this fixture FAILS here rather than passing quietly —
	// the base dwarfs both arms, so no keying is observable and the fixture says so.
	if oppFloor <= base {
		t.Fatalf("precondition: the opposing-side floor must BIND for the keying to be "+
			"observable at all; oppFloor=%d base=%d. At a high bond base neither keying "+
			"shows through — this fixture only has teeth once the base is small.",
			oppFloor, base)
	}
	if ownFloor >= oppFloor {
		t.Fatalf("precondition: this fixture needs the answered side to be the SMALLER "+
			"pool, or both keyings agree; ownFloor=%d oppFloor=%d", ownFloor, oppFloor)
	}

	// THE ASSERTION. Keyed to both sides the sniper pays for the pool they could
	// destroy; keyed to the answered side they pay the flat base.
	if cs.answerBond0 != oppFloor {
		t.Fatalf("the bond must be keyed to the LARGER side's destroyable draw: "+
			"bond0=%d, opposing floor=%d, answered-side floor=%d, base=%d.\n"+
			"If bond0 equals the base or the answered-side floor, the floor is still "+
			"keyed to cs.sideConv(verdict) alone while the bond base has already been "+
			"cut — the half-landed state, in which a dust answer destroys this pool's "+
			"whole draw for the price of the base.",
			cs.answerBond0, oppFloor, ownFloor, base)
	}
}
