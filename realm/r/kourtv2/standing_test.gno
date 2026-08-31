package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// standingFixture opens a claim and returns its state, so the credit rules can
// be exercised against a REAL claimState rather than a hand-built one. The
// difference matters: every gate these tests pin reads a field the lifecycle
// owns (seeded, tier, credEligible, answerBond0), and a struct literal would let
// a renamed or re-purposed field pass silently.
func standingFixture(cur realm, slug string, who address) (*Court, *claimState, uint64) {
	c := testCourt(cur, slug, who, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	id := OpenClaim(cross(cur), slug, "Does standing credit correctly?")
	return c, mustClaim(c, id), id
}

// ------------------------------------------------------------- the gates --

// TestAuthorStandingIsHighOnlyAndNeverSeeded is gone with creditAuthorHigh.
// It paid the author's RECORD only at tier HIGH, on the reasoning that MID is
// what an unlooked-at claim gets by default and crediting that is the
// author-mill's habitat. With the tier derived from stake size there is no
// "the court judged this exceptional" left to gate on, and gating on SIZE would
// pay the record for volume — which is the same faucet, reached differently. So
// the row is dropped rather than re-keyed. The money lane is untouched:
// AuthorBonus was never tier-gated.

func TestDisputeStandingNeedsCredEligibleOnAnUphold(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sg3-alice")
	bob := testutils.TestAddress("sg3-bob")
	c, cs, _ := standingFixture(cur, "sg3", alice)
	cs.answerer, cs.disputer = alice, bob
	cs.answerBond0 = 800_000_000
	cs.answer, cs.provisional = int8(sideYES), int8(sideYES)
	cs.decidedRounds = 1

	// An uphold against NO real opposition earns nothing. Without this gate
	// roughly a fifth of a dispute bond buys standing on any trivially-true
	// claim — the M2-1 finding, one ledger over.
	cs.credEligible = false
	creditDisputeResolved(c, cs)
	uassert.Equal(t, int64(0), Standing("sg3", alice))

	cs.credEligible = true
	creditDisputeResolved(c, cs)
	want := cs.answerBond0 * standingDisputeBps / 10000
	uassert.Equal(t, want, Standing("sg3", alice))
	// The disputer lost; nothing accrues to them.
	uassert.Equal(t, int64(0), Standing("sg3", bob))
}

func TestOverturnCreditsTheDisputerWithoutACredEligibleGate(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sg4-alice")
	bob := testutils.TestAddress("sg4-bob")
	c, cs, _ := standingFixture(cur, "sg4", alice)
	cs.answerer, cs.disputer = alice, bob
	cs.answerBond0 = 800_000_000
	cs.answer, cs.provisional = int8(sideYES), int8(sideNO)
	cs.decidedRounds = 1
	cs.credEligible = false // deliberately: an overturn needs no such gate
	cs.overturnBy, cs.overturnBond = bob, 16_800_000

	// An overturn had to clear quorum AND the verdict threshold to happen at
	// all, so it is weight-gated by construction. Pinning credEligible=false
	// here is the point of the test: if someone later "tidies" the two branches
	// into one predicate, every honest overturn stops earning.
	// EACH SIDE ON ITS OWN BOND: the disputer's is min(20%·X̄, 40%·answerBond0),
	// so scaling them on answerBond0 would pay 2.5x the capital they risked.
	creditDisputeResolved(c, cs)
	want := cs.overturnBond * standingDisputeBps / 10000
	uassert.Equal(t, want, Standing("sg4", bob))
	uassert.Equal(t, int64(0), Standing("sg4", alice))
	if want >= cs.answerBond0*standingDisputeBps/10000 {
		t.Fatalf("the disputer must be paid on their OWN bond, not the answerer's")
	}

	// THE MEASURED THEFT: a stranger opens a later round, lets it fail quorum,
	// and becomes cs.disputer. A failed reopen does not reset `provisional`, so
	// the overturn still stands — and reading cs.disputer here would pay the
	// stranger the whole credit and deny it to bob, who actually won.
	mallory := testutils.TestAddress("sg4-mallory")
	cs.disputer = mallory // overturnBy is NOT re-stamped: only a burning round stamps
	before := Standing("sg4", bob)
	creditDisputeResolved(c, cs)
	uassert.Equal(t, int64(0), Standing("sg4", mallory))
	uassert.Equal(t, before+want, Standing("sg4", bob))
}
// TestFlagStandingScalesWithWhatTheSlashDestroyed went with the quality lane: the flag standing category is dormant and nothing credits it

// ------------------------------------------------- the splitting invariant --

func TestSplittingAPositionNeverIncreasesTotalStanding(cur realm, t *testing.T) {
	whole := testutils.TestAddress("sg6-whole")
	c, cs, _ := standingFixture(cur, "sg6", whole)
	halfA := testutils.TestAddress("sg6-halfa")
	halfB := testutils.TestAddress("sg6-halfb")

	// S9, the invariant the whole earning table is built around: n addresses
	// sharing one holder's capital must never out-earn that holder undivided.
	// Linear is the unique rule that achieves it — any clamp or per-claim cap is
	// concave and pays the split MORE, which is why none exists here.
	// Adjudicated, so the credit is unscaled — the invariant holds at either
	// rate (both sides scale together), and an unscaled one keeps the arithmetic
	// in the failure message readable.
	cs.tier, cs.decidedPID, cs.openBlocks = tierMidX, 7, 1_000
	pos := func(raw uint64) *stakePos { return &stakePos{rawLo: raw} }
	const conv = uint64(4_000_000_000)
	creditWinConviction(c, cs, whole, pos(conv))
	creditWinConviction(c, cs, halfA, pos(conv/2))
	creditWinConviction(c, cs, halfB, pos(conv/2))

	undivided := Standing("sg6", whole)
	split := Standing("sg6", halfA) + Standing("sg6", halfB)
	if split > undivided {
		t.Fatalf("splitting out-earned the whole: %d vs %d", split, undivided)
	}

	// And the same at an awkward magnitude, where floor division is where a
	// concavity would hide if one were ever reintroduced.
	odd := testutils.TestAddress("sg6-odd")
	p1 := testutils.TestAddress("sg6-p1")
	p2 := testutils.TestAddress("sg6-p2")
	p3 := testutils.TestAddress("sg6-p3")
	const oddConv = uint64(999_999_997)
	creditWinConviction(c, cs, odd, pos(oddConv))
	creditWinConviction(c, cs, p1, pos(oddConv/3))
	creditWinConviction(c, cs, p2, pos(oddConv/3))
	creditWinConviction(c, cs, p3, pos(oddConv-2*(oddConv/3)))
	three := Standing("sg6", p1) + Standing("sg6", p2) + Standing("sg6", p3)
	if three > Standing("sg6", odd) {
		t.Fatalf("a three-way split out-earned the whole: %d vs %d", three, Standing("sg6", odd))
	}
}

// ------------------------------------------------------------ arithmetic --

func TestStandingSaturatesRatherThanAbortingASettlement(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sg7-alice")
	c, _, _ := standingFixture(cur, "sg7", alice)

	// Every credit site sits inside Crystallize, ResolveFlag or ResolveDispute.
	// A checked add would panic there and strand a settlement, which is the
	// failure econ vet F4 named ("checked-abort on a shared path is a settlement
	// DoS — clamp instead"). Saturating is safe here only because standing is a
	// record: no coin, draw or vote is derived from it.
	const maxInt64 = int64(9223372036854775807)
	r := getStanding(c, alice)
	r.score = maxInt64 - 5
	r.from[standingCatConv] = maxInt64 - 5

	creditStanding(c, alice, 1_000_000, standingCatConv)
	uassert.Equal(t, maxInt64, Standing("sg7", alice))
}

func TestZeroAndUnknownCreditsAreNoOps(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sg8-alice")
	c, _, _ := standingFixture(cur, "sg8", alice)

	creditStanding(c, alice, 0, standingCatFlag)
	creditStanding(c, alice, -5, standingCatFlag)
	creditStanding(c, "", 100, standingCatFlag)
	uassert.Equal(t, int64(0), Standing("sg8", alice))

	// A miscategorised credit must leave the score and its subtotals SUMMING,
	// because the page rests on exactly that. Not a panic: this is a money path.
	creditStanding(c, alice, 100, standingCatN)
	uassert.Equal(t, int64(0), Standing("sg8", alice))
	uassert.Equal(t, "score:0;highwater:0;flag:0;dispute:0;author:0;conviction:0",
		StandingBreakdown("sg8", alice))
	// It must not even allocate a row for an address it credited nothing to.
	uassert.False(t, c.standings.Has(string(alice)))

	// AND IT MUST NOT LOWER A SATURATED SCORE. The earlier version added first
	// and undid the add with `score -= amount`; satAdd is not invertible, so at
	// the ceiling that subtraction ran against an add that never happened and
	// silently broke monotonicity (S8). Zero is invisible to this bug — the
	// ceiling is the only place it shows.
	const maxInt64 = int64(9223372036854775807)
	ceil := testutils.TestAddress("sg8-ceil")
	getStanding(c, ceil).score = maxInt64
	creditStanding(c, ceil, 1_000_000, standingCatN)
	uassert.Equal(t, maxInt64, Standing("sg8", ceil))
}

// ----------------------------------------------------------------- reads --

func TestBreakdownSumsAndAnUnknownAddressReadsZero(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sg9-alice")
	stranger := testutils.TestAddress("sg9-stranger")
	c, _, _ := standingFixture(cur, "sg9", alice)

	creditStanding(c, alice, 100, standingCatFlag)
	creditStanding(c, alice, 200, standingCatDispute)
	creditStanding(c, alice, 300, standingCatAuthor)
	creditStanding(c, alice, 400, standingCatConv)
	uassert.Equal(t, int64(1000), Standing("sg9", alice))
	uassert.Equal(t, "score:1000;highwater:1000;flag:100;dispute:200;author:300;conviction:400",
		StandingBreakdown("sg9", alice))

	// Never participating is a NORMAL state, not a missing record: every field
	// is present and zero, so no client has to tell "absent" from "nothing yet".
	uassert.Equal(t, int64(0), Standing("sg9", stranger))
	uassert.Equal(t, "score:0;highwater:0;flag:0;dispute:0;author:0;conviction:0",
		StandingBreakdown("sg9", stranger))
}

func TestReadingStandingAllocatesNothing(cur realm, t *testing.T) {
	stranger := testutils.TestAddress("sg10-stranger")
	alice := testutils.TestAddress("sg10-alice")
	c, _, _ := standingFixture(cur, "sg10", alice)

	// The getStanding/lookupStanding split is what keeps the read path pure. A
	// read that reached for the allocator would let the first caller change what
	// the second one sees, and a query carries no storage deposit — so it would
	// be unpaid state growth. check-read-purity.py enforces the call graph; this
	// pins the observable consequence.
	uassert.False(t, c.standings.Has(string(stranger)))
	_ = Standing("sg10", stranger)
	_ = StandingBreakdown("sg10", stranger)
	uassert.False(t, c.standings.Has(string(stranger)))
}

func TestStandingAndTheAnswerRecordAreSeparateLedgers(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sg11-alice")
	c, _, _ := standingFixture(cur, "sg11", alice)

	// The separation is load-bearing, not cosmetic: answerRecord gates who may
	// answer a claim during the priority window, so a moderator able to slash it
	// would shape the answer lane. Standing is slashable; the record is not.
	// Crediting one must never move the other.
	creditStanding(c, alice, 5_000, standingCatConv)
	uassert.Equal(t, int64(5_000), Standing("sg11", alice))
	uassert.Equal(t, 0, AnswerRecord("sg11", alice))

	creditUpheld(c, alice)
	uassert.Equal(t, 1, AnswerRecord("sg11", alice))
	uassert.Equal(t, int64(5_000), Standing("sg11", alice))
}

// ----------------------------------------------------------- end-to-end --

func TestAWinningStakerEarnsStandingThroughARealLifecycle(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sg12-alice")
	bob := testutils.TestAddress("sg12-bob")
	dave := testutils.TestAddress("sg12-dave")
	c := testCourt(cur, "sg12", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "sg12", "Does the hook actually fire?")
	matureOI(cur, "sg12", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "sg12", id, sideNO, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "sg12", id, sideYES)

	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "sg12", id)
	testing.SkipHeights(100_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "sg12", id)

	// Nothing is credited until the position is actually drawn. The hook lives
	// at the draw so that crediting and paying are the same event — not because
	// they share a quantity: since the re-basing the payout scales on convCC and
	// the credit on time-averaged stake, which are deliberately different
	// numbers. An earlier version of this comment claimed they could never
	// disagree, which was true of the code it was written against and is not
	// true of this one.
	uassert.Equal(t, int64(0), Standing("sg12", alice))

	testing.SetRealm(testing.NewUserRealm(alice))
	WithdrawBonus(cross(cur), "sg12", id, sideYES)

	// AN UNDISPUTED WINNER EARNS THE HALF RATE, and this is the whole lifecycle
	// proving the common path pays. Nobody disputed and nobody flagged, so no
	// quality tally concluded and slotConsumed is false — the claim is rated on
	// the default mid, at half. What prices the mill on this path is the flag
	// lane, not this gate.
	got := Standing("sg12", alice)
	if got <= 0 {
		t.Fatalf("an undisputed winner earns the half rate, not nothing: %d", got)
	}

	// The losing staker earns nothing either, for the plainer reason.
	uassert.Equal(t, int64(0), Standing("sg12", bob))
	uassert.Equal(t, int64(0), Standing("sg12", dave))
}

func TestConvictionStandingIsRatedByWhatTheCourtDecided(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sg13-alice")
	c, cs, _ := standingFixture(cur, "sg13", alice)
	cs.openBlocks = 1_000
	const raw = uint64(4_000_000_000)
	p := &stakePos{rawLo: raw}
	avg := int64(raw) / cs.openBlocks
	full := avg * standingConvictionBps / 10000
	half := avg * standingConvictionBps * standingUnadjudicatedBps / 10000 / 10000

	// AN UNDISPUTED CLAIM EARNS HALF. Not nothing: whether anyone disputed you is
	// partly noise — a griefer can open one — so paying only the adjudicated case
	// would punish a correct staker for not having been attacked, on the path
	// most claims take by design.
	// THE FIELD MOVED, THE RULE DID NOT. This drove cs.slotConsumed, which meant
	// "a quality tally reached a conclusion" and is going away with that lane.
	// The rate now turns on `adjudicated(cs)` — a dispute round that reached a
	// verdict — so the fixture sets decidedPID. Every assertion below is the one
	// it always was.
	cs.tier, cs.decidedPID = tierMidX, 0
	creditWinConviction(c, cs, alice, p)
	uassert.Equal(t, half, Standing("sg13", alice))

	// THE TIER ARM IS GONE WITH THE TIER. It refused a claim the court had
	// adjudicated LOW, on the reasoning that a zero draw should carry a zero
	// record. With the multiplier derived from size there is no "the court
	// judged this worthless" left to refuse on — a small claim draws less, not
	// nothing, so the record follows it down rather than off. What still varies
	// is the adjudicated rate, which the two arms below pin.

	// AN ADJUDICATED MID EARNS FULL — same tier value as the first case, double
	// the credit, which is the whole point of reading the adjudication and not
	// the tier.
	cs.tier, cs.decidedPID = tierMidX, 7
	creditWinConviction(c, cs, alice, p)
	uassert.Equal(t, half+full, Standing("sg13", alice))

	// provClose needs no arm of its own, and the arm it once had was wrong:
	// crystallize says provClose DRAWS, so refusing it withheld a credit on a
	// path that pays MID emission. It is rated on its tier and its adjudication
	// like anything else.
	cs.provClose = true
	creditWinConviction(c, cs, alice, p)
	uassert.Equal(t, half+full*2, Standing("sg13", alice))

	// And the two rates really are 2:1, stated as its own assertion so the
	// owner's ruling is pinned by a number rather than by two additions.
	uassert.Equal(t, full, half*2)

	// THE PREDICATE, directly. Everything above reaches it through a credit, so
	// a re-key that got the sense backwards would show up as four wrong numbers
	// rather than as one wrong answer.
	uassert.False(t, adjudicated(&claimState{}))
	uassert.True(t, adjudicated(&claimState{decidedPID: 1}))
	// slotConsumed no longer has any say — asserted while the field still
	// exists, because after it is deleted this can only be asserted by absence.
	uassert.False(t, adjudicated(&claimState{slotConsumed: true}))
}

// TestTheFlagHookFiresAtSettlementAndPaysTheOriginationFlagger went with the quality lane: there is no flagger to pay

func TestTheDisputeHookFiresAtFinalizeAndPaysTheOverturner(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sh2-alice")
	bob := testutils.TestAddress("sh2-bob")
	carol := testutils.TestAddress("sh2-carol")
	c := testCourt(cur, "sh2", alice, 50_000_000_000)
	c.coin.Mint(bob, 20_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "sh2", "Does the dispute hook fire?")
	matureOI(cur, "sh2", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "sh2", id, sideYES)

	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "sh2", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "sh2", id, "yes") // overturn, on real weight
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "sh2", id)

	cs := mustClaim(c, id)
	if cs.provisional == cs.answer {
		t.Fatal("setup: this round must have overturned")
	}
	// Stamped at the round that won, not read back from cs.disputer at Finalize.
	uassert.Equal(t, bob, cs.overturnBy)
	uassert.Equal(t, int64(0), Standing("sh2", bob)) // nothing until Finalize

	testing.SkipHeights(EscrowUntil("sh2", id) - heightNow())
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "sh2", id)

	want := cs.overturnBond * standingDisputeBps / 10000
	uassert.Equal(t, want, Standing("sh2", bob))
	if want <= 0 {
		t.Fatalf("an overturner must earn on their own bond: %d", want)
	}
	// Their OWN bond, not the answerer's — the two differ by 2.5x, because the
	// dispute bond's 40%-of-answer-bond arm always binds.
	if want >= cs.answerBond0*standingDisputeBps/10000 {
		t.Fatal("the overturner must be paid on their own bond, not the answerer's")
	}
	// The answerer was adjudicated wrong and earns nothing.
	uassert.Equal(t, int64(0), Standing("sh2", alice))
}

// TestTheAuthorHookFiresAtCrystallizeAndOnlyAtHigh went with creditAuthorHigh.
// It pinned that the author's STANDING credit fires from Crystallize (not from
// the AuthorBonus pull, so it does not depend on the author bothering to draw)
// and only at tier HIGH. With the multiplier derived from stake size there is no
// HIGH to gate on, and gating the record on size would pay standing for volume —
// the author-mill faucet the gate existed to close. The money lane is untouched:
// AuthorBonus was never tier-gated and still pays cs.drawAuthor.

func TestHighWaterTracksTheMaxAndSurvivesASlash(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sg14-alice")
	c, _, _ := standingFixture(cur, "sg14", alice)

	creditStanding(c, alice, 1_000, standingCatFlag)
	r := lookupStanding(c, alice)
	uassert.Equal(t, int64(1_000), r.score)
	uassert.Equal(t, int64(1_000), r.highWater)

	// Stand in for the slash the moderation lane will land later: score falls,
	// the mark does not. This is the whole point of the field — a successor set
	// with no appeals lane to fall back on needs to know what to put back, and
	// the only honest answer is the largest score this address ever earned.
	r.score = 250
	uassert.Equal(t, int64(1_000), r.highWater)

	// A later credit CLIMBS BACK rather than resetting the ceiling to wherever
	// the score happened to land. Latest-not-max would let a slashed address
	// earn one unit and have its mark collapse to 251, quietly making the slash
	// permanent — the failure this assertion exists for.
	creditStanding(c, alice, 100, standingCatConv)
	uassert.Equal(t, int64(350), r.score)
	uassert.Equal(t, int64(1_000), r.highWater)

	// And once earnings pass the old mark, it moves again.
	creditStanding(c, alice, 5_000, standingCatConv)
	uassert.Equal(t, int64(5_350), r.score)
	uassert.Equal(t, int64(5_350), r.highWater)

	// The invariant, stated as an assertion rather than as a comment.
	if r.score > r.highWater {
		t.Fatalf("score must never exceed its high-water mark: %d > %d", r.score, r.highWater)
	}
}

// --------------------------------------------------- the defensive guards --
//
// These three survived a mutation pass, and the reason is worth stating: each
// guards a state the rest of the design forbids reaching, so no LIFECYCLE test
// can drive one. That makes them look like permanent gaps and they are not —
// every one is reachable by calling the function directly, which an in-package
// test may do. A guard nothing can kill is a guard nobody can trust.

func TestScaleBpsHandlesItsEdgesRatherThanPanicking(cur realm, t *testing.T) {
	// mulDiv128 PANICS on a negative first argument, and scaleBps sits on four
	// settlement paths, so the non-positive arms are the difference between a
	// zero credit and a stranded verdict.
	uassert.Equal(t, int64(0), scaleBps(-5, 1_000))
	uassert.Equal(t, int64(0), scaleBps(0, 1_000))
	uassert.Equal(t, int64(0), scaleBps(1_000, 0))
	uassert.Equal(t, int64(0), scaleBps(1_000, -1))

	// The bps clamp. mulDiv128's surviving panic arm is `q > MaxInt64`, and the
	// ONLY thing that makes it unreachable here is bps <= 10_000 bounding q by
	// base. The constants above are labelled CALIBRATION — expected to move — so
	// a retune to 12_000 must clamp rather than arm that panic. Asserted as an
	// equality against par, so it fails if the clamp is deleted rather than
	// merely if it is wrong.
	uassert.Equal(t, scaleBps(1_000_000, 10_000), scaleBps(1_000_000, 12_000))

	// And a full-range base at par must come back unchanged, not panic: this is
	// the input the 128-bit path exists for.
	const maxInt64 = int64(9223372036854775807)
	uassert.Equal(t, maxInt64, scaleBps(maxInt64, 10_000))
}

func TestLookupStandingToleratesACourtBuiltByHand(cur realm, t *testing.T) {
	// startCourt creates the tree eagerly, so this branch is dead on every real
	// court — which is exactly why nothing drove it. It exists for a fixture
	// that built a Court by hand, as render_test.gno does, and without it any
	// such fixture nil-panics the moment it reads standing.
	if r := lookupStanding(&Court{}, testutils.TestAddress("sg15-nobody")); r != nil {
		t.Fatal("a court with no standings tree must read as absent")
	}
}

// THE 7.9x TRAP, kept on the credit that survived it.
//
// Crystallize calls advancePools, which settles the SIDE integrals and never a
// per-position rawHi/rawLo — so a position whose last stake predates the freeze
// carries a stale integral, and a credit that reads it without accruing first
// under-counts every block between the two. Measured at ~7.9x when this was
// found.
//
// creditAuthorHigh accrued INTERNALLY and this test drove it directly.
// creditWinConviction does not: its caller accrues (crystallize.gno, "settle to
// the freeze pin") and then credits. So what is pinned here is the DEPENDENCE —
// that the credit reads the accrued integral and is worth ~stake x held once it
// has been accrued, and near nothing before. A caller that dropped its accrue
// would produce the second number, and this says what that number looks like.
func TestWinConvictionCreditReadsTheAccruedIntegral(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sg16-alice")
	c, cs, _ := standingFixture(cur, "sg16", alice)

	// The position holds 1,000 stake across 400 un-accrued blocks, so accrue
	// must add 400,000 to a base that starts at zero.
	const stake, held = int64(1_000), int64(400)
	cs.provisional, cs.openBlocks = int8(sideYES), 1_000
	cs.frozenAt = heightNow()
	cs.decidedPID = 7 // adjudicated, so the rate is not the halved one
	p := &stakePos{stake: stake, lastRawAt: cs.frozenAt - held}
	cs.stakers.Set(posKey(alice, sideYES), p)

	// BEFORE the accrue: rawLo is 0, so the credit is zero. This is the number a
	// caller that forgot to accrue would produce.
	creditWinConviction(c, cs, alice, p)
	uassert.Equal(t, int64(0), Standing("sg16", alice))

	// AFTER it: stake x held, which is what the draw is computed from.
	accrue(c, cs, p, sideYES)
	creditWinConviction(c, cs, alice, p)
	want := (stake * held / cs.openBlocks) * standingConvictionBps / 10000
	uassert.Equal(t, want, Standing("sg16", alice))
	if want <= 0 {
		t.Fatalf("the fixture must produce a live credit: %d", want)
	}
}

func TestTimeAvgStakeClampsWhereDiv128WouldPanic(cur realm, t *testing.T) {
	cs := &claimState{openBlocks: 1_000}

	// div128 PANICS on hi >= den, and this helper now runs inside Crystallize,
	// where that panic would strand the whole claim's draw rather than one
	// address's pull. Unreachable at real magnitudes; clamped anyway, because
	// every guard in this file was told the same thing about itself.
	uassert.Equal(t, int64(0), timeAvgStake(cs, uint64(cs.openBlocks), 0))
	uassert.Equal(t, int64(0), timeAvgStake(cs, ^uint64(0), ^uint64(0)))

	// openBlocks is floored at 1 by Crystallize, but a hand-built claimState is
	// not, and a zero denominator is div128's other panic arm.
	uassert.Equal(t, int64(0), timeAvgStake(&claimState{openBlocks: 0}, 0, 5_000))

	// And the ordinary case still divides.
	uassert.Equal(t, int64(5), timeAvgStake(cs, 0, 5_000))
}

// ------------------------------------------- the rates: default + override --

func TestCreditRatesInheritUntilACourtOverrides(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sg17-alice")
	c, cs, _ := standingFixture(cur, "sg17", alice)
	// decidedPID, not slotConsumed: the full conviction rate is what an
	// ADJUDICATED claim earns, and this test is about the rate TABLE rather than
	// about which field selects the rate.
	cs.tier, cs.decidedPID, cs.openBlocks = tierMidX, 7, 1_000
	p := &stakePos{rawLo: 4_000_000_000}
	avg := int64(4_000_000)

	// Inherited: the launch calibration, and the read says so.
	creditWinConviction(c, cs, alice, p)
	uassert.Equal(t, avg*standingConvictionBps/10000, Standing("sg17", alice))
	if !strings.Contains(CreditRates("sg17"), ";inherited:1") {
		t.Fatal("a court with no override reads as inheriting")
	}

	// Overridden: an active moderator halves what staking is worth here.
	testing.SetRealm(testing.NewUserRealm(alice)) // the creator is the 1-of-1 set
	SetCourtCreditRates(cross(cur), "sg17", 10_000, 10_000, 2_000, 500, 5_000)
	bob := testutils.TestAddress("sg17-bob")
	creditWinConviction(c, cs, bob, p)
	uassert.Equal(t, avg*500/10000, Standing("sg17", bob))
	if !strings.Contains(CreditRates("sg17"), ";inherited:0") {
		t.Fatal("an overridden court must not read as inheriting")
	}

	// Cleared: back to the default, and NIL is what "inherit" means — not all
	// zero, which for a five-tuple is a court that deliberately zeroed its board.
	testing.SetRealm(testing.NewUserRealm(alice))
	ClearCourtCreditRates(cross(cur), "sg17")
	carol := testutils.TestAddress("sg17-carol")
	creditWinConviction(c, cs, carol, p)
	uassert.Equal(t, avg*standingConvictionBps/10000, Standing("sg17", carol))
}

func TestTheRateOrderingCannotBeSetThroughAtAll(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sg18-alice")
	testCourt(cur, "sg18", alice, 10_000_000_000)

	// The bound is the ORDERING, not a range per number, and it is checked on
	// the whole tuple — which is why the setter takes one. Five independent
	// setters would leave a window between two calls where the ordering is
	// violated and credits are paid through it.
	bad := [][]int64{
		{1_000, 10_000, 2_000, 500, 5_000},  // policing below authorship (flag)
		{10_000, 1_000, 2_000, 500, 5_000},  // policing below authorship (dispute)
		{10_000, 10_000, 500, 1_000, 5_000}, // authorship at or below staking
		{10_000, 10_000, 1_000, 1_000, 5_000},
		{10_000, 10_000, 2_000, 500, 0},      // the unadjudicated rate must be real
		{10_000, 10_000, 2_000, 500, 10_000}, // ...and a real FRACTION
		{12_000, 10_000, 2_000, 500, 5_000},  // above the range scaleBps honours
		{10_000, 10_000, 2_000, -1, 5_000},
	}
	for _, r := range bad {
		testing.SetRealm(testing.NewUserRealm(alice))
		uassert.AbortsContains(t, cur, "kourtv2:", func() {
			SetCourtCreditRates(cross(cur), "sg18", r[0], r[1], r[2], r[3], r[4])
		})
	}
	// The shipped calibration is itself a legal setting — if it were not, the
	// bound would be refusing the thing it was written to describe.
	testing.SetRealm(testing.NewUserRealm(alice))
	SetCourtCreditRates(cross(cur), "sg18", standingFlagBps, standingDisputeBps,
		standingAuthorHighBps, standingConvictionBps, standingUnadjudicatedBps)
}

func TestOnlyTheRightAuthorityMovesTheCreditRates(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sg19-alice") // creator, so the 1-of-1 mod set
	stranger := testutils.TestAddress("sg19-stranger")
	testCourt(cur, "sg19", alice, 10_000_000_000)
	ok := []int64{10_000, 10_000, 2_000, 1_000, 5_000}

	// A COURT OVERRIDE takes an active moderator. Without this, anyone reprices
	// what work is worth in a court they have nothing to do with.
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "kourtv2:", func() {
		SetCourtCreditRates(cross(cur), "sg19", ok[0], ok[1], ok[2], ok[3], ok[4])
	})
	uassert.AbortsContains(t, cur, "kourtv2:", func() {
		ClearCourtCreditRates(cross(cur), "sg19")
	})

	// THE REALM DEFAULT takes the global DAO admin, which a court's own
	// moderator is not — a court moderator repricing every OTHER court is the
	// escalation this separation exists to prevent.
	before := CreditRates("sg19")
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "global DAO admin", func() {
		SetCreditRatesDefault(cross(cur), ok[0], ok[1], ok[2], ok[3], ok[4])
	})
	uassert.Equal(t, before, CreditRates("sg19"))

	// And the authorised paths work, so the refusals above are about authority
	// and not about the arguments.
	testing.SetRealm(testing.NewUserRealm(alice))
	SetCourtCreditRates(cross(cur), "sg19", ok[0], ok[1], ok[2], ok[3], ok[4])
	testing.SetRealm(testing.NewUserRealm(alice))
	ClearCourtCreditRates(cross(cur), "sg19")
}
