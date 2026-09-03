package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// THE QUOTE IS THE PAYMENT, and the only way to know that is to collect it.
//
// DrawQuote exists so the page can say what "Open the rewards" is worth before
// somebody presses it. A figure derived independently of the payment path is the
// defect this realm has now had three times on deadlines — a read that
// contradicts its own gate — so the assertion here is not "the quote looks
// sensible" but "the quote equals what Crystallize then paid", compared against
// DrawSlices after the fact.
//
// Not circular: DrawQuote is computed BEFORE the call, from the pre-crystallize
// state, and DrawSlices reports what the write path actually stored.
func TestTheDrawQuoteIsWhatCrystallizeThenPays(cur realm, t *testing.T) {
	alice := testutils.TestAddress("dqz-alice")
	bob := testutils.TestAddress("dqz-bob")
	c := testCourt(cur, "dqz", alice, 90_000_000_000)
	c.coin.Mint(bob, 40_000_000_000)
	id := settledClaim(cur, c, "dqz", alice, bob)

	qw, qa, qan := DrawQuote("dqz", id)
	if qw == 0 && qa == 0 && qan == 0 {
		t.Fatal("fixture: a settled, uncrystallized claim must quote a draw, or " +
			"this asserts nothing")
	}

	// A COURT THAT CAN ACTUALLY PAY. Without this the period budget is 0, the
	// payment is 0, and "payment <= quote" holds against any quote at all —
	// measured: halving DrawQuote survived that version of this test. One period
	// of emission gives the reservoir something to grant, and then the two
	// numbers can be compared for equality rather than for an inequality that
	// zero satisfies.
	testing.SkipHeights(periodBlocks)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "dqz", id)
	pw, pa, pan, _ := DrawSlices("dqz", id)
	if pw+pa+pan == 0 {
		t.Fatal("fixture: the court must be able to pay, or the comparison below " +
			"is satisfied by zero")
	}

	// THE QUOTE IS A CEILING THE PAYMENT NEVER EXCEEDS. The quote is what the
	// claim earned; the payment is that, clamped by the period budget and the
	// junior reservoir, both of which belong to the court and neither of which a
	// read may advance. So `payment <= quote` is the invariant, and a payment
	// ABOVE the quote would mean the shared chain had drifted — which is the
	// thing this test exists to catch.
	uassert.True(t, pw <= qw)
	uassert.True(t, pa <= qa)
	uassert.True(t, pan <= qan)
	// AND EQUAL when nothing clamped, which is this fixture: a quote that is
	// merely "not too high" is satisfied by any understatement, so the useful
	// assertion is that the reader was shown the figure they then received.
	uassert.Equal(t, pw, qw)
	uassert.Equal(t, pa, qa)
	uassert.Equal(t, pan, qan)
	// And the exclusions travel: an upheld answer pays its answerer, a seeded
	// claim pays no author. Whatever the clamps did, a slice the quote called
	// zero must not appear in the payment.
	if qa == 0 && pa != 0 {
		t.Fatalf("the payment invented an author slice the quote excluded: %d", pa)
	}
	if qan == 0 && pan != 0 {
		t.Fatalf("the payment invented an answerer slice the quote excluded: %d", pan)
	}

	// AND IT GOES QUIET once there is nothing left to quote: after crystallize
	// DrawSlices is the authority, and two answers to one question is what this
	// read exists to avoid.
	zw, za, zan := DrawQuote("dqz", id)
	if zw != 0 || za != 0 || zan != 0 {
		t.Fatalf("a crystallized claim must stop quoting: %d %d %d", zw, za, zan)
	}
	// A claim with no verdict has nothing to quote either.
	testing.SetRealm(testing.NewUserRealm(alice))
	fresh := OpenClaim(cross(cur), "dqz", "no verdict, no quote")
	if w, a, an := DrawQuote("dqz", fresh); w != 0 || a != 0 || an != 0 {
		t.Fatalf("an unanswered claim must quote nothing: %d %d %d", w, a, an)
	}
}

func TestCrystallizeMidHappyPathDrainsEscrow(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cz1-alice")
	bob := testutils.TestAddress("cz1-bob")
	dave := testutils.TestAddress("cz1-dave")
	c := testCourt(cur, "cz1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "cz1", "The draw happy path")
	matureOI(cur, "cz1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "cz1", id, sideNO, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "cz1", id, sideYES)

	testing.SetRealm(testing.NewUserRealm(dave))
	uassert.AbortsContains(t, cur, "no final verdict", func() {
		Crystallize(cross(cur), "cz1", id)
	})
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "cz1", id)
	// Participant week: a stranger waits, a participant lands it.
	testing.SetRealm(testing.NewUserRealm(dave))
	uassert.AbortsContains(t, cur, "participant-only", func() {
		Crystallize(cross(cur), "cz1", id)
	})
	// Cross the first weekly period boundary so the reservoir has accrued a
	// budget (it starts EMPTY — the first budget lands at the first roll),
	// while staying inside the participant week.
	testing.SkipHeights(100_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "cz1", id)
	uassert.AbortsContains(t, cur, "already crystallized", func() {
		Crystallize(cross(cur), "cz1", id)
	})

	w, a, ans, carrot := DrawSlices("cz1", id)
	if w <= 0 || a <= 0 || ans < 0 || carrot <= 0 {
		t.Fatalf("mid draw slices must be live: %d/%d/%d/%d", w, a, ans, carrot)
	}
	// The 80/8/5 shape (floor slack 1).
	if w/16 < a && a-w/10 > 1 {
		t.Fatalf("slice ordering broke: winners %d author %d", w, a)
	}

	// The sole winning staker takes the whole winners' slice (under her cap).
	emittedBefore := EmittedTotal("cz1")
	aliceBefore := c.coin.BalanceOf(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	got := WithdrawBonus(cross(cur), "cz1", id, sideYES)
	if got != w || c.coin.BalanceOf(alice) != aliceBefore+w {
		t.Fatalf("sole winner draws the whole slice: %d vs %d", got, w)
	}
	uassert.AbortsContains(t, cur, "already drawn", func() {
		WithdrawBonus(cross(cur), "cz1", id, sideYES)
	})
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "only the winning side", func() {
		WithdrawBonus(cross(cur), "cz1", id, sideNO)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	gotA := AuthorBonus(cross(cur), "cz1", id)
	gotAns := AnswererBonus(cross(cur), "cz1", id)
	if gotA != a || gotAns != ans {
		t.Fatalf("author/answerer slices under caps: %d/%d vs %d/%d", gotA, gotAns, a, ans)
	}
	if EmittedTotal("cz1") != emittedBefore+w+a+ans {
		t.Fatal("every draw mints through the one emission ledger")
	}
	// No vote resolved this claim: no carrot exists.
	testing.SetRealm(testing.NewUserRealm(dave))
	uassert.AbortsContains(t, cur, "nobody voted", func() {
		PullCarrot(cross(cur), "cz1", id)
	})

	// Principal + deposit/fee all came home: the escrow drains to zero.
	testing.SetRealm(testing.NewUserRealm(alice))
	WithdrawStake(cross(cur), "cz1", id, sideYES)
	testing.SetRealm(testing.NewUserRealm(bob))
	WithdrawStake(cross(cur), "cz1", id, sideNO)
	if got := c.coin.BalanceOf(c.escrow); got != 0 {
		t.Fatalf("escrow must drain to zero: %d", got)
	}
}
// TestCrystallizeLowTierZeroDrawCarrotStillPays went with the quality lane: a LOW tier no longer zeroes the draw; size rates a small claim 0.25x

// F9 headroom probe (v0.45 gap 1). The flash-proof cap is
// bound = tier·(positionRaw/openBlocks)/2, i.e. HALF the position's
// time-averaged stake at mid tier (tierMidX == 1). The gross it caps is the
// staker's share of the conviction-scaled draw, which the deploy calibration
// bounds at ≤19.27%·X̄ over a 12-week life. 0.1927 < 0.5, so on a constant pool
// the cap has ~2.6× of headroom and cannot bind — the same relationship that
// keeps the answer bond above the slash. This drives the most extreme LEGAL
// shape instead: stake big, bank conviction, unstake (F9 keeps conviction), then
// let the claim age so openBlocks dilutes rawAvg while conviction stands. If the
// cap is reachable at all, it is here.
func TestF9CapHeadroomAtTheExtreme(cur realm, t *testing.T) {
	alice := testutils.TestAddress("f9-alice")
	c := testCourt(cur, "f9c", alice, 1_000_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "f9c", "Banked conviction, diluted raw")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "f9c", id, sideYES, 100_000_000_000) // 100k CC
	testing.SkipHeights(4 * periodBlocks)                  // bank conviction AND raw
	testing.SetRealm(testing.NewUserRealm(alice))
	// Retain twice the answerability floor — DERIVED, like the two drain probes
	// in quality_test.gno. v0.27 made that floor a fraction of the court's own
	// supply, so "unstake to a sliver, then answer" is no longer a legal shape:
	// the floor bounds how far a position may diverge and still be answerable.
	// That MOVES the boundary this test probes rather than invalidating it, and
	// moves it in the test's favour — the most extreme reachable divergence is
	// now the strongest probe the rules permit, and the F9 cap has more headroom
	// against it than the old fixture claimed to show.
	keep := effMinAnswerX(c) * 2
	Unstake(cross(cur), "f9c", id, sideYES, 100_000_000_000-keep) // raw stops; conviction kept
	testing.SkipHeights(6 * periodBlocks)                         // openBlocks grows, raw does not
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "f9c", id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "f9c", id)
	testing.SkipHeights(priorityWindowBlocks + 1)
	testing.SkipHeights(periodBlocks)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "f9c", id)

	cs := mustClaim(c, id)
	p := cs.stakers.Get(posKey(alice, sideYES)).(*stakePos)

	testing.SetRealm(testing.NewUserRealm(alice))
	pay := WithdrawBonus(cross(cur), "f9c", id, sideYES)

	// Read the position AFTER the pull: WithdrawBonus calls accrue() to settle it
	// to the freeze pin, so a conviction read taken before would be stale (it is,
	// by ~0.15% — enough to make an equality assertion lie).
	convCC := convToCC(p.convHi, p.convLo)
	gross := mulDiv128(cs.drawWinners, convCC, cs.winPoolConvCC)
	rawAvg := div128(p.rawHi, p.rawLo, cs.openBlocks)
	bound := mulDiv128(rawAvg, tierBpsFor(cs), 2*tierParBps)

	if pay != gross {
		t.Fatalf("THE F9 CAP BINDS HERE — it is reachable after all, so build the "+
			"binding fixture from this state: pay=%d gross=%d bound=%d rawAvg=%d openBlocks=%d",
			pay, gross, bound, rawAvg, cs.openBlocks)
	}
	// Measured headroom at this extreme: bound 2.0e10 vs gross 2.2e9, ~9×. The
	// ratio gross/bound is 2·rate·openBlocks, so binding needs openBlocks >
	// 1/(2·rate) ≈ 1.1e7 blocks ≈ 91 weeks — far past the 12-week dead-claim
	// timeout PostAnswer now enforces. The cap is therefore UNREACHABLE at mid
	// tier, and higher tiers only double the bound. This pins the relationship
	// rather than a number: if rates, windows, or the timeout ever change enough
	// to invert it, F9 starts binding honest positions and this fails.
	if bound <= gross {
		t.Fatalf("F9 headroom is gone — the cap now binds honest positions: bound=%d gross=%d",
			bound, gross)
	}
}

// P2 per-voter carrot clamp probe (v0.45 gap 4). The clamp is b0/2 - 1 where
// b0 = max(carrotClampMinCC, 2%·X̄frozen), so it bites a SOLE voter (w == denom, share ==
// carrotTotal) exactly when carrotTotal = 7%·midGross exceeds 1%·X̄, i.e. when
// midGross > 14.3%·X̄. midGross/X̄ = rate·T, so unlike the F9 cap (which needs ~91
// weeks and is unreachable) this one needs ~9 weeks at the hot rate — inside the
// 12-week life PostAnswer permits. This drives a long-lived claim with a single
// conclusive-tally voter to find out.
func TestP2CarrotClampBindsForASoleVoter(cur realm, t *testing.T) {
	alice := testutils.TestAddress("p2-alice") // author/answerer/staker
	flagger := testutils.TestAddress("p2-flag")
	voter := testutils.TestAddress("p2-voter") // sole non-participant voter
	c := testCourt(cur, "p2c", alice, 1_000_000_000_000)
	c.coin.Mint(flagger, 50_000_000_000)
	c.coin.Mint(voter, 200_000_000_000) // >= fullBar, so the flag is CONCLUSIVE

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "p2c", "Long-lived claim, one carrot voter")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "p2c", id, sideYES, 100_000_000_000) // 100k CC held throughout
	testing.SkipHeights(11 * periodBlocks)                 // bank conviction (< 12wk timeout)
	// observePools only fires on stake/unstake, so a single opening Stake leaves
	// the trailing ring with one filled bucket and PostAnswer refuses ("not enough
	// stake history"). Three dust stakes an epoch apart mature it without
	// materially moving X̄ (3 CC against 100k).
	matureOI(cur, "p2c", id, alice, 1_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "p2c", id, sideYES)

	// An upheld dispute round carried by the sole voter: that is what sets
	// decidedPID and funds the carrot the clamp is measured against. It used to be
	// a conclusive MID flag, which did the same two jobs without a bond.
	upholdByVote(cur, "p2c", id, c, flagger, voter)
	if cs := mustClaim(c, id); cs.decidedPID == 0 {
		t.Fatal("setup: need a decided round for the carrot to pay from")
	}
	testing.SkipHeights(priorityWindowBlocks + 1)
	testing.SkipHeights(periodBlocks)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "p2c", id)

	cs := mustClaim(c, id)
	b0 := cs.xBarFrozen * carrotClampXBps / 10000
	if b0 < carrotClampMinCC {
		b0 = carrotClampMinCC
	}
	clamp := b0/2 - 1
	uncapped := cs.carrotTotal // sole voter: w == denom, so share == carrotTotal

	// MEASURED: on this cold court the natural carrot reaches only ~49% of the
	// clamp at 11 of the 12 permitted weeks (carrotTotal 4.91e8 vs clamp 1.00e9).
	// The reason is not the claim's age but the RATE: dEffBpsFP = min(budget,
	// dReal) where dReal is the EMA'd REALIZED mint rate, so a single-claim court
	// that emits almost nothing sits at the cold r0 (~63.8 bps/wk) — and emaMinted
	// decays by 3/4 every roll, so it cannot be seeded either. On a busy court at
	// the hot rate the ratio is midGross/X̄ ≤ 19.27%, giving carrotTotal = 7% of
	// that = 1.35%·X̄ against a 1%·X̄ clamp, so P2 DOES bind there — unlike the F9
	// cap, which is unreachable at any rate. Reachable in production, not by
	// natural flow in a single-claim harness.
	if uncapped >= clamp {
		t.Fatalf("cold-court assumption broke — the natural carrot now reaches the "+
			"clamp, so build the natural fixture: carrotTotal=%d clamp=%d", uncapped, clamp)
	}

	// So exercise the clamp itself, which is what was never covered: craft a
	// carrot above the bound and require the pull to be cut to exactly b0/2-1.
	cs.carrotTotal = clamp * 3
	cs.carrotPool = cs.carrotTotal
	testing.SetRealm(testing.NewUserRealm(voter))
	got := PullCarrot(cross(cur), "p2c", id)
	if got != clamp {
		t.Fatalf("a sole voter must be clamped to b0/2-1: got %d clamp %d (uncapped share %d)",
			got, clamp, cs.carrotTotal)
	}
	if cs.carrotPool != cs.carrotTotal-clamp {
		t.Fatalf("only the clamped amount leaves the pool: pool=%d want %d",
			cs.carrotPool, cs.carrotTotal-clamp)
	}
}

// TestFullBarLowStillPaysTheTierInvariantCarrot went with the quality lane: there is no full bar and no conclusive low

// TestDecidedRoundCarrotSurvivesAStaleSubBarTally went with the quality lane: the stale tally it outranked was the quality tally

// TestCrystallizeWaitsOutTheQuietWindow went with the quality lane: the 24h quiet window was anchored on lastFlagEventAt, which only the flag lane ever stamped; crystallize.gno records why the guard went with it

// capBonus's F9 bound, found SURVIVING: multiplying it by 1000 failed no test, because
// TestF9CapHeadroomAtTheExtreme establishes the cap is UNREACHABLE by natural flow
// (~9x headroom at the extreme). That makes it defence rather than a live clamp — but
// capBonus is a pure function taking its inputs as arguments, so the clamp itself is
// testable directly without crafting protocol state the design forbids.
func TestCapBonusClampsToTheF9Bound(cur realm, t *testing.T) {
	// The multiplier reads only FROZEN claim state — the claim's own size and
	// the court's typical claim as of its answer — so a bare claimState is the
	// whole fixture. That is the property that lets Crystallize be permissionless
	// without letting its caller choose the number.
	const ref = int64(1_000_000)
	cs := &claimState{openBlocks: 1, tierRef: ref, xBarFrozen: ref}
	// rawAvg = 100 at par -> bound = 50.
	if got := capBonus(cs, 1_000, 0, 100); got != 50 {
		t.Fatalf("gross above the bound must clamp to (tier x rawAvg)/2: got %d want 50", got)
	}
	// Below the bound, gross passes through untouched.
	if got := capBonus(cs, 10, 0, 100); got != 10 {
		t.Fatalf("gross below the bound is unchanged: got %d want 10", got)
	}
	// Twice the court's typical claim doubles it — the old HIGH, reached by size
	// instead of by a two-thirds mandate.
	cs.xBarFrozen = 2 * ref
	if got := capBonus(cs, 1_000, 0, 100); got != 100 {
		t.Fatalf("the bound is tier-scaled: got %d want 100", got)
	}
	// ...and it stops there. Ten times the typical claim draws the same multiple
	// as twice it; the ceiling is what keeps the emission ceiling where every
	// deploy invariant was fitted to it.
	cs.xBarFrozen = 10 * ref
	if got := capBonus(cs, 1_000, 0, 100); got != 100 {
		t.Fatalf("the ceiling clamps: got %d want 100", got)
	}
	// THE SMALLEST CLAIM STILL PAYS SOMETHING. Under the vote a LOW bounded this
	// to zero; under size there is no "worthless" verdict to justify that, so the
	// floor is 0.25x: 100 * 2500 / 20000 = 12.
	cs.xBarFrozen = 0
	if got := capBonus(cs, 1_000, 0, 100); got != 12 {
		t.Fatalf("the floor is 0.25x, not zero: got %d want 12", got)
	}
	// A claim frozen before this shipped carries no reference, and reads as par
	// rather than as zero — the alternative would retroactively zero every
	// pre-existing claim's caps.
	if got := capBonus(&claimState{openBlocks: 1}, 1_000, 0, 100); got != 50 {
		t.Fatalf("no reference reads as par: got %d want 50", got)
	}
	// And the floor on the OTHER end: a negative gross never becomes a payout.
	cs.xBarFrozen = ref
	if got := capBonus(cs, -5, 0, 100); got != 0 {
		t.Fatalf("a negative gross floors at zero: got %d", got)
	}
}

// The P7 draw split, found SURVIVING by the mutation harness: setting
// `drawWinners = d` — the whole draw to the winners, with no 80/93 — failed no test.
// The author slice IS pinned, so only the winners' side was open, and it is the side
// that matters: crystallize.gno's own comment says the 80/8/5 split is taken OUT of D,
// that a winner receives 80/93 = 0.860 x midGross rather than the full midGross, and
// "Do NOT 'fix' toward §3.5 — it would inflate every draw 16%". That exact edit would
// have passed.
//
// Asserted as a RATIO against the observed total rather than against d, because d is
// not exported and the three slices are floored independently. If the split is taken,
// winners x 93 == total x 80 exactly up to floor loss; if the whole draw goes to the
// winners, total becomes d x 106/93 and the identity breaks by ~1.8 x d.
func TestP7SplitTakesEightyOfNinetyThreeForWinners(cur realm, t *testing.T) {
	alice := testutils.TestAddress("p7s-alice")
	flagger := testutils.TestAddress("p7s-flag")
	voter := testutils.TestAddress("p7s-voter")
	c := testCourt(cur, "p7s", alice, 50_000_000_000)
	c.coin.Mint(flagger, 10_000_000_000)
	c.coin.Mint(voter, 20_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "p7s", "the split comes out of D")
	matureOI(cur, "p7s", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "p7s", id, sideYES)
	// An upheld round so the answer stands and D > 0, making every slice payable.
	upholdByVote(cur, "p7s", id, c, flagger, voter)
	testing.SkipHeights(priorityWindowBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "p7s", id)

	w, a, ans, _ := DrawSlices("p7s", id)
	if w <= 0 || a <= 0 || ans <= 0 {
		t.Fatalf("setup: a MID claim must pay all three slices: %d/%d/%d", w, a, ans)
	}
	total := w + a + ans
	// Floor loss is at most one unit per slice, so allow a few units of slack and no
	// more — the mutation misses by ~1.8x the draw, not by units.
	const slack = int64(4)
	lhs, rhs := w*(splitWinners+splitAuthor+splitAnswerer), total*splitWinners
	if lhs > rhs+slack*splitWinners || lhs < rhs-slack*splitWinners {
		t.Fatalf("P7: winners take %d/%d of the draw, not the whole of it: "+
			"w=%d total=%d (w*93=%d vs total*80=%d)",
			splitWinners, splitWinners+splitAuthor+splitAnswerer, w, total, lhs, rhs)
	}
	// And the author/answerer shares are the other 8 and 5, so the three exhaust D.
	if a*splitWinners < w*splitAuthor-slack*splitWinners ||
		a*splitWinners > w*splitAuthor+slack*splitWinners {
		t.Fatalf("P7: the author slice must be %d/%d of the winners': a=%d w=%d",
			splitAuthor, splitWinners, a, w)
	}
}

// AnswererBonus had FIVE surviving mutations — every guard in the function, which
// is the worst-covered money path found since v0.68. Two of them stand between a
// caller and mintEmission: delete `who != cs.answerer` and ANYONE draws the
// answerer's slice into their own balance; delete `answererPaid` and the answerer
// draws it again, and again. Neither is an equivalence — both mint.
//
// The function was not untested, which is why this went unnoticed. Two fixtures
// call it: TestCrystallizeMidHappyPathDrainsEscrow asserts the answerer draws
// exactly its slice (so the tier bound is never reached), and the M3 overturn
// fixture asserts zero — but by way of drawAnswerer == 0, not the bound. Both call
// it AS the answerer, once. Every guard was therefore exercised on the side where
// it does nothing, which is indistinguishable from coverage until something breaks
// it on purpose.
func TestAnswererBonusGuardsItsSliceAndItsCap(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ab1-alice")
	bob := testutils.TestAddress("ab1-bob")
	c := testCourt(cur, "ab1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "ab1", "The answerer's slice and its cap")
	matureOI(cur, "ab1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "ab1", id, sideNO, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "ab1", id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "ab1", id)
	testing.SkipHeights(100_000) // the reservoir starts empty; cross a period
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "ab1", id)

	// Only the answerer, and the check must be the ANSWERER's identity rather than
	// mere participation: bob staked, settled and is a live participant here.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "only the answerer draws this slice", func() {
		AnswererBonus(cross(cur), "ab1", id)
	})

	_, _, ans, _ := DrawSlices("ab1", id)
	if ans <= 0 {
		t.Fatalf("setup: this claim must have a live answerer slice, got %d", ans)
	}
	cs := mustClaim(c, id)
	if tierBpsFor(cs) <= 0 {
		t.Fatalf("setup: an answered claim must carry a positive multiplier, got %d",
			tierBpsFor(cs))
	}
	// The bound is multiplier x b0 / 2 and the natural fixture sits UNDER it,
	// exactly as the happy path asserts. So drive the bound down to half the
	// slice instead of driving the slice up past the bound: clamping DOWN keeps
	// the mint smaller than one the reservoir has already funded, whereas an
	// inflated draw would test the cap against the emission budget as much as
	// against the cap.
	if natural := mulDiv128(cs.answerBond0, tierBpsFor(cs), 2*tierParBps); ans > natural {
		t.Fatalf("this fixture assumes the cap is slack (slice %d, bound %d); it now "+
			"binds on its own, so assert the natural value instead of squeezing it",
			ans, natural)
	}
	// THE SQUEEZE INVERTS THE BOUND, so it has to invert the SAME multiplier the
	// bound uses. Dividing by cs.tier — the old voted band — left the bound equal
	// to the slice and the clamp untested: the failure read "bound 2448, slice
	// 2448", which is a test that no longer bites rather than a broken cap.
	cs.answerBond0 = mulDiv128(ans, tierParBps, tierBpsFor(cs))
	// The bound reads the ACTUAL multiplier. This test is about the answerer's
	// CAP, not about what sets the tier — pinning a mid here would make it fail
	// on any claim the size derivation rates differently, which is every claim.
	want := mulDiv128(cs.answerBond0, tierBpsFor(cs), 2*tierParBps)
	if want <= 0 || want >= ans {
		t.Fatalf("the squeeze must land strictly between 0 and the slice: "+
			"bound %d, slice %d", want, ans)
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	got := AnswererBonus(cross(cur), "ab1", id)
	if got != want {
		t.Fatalf("the tier bound must clamp the answerer's slice to %d, not pay %d "+
			"(uncapped slice %d)", want, got, ans)
	}

	// One draw only. Without this latch the clamped slice is mintable on every call.
	uassert.AbortsContains(t, cur, "already drawn", func() {
		AnswererBonus(cross(cur), "ab1", id)
	})
}

// AuthorBonus is AnswererBonus's twin and had the same three gaps: the identity
// check, the one-draw latch, and the F9 cap. Same cause, too — the happy-path
// fixture's author IS its answerer and draws once, so "only the author" was only
// ever asked of the author.
//
// The cap arm drives the F9 time-average to ZERO rather than crafting a bound,
// because that is what F9 says: the bonus is capped by capital-time, so a position
// with no measurable capital-time draws nothing however large the slice it would
// otherwise take. Inflating openBlocks is the cheapest way to say that — it is the
// divisor of the raw integral — and it keeps the assertion (pay is 0 while the
// slice is live) independent of the formula under test, instead of recomputing
// capBonus's own arithmetic and comparing it with itself.
func TestAuthorBonusGuardsItsSliceAndItsF9Cap(cur realm, t *testing.T) {
	alice := testutils.TestAddress("au1-alice")
	bob := testutils.TestAddress("au1-bob")
	c := testCourt(cur, "au1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "au1", "The author's slice and its F9 cap")
	matureOI(cur, "au1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "au1", id, sideNO, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "au1", id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "au1", id)
	testing.SkipHeights(100_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "au1", id)

	// Not the author — and bob is a staker who settled this very claim, so what is
	// refused here is the AUTHOR's identity and not mere standing.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "only the author draws this slice", func() {
		AuthorBonus(cross(cur), "au1", id)
	})

	_, a, _, _ := DrawSlices("au1", id)
	if a <= 0 {
		t.Fatalf("setup: this claim must have a live author slice, got %d", a)
	}
	// Stretch the claim's open life so far that the author's time-averaged stake
	// floors to zero. The slice stays live; only the F9 bound moves.
	cs := mustClaim(c, id)
	cs.openBlocks = int64(1) << 60 // far above any raw integral this fixture can bank

	testing.SetRealm(testing.NewUserRealm(alice))
	got := AuthorBonus(cross(cur), "au1", id)
	if got != 0 {
		t.Fatalf("with no measurable capital-time the F9 cap must pay nothing, not "+
			"%d of a %d slice", got, a)
	}

	// One draw only, and the latch holds even though that draw paid zero — a
	// no-op draw must still consume the slice, or the cap becomes a retry loop.
	uassert.AbortsContains(t, cur, "already drawn", func() {
		AuthorBonus(cross(cur), "au1", id)
	})
}

// The DECIDED round's carrot electorate, found SURVIVING: drop the carrotChoice half
// of PullCarrot's first branch and a voter who voted AGAINST the verdict draws the
// policing pay of the round that went the other way. That is the whole point of the
// carrot — it pays for being right, and paying both sides pays for turning up.
//
// Nothing caught it because no fixture had ever built a CONTESTED decided round. cz6
// has a single voter, so every recorded vote equals carrotChoice by construction and
// the comparison is true whatever it compares. Here the round is contested and the
// losing voter is refused by name.
func TestDecidedCarrotRefusesTheAgainstVerdictVoter(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cvd1-alice") // author + answerer
	bob := testutils.TestAddress("cvd1-bob")     // disputer
	carol := testutils.TestAddress("cvd1-carol") // votes NO, wins, big weight
	dan := testutils.TestAddress("cvd1-dan")     // votes YES, loses
	c := testCourt(cur, "cvd1", alice, 50_000_000_000)
	c.coin.Mint(bob, 1_000_000_000)
	c.coin.Mint(carol, 5_000_000_000)
	c.coin.Mint(dan, 1_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "cvd1", "a decided round pays only its own side")
	matureOI(cur, "cvd1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "cvd1", id, sideYES)
	c.params.escrowMinBlocks = 900_000
	c.params.escrowMaxBlocks = 900_000

	// Round 1 fails quorum, which opens the escrow window the decided round needs.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "cvd1", id)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "cvd1", id)

	// A CONTESTED round: NO carries on weight, so the YES voter is on the losing side
	// of the verdict while still having voted.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "cvd1", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "cvd1", id, "no")
	testing.SetRealm(testing.NewUserRealm(dan))
	VoteDispute(cross(cur), "cvd1", id, "yes")
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "cvd1", id)

	cs := mustClaim(c, id)
	if cs.decidedPID == 0 || cs.carrotChoice != "no" {
		t.Fatalf("setup: need a decided round carried by NO: pid=%d choice=%q",
			cs.decidedPID, cs.carrotChoice)
	}

	testing.SkipHeights(EscrowUntil("cvd1", id) - heightNow())
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "cvd1", id)
	testing.SkipHeights(priorityWindowBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "cvd1", id)
	if _, _, _, carrot := DrawSlices("cvd1", id); carrot <= 0 {
		t.Fatalf("setup: a decided round must leave a carrot to fight over: %d", carrot)
	}

	// The voter who voted WITH the verdict is paid.
	testing.SetRealm(testing.NewUserRealm(carol))
	if share := PullCarrot(cross(cur), "cvd1", id); share <= 0 {
		t.Fatalf("the with-verdict voter must be paid: %d", share)
	}
	// The one who voted against it is not — and note it is refused for the RIGHT
	// reason: dan did vote, so this cannot pass by way of the non-voter branch.
	testing.SetRealm(testing.NewUserRealm(dan))
	uassert.AbortsContains(t, cur, "with-verdict voters", func() {
		PullCarrot(cross(cur), "cvd1", id)
	})
}

// THE CARROT'S SPLIT, found SURVIVING: replace the denominator with the voter's own
// weight and the whole kourtv2 suite still passes. In production that pays EVERY
// with-verdict voter the entire carrot instead of their share, so the pool over-draws
// by the size of the electorate.
//
// Nothing caught it because every carrot fixture pulls with ONE voter on the winning
// side, which makes w == denom by construction and collapses
// mulDiv128(carrotTotal, w, denom) to carrotTotal. Measured before writing this: five
// PullCarrot call sites in four tests, and not one has two distinct voters drawing on
// the same claim -- one is named ...ForASoleVoter. Their assertions are either
// clamp-dominated (p2c crafts carrotTotal above the bound and requires exactly
// b0/2-1, the same number with or without a denominator bug) or a bare sign check
// (cvd1 and rntw6 ask only for > 0). A share that is wrong by a factor of the
// electorate is still positive, and still gets clamped to the same ceiling.
//
// So this fixture is the smallest one that CANNOT degenerate: two voters on the
// winning side with DIFFERENT weights. The four preconditions are load-bearing, not
// decoration -- they assert the denominator is a genuine sum, that the weights
// differ, that the clamp does not bind, and that a share is strictly less than the
// whole carrot. Drop any of them and this test rots back into the shape it exists to
// replace, which is exactly how the existing coverage came to prove nothing.
func TestDecidedCarrotSplitsOnWeightNotHeadcount(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cspl-alice") // author + answerer
	bob := testutils.TestAddress("cspl-bob")     // disputer
	carol := testutils.TestAddress("cspl-carol") // votes NO, wins, BIG weight
	erin := testutils.TestAddress("cspl-erin")   // votes NO, wins, SMALL weight
	dan := testutils.TestAddress("cspl-dan")     // votes YES, loses
	c := testCourt(cur, "cspl", alice, 50_000_000_000)
	c.coin.Mint(bob, 1_000_000_000)
	c.coin.Mint(carol, 5_000_000_000)
	c.coin.Mint(erin, 1_000_000_000)
	c.coin.Mint(dan, 1_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "cspl", "the carrot splits on weight")
	matureOI(cur, "cspl", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "cspl", id, sideYES)
	c.params.escrowMinBlocks = 900_000
	c.params.escrowMaxBlocks = 900_000

	// Round 1 fails quorum, which opens the escrow window the decided round needs.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "cspl", id)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "cspl", id)

	// The decided round: NO carries on carol's and erin's COMBINED weight.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "cspl", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "cspl", id, "no")
	testing.SetRealm(testing.NewUserRealm(erin))
	VoteDispute(cross(cur), "cspl", id, "no")
	testing.SetRealm(testing.NewUserRealm(dan))
	VoteDispute(cross(cur), "cspl", id, "yes")
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "cspl", id)

	cs := mustClaim(c, id)
	if cs.decidedPID == 0 || cs.carrotChoice != "no" {
		t.Fatalf("setup: need a decided round carried by NO: pid=%d choice=%q",
			cs.decidedPID, cs.carrotChoice)
	}

	testing.SkipHeights(EscrowUntil("cspl", id) - heightNow())
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "cspl", id)
	testing.SkipHeights(priorityWindowBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "cspl", id)

	// Read the weights this realm actually RECORDED, rather than re-deriving them
	// from the mints -- the lanes cap at live balance, so a re-derivation is the very
	// mistake PullCarrot's own comment above warns about.
	wOf := func(who address) int64 {
		v := cs.voted.Get("dw" + beClaimKey(uint64(cs.decidedPID)) + string(who))
		if v == nil {
			t.Fatalf("setup: no recorded weight for %s on the deciding round", who)
		}
		return v.(int64)
	}
	wC, wE, denom := wOf(carol), wOf(erin), cs.carrotDenom

	// PRECONDITION 1: the denominator is a GENUINE SUM. Without this the fixture is
	// the degenerate single-voter shape and proves nothing about the division.
	if denom != wC+wE || wC == denom || wE == denom {
		t.Fatalf("setup: denom must be a real sum of two weights: wC=%d wE=%d denom=%d",
			wC, wE, denom)
	}
	// PRECONDITION 2: the weights DIFFER, so a share that splits by headcount is a
	// different number from the right one.
	if wC == wE {
		t.Fatalf("setup: the two winning weights must differ: wC=%d wE=%d", wC, wE)
	}
	// PRECONDITION 3: the clamp must NOT bind, or both shares are cut to b0/2-1 and
	// every assertion below passes for the wrong reason.
	b0 := cs.xBarFrozen * carrotClampXBps / 10000
	if b0 < carrotClampMinCC {
		b0 = carrotClampMinCC
	}
	clamp := b0/2 - 1
	total := cs.carrotTotal
	wantC := mulDiv128(total, wC, denom)
	wantE := mulDiv128(total, wE, denom)
	if wantC >= clamp || wantE >= clamp {
		t.Fatalf("setup: the clamp must not bind or this test is clamp-dominated: "+
			"wantC=%d wantE=%d clamp=%d", wantC, wantE, clamp)
	}
	// PRECONDITION 4: and a proportional share is STRICTLY LESS than the whole
	// carrot, which is the single number a denominator bug collapses to.
	if wantC >= total {
		t.Fatalf("setup: a share of a two-voter carrot must be less than all of it: "+
			"wantC=%d carrotTotal=%d", wantC, total)
	}

	testing.SetRealm(testing.NewUserRealm(carol))
	gotC := PullCarrot(cross(cur), "cspl", id)
	if gotC != wantC {
		t.Fatalf("the big-weight voter draws carrotTotal*w/denom: got %d want %d "+
			"(w=%d denom=%d total=%d)", gotC, wantC, wC, denom, total)
	}
	testing.SetRealm(testing.NewUserRealm(erin))
	gotE := PullCarrot(cross(cur), "cspl", id)
	if gotE != wantE {
		t.Fatalf("the small-weight voter draws carrotTotal*w/denom: got %d want %d "+
			"(w=%d denom=%d total=%d)", gotE, wantE, wE, denom, total)
	}
	// Ordered by weight, and NOT equal -- a headcount split makes these the same.
	if gotC <= gotE {
		t.Fatalf("more weight must draw more carrot: gotC=%d (w=%d) gotE=%d (w=%d)",
			gotC, wC, gotE, wE)
	}
	// AND THE POOL IS NOT OVER-DRAWN, which is the production consequence: each
	// voter pulling their "share" must not between them exceed the carrot.
	if gotC+gotE > total {
		t.Fatalf("the two shares must not exceed the carrot: %d+%d > %d",
			gotC, gotE, total)
	}
}
