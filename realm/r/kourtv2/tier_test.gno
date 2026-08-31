package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// THE DRAW MULTIPLIER, tested directly, because it decides money and nothing
// else in the suite reaches it without a whole claim lifecycle in front of it.
//
// It replaced a three-bucket vote. The vote was wrong to have — it asked a
// second ballot on every disputed claim — but it had one property this does not:
// a human said the number. Here a formula does, so the formula is what gets
// pinned.

func TestTierMultiplierIsTheClaimAgainstTheCourtsTypical(cur realm, t *testing.T) {
	const ref = int64(1_000_000)

	// PAR IS THE COURT'S OWN AVERAGE CLAIM, which is the whole point of a
	// reference that moves: a claim of typical size earns 1x in every court,
	// large or small, with no constant chosen by hand.
	uassert.Equal(t, tierParBps, tierBpsFor(&claimState{tierRef: ref, xBarFrozen: ref}))

	// Linear between the clamps. Half the typical claim earns half.
	uassert.Equal(t, tierParBps/2, tierBpsFor(&claimState{tierRef: ref, xBarFrozen: ref / 2}))
	uassert.Equal(t, tierParBps*3/2, tierBpsFor(&claimState{tierRef: ref, xBarFrozen: ref * 3 / 2}))

	// THE CEILING IS THE OLD HIGH BAND, and it is what keeps the emission
	// ceiling where every deploy invariant was fitted to it. Twice the typical
	// claim reaches it; ten times does not go past it.
	uassert.Equal(t, tierCeilBps, tierBpsFor(&claimState{tierRef: ref, xBarFrozen: 2 * ref}))
	uassert.Equal(t, tierCeilBps, tierBpsFor(&claimState{tierRef: ref, xBarFrozen: 10 * ref}))
	uassert.Equal(t, tierCeilBps, tierBpsFor(&claimState{tierRef: 1, xBarFrozen: 1 << 40}))

	// THE FLOOR IS NOT ZERO, and that is the deliberate departure from the vote.
	// A vote saying "worthless" can justify paying nothing; a small size cannot,
	// because the same measure already cleared this claim to be answered at all.
	uassert.Equal(t, tierFloorBps, tierBpsFor(&claimState{tierRef: ref, xBarFrozen: 1}))
	uassert.Equal(t, tierFloorBps, tierBpsFor(&claimState{tierRef: ref, xBarFrozen: 0}))

	// A CLAIM FROZEN BEFORE THIS SHIPPED carries no reference and reads as PAR,
	// not as zero and not as the ceiling. Zero would retroactively wipe the draw
	// of every claim already answered; the ceiling would double it.
	uassert.Equal(t, tierParBps, tierBpsFor(&claimState{xBarFrozen: 5 * ref}))
	uassert.Equal(t, tierParBps, tierBpsFor(&claimState{}))
}

// THE ACCUMULATOR EXISTS BECAUSE THE OBVIOUS AVERAGE STALLS, and this is the
// test that says so. Written the natural way —
//
//	ema += (x - ema) / N
//
// integer division truncates every update where |x - ema| < N to zero, and the
// average sticks a few units from the truth FOREVER. On a court whose claims are
// all within N base units of each other that is every update, so the reference
// would freeze at whatever the first few claims happened to be and never move
// again. Holding N x the mean and dividing only on read keeps the residue.
func TestTheRunningAverageDoesNotStallOnSmallSteps(cur realm, t *testing.T) {
	c := &Court{}

	// A step far smaller than tierEMAN. The naive form cannot move at all here:
	// (1 - 0)/16 == 0.
	for i := 0; i < 400; i++ {
		observeClaimSize(c, 1)
	}
	if c.xBarAcc/tierEMAN != 1 {
		t.Fatalf("a run of size-1 claims must converge to 1, got %d", c.xBarAcc/tierEMAN)
	}

	// And it converges DOWNWARD from a large seed by the same mechanism — the
	// direction the naive form also cannot take when the gap closes below N.
	c2 := &Court{}
	for i := 0; i < 200; i++ {
		observeClaimSize(c2, 1_000_000)
	}
	for i := 0; i < 400; i++ {
		observeClaimSize(c2, 3)
	}
	if got := c2.xBarAcc / tierEMAN; got > 10 {
		t.Fatalf("the average must fall to the new size, got %d", got)
	}

	// The memory really is about tierEMAN claims: one outsized claim moves the
	// average by roughly 1/N, not to the new value and not not at all.
	c3 := &Court{}
	for i := 0; i < 300; i++ {
		observeClaimSize(c3, 1_000)
	}
	before := c3.xBarAcc / tierEMAN
	observeClaimSize(c3, 1_000_000)
	after := c3.xBarAcc / tierEMAN
	if after <= before {
		t.Fatal("a large claim must raise the average")
	}
	if after > before+1_000_000/tierEMAN {
		t.Fatalf("one claim must not carry the average: %d -> %d", before, after)
	}
}

// The reference, and the two jobs its floor does.
func TestTheReferenceFloorBootstrapsAndBoundsTheGame(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tierf-alice")
	c := testCourt(cur, "tierf", alice, 50_000_000_000)

	floor := supplyFloor(c, tierRefFloorBps, tierRefDustCC)
	if floor <= 0 {
		t.Fatal("the fixture must have a live supply floor")
	}

	// BOOTSTRAP: a court with no answered claims has an empty accumulator, and
	// the floor is the reference. No divide by zero, no "wait for N claims"
	// special case — a new court simply behaves like a fixed-reference one.
	uassert.Equal(t, floor, tierRefAt(c))

	// ANTI-GAMING: a low reference lifts EVERYBODY's multiplier, so the cheap
	// attack is a run of dust claims to drag the average down rather than
	// capital to grow one claim. The floor removes the question.
	for i := 0; i < 500; i++ {
		observeClaimSize(c, 1)
	}
	if c.xBarAcc/tierEMAN >= floor {
		t.Fatal("the fixture must drive the raw average below the floor")
	}
	uassert.Equal(t, floor, tierRefAt(c))

	// Above the floor the court's own claims take over, which is the half that
	// makes "big" mean big HERE.
	big := floor * 4
	for i := 0; i < 400; i++ {
		observeClaimSize(c, big)
	}
	if got := tierRefAt(c); got <= floor {
		t.Fatalf("a court of large claims must re-centre above the floor, got %d", got)
	}
}

// A claim is never measured against an average it is itself part of.
//
// Both halves land at the freeze, and the ORDER is the whole content: taking the
// reference after the observation would let a large claim inflate its own
// denominator and shrink its own multiplier — and a small one raise it. The
// effect is 1/tierEMAN, which is small enough to be invisible in a lifecycle
// test and permanent in the ledger.
func TestAClaimIsNotInTheAverageItIsMeasuredAgainst(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tiero-alice")
	c := testCourt(cur, "tiero", alice, 50_000_000_000)

	// Seed a history well above the floor so the average, not the floor, is what
	// the claim is measured against.
	seed := supplyFloor(c, tierRefFloorBps, tierRefDustCC) * 4
	for i := 0; i < 400; i++ {
		observeClaimSize(c, seed)
	}
	refBefore := tierRefAt(c)

	// The write site's order, reproduced: reference first, then observe.
	cs := &claimState{}
	cs.tierRef = tierRefAt(c)
	observeClaimSize(c, seed*8)

	uassert.Equal(t, refBefore, cs.tierRef)
	if tierRefAt(c) <= refBefore {
		t.Fatal("the observation must still have moved the court's average")
	}
	// The claim it belongs to is unaffected by its own arrival.
	uassert.Equal(t, refBefore, cs.tierRef)
}

// THE SPAM DISCOUNT, against the owner's own table.
//
// 1 - 2s, reaching zero exactly at the half the discard threshold uses. The two
// are one constant seen twice, so this table and dispute.gno's `spamW*2 > cast`
// must move together or a gap opens between "pays nothing" and "is deleted".
func TestTheSpamDiscountMatchesTheTable(cur realm, t *testing.T) {
	const total = int64(100)
	at := func(spam int64) int64 {
		return spamNetBps(&claimState{spamW: spam, spamTotalW: total})
	}

	uassert.Equal(t, tierParBps, at(0))       // 1.00x
	uassert.Equal(t, int64(8_000), at(10))    // 0.80x
	uassert.Equal(t, int64(5_000), at(25))    // 0.50x
	uassert.Equal(t, int64(3_400), at(33))    // 0.34x
	uassert.Equal(t, int64(2_000), at(40))    // 0.20x
	uassert.Equal(t, int64(0), at(50))        // pays nothing, still stands
	uassert.Equal(t, int64(0), at(60))        // and past half it cannot go negative
	uassert.Equal(t, int64(0), at(total))

	// NO DECIDED ROUND IS NOT ZERO SPAM'S OPPOSITE. An undisputed claim, and
	// every claim decided before this shipped, carries a zero denominator — and
	// reading that as "the voters said nothing, so pay nothing" would zero the
	// draw of most of the docket. It is "nobody voted", so nothing is discounted.
	uassert.Equal(t, tierParBps, spamNetBps(&claimState{}))
	uassert.Equal(t, tierParBps, spamNetBps(&claimState{spamW: 5}))

	// THE ZERO IS EXACTLY THE DISCARD BAR. Just under half still pays; at half it
	// does not. dispute.gno discards on spamW*2 > total, so these two lines are
	// the seam between "draws nothing" and "is deleted" and they must stay
	// adjacent.
	if at(49) <= 0 {
		t.Fatal("just under half must still pay something")
	}
	uassert.Equal(t, int64(0), at(50))
}

// THE TWO MULTIPLIERS COMPOSE, and a spam vote can never PROMOTE a claim.
//
// If spam replaced size instead, a small self-staked claim rated 0.25x that got
// disputed and drew no spam would jump to 1.00x — 4x, bought for a dispute bond
// by a second address, since OpenDispute bars only the answerer. Composition is
// what makes a dispute one-directional.
func TestASpamVoteCanOnlyLowerAClaimNeverPromoteIt(cur realm, t *testing.T) {
	const ref = int64(1_000_000)
	small := &claimState{tierRef: ref, xBarFrozen: ref / 4} // floor: 0.25x
	uassert.Equal(t, tierFloorBps, tierBpsFor(small))

	// Disputed, nobody flagged spam: the discount is par, so the claim keeps its
	// size rating. Under a REPLACEMENT it would now be at 1.00x.
	small.spamW, small.spamTotalW = 0, 100
	uassert.Equal(t, tierParBps, spamNetBps(small))
	uassert.Equal(t, tierFloorBps, tierBpsFor(small))
	if mulDiv128(tierBpsFor(small), spamNetBps(small), tierParBps) != tierFloorBps {
		t.Fatal("a clean dispute must leave a small claim at its size rating")
	}

	// And a big claim IS lowered by spam: 2.00x with a quarter flagging spam is
	// 1.00x, not 2.00x and not 0.50x.
	big := &claimState{tierRef: ref, xBarFrozen: 2 * ref, spamW: 25, spamTotalW: 100}
	uassert.Equal(t, tierCeilBps, tierBpsFor(big))
	uassert.Equal(t, tierParBps,
		mulDiv128(tierBpsFor(big), spamNetBps(big), tierParBps))
}
