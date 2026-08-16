package courtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

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
	// Reopen decides (uphold): the slash refunds into the bond pre-disposition.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "qf8", id)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "qf8", id, "no")
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "qf8", id)
	if cs.pendingSlash != 0 || cs.answerBond != ab {
		t.Fatalf("a decided round refunds the slash into the bond: %d/%d vs %d",
			cs.pendingSlash, cs.answerBond, ab)
	}
	// Finalize: the upheld answerer takes the WHOLE bond home.
	testing.SkipHeights(EscrowUntil("qf8", id) - runtimeHeight())
	aliceBefore := c.coin.BalanceOf(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "qf8", id)
	if c.coin.BalanceOf(alice) != aliceBefore+ab {
		t.Fatal("the upheld bond returns whole, slash included")
	}
}
