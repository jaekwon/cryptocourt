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
	// v0.55: the carrot is TIER-invariant, not TURNOUT-invariant. This tally is a
	// DUST low — conclusive at the supply-floorless demotionBar, below the full bar —
	// where the flag bond returns WHOLE, so paying an X̄-scaled pot here was v0.25's
	// A21 faucet arriving through the carrot. Tier-invariance is pinned above the bar
	// by TestFullBarLowStillPaysTheTierInvariantCarrot.
	if carrot != 0 {
		t.Fatalf("a sub-full-bar tally pays no carrot: %d", carrot)
	}
	// The winner pull is a zero, not a revert (cap = 0 at tier 0).
	testing.SetRealm(testing.NewUserRealm(alice))
	if got := WithdrawBonus(cross(cur), "cz2", id, sideYES); got != 0 {
		t.Fatal("low tier pays zero accuracy reward")
	}
	// Eve (non-participant conclusive voter) pulls, and gets NOTHING (v0.55): the
	// tally was sub-full-bar, so there is no pot. The pull is a zero rather than a
	// revert, and it reserves no accrual — SeniorOwed must not move, since a senior
	// entitlement here would advance the monotone reservedTail against a mint that
	// never happens.
	owedBefore := SeniorOwed("cz2")
	testing.SetRealm(testing.NewUserRealm(eve))
	if share := PullCarrot(cross(cur), "cz2", id); share != 0 {
		t.Fatalf("a sub-full-bar tally pulls nothing: %d", share)
	}
	if SeniorOwed("cz2") != owedBefore {
		t.Fatalf("a zero pull must reserve no accrual: %d vs %d",
			SeniorOwed("cz2"), owedBefore)
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


// The other side of v0.55: tier-invariance is real ABOVE the bar. F2/A11 argues a
// conclusive LOW must still pay its electorate the same 7%·midGross a mid or high
// would — what v0.55 withholds is only the SUB-BAR pot, where the flag bond returns
// whole and the pot was an X̄-scaled mint against 1.1 CC of burn. This drives a
// full-bar low in the T2 band (low share in [1/2, 2/3), so no slash reserves and
// Crystallize is reachable) and requires the carrot to be paid in full.
func TestFullBarLowStillPaysTheTierInvariantCarrot(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cz5-alice")
	flagger := testutils.TestAddress("cz5-flagger")
	eve := testutils.TestAddress("cz5-eve")   // 3 CC low
	frank := testutils.TestAddress("cz5-frank") // 2.5 CC mid -> low share 6/11
	c := testCourt(cur, "cz5", alice, 50_000_000_000)
	c.coin.Mint(flagger, 1_000_000_000)
	c.coin.Mint(eve, 3_000_000_000)
	c.coin.Mint(frank, 2_500_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "cz5", "A full-bar low still pays its voters")
	matureOI(cur, "cz5", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "cz5", id, sideYES)
	testing.SetRealm(testing.NewUserRealm(flagger))
	OpenFlag(cross(cur), "cz5", id)
	testing.SetRealm(testing.NewUserRealm(eve))
	VoteQuality(cross(cur), "cz5", id, qualityLow)
	testing.SetRealm(testing.NewUserRealm(frank))
	VoteQuality(cross(cur), "cz5", id, qualityMid)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "cz5", id)
	cs := mustClaim(c, id)
	_, fullBar := qualityBars(c, cs)
	if cs.conclusiveTurnout < fullBar || cs.tier != tierLowX || cs.pendingSlash != 0 {
		t.Fatalf("setup: need a full-bar T2 low with no reserve: turnout=%d bar=%d "+
			"tier=%d pending=%d", cs.conclusiveTurnout, fullBar, cs.tier, cs.pendingSlash)
	}
	SettleUndisputed(cross(cur), "cz5", id)
	testing.SkipHeights(priorityWindowBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "cz5", id)
	w, a, ans, carrot := DrawSlices("cz5", id)
	if w != 0 || a != 0 || ans != 0 {
		t.Fatalf("tier low still draws nothing: %d/%d/%d", w, a, ans)
	}
	if carrot <= 0 {
		t.Fatal("above the full bar the carrot is tier-invariant and must be paid")
	}

	// Two guards on the STANDALONE branch, both found surviving. This is the fixture
	// that has a live pot to take, so it is where they belong.
	//
	// First: the electorate is the tally's own voters. A complete non-voter is refused.
	gus := testutils.TestAddress("cz5-gus") // never voted on anything
	testing.SetRealm(testing.NewUserRealm(gus))
	uassert.AbortsContains(t, cur, "conclusive quality tally", func() {
		PullCarrot(cross(cur), "cz5", id)
	})

	// Second: the carrot is a POT, not a per-voter entitlement. That is not a detail —
	// it is the invariant the item-4 econ vet's NO-CHANGE verdict rested on ("the WHOLE
	// electorate together is paid less than one flagger's own bond"), and it had no test.
	// Eve takes her pro-rata share, then the pot is left holding a single unit and
	// Frank — whose own share is of the same order as Eve's — must take only that unit.
	testing.SetRealm(testing.NewUserRealm(eve))
	evesShare := PullCarrot(cross(cur), "cz5", id)
	if evesShare <= 1 {
		t.Fatalf("setup: shares here must exceed a single unit for the clamp arm below "+
			"to mean anything: %d", evesShare)
	}
	cs.carrotPool = 1
	testing.SetRealm(testing.NewUserRealm(frank))
	if share := PullCarrot(cross(cur), "cz5", id); share != 1 {
		t.Fatalf("a share must be clamped to what is left in the pot, not paid in "+
			"full: got %d want 1", share)
	}
	if cs.carrotPool != 0 {
		t.Fatalf("and the pot must be empty afterwards, not negative: %d", cs.carrotPool)
	}
}

// The `decidedPID == 0` clause of v0.55's withholding, pinned. On a DECIDED claim the
// carrot's electorate is the verdict round's with-verdict voters (PullCarrot's first
// branch), who never cast the quality tally at all — so a stale sub-bar
// conclusiveTurnout left over from an earlier dust-low flag must not withhold THEIR
// pot. Reachable exactly as built here: a dust-low flag sets conclusiveTurnout below
// the bar, then a decided round whose ride nobody votes leaves it there while setting
// decidedPID. Without the clause the verdict lane is silently unpaid, and no other
// fixture notices.
func TestDecidedRoundCarrotSurvivesAStaleSubBarTally(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cz6-alice") // author + answerer + staker
	flagger := testutils.TestAddress("cz6-flag")
	eve := testutils.TestAddress("cz6-eve")   // dust low: >= demotionBar, < fullBar
	bob := testutils.TestAddress("cz6-bob")   // disputer
	carol := testutils.TestAddress("cz6-carol") // with-verdict voter, clears quorum
	c := testCourt(cur, "cz6", alice, 50_000_000_000)
	c.coin.Mint(flagger, 1_000_000_000)
	c.coin.Mint(eve, 1_000_000_000)
	c.coin.Mint(bob, 1_000_000_000)
	c.coin.Mint(carol, 5_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "cz6", "a decided round pays its own voters")
	matureOI(cur, "cz6", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "cz6", id, sideYES)
	c.params.escrowMinBlocks = 900_000
	c.params.escrowMaxBlocks = 900_000

	// Round 1 fails quorum: opens the escrow window for the decided round below.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "cz6", id)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "cz6", id)

	// A DUST low leaves conclusiveTurnout below the bar (and levies no slash).
	testing.SetRealm(testing.NewUserRealm(flagger))
	OpenFlag(cross(cur), "cz6", id)
	testing.SetRealm(testing.NewUserRealm(eve))
	VoteQuality(cross(cur), "cz6", id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "cz6", id)
	cs := mustClaim(c, id)
	_, fullBar := qualityBars(c, cs)
	if cs.conclusiveSeq == 0 || cs.conclusiveTurnout >= fullBar || cs.pendingSlash != 0 {
		t.Fatalf("setup: need a stale SUB-BAR conclusive tally and no reserve: seq=%d "+
			"turnout=%d bar=%d pending=%d", cs.conclusiveSeq, cs.conclusiveTurnout,
			fullBar, cs.pendingSlash)
	}

	// A decided round whose quality ride nobody votes: decidedPID lands, the stale
	// sub-bar conclusiveTurnout stays.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "cz6", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "cz6", id, "no")
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "cz6", id)
	if cs.decidedPID == 0 || cs.conclusiveTurnout >= fullBar {
		t.Fatalf("setup: need a decided round over a stale sub-bar tally: pid=%d turnout=%d",
			cs.decidedPID, cs.conclusiveTurnout)
	}

	testing.SkipHeights(EscrowUntil("cz6", id) - runtimeHeight())
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "cz6", id)
	testing.SkipHeights(priorityWindowBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "cz6", id)

	if _, _, _, carrot := DrawSlices("cz6", id); carrot <= 0 {
		t.Fatalf("a decided round's carrot must survive a stale sub-bar quality tally: %d",
			carrot)
	}
	// And the verdict voter can actually take it.
	testing.SetRealm(testing.NewUserRealm(carol))
	if share := PullCarrot(cross(cur), "cz6", id); share <= 0 {
		t.Fatalf("the with-verdict voter must be paid: %d", share)
	}
}

// The 24h quiet window (Q6), found SURVIVING by the mutation harness: replacing
// `now < cs.lastFlagEventAt+priorityWindowBlocks` with `if false` failed no test.
// The window exists so Crystallize cannot RACE a flag event — every flag close,
// reopen and void restamps lastFlagEventAt precisely so the draw cannot be frozen
// in the same breath as a quality outcome that a party has not had time to react to.
// Nothing pinned it, so nothing objected to removing the reaction period entirely.
func TestCrystallizeWaitsOutTheQuietWindow(cur realm, t *testing.T) {
	alice := testutils.TestAddress("qw-alice")
	flagger := testutils.TestAddress("qw-flag")
	voter := testutils.TestAddress("qw-voter")
	c := testCourt(cur, "qwin", alice, 50_000_000_000)
	c.coin.Mint(flagger, 10_000_000_000)
	c.coin.Mint(voter, 20_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "qwin", "the draw waits for the reaction period")
	matureOI(cur, "qwin", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "qwin", id, sideYES)

	// A conclusive MID flag: consumes the slot, restamps lastFlagEventAt at its close.
	testing.SetRealm(testing.NewUserRealm(flagger))
	OpenFlag(cross(cur), "qwin", id)
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteQuality(cross(cur), "qwin", id, qualityMid)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "qwin", id)
	SettleUndisputed(cross(cur), "qwin", id)

	cs := mustClaim(c, id)
	if cs.lastFlagEventAt == 0 {
		t.Fatal("setup: the flag close must restamp the quiet-window anchor")
	}
	// Inside the window: refused, even for a participant with everything else ready.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "24h quiet window", func() {
		Crystallize(cross(cur), "qwin", id)
	})
	if cs.crystallized {
		t.Fatal("a refused Crystallize must not have crystallized")
	}
	// One block short is still short — the boundary, not just the middle.
	testing.SkipHeights(priorityWindowBlocks - 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "24h quiet window", func() {
		Crystallize(cross(cur), "qwin", id)
	})
	// And once it passes, the same call succeeds — so the guard is a delay, not a bar.
	testing.SkipHeights(2)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "qwin", id)
	if !cs.crystallized {
		t.Fatal("past the quiet window the draw must crystallize")
	}
}

// capBonus's F9 bound, found SURVIVING: multiplying it by 1000 failed no test, because
// TestF9CapHeadroomAtTheExtreme establishes the cap is UNREACHABLE by natural flow
// (~9x headroom at the extreme). That makes it defence rather than a live clamp — but
// capBonus is a pure function taking its inputs as arguments, so the clamp itself is
// testable directly without crafting protocol state the design forbids.
func TestCapBonusClampsToTheF9Bound(cur realm, t *testing.T) {
	cs := &claimState{tier: tierMidX, openBlocks: 1}
	// rawAvg = 100, tier 1 -> bound = 50.
	if got := capBonus(cs, 1_000, 0, 100); got != 50 {
		t.Fatalf("gross above the bound must clamp to (tier x rawAvg)/2: got %d want 50", got)
	}
	// Below the bound, gross passes through untouched.
	if got := capBonus(cs, 10, 0, 100); got != 10 {
		t.Fatalf("gross below the bound is unchanged: got %d want 10", got)
	}
	// The bound scales with the tier: HIGH doubles it.
	cs.tier = tierHighX
	if got := capBonus(cs, 1_000, 0, 100); got != 100 {
		t.Fatalf("the bound is tier-scaled: got %d want 100", got)
	}
	// At tier LOW the bound is zero, so nothing is payable — the same reason a low
	// tier zeroes the draw.
	cs.tier = tierLowX
	if got := capBonus(cs, 1_000, 0, 100); got != 0 {
		t.Fatalf("tier LOW bounds the bonus to zero: got %d", got)
	}
	// And the floor: a negative gross never becomes a payout.
	cs.tier = tierMidX
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
	// A conclusive MID keeps the tier at 1 so D > 0 and every slice is payable.
	testing.SetRealm(testing.NewUserRealm(flagger))
	OpenFlag(cross(cur), "p7s", id)
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteQuality(cross(cur), "p7s", id, qualityMid)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "p7s", id)
	SettleUndisputed(cross(cur), "p7s", id)
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
	if cs.tier <= 0 {
		t.Fatalf("setup: an undisputed mid claim must carry a positive tier, got %d",
			cs.tier)
	}
	// The bound is tier x b0 / 2 and the natural fixture sits UNDER it, exactly as
	// the happy path asserts. So drive the bound down to half the slice instead of
	// driving the slice up past the bound: clamping DOWN keeps the mint smaller
	// than one the reservoir has already funded, whereas an inflated draw would
	// test the cap against the emission budget as much as against the cap.
	if natural := cs.tier * cs.answerBond0 / 2; ans > natural {
		t.Fatalf("this fixture assumes the cap is slack (slice %d, bound %d); it now "+
			"binds on its own, so assert the natural value instead of squeezing it",
			ans, natural)
	}
	cs.answerBond0 = ans / cs.tier
	want := cs.tier * cs.answerBond0 / 2
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

	testing.SkipHeights(EscrowUntil("cvd1", id) - runtimeHeight())
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
