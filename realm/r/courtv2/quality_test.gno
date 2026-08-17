package courtv2

import (
	"math/bits"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// convForCC crafts a u128 conviction accumulator whose convToCC is exactly cc
// (base units) — the inverse of convToCC's ÷(periodBlocks·1e10), for tests that
// inject a known winning-pool midGross.
func convForCC(cc int64) (hi, lo uint64) {
	den := uint64(periodBlocks) * 10_000 * 1_000_000
	return bits.Mul64(uint64(cc), den)
}

// qfSetup: alice authors+answers (participant), bob is a free wallet, carol
// carries big aged weight (20k CC), dust carries tiny aged weight (0.05 CC).
func qfSetup(cur realm, t *testing.T, slug string) (c *Court, id uint64, alice, bob, carol, dust address) {
	t.Helper()
	alice = testutils.TestAddress(slug + "-alice")
	bob = testutils.TestAddress(slug + "-bob")
	carol = testutils.TestAddress(slug + "-carol")
	dust = testutils.TestAddress(slug + "-dust")
	c = testCourt(cur, slug, alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)
	c.coin.Mint(dust, 50_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id = OpenClaim(cross(cur), slug, "Quality lane on "+slug)
	matureOI(cur, slug, id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), slug, id, sideYES)
	return
}

func TestFlagInconclusiveReopensAndDoubles(cur realm, t *testing.T) {
	c, id, alice, bob, _, dust := qfSetup(cur, t, "qf1")

	b0 := FlagBondNext("qf1", id)
	xbar := XBarFrozen("qf1", id)
	if want := xbar * flagBondXBps / 10000; b0 != want || b0 < flagMinCC {
		t.Fatalf("b0 = max(min, 2%% xbar): got %d want %d", b0, want)
	}

	bobBefore := c.coin.BalanceOf(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "qf1", id)
	uassert.AbortsContains(t, cur, "already open", func() {
		OpenFlag(cross(cur), "qf1", id)
	})
	// Participants cannot vote their own claim's quality (Q2).
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "participants cannot vote", func() {
		VoteQuality(cross(cur), "qf1", id, qualityLow)
	})
	// A dust-weight low: directionally backed, below the demotion bar.
	testing.SetRealm(testing.NewUserRealm(dust))
	VoteQuality(cross(cur), "qf1", id, qualityLow)
	uassert.AbortsContains(t, cur, "already voted", func() {
		VoteQuality(cross(cur), "qf1", id, qualityLow)
	})
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "still open", func() {
		ResolveFlag(cross(cur), "qf1", id)
	})

	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "qf1", id)
	// T1: inconclusive-LOW returns the bond IN FULL; the slot reopens ×2 but
	// enters a cooldown first (M3-MED-1: back-to-back dust-low re-flags would
	// otherwise block Crystallize for free).
	if c.coin.BalanceOf(bob) != bobBefore {
		t.Fatal("inconclusive-low must return the whole bond (T1)")
	}
	if FlagCycles("qf1", id) != 1 || FlagState("qf1", id) != "cooldown" {
		t.Fatalf("the slot reopens with a counted cycle, in cooldown: %s", FlagState("qf1", id))
	}
	if FlagBondNext("qf1", id) != 2*b0 {
		t.Fatalf("the reopened bond doubles: %d", FlagBondNext("qf1", id))
	}
	// Re-flag refused during the cooldown; allowed once it lapses.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "cooldown after an inconclusive", func() {
		OpenFlag(cross(cur), "qf1", id)
	})
	testing.SkipHeights(flagCooldownBlocks + 1)
	if FlagState("qf1", id) != "open" {
		t.Fatal("the slot re-opens after the cooldown lapses")
	}
}

func TestConclusiveMidConsumesSlotAndBurnsBond(cur realm, t *testing.T) {
	c, id, _, bob, carol, _ := qfSetup(cur, t, "qf2")
	bond := FlagBondNext("qf2", id)
	bobBefore := c.coin.BalanceOf(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "qf2", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "qf2", id, qualityMid) // 20k CC >= the full bar
	testing.SkipHeights(c.params.votingBlocks + 1)

	supplyBefore := c.coin.TotalSupply()
	ResolveFlag(cross(cur), "qf2", id)
	if got := supplyBefore - c.coin.TotalSupply(); got != bond {
		t.Fatalf("a wrong flag's bond burns whole: %d vs %d", got, bond)
	}
	if c.coin.BalanceOf(bob) != bobBefore-bond {
		t.Fatal("the flagger paid the bond")
	}
	tier, final := QualityTier("qf2", id)
	if tier != qualityMid || !final || FlagState("qf2", id) != "consumed" {
		t.Fatal("conclusive mid: tier final, slot consumed")
	}
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "consumed", func() {
		OpenFlag(cross(cur), "qf2", id)
	})
}

func TestSlashLowReservesFromAnswerBond(cur realm, t *testing.T) {
	c, id, alice, bob, carol, _ := qfSetup(cur, t, "qf3")
	xbar := XBarFrozen("qf3", id)
	ab := AnswerBond("qf3", id)
	bond := FlagBondNext("qf3", id)
	dep := c.params.minClaimDepositCC
	fee := dep * depositFeeBps / 10000

	bobBefore := c.coin.BalanceOf(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "qf3", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "qf3", id, qualityLow) // full bar + 2/3 low, undisputed
	testing.SkipHeights(c.params.votingBlocks + 1)

	supplyBefore := c.coin.TotalSupply()
	ResolveFlag(cross(cur), "qf3", id)
	// Bond returned (conclusive low), deposit+fee burned NOW, slash RESERVED.
	if c.coin.BalanceOf(bob) != bobBefore {
		t.Fatal("a conclusive-low flagger gets the bond back")
	}
	if got := supplyBefore - c.coin.TotalSupply(); got != dep+fee {
		t.Fatalf("dust burns now are deposit+fee: %d vs %d", got, dep+fee)
	}
	tier, final := QualityTier("qf3", id)
	if tier != qualityLow || final {
		t.Fatal("slash-grade low is NOT final until the counter window closes")
	}
	if FlagState("qf3", id) != "counter-window" {
		t.Fatal("the slash escrows one counter-flag window")
	}
	wantSlash := xbar * slashXBps / 10000
	cs := mustClaim(c, id)
	if cs.pendingSlash != wantSlash || cs.answerBond != ab-wantSlash {
		t.Fatalf("slash reserves from the answer bond: %d/%d", cs.pendingSlash, cs.answerBond)
	}
	// The dust bounty (min(bond, 80% x dust burns)) is senior-queued already.
	wantBounty := (dep + fee) * compOfBurnBps / 10000
	if wantBounty > bond {
		wantBounty = bond
	}
	if got := SeniorOwed("qf3"); got != wantBounty {
		t.Fatalf("dust bounty owed %d, want %d", got, wantBounty)
	}
	// Author's deposit is gone for good (exactly-once already zeroed).
	if cs.deposit != 0 || cs.fee != 0 {
		t.Fatal("deposit and fee must be zeroed at the burn")
	}
	_ = alice
}

func TestDisputeVoidsOpenFlagAndRideCarriesQuality(cur realm, t *testing.T) {
	c, id, _, bob, carol, dust := qfSetup(cur, t, "qf4")
	testing.SetRealm(testing.NewUserRealm(dust))
	dustBefore := c.coin.BalanceOf(dust)
	OpenFlag(cross(cur), "qf4", id)
	if c.coin.BalanceOf(dust) == dustBefore {
		t.Fatal("the flag bond escrows")
	}
	// A dispute arrives mid-flag: the flag VOIDS — bond whole, slot open.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "qf4", id)
	if c.coin.BalanceOf(dust) != dustBefore {
		t.Fatal("a voided flag returns the whole bond")
	}
	if FlagState("qf4", id) != "open" || FlagCycles("qf4", id) != 0 {
		t.Fatal("a voided flag neither consumes the slot nor counts a cycle")
	}
	// No new flag while the dispute runs; quality votes ride the dispute.
	testing.SetRealm(testing.NewUserRealm(dust))
	uassert.AbortsContains(t, cur, "dispute is open", func() {
		OpenFlag(cross(cur), "qf4", id)
	})
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "qf4", id, qualityHigh) // 2/3 + full bar via the ride
	VoteDispute(cross(cur), "qf4", id, "no")        // uphold with quorum
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "qf4", id)
	tier, final := QualityTier("qf4", id)
	if tier != qualityHigh || !final {
		t.Fatal("a decided round's ride settles quality (high: 2/3 + bar)")
	}
	if FlagState("qf4", id) != "consumed" {
		t.Fatal("a conclusive ride consumes the slot")
	}
}

// slashSetup drives qfSetup into a reserved slash: carol's full-bar 2/3-low.
func slashSetup(cur realm, t *testing.T, slug string) (c *Court, id uint64, alice, bob, carol address, slash, bond int64) {
	t.Helper()
	var dust address
	c, id, alice, bob, carol, dust = qfSetup(cur, t, slug)
	_ = dust
	bond = FlagBondNext(slug, id)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), slug, id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), slug, id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), slug, id)
	slash = XBarFrozen(slug, id) * slashXBps / 10000
	return
}

func TestSlashWindowClosesUnchallenged(cur realm, t *testing.T) {
	c, id, _, _, _, slash, bond := slashSetup(cur, t, "qf5")
	dep := c.params.minClaimDepositCC
	fee := dep * depositFeeBps / 10000
	dustPaid := SeniorOwed("qf5") // min(bond, 80% x (dep+fee))

	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("qf5-x")))
	uassert.AbortsContains(t, cur, "window is still open", func() {
		ResolveSlashWindow(cross(cur), "qf5", id)
	})
	cs := mustClaim(c, id)
	testing.SkipHeights(cs.pendingSlashUntil - runtimeHeight() + 1)
	supplyBefore := c.coin.TotalSupply()
	ResolveSlashWindow(cross(cur), "qf5", id)
	if got := supplyBefore - c.coin.TotalSupply(); got != slash {
		t.Fatalf("the unchallenged slash burns whole: %d vs %d", got, slash)
	}
	_, final := QualityTier("qf5", id)
	if !final || cs.pendingSlash != 0 || FlagState("qf5", id) != "consumed" {
		t.Fatal("the window close finalizes the low")
	}
	// Bounty tops up to min(bond, 80% x (dep+fee+slash)) total.
	wantTotal := (dep + fee + slash) * compOfBurnBps / 10000
	if wantTotal > bond {
		wantTotal = bond
	}
	if got := SeniorOwed("qf5"); got != wantTotal {
		t.Fatalf("bounty total %d, want %d (dust was %d)", got, wantTotal, dustPaid)
	}
	uassert.AbortsContains(t, cur, "no slash is pending", func() {
		ResolveSlashWindow(cross(cur), "qf5", id)
	})
}

func TestCounterRevoteOverturnsSlash(cur realm, t *testing.T) {
	c, id, alice, bob, carol, slash, _ := slashSetup(cur, t, "qf6")
	ab := AnswerBond("qf6", id) // already slash-reduced
	dustPaid := SeniorOwed("qf6")

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "only the slashed answerer", func() {
		CounterFlag(cross(cur), "qf6", id)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	CounterFlag(cross(cur), "qf6", id)
	uassert.AbortsContains(t, cur, "already", func() {
		CounterFlag(cross(cur), "qf6", id)
	})
	// Maximal mobilization: carol re-votes MID at the full bar.
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "qf6", id, qualityMid)
	testing.SkipHeights(c.params.votingBlocks + 1)
	supplyBefore := c.coin.TotalSupply()
	ResolveCounter(cross(cur), "qf6", id)
	if c.coin.TotalSupply() != supplyBefore {
		t.Fatal("an overturned slash burns nothing")
	}
	if AnswerBond("qf6", id) != ab+slash {
		t.Fatal("the slash reserve rejoins the answer bond")
	}
	tier, final := QualityTier("qf6", id)
	if tier != qualityLow || !final {
		t.Fatal("the dust low stands final; only the slash fell")
	}
	if SeniorOwed("qf6") != dustPaid {
		t.Fatal("no bounty top-up on an overturned slash")
	}
}

func TestCounterRevoteInconclusiveSlashStands(cur realm, t *testing.T) {
	c, id, alice, _, _, slash, _ := slashSetup(cur, t, "qf7")
	testing.SetRealm(testing.NewUserRealm(alice))
	CounterFlag(cross(cur), "qf7", id)
	// Nobody shows up: the absent electorate does not rescue the answerer.
	testing.SkipHeights(c.params.votingBlocks + 1)
	supplyBefore := c.coin.TotalSupply()
	ResolveCounter(cross(cur), "qf7", id)
	if got := supplyBefore - c.coin.TotalSupply(); got != slash {
		t.Fatalf("an inconclusive re-vote lets the slash stand: %d vs %d", got, slash)
	}
	if _, final := QualityTier("qf7", id); !final {
		t.Fatal("the close finalizes")
	}
}

// The one reachable dispute-supersedes-slash chain: a FAILED round leaves
// decidedRounds==0 (slashable) with a standing escrow window; the flag slash
// lands; a REOPEN dispute then decides — the slash must refund into the bond
// before the round disposes it (unslash), and the upheld answerer exits whole
// on the bond while the dust low keeps the deposit.
func TestReopenDisputeSupersedesPendingSlash(cur realm, t *testing.T) {
	alice := testutils.TestAddress("qf8-alice")
	bob := testutils.TestAddress("qf8-bob")
	carol := testutils.TestAddress("qf8-carol")
	c := testCourt(cur, "qf8", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "qf8", "Slash superseded")
	matureOI(cur, "qf8", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "qf8", id, sideYES)
	ab := AnswerBond("qf8", id)
	c.params.escrowMinBlocks = 700_000 // room for flag vote + reopen inside escrow
	c.params.escrowMaxBlocks = 700_000

	// Round 1 fails quorum: provisional defaults, decidedRounds stays 0.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "qf8", id)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "qf8", id)
	if FailedRounds("qf8", id) != 1 {
		t.Fatal("round 1 must fail quorum")
	}
	// Flag → slash-low reserves from the bond.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "qf8", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "qf8", id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "qf8", id)
	cs := mustClaim(c, id)
	if cs.pendingSlash <= 0 {
		t.Fatal("the slash must reserve (failed rounds keep decidedRounds 0)")
	}
	slash := cs.pendingSlash

	// Reopen and win it — but NOBODY rides the quality question, so the round
	// adjudicated the verdict and nothing else. v0.47: the slash SURVIVES. (This
	// test previously asserted the opposite — "the upheld bond returns whole,
	// slash included" — which was the attacker's payoff encoded as a green test:
	// opening a round used to unslash unconditionally, so a reopen erased an
	// adjudicated slash and slotConsumed barred any replacement flag.)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "qf8", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "qf8", id, "no")
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "qf8", id)
	if cs.pendingSlash != slash || cs.answerBond != ab-slash {
		t.Fatalf("a ride that adjudicated nothing must not erase the slash: %d/%d want %d/%d",
			cs.pendingSlash, cs.answerBond, slash, ab-slash)
	}
	if cs.counterUsed {
		t.Fatal("a stranger's dispute must not spend the answerer's counter re-vote")
	}
	if cs.pendingSlashUntil <= runtimeHeight() {
		t.Fatal("the surviving reserve must get a fresh counter-flag window")
	}

	// Finalize returns the bond LESS the standing reserve; the reserve then burns.
	testing.SkipHeights(EscrowUntil("qf8", id) - runtimeHeight())
	aliceBefore := c.coin.BalanceOf(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "qf8", id)
	if c.coin.BalanceOf(alice) != aliceBefore+ab-slash {
		t.Fatalf("the upheld bond returns less the standing slash: got %d want %d",
			c.coin.BalanceOf(alice), aliceBefore+ab-slash)
	}
	// The long escrow skip above already outran the re-armed window; only wait
	// when it has not lapsed yet (SkipHeights refuses to go backwards).
	if now := runtimeHeight(); now < cs.pendingSlashUntil {
		testing.SkipHeights(cs.pendingSlashUntil - now + 1)
	}
	supplyBefore := c.coin.TotalSupply()
	ResolveSlashWindow(cross(cur), "qf8", id)
	if got := supplyBefore - c.coin.TotalSupply(); got != slash {
		t.Fatalf("the surviving slash must burn: %d want %d", got, slash)
	}
}

// The rescue arm of disposeSlashOnRide: a reopen whose ride DOES clear the
// slash's own bar (full bar, low short of ⅔) lifts the slash — the ride is the
// counter re-vote, before a strictly larger electorate, so it is scored on
// ResolveCounter's exact test. Pins that v0.47 did not simply make slashes
// unliftable.
func TestReopenRideAtFullBarLiftsTheSlash(cur realm, t *testing.T) {
	alice := testutils.TestAddress("qfa-alice")
	bob := testutils.TestAddress("qfa-bob")
	carol := testutils.TestAddress("qfa-carol")
	c := testCourt(cur, "qfa", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "qfa", "Slash lifted by the ride")
	matureOI(cur, "qfa", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "qfa", id, sideYES)
	ab := AnswerBond("qfa", id)
	c.params.escrowMinBlocks = 700_000
	c.params.escrowMaxBlocks = 700_000

	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "qfa", id)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "qfa", id) // failed quorum: decidedRounds stays 0
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "qfa", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "qfa", id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "qfa", id)
	cs := mustClaim(c, id)
	if cs.pendingSlash <= 0 {
		t.Fatal("setup: the slash must reserve")
	}

	// Reopen, and this time the electorate rides quality at the FULL bar with no
	// ⅔-low: the same test ResolveCounter applies, so the slash lifts.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "qfa", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "qfa", id, "no")
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "qfa", id, qualityMid)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "qfa", id)
	if cs.pendingSlash != 0 || cs.answerBond != ab {
		t.Fatalf("a full-bar non-⅔-low ride lifts the slash: %d/%d want 0/%d",
			cs.pendingSlash, cs.answerBond, ab)
	}
}

// v0.40: the draw-proportional slash sizer — floor binds at low conviction, the
// 1.6× draw arm binds when the winning pool's mid draw is large, and it reads
// the answer side's pool.
func TestSlashSizeForDrawProportional(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sd-alice")
	c := testCourt(cur, "sd1", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "sd1", "slash sizer")
	cs := mustClaim(c, id)
	cs.answer = sideYES
	cs.xBarFrozen = 100_000_000 // 100 CC → flat floor 4.5 CC
	flat := cs.xBarFrozen * slashXBps / 10000

	// No conviction → floor binds.
	if got := slashSizeFor(cs); got != flat {
		t.Fatalf("floor must bind at zero conviction: got %d want %d", got, flat)
	}
	// midGross = 20 CC → draw arm 1.6×20 = 32 CC binds over the 4.5 CC floor.
	cs.yesConvHi, cs.yesConvLo = convForCC(20_000_000)
	if mg := convToCC(cs.yesConvHi, cs.yesConvLo); mg != 20_000_000 {
		t.Fatalf("crafted midGross: got %d", mg)
	}
	want := int64(20_000_000) * slashDrawBps / 10000 // 32 CC
	if got := slashSizeFor(cs); got != want || got <= flat {
		t.Fatalf("draw arm must bind: got %d want %d (flat %d)", got, want, flat)
	}
	// The sizer does NOT clamp to the bond — the caller does. A huge pool
	// returns a size far above a small bond (documents why the clamp exists).
	cs.yesConvHi, cs.yesConvLo = convForCC(10_000_000_000) // 10k CC
	if got := slashSizeFor(cs); got <= cs.xBarFrozen*answerBondBps/10000 {
		t.Fatal("the sizer must return the unclamped draw size; the caller clamps to the bond")
	}
	// The NO-side answer reads the (empty) NO pool → floor.
	cs.answer = sideNO
	if got := slashSizeFor(cs); got != flat {
		t.Fatal("a NO answer must read the NO pool, not the (large) YES pool")
	}
}

// v0.40: at settle the retained reserve is the draw-proportional size (not the
// flat floor) when the winning pool's draw is large — and it clamps to the bond.
func TestSlashReserveDrawProportionalAtSettle(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sr-alice")
	bob := testutils.TestAddress("sr-bob")
	c := testCourt(cur, "sr1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "sr1", "draw-proportional settle reserve")
	matureOI(cur, "sr1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "sr1", id, sideNO, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "sr1", id, sideYES)
	cs := mustClaim(c, id)
	bond0 := cs.answerBond0
	flat := cs.xBarFrozen * slashXBps / 10000

	// Inject a winning-pool midGross of 0.2·X̄ (draw arm 0.32·X̄ — binds over the
	// 0.045·X̄ floor, stays under the 0.5·X̄ bond, so no clamp).
	cs.yesConvHi, cs.yesConvLo = convForCC(cs.xBarFrozen / 5)
	want := slashSizeFor(cs)
	if want <= flat {
		t.Fatalf("draw arm must bind: want %d flat %d", want, flat)
	}
	if want >= bond0 {
		t.Fatalf("this case must stay under the bond (no clamp): want %d bond0 %d", want, bond0)
	}
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "sr1", id)
	if cs.answerBond != want {
		t.Fatalf("settle must retain the draw-proportional reserve: got %d want %d", cs.answerBond, want)
	}
	// The rest of the bond returned to the answerer.
	if cs.answerBond >= bond0 {
		t.Fatal("most of the bond should have returned; only the reserve is held")
	}
}

// audit_slash_v040 LOW: a conclusive-low flag resolving BEFORE settle must not
// have its low tier reset to mid by SettleUndisputed — the junk claim draws 0,
// not a full mid draw.
func TestConclusiveLowSurvivesLateSettle(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cl-alice")
	bob := testutils.TestAddress("cl-bob")
	carol := testutils.TestAddress("cl-carol")
	c := testCourt(cur, "cl1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "cl1", "junk that gets flagged before settle")
	matureOI(cur, "cl1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "cl1", id, sideYES)

	// The flag resolves conclusive-low FIRST (nobody settled yet).
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "cl1", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "cl1", id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "cl1", id)
	if tier, _ := QualityTier("cl1", id); tier != qualityLow {
		t.Fatal("the flag must land conclusive-low")
	}

	// NOW settle (permissionless, still callable — verdictAt was never set).
	SettleUndisputed(cross(cur), "cl1", id)
	if tier, _ := QualityTier("cl1", id); tier != qualityLow {
		t.Fatal("settle must NOT reset a conclusive-low tier back to mid")
	}

	// Close the counter window, then crystallize: the low tier means D = 0.
	cs := mustClaim(c, id)
	testing.SkipHeights(cs.pendingSlashUntil - runtimeHeight() + 1)
	ResolveSlashWindow(cross(cur), "cl1", id)
	testing.SkipHeights(priorityWindowBlocks + 1) // 24h quiet
	testing.SkipHeights(periodBlocks)             // a budget to draw from, if any
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "cl1", id)
	if w, a, ans, _ := DrawSlices("cl1", id); w != 0 || a != 0 || ans != 0 {
		t.Fatalf("a conclusive-low claim must draw nothing: %d/%d/%d", w, a, ans)
	}
}

// TestConclusiveLowSurvivesLateFinalize is the Finalize twin of the test above
// (audit convergence v0.42). A slash-grade conclusive-LOW flag leaves
// slotConsumed=true but tierFinal=false for its counter-flag window; a FAILED
// dispute round leaves verdictAt=0 and decidedRounds=0, so Finalize is callable
// in that window. Finalize's tier reset must honor the conclusive low — without
// the &&!slotConsumed guard it clobbers LOW→MID and the junk claim draws full mid.
func TestConclusiveLowSurvivesLateFinalize(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cf-alice")
	bob := testutils.TestAddress("cf-bob")
	carol := testutils.TestAddress("cf-carol")
	c := testCourt(cur, "cf1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)
	// Pin a tiny escrow window so it lapses well before the flag's counter-flag
	// window closes — making Finalize reachable INSIDE that window deterministically,
	// independent of price/xBar (escrowUntil is set once, at ResolveDispute).
	c.params.escrowMinBlocks = 10
	c.params.escrowMaxBlocks = 10

	// Staked + answered, then a dispute that FAILS quorum: the round defaults the
	// verdict to the answer with verdictAt=0 and decidedRounds=0 (Finalize-able,
	// still slash-eligible), and closes the dispute.
	id := stakeAnswerDispute(cur, "cf1", alice, bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "cf1", id)
	testing.SkipHeights(c.params.votingBlocks + 1) // nobody votes → failed quorum
	ResolveDispute(cross(cur), "cf1", id)
	if FailedRounds("cf1", id) != 1 || ProvClose("cf1", id) || DisputeOpen("cf1", id) {
		t.Fatal("one failed round: provisional stands, not provClosed, dispute closed")
	}

	// The crowd flags it conclusive-LOW at the full bar → slash-grade: slotConsumed,
	// tier=low, tierFinal=false, a slash pending in its counter-flag window.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "cf1", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "cf1", id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "cf1", id)
	if tier, final := QualityTier("cf1", id); tier != qualityLow || final {
		t.Fatalf("flag must land slash-grade low (not yet final): tier=%d final=%v", tier, final)
	}
	cs := mustClaim(c, id)
	if cs.pendingSlash <= 0 {
		t.Fatal("a slash must be pending — the counter-flag window is open")
	}

	// Finalize NOW, inside the counter window (escrow lapsed a week ago). A
	// participant (the author staked+answered) may finalize even in the grace week.
	if runtimeHeight() < cs.escrowUntil {
		testing.SkipHeights(cs.escrowUntil - runtimeHeight() + 1)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "cf1", id)
	if tier, _ := QualityTier("cf1", id); tier != qualityLow {
		t.Fatal("Finalize must NOT reset a conclusive-low tier back to mid (the SettleUndisputed twin)")
	}

	// Close the counter window and crystallize: the low tier means D = 0.
	testing.SkipHeights(cs.pendingSlashUntil - runtimeHeight() + 1)
	ResolveSlashWindow(cross(cur), "cf1", id)
	testing.SkipHeights(priorityWindowBlocks + 1) // 24h quiet
	testing.SkipHeights(periodBlocks)             // a budget to draw from, if any
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "cf1", id)
	if w, a, ans, _ := DrawSlices("cf1", id); w != 0 || a != 0 || ans != 0 {
		t.Fatalf("a conclusive-low claim must draw nothing after Finalize: %d/%d/%d", w, a, ans)
	}
}

// DIAGNOSTIC (audit round 2): can a mill bank huge conviction, drain the stake to
// the floor just before answering, and thereby collateralize the slash with a
// tiny bond? The slash is sized off LIFETIME conviction; the bond is sized off the
// 3-HOUR trailing average — and Unstake keeps conviction by design (F9).
func TestDrainedStakeCannotUndercollateralizeTheSlash(cur realm, t *testing.T) {
	alice := testutils.TestAddress("drn-alice")
	c := testCourt(cur, "drn1", alice, 1_000_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "drn1", "Drained before the answer")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "drn1", id, sideYES, 100_000_000_000) // 100k CC
	testing.SkipHeights(11 * periodBlocks)                  // 11 weeks of accrual (< 12wk dead-claim)

	// Drain to the answer floor, then let the 3h window forget the big position.
	testing.SetRealm(testing.NewUserRealm(alice))
	Unstake(cross(cur), "drn1", id, sideYES, 99_900_000_000) // leaves 100 CC = minAnswerX
	testing.SkipHeights(answerWindow + epochBlocks)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "drn1", id, sideYES)

	cs := mustClaim(c, id)
	if got, want := cs.answerBond, slashSizeFor(cs); got < want {
		t.Fatalf("bond must collateralize the slash: bond=%d slash=%d (ratio %dx)", got, want, want/got)
	}
}

// The flat arm must be collateralized too, at ANY court cap. A draw-arm-only
// floor passes every fixture today only because answerBondCapCC is 0 everywhere;
// this pins the invariant against the day that knob is wired.
func TestBondCollateralizesSlashUnderCourtCap(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cap-alice")
	c := testCourt(cur, "cap1", alice, 50_000_000_000)
	// A cap far below the 50%·X̄ arm, so the flat arm would escape a draw-only floor.
	c.params.answerBondCapCC = 1

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "cap1", "Capped-bond claim")
	matureOI(cur, "cap1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "cap1", id, sideYES)

	cs := mustClaim(c, id)
	if got, want := cs.answerBond, slashSizeFor(cs); got < want {
		t.Fatalf("the cap must not un-collateralize the slash: bond=%d slash=%d", got, want)
	}
}

// PostAnswer must refuse a claim past the dead-claim timeout: CloseDeadClaim is
// permissionless but optional, and every X̄-derived bound is derived for a
// <=12-week life (conviction keeps accruing on an un-closed claim).
func TestPostAnswerRefusesPastDeadClaimTimeout(cur realm, t *testing.T) {
	alice := testutils.TestAddress("dct-alice")
	testCourt(cur, "dct1", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "dct1", "Answered far too late")
	matureOI(cur, "dct1", id, alice, 200_000_000)
	testing.SkipHeights(deadClaimTimeout)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "past the dead-claim timeout", func() {
		PostAnswer(cross(cur), "dct1", id, sideYES)
	})
}

// B (round-2 convergence): X̄frozen is the P6 base for every prize/punishment in
// the claim, so it must be drain-resistant. The bond floor alone cannot pin this —
// it repairs the bond and leaves the OTHER consumers reading the drained value.
// Here the same drain is priced off the lifetime average, so the demotion bar can
// no longer be cleared by dust: 25 CC of weight must not be able to zero the draw.
func TestDrainedClaimPricesBarsOffLifetimeStake(cur realm, t *testing.T) {
	alice := testutils.TestAddress("bar-alice")
	c := testCourt(cur, "bar1", alice, 1_000_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "bar1", "Drained, but priced honestly")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "bar1", id, sideYES, 100_000_000_000) // 100k CC
	testing.SkipHeights(11 * periodBlocks)
	testing.SetRealm(testing.NewUserRealm(alice))
	Unstake(cross(cur), "bar1", id, sideYES, 99_900_000_000) // drain to 100 CC
	testing.SkipHeights(answerWindow + epochBlocks)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "bar1", id, sideYES)

	// The frozen base is the lifetime average, not the 100 CC the ring reports.
	xbar := XBarFrozen("bar1", id)
	if xbar < 50_000_000_000 {
		t.Fatalf("X̄frozen must be the drain-resistant lifetime base, got %d", xbar)
	}
	// Therefore the dust-demotion faucet is priced out: the flag bond and the
	// demotion bar both scale with the honest size of the claim.
	if b0 := FlagBondNext("bar1", id); b0 < 1_000_000_000 {
		t.Fatalf("the flag bond must scale with the honest size, got %d", b0)
	}
	cs := mustClaim(c, id)
	if cs.answerBond < slashSizeFor(cs) {
		t.Fatalf("bond must still collateralize the slash: %d < %d", cs.answerBond, slashSizeFor(cs))
	}
}

// v0.47: a DECIDED dispute round buys no slash immunity. dave brings real
// overturn weight (>= floor/4, so the round is credEligible — the strongest form
// of the rejected alternative gate) but carol's larger uphold carries it, and
// NOBODY rides the quality question, so the ride is inconclusive: the round
// adjudicated the ANSWER and never the CLAIM. Reverting slashGrade to
// `decidedRounds == 0` fails the Finalize leg; gating it on `!credEligible`
// instead fails the slash leg. The fixture asserts its own preconditions so it
// degrades loudly rather than silently weakening.
func TestDecidedRoundBuysNoSlashImmunity(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sim-alice")
	bob := testutils.TestAddress("sim-bob")
	carol := testutils.TestAddress("sim-carol")
	dave := testutils.TestAddress("sim-dave")
	c := testCourt(cur, "sim1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)
	c.coin.Mint(dave, 8_000_000_000)
	c.params.escrowMinBlocks, c.params.escrowMaxBlocks = 10, 10

	id := stakeAnswerDispute(cur, "sim1", alice, bob)
	ab := AnswerBond("sim1", id)

	// A decided round: dave votes to overturn with real weight, carol upholds
	// with more (threshold 5001 bps, so a tie never overturns).
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "sim1", id)
	testing.SetRealm(testing.NewUserRealm(dave))
	VoteDispute(cross(cur), "sim1", id, "yes")
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "sim1", id, "no")
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "sim1", id)

	cs := mustClaim(c, id)
	if cs.decidedRounds != 1 || Provisional("sim1", id) != sideYES {
		t.Fatal("fixture: the round must DECIDE and uphold the answer")
	}
	if cs.slotConsumed || cs.tierFinal {
		t.Fatal("fixture: nobody rode quality, so the ride must be inconclusive")
	}
	wantReserve := slashSizeFor(cs) // immutable after the answer (v0.43)

	// LOCKSTEP LEG: a decided round must no longer free the slash reserve.
	testing.SkipHeights(cs.escrowUntil - runtimeHeight() + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "sim1", id)
	if cs.answerBond != wantReserve {
		t.Fatalf("a decided round must not free the reserve: answerBond=%d want %d (bond was %d)",
			cs.answerBond, wantReserve, ab)
	}

	// GATE LEG: a full-bar 2/3-low flag still slashes a contested-and-upheld claim.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "sim1", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "sim1", id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "sim1", id)
	if cs.pendingSlash != wantReserve {
		t.Fatalf("an upheld-but-junk claim must still slash: pendingSlash=%d want %d",
			cs.pendingSlash, wantReserve)
	}
	testing.SkipHeights(cs.pendingSlashUntil - runtimeHeight() + 1)
	supplyBefore := c.coin.TotalSupply()
	ResolveSlashWindow(cross(cur), "sim1", id)
	if got := supplyBefore - c.coin.TotalSupply(); got != wantReserve {
		t.Fatalf("the slash must burn the retained reserve: burned %d want %d", got, wantReserve)
	}
}

// disposeSlashOnRide must score the ride on ResolveCounter's bar, never on mere
// "conclusiveness": applyQualityTally goes conclusive at the demotionBar, which
// has NO supply floor, so a dust ride would otherwise be able to lift a slash
// imposed at the full supply-floored bar. Here a dust voter rides MID — enough
// to be conclusive, far short of fullBar — and the slash must still stand.
func TestDustRideCannotLiftTheSlash(cur realm, t *testing.T) {
	alice := testutils.TestAddress("qfd-alice")
	bob := testutils.TestAddress("qfd-bob")
	carol := testutils.TestAddress("qfd-carol")
	dust := testutils.TestAddress("qfd-dust")
	c := testCourt(cur, "qfd", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)
	c.coin.Mint(dust, 1_000_000_000) // >= demotionBar, << fullBar (5% of supply)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "qfd", "Dust ride cannot rescue")
	matureOI(cur, "qfd", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "qfd", id, sideYES)
	c.params.escrowMinBlocks = 700_000
	c.params.escrowMaxBlocks = 700_000

	// A failed round keeps the claim slashable; the flag then reserves a slash.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "qfd", id)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "qfd", id)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "qfd", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "qfd", id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "qfd", id)
	cs := mustClaim(c, id)
	slash := cs.pendingSlash
	if slash <= 0 {
		t.Fatal("setup: the slash must reserve at the full bar")
	}
	demotionBar, fullBar := qualityBars(c, cs)
	if 1_000_000_000 < demotionBar || 1_000_000_000 >= fullBar {
		t.Fatalf("setup: dust must be conclusive but sub-full-bar (bars %d/%d)", demotionBar, fullBar)
	}

	// Reopen; only dust rides quality, at MID. Conclusive — but nowhere near the
	// bar that imposed the slash, so it adjudicates nothing about the slash.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "qfd", id)
	testing.SetRealm(testing.NewUserRealm(dust))
	VoteQuality(cross(cur), "qfd", id, qualityMid)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "qfd", id, "no")
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "qfd", id)
	if cs.pendingSlash != slash {
		t.Fatalf("a sub-full-bar ride must not lift the slash: %d want %d", cs.pendingSlash, slash)
	}
	// And the dust ride cannot PROMOTE the tier either. resolveQualityRide has no
	// !slotConsumed guard, so two braces hold instead. First, the bar asymmetry
	// inside applyQualityTally: the demotionBar enables a LOW demotion only, while
	// any mid/high outcome needs the full supply-floored bar — so this ride is
	// simply inconclusive and the full-bar LOW stands. Second, since v0.51, the
	// qualityReasked latch: a later round votes the SAME accumulating tally, so a
	// promotion has to out-weigh the standing low rather than start from an empty
	// one. Before that latch the tier was the larger of the two re-rollable prizes
	// — a full-bar MID ride on a wiped tally restored the whole draw — and only the
	// first brace stood in its way. This pins the asymmetry; the latch's own pin is
	// TestSockDisputeCannotEraseTheCounterTally.
	if tier, final := QualityTier("qfd", id); tier != qualityLow || final {
		t.Fatalf("a dust ride must not promote the tier: got tier=%d final=%v", tier, final)
	}
}

// The T2 "failed slash attempt" half-burn branch (v0.45 gap 2) had NO test: every
// conclusive-low fixture is either slash-grade (full bar AND >=2/3 low) or below
// the full bar (dust low, T1 full return). This hits the band between them —
// qLowW/turnout in [1/2, 2/3) at full-bar turnout — where the electorate demoted
// the claim but fell short of the supermajority a slash requires, and the flagger
// pays half the bond for the failed attempt.
func TestConclusiveLowBelowTwoThirdsHalfBurnsTheBond(cur realm, t *testing.T) {
	alice := testutils.TestAddress("t2-alice")
	bob := testutils.TestAddress("t2-bob")     // flagger
	low := testutils.TestAddress("t2-low")     // 10B low
	mid := testutils.TestAddress("t2-mid")     // 8B mid
	c := testCourt(cur, "t2c", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(low, 10_000_000_000)
	c.coin.Mint(mid, 8_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "t2c", "Demoted, but short of the supermajority")
	matureOI(cur, "t2c", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "t2c", id, sideYES)

	bond := FlagBondNext("t2c", id)
	bobBefore := c.coin.BalanceOf(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "t2c", id)
	testing.SetRealm(testing.NewUserRealm(low))
	VoteQuality(cross(cur), "t2c", id, qualityLow)
	testing.SetRealm(testing.NewUserRealm(mid))
	VoteQuality(cross(cur), "t2c", id, qualityMid)
	testing.SkipHeights(c.params.votingBlocks + 1)

	// 10B low of 18B turnout: median-low (10*2 >= 18) but short of 2/3
	// (10*3 = 30 < 36), at full-bar turnout — exactly the T2 band.
	cs := mustClaim(c, id)
	_, fullBar := qualityBars(c, cs)
	turnout := cs.qLowW + cs.qMidW + cs.qHighW
	if turnout < fullBar || cs.qLowW*2 < turnout || cs.qLowW*3 >= turnout*2 {
		t.Fatalf("fixture must sit in [1/2, 2/3) at full-bar turnout: low=%d turnout=%d bar=%d",
			cs.qLowW, turnout, fullBar)
	}

	supplyBefore := c.coin.TotalSupply()
	ResolveFlag(cross(cur), "t2c", id)

	half := bond / 2
	if got := bobBefore - c.coin.BalanceOf(bob); got != bond-half {
		t.Fatalf("a failed slash attempt costs the flagger half the bond: lost %d want %d",
			got, bond-half)
	}
	// Supply drops by the burned half PLUS the dust burns every conclusive low
	// carries (deposit + fee), which are independent of the slash question.
	dep := c.params.minClaimDepositCC
	fee := dep * depositFeeBps / 10000
	if got, want := supplyBefore-c.coin.TotalSupply(), bond-half+dep+fee; got != want {
		t.Fatalf("the other half burns, with the low's deposit+fee: burned %d want %d", got, want)
	}
	if cs.pendingSlash != 0 {
		t.Fatalf("short of 2/3 reserves NO slash: %d", cs.pendingSlash)
	}
	if tier, final := QualityTier("t2c", id); tier != qualityLow || !final {
		t.Fatalf("the claim is still conclusively demoted and final: tier=%d final=%v", tier, final)
	}
}

// REPRO (sweep finding, post-v0.49): v0.47 shut slashGrade's door to purchased
// immunity, but resolveQualityRide's is open. pendingSlash is ORIGINATED in
// exactly one place — ResolveFlag's slashGrade branch — while a conclusive ride
// latches slotConsumed, which OpenFlag refuses forever. So a full-bar 2/3-low
// verdict delivered ON THE RIDE forecloses the only path that could ever levy the
// slash. The mill buys that by sock-disputing in the block after the answer:
// votingBlocks (7d) > settleDelay (72h), so no flag can have resolved, and
// OpenFlag panics while disputeOpen. The honest crowd then does exactly what the
// mechanism asks — upholds the true answer and votes the junk claim LOW — and in
// doing so destroys the slash. EXPECTED TO FAIL until the ride can originate.
func TestConclusiveLowRideMustLevyTheSlash(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rid-alice") // author + answerer (the mill)
	sock := testutils.TestAddress("rid-sock")   // the mill's second wallet
	crowd := testutils.TestAddress("rid-crowd") // honest, full-bar weight
	c := testCourt(cur, "rid1", alice, 50_000_000_000)
	c.coin.Mint(sock, 10_000_000_000)
	c.coin.Mint(crowd, 20_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "rid1", "Junk but true — slash me if you can")
	matureOI(cur, "rid1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "rid1", id, sideYES)
	cs := mustClaim(c, id)
	exposure := slashSizeFor(cs)
	if exposure <= 0 {
		t.Fatal("setup: the claim must carry real slash exposure")
	}

	// The purchase: dispute in the next block, before any flag can exist.
	testing.SetRealm(testing.NewUserRealm(sock))
	OpenDispute(cross(cur), "rid1", id)
	// The honest crowd upholds the true answer AND votes the claim junk.
	testing.SetRealm(testing.NewUserRealm(crowd))
	VoteDispute(cross(cur), "rid1", id, "no")
	testing.SetRealm(testing.NewUserRealm(crowd))
	VoteQuality(cross(cur), "rid1", id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "rid1", id)

	if tier, _ := QualityTier("rid1", id); tier != qualityLow {
		t.Fatalf("setup: the ride must land a conclusive LOW, got tier=%d", tier)
	}
	if !cs.slotConsumed {
		t.Fatal("setup: a conclusive ride latches the flag slot")
	}
	// THE HOLE: a full-bar 2/3-low verdict, and no slash exists or ever can.
	if cs.pendingSlash != exposure {
		t.Fatalf("a full-bar 2/3-low RIDE must levy the slash like the flag lane does: "+
			"pendingSlash=%d want %d (slot consumed=%v, so OpenFlag is refused forever)",
			cs.pendingSlash, exposure, cs.slotConsumed)
	}
	// A conclusive low burns the junk claim's deposit and fee whichever lane asked;
	// skipping them refunded the mill its stake at crystallize.
	if cs.deposit != 0 || cs.fee != 0 {
		t.Fatalf("a conclusive-low ride must burn deposit+fee: %d/%d", cs.deposit, cs.fee)
	}
	// And it pays NO bounty: nobody posted a bond on a ride. Paying cs.flagger here
	// would either strand accrual at the zero address forever (reservedTail is
	// monotone) or mint to a stale flagger whose bond already came back under T1.
	if cs.slashFlagger != "" {
		t.Fatalf("a ride-levied slash has no bounty beneficiary, got %s", cs.slashFlagger)
	}
	// The answerer keeps the one Q5 challenge: tierFinal stays false while it stands.
	if cs.tierFinal {
		t.Fatal("a reserve levied by the ride leaves the counter-flag window open")
	}
}

// The slashLevied latch: origination is exactly-once per claim ACROSS BOTH LANES.
// The flag lane was bounded by slotConsumed, but the ride is not — so without the
// latch a reopen chain levies a fresh slashSizeFor out of the REMAINING bond every
// round, which fits inside a 3-week escrow.
func TestSlashIsLeviedAtMostOncePerClaim(cur realm, t *testing.T) {
	alice := testutils.TestAddress("lev-alice")
	bob := testutils.TestAddress("lev-bob")
	carol := testutils.TestAddress("lev-carol")
	c := testCourt(cur, "lev1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "lev1", "Levy me twice if you can")
	matureOI(cur, "lev1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "lev1", id, sideYES)
	c.params.escrowMinBlocks, c.params.escrowMaxBlocks = 900_000, 900_000

	// A failed round keeps the claim slashable; the FLAG lane then levies.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "lev1", id)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "lev1", id)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "lev1", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "lev1", id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "lev1", id)
	cs := mustClaim(c, id)
	first := cs.pendingSlash
	if first <= 0 || !cs.slashLevied {
		t.Fatalf("setup: the flag lane must levy once: pending=%d levied=%v", first, cs.slashLevied)
	}
	// Close the window: the slash burns and the bond keeps its remainder.
	testing.SkipHeights(cs.pendingSlashUntil - runtimeHeight() + 1)
	ResolveSlashWindow(cross(cur), "lev1", id)
	remainder := cs.answerBond
	if cs.pendingSlash != 0 || remainder <= 0 {
		t.Fatalf("setup: settled, with bond remaining: pending=%d bond=%d", cs.pendingSlash, remainder)
	}

	// A reopen whose ride is ALSO a full-bar 2/3-low must NOT levy a second time.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "lev1", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "lev1", id, "no")
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "lev1", id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "lev1", id)
	if cs.pendingSlash != 0 || cs.answerBond != remainder {
		t.Fatalf("a claim is slashed at most once: pending=%d bond=%d want 0/%d",
			cs.pendingSlash, cs.answerBond, remainder)
	}
}

// levySlash drives a claim to a standing, adjudicated slash reserve: a failed
// round 1 (so decidedRounds stays 0 and the claim is still slashable), then a
// flag whose conclusive ⅔-low reserves from the answer bond. Returns the claim
// and the reserve; the posted bond is cs.answerBond + the reserve.
func levySlash(cur realm, c *Court, slug string, alice, bob, carol address) (*claimState, int64) {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), slug, "a standing slash reserve")
	matureOI(cur, slug, id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), slug, id, sideYES)
	c.params.escrowMinBlocks = 900_000
	c.params.escrowMaxBlocks = 900_000
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), slug, id)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), slug, id)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), slug, id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), slug, id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), slug, id)
	cs := mustClaim(c, id)
	return cs, cs.pendingSlash
}

// v0.51 — THE WIPE WAS THE RE-ROLL. Every reopen used to reset the shared
// quality tally, so a sock bought a fresh coin flip for the price of a dispute
// bond and the honest weight that had already answered the question was erased
// rather than out-voted. The question is now re-asked EXACTLY ONCE after
// anything has been adjudicated (the v0.31/Q5 doctrine, "forces one re-vote");
// every later round and window votes the SAME accumulating tally.
//
// Here the answerer spends that one re-ask themselves and the electorate answers
// low again, decisively. The sock — a fresh wallet, since OpenDispute's
// same-address guard is hygiene only — must now OUT-WEIGH 30 CC of standing low
// with its 8 CC of mid instead of deleting it. Before the fix dave's mid stood
// alone, cleared the full bar unopposed, and refunded the slash.
func TestSockDisputeCannotEraseTheCounterTally(cur realm, t *testing.T) {
	alice := testutils.TestAddress("wp1-alice") // author + answerer
	bob := testutils.TestAddress("wp1-bob")     // round-1 disputer, then flagger
	carol := testutils.TestAddress("wp1-carol") // the honest electorate
	dave := testutils.TestAddress("wp1-dave")   // the answerer's sybil wallet
	c := testCourt(cur, "wp1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 30_000_000_000)
	c.coin.Mint(dave, 8_000_000_000)
	cs, slash := levySlash(cur, c, "wp1", alice, bob, carol)
	if slash <= 0 {
		t.Fatal("setup: the slash must reserve")
	}
	remainder := cs.answerBond

	// The answerer spends their ONE Q5 challenge; the crowd answers low again.
	testing.SetRealm(testing.NewUserRealm(alice))
	CounterFlag(cross(cur), "wp1", cs.id)
	seq := cs.qVoteSeq
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "wp1", cs.id, qualityLow)
	low := cs.qLowW

	// The sock buys a round. It inherits the tally; it does not reset it.
	testing.SetRealm(testing.NewUserRealm(dave))
	OpenDispute(cross(cur), "wp1", cs.id)
	if cs.qVoteSeq != seq {
		t.Fatalf("a later round votes the SAME tally: seq %d want %d", cs.qVoteSeq, seq)
	}
	if cs.qLowW != low {
		t.Fatalf("the honest low weight survives the reopen: %d want %d", cs.qLowW, low)
	}
	testing.SetRealm(testing.NewUserRealm(dave))
	VoteQuality(cross(cur), "wp1", cs.id, qualityMid)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "wp1", cs.id, "no")
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "wp1", cs.id)
	// pendingSlash 0 with the bond still short IS settle; a refund would restore
	// the bond, a re-arm would leave the reserve standing.
	if cs.pendingSlash != 0 || cs.answerBond != remainder {
		t.Fatalf("the accumulated ⅔-low settles the slash: pending=%d bond=%d want 0/%d",
			cs.pendingSlash, cs.answerBond, remainder)
	}
}

// A round must CLOSE a lapsed counter lane, never inherit it. VoteQuality's
// "the counter re-vote has closed" guard is unconditional, so a lane left open
// past counterVoteEnd froze the whole quality lane for the claim: the ride could
// not be voted by anyone, and the reserve's only remaining exit was whatever the
// clock defaulted to. This is the regression pin for that freeze.
func TestLapsedCounterLaneDoesNotFreezeTheRide(cur realm, t *testing.T) {
	alice := testutils.TestAddress("wp2-alice")
	bob := testutils.TestAddress("wp2-bob")
	carol := testutils.TestAddress("wp2-carol")
	dave := testutils.TestAddress("wp2-dave")
	c := testCourt(cur, "wp2", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 30_000_000_000)
	c.coin.Mint(dave, 8_000_000_000)
	cs, slash := levySlash(cur, c, "wp2", alice, bob, carol)
	if slash <= 0 {
		t.Fatal("setup: the slash must reserve")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	CounterFlag(cross(cur), "wp2", cs.id)
	testing.SkipHeights(c.params.votingBlocks + 1) // the lane lapses unresolved
	testing.SetRealm(testing.NewUserRealm(dave))
	OpenDispute(cross(cur), "wp2", cs.id)
	if cs.counterOpen {
		t.Fatal("a round must close a lapsed counter lane, not inherit it")
	}
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "wp2", cs.id, qualityLow) // must not abort
	if cs.qLowW <= 0 {
		t.Fatal("the ride must be votable after a lapsed lane closes")
	}
}

// The QUALITY question has its own, higher bar and can be answered on a round the
// governor's quorum floor rejected. Scoring the ride on the failed-quorum branch
// (v0.51) rather than re-arming blindly is what stops a full-bar rescue tally
// from being discarded and then burned by the unconditional ResolveSlashWindow.
// A below-bar ride still re-arms — TestReopenSupersedesCounter pins that arm.
func TestFailedQuorumRideAtFullBarLiftsTheSlash(cur realm, t *testing.T) {
	alice := testutils.TestAddress("wp3-alice")
	bob := testutils.TestAddress("wp3-bob")
	carol := testutils.TestAddress("wp3-carol")
	dave := testutils.TestAddress("wp3-dave")
	c := testCourt(cur, "wp3", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 30_000_000_000)
	c.coin.Mint(dave, 8_000_000_000)
	cs, slash := levySlash(cur, c, "wp3", alice, bob, carol)
	if slash <= 0 {
		t.Fatal("setup: the slash must reserve")
	}
	ab := cs.answerBond + slash

	// Round 2: nobody votes the VERDICT (it fails quorum) but the crowd rides
	// quality at the full bar with no ⅔-low — ResolveCounter's own rescue test.
	testing.SetRealm(testing.NewUserRealm(dave))
	OpenDispute(cross(cur), "wp3", cs.id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "wp3", cs.id, qualityMid)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "wp3", cs.id)
	if FailedRounds("wp3", cs.id) != 2 {
		t.Fatalf("setup: round 2 must fail quorum, got %d failed", FailedRounds("wp3", cs.id))
	}
	if cs.pendingSlash != 0 || cs.answerBond != ab {
		t.Fatalf("a full-bar non-⅔-low ride lifts the slash even on a quorum-less round: "+
			"pending=%d bond=%d want 0/%d", cs.pendingSlash, cs.answerBond, ab)
	}
}

// The ride's deadline is the governor's own roll. disputeOpen stays true until
// the permissionless ResolveDispute, and nothing else bounded the window — so
// under an accumulating tally a vote landing after the roll closed would persist
// into every later round, letting transaction ordering rather than the
// electorate decide the reserve.
func TestRideVoteClosesWithTheRoll(cur realm, t *testing.T) {
	alice := testutils.TestAddress("wp4-alice")
	bob := testutils.TestAddress("wp4-bob")
	carol := testutils.TestAddress("wp4-carol")
	c := testCourt(cur, "wp4", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 30_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "wp4", "the ride closes with the roll")
	matureOI(cur, "wp4", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "wp4", id, sideYES)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "wp4", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "wp4", id, qualityLow) // in time: fine
	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "the dispute vote has closed", func() {
		VoteQuality(cross(cur), "wp4", id, qualityMid)
	})
}

// v0.51 follow-up (HIGH, found by two independent reviewers): the answerer's ONE
// v0.31/Q5 challenge must be an INDEPENDENT poll, not a continuation of a
// stranger's. Gating CounterFlag on the shared qualityReasked latch made the
// challenge third-party consumable RACE-FREE: ResolveFlag is permissionless, so the
// flagger submits ResolveFlag and OpenDispute at the same height, and CounterFlag
// panics on pendingSlash<=0 before the first and on disputeOpen after the second —
// there is no block in between. The answerer then inherits the ride's tally, and
// because qVoted keys on qVoteSeq|addr a frozen seq LOCKS OUT everyone who already
// voted: an honest elector who changes their mind cannot, and their earlier low
// still counts against the answerer. §3.4's "win ⅔ TWICE, the second against
// maximal mobilization (p² ≈ 0)" collapses to p.
//
// Weights are chosen so the two worlds diverge on the SAME electorate and beliefs:
// carol 0.8xfullBar, dan 0.35xfullBar. carol alone is sub-bar (the ride re-arms);
// carol+dan clears the bar; and carol >= 2xdan, so an inherited carol-low would
// hold the ⅔ and SETTLE where a fresh tally REFUNDS.
func TestCounterFlagAlwaysGetsAnIndependentPoll(cur realm, t *testing.T) {
	alice := testutils.TestAddress("wp5-alice") // author + answerer
	bob := testutils.TestAddress("wp5-bob")     // round-1 disputer, flagger, then sock
	carol := testutils.TestAddress("wp5-carol")
	dan := testutils.TestAddress("wp5-dan")
	c := testCourt(cur, "wp5", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 2_550_000_000)
	c.coin.Mint(dan, 1_115_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "wp5", "the counter re-vote is its own poll")
	matureOI(cur, "wp5", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "wp5", id, sideYES)
	c.params.escrowMinBlocks = 900_000
	c.params.escrowMaxBlocks = 900_000

	// Round 1 fails quorum → decidedRounds stays 0, so the flag can still slash.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "wp5", id)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "wp5", id)

	// The flag: carol AND dan low, over the full bar → conclusive ⅔-low, slash.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "wp5", id)
	for _, v := range []address{carol, dan} {
		testing.SetRealm(testing.NewUserRealm(v))
		VoteQuality(cross(cur), "wp5", id, qualityLow)
	}
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "wp5", id)
	cs := mustClaim(c, id)
	slash := cs.pendingSlash
	if slash <= 0 {
		t.Fatal("setup: the slash must reserve")
	}
	remainder := cs.answerBond

	// A stranger's round lands before the answerer can counter-flag, and spends the
	// ride's one re-ask. carol re-states low, but alone she is sub-bar.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "wp5", id)
	if !cs.qualityReasked {
		t.Fatal("setup: the stranger's round must consume the ride's one re-ask")
	}
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "wp5", id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "wp5", id) // quorum-less: sub-bar ride re-arms
	if cs.pendingSlash != slash {
		t.Fatalf("setup: a sub-bar ride leaves the reserve standing: %d", cs.pendingSlash)
	}

	// THE GUARD: the answerer's challenge opens a FRESH tally regardless.
	seq := cs.qVoteSeq
	testing.SetRealm(testing.NewUserRealm(alice))
	CounterFlag(cross(cur), "wp5", id)
	if cs.qVoteSeq == seq {
		t.Fatal("the answerer's one challenge must open a fresh tally, not inherit the ride's")
	}
	if cs.qLowW != 0 {
		t.Fatalf("a fresh tally starts empty: qLowW=%d", cs.qLowW)
	}
	// carol must be able to vote AGAIN, having voted low on the ride moments ago.
	for _, v := range []address{carol, dan} {
		testing.SetRealm(testing.NewUserRealm(v))
		VoteQuality(cross(cur), "wp5", id, qualityMid)
	}
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveCounter(cross(cur), "wp5", id)
	if cs.pendingSlash != 0 || cs.answerBond != remainder+slash {
		t.Fatalf("a full-bar non-⅔-low challenge refunds the reserve: pending=%d bond=%d want 0/%d",
			cs.pendingSlash, cs.answerBond, remainder+slash)
	}
}

// v0.53 (HIGH regression, found in the post-commit vet of v0.51): a ride may CONFIRM
// a slash only once the answerer has actually been offered their v0.31/Q5 challenge.
// v0.51 replaced the failed-quorum branch's unconditional rearm with a full score,
// which let a quorum-less round SETTLE a reserve while counterUsed was still false —
// annihilating the challenge with no block in which the answerer could act, by the
// same race-free construction v0.52 closed at the counter lane: ResolveFlag is
// permissionless, so the sock's OpenDispute lands in the block the reserve is carved
// in, CounterFlag panics on disputeOpen for the whole round, and after settleSlash it
// panics on pendingSlash <= 0 forever. Half a dispute bond destroyed up to 30.8%·X̄
// plus the poll.
//
// The reserve is NOT forgiven by re-arming: ResolveSlashWindow still settles it
// unconditionally once the window lapses, and the RESCUE arm is untouched (see
// TestFailedQuorumRideAtFullBarLiftsTheSlash) — a ride can still LIFT a slash, it
// just cannot BURN one behind the answerer's back.
func TestQuorumlessRideCannotAnnihilateTheQ5Window(cur realm, t *testing.T) {
	alice := testutils.TestAddress("wp6-alice") // author + answerer
	bob := testutils.TestAddress("wp6-bob")     // round-1 disputer, then flagger
	carol := testutils.TestAddress("wp6-carol") // the honest low bloc
	dave := testutils.TestAddress("wp6-dave")   // the flagger's sock
	c := testCourt(cur, "wp6", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 30_000_000_000)
	c.coin.Mint(dave, 8_000_000_000)
	cs, slash := levySlash(cur, c, "wp6", alice, bob, carol)
	if slash <= 0 || cs.counterUsed {
		t.Fatal("setup: an unspent challenge over a standing reserve")
	}

	// The sock's round makes CounterFlag unreachable for its whole duration, and the
	// low bloc re-states low on the fresh seq — a full-bar ⅔-low ride.
	testing.SetRealm(testing.NewUserRealm(dave))
	OpenDispute(cross(cur), "wp6", cs.id)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "a dispute is open", func() {
		CounterFlag(cross(cur), "wp6", cs.id)
	})
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "wp6", cs.id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1) // nobody votes the VERDICT
	ResolveDispute(cross(cur), "wp6", cs.id)       // failed quorum
	if FailedRounds("wp6", cs.id) != 2 {
		t.Fatalf("setup: the round must fail quorum, got %d", FailedRounds("wp6", cs.id))
	}

	// THE GUARD: the reserve stands on a fresh window, challenge still unspent.
	if cs.pendingSlash != slash {
		t.Fatalf("a quorum-less ride must not burn the reserve before the answerer's "+
			"challenge was ever offered: pending=%d want %d", cs.pendingSlash, slash)
	}
	if cs.counterUsed {
		t.Fatal("the challenge must still be unspent")
	}
	if cs.pendingSlashUntil <= runtimeHeight() {
		t.Fatal("the reserve must get a usable window")
	}
	// And the answerer can now actually use it.
	testing.SetRealm(testing.NewUserRealm(alice))
	CounterFlag(cross(cur), "wp6", cs.id)
	if !cs.counterOpen || !cs.counterUsed {
		t.Fatal("the answerer's challenge must be reachable after the round")
	}
	// The reserve is not forgiven: an unrescued challenge still settles it.
	testing.SkipHeights(c.params.votingBlocks + 1)
	supplyBefore := c.coin.TotalSupply()
	ResolveCounter(cross(cur), "wp6", cs.id)
	if cs.pendingSlash != 0 {
		t.Fatalf("an unrescued challenge settles the reserve: %d", cs.pendingSlash)
	}
	if burned := supplyBefore - c.coin.TotalSupply(); burned < slash {
		t.Fatalf("the reserve must burn, not vanish: burned %d want >= %d", burned, slash)
	}
}

// v0.54 (HIGH): a PROMOTION out of an adjudicated tier must carry a ⅔ MANDATE in its
// own bucket. MID is reachable as a bare RESIDUAL — applyQualityTally returns
// conclusive MID whenever the full bar is met and low misses the weighted median, so a
// mid bloc that is merely the largest, not a supermajority, used to overturn a
// conclusive ⅔-low and restore cs.tier, and with it the WHOLE draw (tierLowX = 0
// zeroes D outright). ~4%·X̄ net against a draw bounded at 19.27%·X̄.
//
// Here the low bloc is IN the ride tally at 4 CC against the mill's 6 CC of mid: enough
// for MID to classify (low misses the median), not enough for a mandate (3x6 < 2x10).
// A turnout comparison was tried instead and is bypassable — a throwaway dust-LOW round
// rewrites cs.conclusiveTurnout DOWNWARD, so the promotion lands next round for one
// extra bond. The fixture also pins that the ratchet leaves the RESERVE alone: the same
// ride still refunds it with the tier left LOW.
func TestResidualMidRideCannotBuyTheTier(cur realm, t *testing.T) {
	alice := testutils.TestAddress("wp7-alice") // author + answerer
	bob := testutils.TestAddress("wp7-bob")     // round-1 disputer, then flagger
	carol := testutils.TestAddress("wp7-carol") // the honest low bloc, 4 CC
	dave := testutils.TestAddress("wp7-dave")   // the mill's mid bloc, 6 CC
	c := testCourt(cur, "wp7", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 4_000_000_000)
	c.coin.Mint(dave, 6_000_000_000)
	cs, slash := levySlash(cur, c, "wp7", alice, bob, carol)
	if slash <= 0 || cs.tier != tierLowX {
		t.Fatalf("setup: a conclusive ⅔-low with a reserve, got tier=%d slash=%d",
			cs.tier, slash)
	}
	remainder := cs.answerBond

	testing.SetRealm(testing.NewUserRealm(dave))
	OpenDispute(cross(cur), "wp7", cs.id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "wp7", cs.id, qualityLow)
	testing.SetRealm(testing.NewUserRealm(dave))
	VoteQuality(cross(cur), "wp7", cs.id, qualityMid)
	testing.SetRealm(testing.NewUserRealm(dave))
	VoteDispute(cross(cur), "wp7", cs.id, "no") // meets quorum, yes == 0 -> UPHELD
	low, mid := cs.qLowW, cs.qMidW
	if low*2 >= low+mid || mid*3 >= (low+mid)*2 {
		t.Fatalf("fixture must be residual-MID without a mandate: low=%d mid=%d", low, mid)
	}
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "wp7", cs.id)

	if tier, _ := QualityTier("wp7", cs.id); tier != int(tierLowX) {
		t.Fatalf("a residual mid must not buy the tier: got tier=%d want %d (low=%d mid=%d)",
			tier, tierLowX, low, mid)
	}
	if cs.pendingSlash != 0 || cs.answerBond != remainder+slash {
		t.Fatalf("the ratchet must not refuse a rescue: pending=%d bond=%d want 0/%d",
			cs.pendingSlash, cs.answerBond, remainder+slash)
	}
}

// The ratchet's PROMOTION-only qualifier, pinned. §3.4's F3 asymmetry makes demotion
// deliberately cheap, so a demotion must land even carrying NO ⅔ mandate:
// applyQualityTally goes conclusive LOW on the weighted median (qLowW*2 >= turnout),
// which admits a low share anywhere in [1/2, 2/3). Dropping `tier > int(cs.tier)` would
// gate exactly that band and freeze a standing MID in place, inverting F3 in the mill's
// favour. A sole-low-voter fixture cannot see this — it satisfies the mandate trivially
// — so the qualifier only becomes verifiable at a low share under ⅔.
func TestUnmandatedDemotionRideStillLands(cur realm, t *testing.T) {
	alice := testutils.TestAddress("wp8-alice")
	bob := testutils.TestAddress("wp8-bob")
	carol := testutils.TestAddress("wp8-carol") // 30 CC MID: the standing tier
	dave := testutils.TestAddress("wp8-dave")   // 5 CC low
	erin := testutils.TestAddress("wp8-erin")   // 4 CC mid -> low share 5/9, under ⅔
	c := testCourt(cur, "wp8", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 30_000_000_000)
	c.coin.Mint(dave, 5_000_000_000)
	c.coin.Mint(erin, 4_000_000_000)
	id := standingMid(cur, c, "wp8", alice, bob, carol)
	cs := mustClaim(c, id)

	testing.SetRealm(testing.NewUserRealm(dave))
	OpenDispute(cross(cur), "wp8", id)
	testing.SetRealm(testing.NewUserRealm(dave))
	VoteQuality(cross(cur), "wp8", id, qualityLow)
	testing.SetRealm(testing.NewUserRealm(erin))
	VoteQuality(cross(cur), "wp8", id, qualityMid)
	testing.SetRealm(testing.NewUserRealm(dave))
	VoteDispute(cross(cur), "wp8", id, "no")
	low, mid := cs.qLowW, cs.qMidW
	if low*2 < low+mid || low*3 >= (low+mid)*2 {
		t.Fatalf("fixture must be a median demotion WITHOUT a ⅔ mandate: low=%d mid=%d",
			low, mid)
	}
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "wp8", id)
	if tier, _ := QualityTier("wp8", id); tier != int(tierLowX) {
		t.Fatalf("an unmandated demotion must still land: got tier=%d want %d (low=%d mid=%d)",
			tier, tierLowX, low, mid)
	}
}

// The mandate bar must be exactly HIGH's own bar, no tighter. applyQualityTally returns
// conclusive HIGH only on qHighW*3 >= turnout*2, so an honest ⅔ HIGH carries a mandate
// by construction and must never be refused. Both ratchet reviewers found the earlier
// turnout-comparison form refusing precisely this — a promotion with a STRONGER mandate
// than the residual MID it overturns, losing the whole draw. The high share here is
// 7/10: over ⅔, under 3/4, so tightening the bar one notch fails this test. Turnout is
// also deliberately BELOW the standing tally's, which is what the old form tripped on.
func TestMandatedHighRidePromotesOverAStandingMid(cur realm, t *testing.T) {
	alice := testutils.TestAddress("wp9-alice")
	bob := testutils.TestAddress("wp9-bob")
	carol := testutils.TestAddress("wp9-carol") // 30 CC MID: the standing tier
	dave := testutils.TestAddress("wp9-dave")   // 7 CC high
	erin := testutils.TestAddress("wp9-erin")   // 3 CC mid -> high share 7/10
	c := testCourt(cur, "wp9", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 30_000_000_000)
	c.coin.Mint(dave, 7_000_000_000)
	c.coin.Mint(erin, 3_000_000_000)
	id := standingMid(cur, c, "wp9", alice, bob, carol)
	cs := mustClaim(c, id)
	wonAt := cs.conclusiveTurnout

	testing.SetRealm(testing.NewUserRealm(dave))
	OpenDispute(cross(cur), "wp9", id)
	testing.SetRealm(testing.NewUserRealm(dave))
	VoteQuality(cross(cur), "wp9", id, qualityHigh)
	testing.SetRealm(testing.NewUserRealm(erin))
	VoteQuality(cross(cur), "wp9", id, qualityMid)
	testing.SetRealm(testing.NewUserRealm(dave))
	VoteDispute(cross(cur), "wp9", id, "no")
	high, turnout := cs.qHighW, cs.qLowW+cs.qMidW+cs.qHighW
	if high*3 < turnout*2 || high*4 >= turnout*3 {
		t.Fatalf("fixture must sit in [2/3, 3/4): high=%d turnout=%d", high, turnout)
	}
	if turnout > wonAt {
		t.Fatalf("fixture must also be BELOW the standing turnout (%d), which is what "+
			"the old turnout form tripped on: %d", wonAt, turnout)
	}
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "wp9", id)
	if tier, _ := QualityTier("wp9", id); tier != int(tierHighX) {
		t.Fatalf("a ⅔-mandated high must promote: got tier=%d want %d (high=%d of %d)",
			tier, tierHighX, high, turnout)
	}
}

// standingMid drives a claim to a STANDING conclusive MID at high turnout: a failed
// round 1 to open the escrow window, then a flag the mid bloc carries alone. The tier
// the ratchet's promotion tests are measured against.
func standingMid(cur realm, c *Court, slug string, alice, bob, mid address) uint64 {
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), slug, "a standing conclusive mid")
	matureOI(cur, slug, id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), slug, id, sideYES)
	c.params.escrowMinBlocks = 900_000
	c.params.escrowMaxBlocks = 900_000
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), slug, id)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), slug, id)
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), slug, id)
	testing.SetRealm(testing.NewUserRealm(mid))
	VoteQuality(cross(cur), slug, id, qualityMid)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), slug, id)
	return id
}

// QualityBars is a pure read, and it must agree exactly with the bars ResolveFlag
// scores against — otherwise it would tell an elector to clear a bar the mechanism
// does not use. Pinned against the internal predicate on the same claim, and pinned
// as SEALED-SAFE: the bars are not the tally, so this read must expose no bucket.
func TestQualityBarsQuotesTheBarsResolveFlagUses(cur realm, t *testing.T) {
	alice := testutils.TestAddress("qb-alice")
	bob := testutils.TestAddress("qb-bob")
	carol := testutils.TestAddress("qb-carol")
	c := testCourt(cur, "qb1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 4_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "qb1", "the bars are quotable")
	matureOI(cur, "qb1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "qb1", id, sideYES)

	cs := mustClaim(c, id)
	wantDemotion, wantFull := qualityBars(c, cs)
	gotDemotion, gotFull := QualityBars("qb1", id)
	if gotDemotion != wantDemotion || gotFull != wantFull {
		t.Fatalf("the quoted bars must be the scored bars: got %d/%d want %d/%d",
			gotDemotion, gotFull, wantDemotion, wantFull)
	}
	if gotDemotion <= 0 || gotFull < gotDemotion {
		t.Fatalf("bars must be positive and ordered: %d/%d", gotDemotion, gotFull)
	}

	// Both bars read a SEALED past epoch, so they are claim-constant for life: a
	// voter can act on the quote and it cannot be moved under them mid-vote. This is
	// what the fix in resolveQualityRide's authority test also relies on.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "qb1", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "qb1", id, qualityLow)
	afterDemotion, afterFull := QualityBars("qb1", id)
	if afterDemotion != wantDemotion || afterFull != wantFull {
		t.Fatalf("the bars must not move once the epoch is sealed: %d/%d want %d/%d",
			afterDemotion, afterFull, wantDemotion, wantFull)
	}
}
