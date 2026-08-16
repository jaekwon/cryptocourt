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
	// T1: inconclusive-LOW returns the bond IN FULL; the slot reopens ×2.
	if c.coin.BalanceOf(bob) != bobBefore {
		t.Fatal("inconclusive-low must return the whole bond (T1)")
	}
	if FlagCycles("qf1", id) != 1 || FlagState("qf1", id) != "open" {
		t.Fatal("the slot must reopen with a counted cycle")
	}
	if FlagBondNext("qf1", id) != 2*b0 {
		t.Fatalf("the reopened bond doubles: %d", FlagBondNext("qf1", id))
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
