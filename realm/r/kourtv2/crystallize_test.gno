package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

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

func TestCrystallizeLowTierZeroDrawCarrotStillPays(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cz2-alice")
	eve := testutils.TestAddress("cz2-eve")
	c := testCourt(cur, "cz2", alice, 50_000_000_000)
	c.coin.Mint(eve, 1_000_000_000) // dust-low weight: >= X̄/4, < the 5% full bar

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "cz2", "A junk claim")
	matureOI(cur, "cz2", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "cz2", id, sideYES)
	// A second wallet flags; eve's 1000 CC lands a DUST low (>= quarter-bar,
	// below the full bar → no slash).
	flagger := testutils.TestAddress("cz2-flagger")
	c.coin.Mint(flagger, 1_000_000_000)
	testing.SetRealm(testing.NewUserRealm(flagger))
	OpenFlag(cross(cur), "cz2", id)
	testing.SetRealm(testing.NewUserRealm(eve))
	VoteQuality(cross(cur), "cz2", id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "cz2", id)
	tier, final := QualityTier("cz2", id)
	if tier != qualityLow || !final {
		t.Fatal("a quarter-bar low without the full bar is a final dust low")
	}
	// Settle AFTER the low: the verdict must not overwrite the final tier.
	SettleUndisputed(cross(cur), "cz2", id)
	if tier, _ := QualityTier("cz2", id); tier != qualityLow {
		t.Fatal("settle must not overwrite a final tier")
	}
	// The reopen-relative rule: 24h quiet after the flag-vote close.
	testing.SkipHeights(priorityWindowBlocks + 1)
	authorBefore := c.coin.BalanceOf(alice)
	supplyBefore := c.coin.TotalSupply()
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "cz2", id)
	// The burned deposit and fee stay burned. Asserting the FIELDS is not enough —
	// Crystallize zeroes them after paying, so a resurrected refund would be
	// invisible there (v0.45). The author's balance is what discriminates: a refund
	// would come out of escrow, i.e. out of staked principal. Nothing mints either,
	// since tier low means D = 0 (the carrot mints later, at pull).
	if got := c.coin.BalanceOf(alice); got != authorBefore {
		t.Fatalf("no coin may reach the author on a burned-deposit claim: %d vs %d", got, authorBefore)
	}
	if got := c.coin.TotalSupply(); got != supplyBefore {
		t.Fatalf("tier low mints nothing at crystallize: %d vs %d", got, supplyBefore)
	}
	w, a, ans, carrot := DrawSlices("cz2", id)
	if w != 0 || a != 0 || ans != 0 {
		t.Fatalf("tier low draws nothing: %d/%d/%d", w, a, ans)
	}
	if carrot <= 0 {
		t.Fatal("the carrot is tier-invariant: paid even at low")
	}
	// The winner pull is a zero, not a revert (cap = 0 at tier 0).
	testing.SetRealm(testing.NewUserRealm(alice))
	if got := WithdrawBonus(cross(cur), "cz2", id, sideYES); got != 0 {
		t.Fatal("low tier pays zero accuracy reward")
	}
	// Eve (non-participant conclusive voter) pulls the carrot, senior-queued.
	owedBefore := SeniorOwed("cz2")
	testing.SetRealm(testing.NewUserRealm(eve))
	share := PullCarrot(cross(cur), "cz2", id)
	if share <= 0 || SeniorOwed("cz2") != owedBefore+share {
		t.Fatalf("the carrot senior-queues: %d", share)
	}
	uassert.AbortsContains(t, cur, "already claimed", func() {
		PullCarrot(cross(cur), "cz2", id)
	})
	// Participants never take the carrot.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "never the carrot", func() {
		PullCarrot(cross(cur), "cz2", id)
	})
	// The burned deposit stays burned: no refund arrived at crystallize.
	cs := mustClaim(c, id)
	if cs.deposit != 0 || cs.fee != 0 {
		t.Fatal("low-slashed deposit/fee must not resurrect")
	}
	// Conservation: once the only stake is withdrawn, escrow is empty — the burned
	// deposit/fee left no phantom balance and the flag bond went back to its poster.
	testing.SetRealm(testing.NewUserRealm(alice))
	WithdrawStake(cross(cur), "cz2", id, sideYES)
	if got := c.coin.BalanceOf(c.escrow); got != 0 {
		t.Fatalf("escrow must drain to zero: %d", got)
	}
}

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
	testing.SkipHeights(6 * periodBlocks)                   // openBlocks grows, raw does not
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
	bound := mustMul(cs.tier, rawAvg) / 2

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
// b0 = max(flagMinCC, 2%·X̄frozen), so it bites a SOLE voter (w == denom, share ==
// carrotTotal) exactly when carrotTotal = 7%·midGross exceeds 1%·X̄, i.e. when
// midGross > 14.3%·X̄. midGross/X̄ = rate·T, so unlike the F9 cap (which needs ~91
// weeks and is unreachable) this one needs ~9 weeks at the hot rate — inside the
// 12-week life PostAnswer permits. This drives a long-lived claim with a single
// conclusive-tally voter to find out.
func TestP2CarrotClampBindsForASoleVoter(cur realm, t *testing.T) {
	alice := testutils.TestAddress("p2-alice")   // author/answerer/staker
	flagger := testutils.TestAddress("p2-flag")
	voter := testutils.TestAddress("p2-voter")   // sole non-participant voter
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

	// A conclusive MID flag: consumes the slot, sets the tally the carrot pays.
	testing.SetRealm(testing.NewUserRealm(flagger))
	OpenFlag(cross(cur), "p2c", id)
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteQuality(cross(cur), "p2c", id, qualityMid)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "p2c", id)
	if tier, _ := QualityTier("p2c", id); tier != qualityMid {
		t.Fatalf("setup: need a conclusive MID tally, got tier=%d", tier)
	}
	SettleUndisputed(cross(cur), "p2c", id)
	testing.SkipHeights(priorityWindowBlocks + 1)
	testing.SkipHeights(periodBlocks)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "p2c", id)

	cs := mustClaim(c, id)
	b0 := cs.xBarFrozen * flagBondXBps / 10000
	if b0 < flagMinCC {
		b0 = flagMinCC
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
