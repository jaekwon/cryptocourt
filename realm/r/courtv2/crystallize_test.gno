package courtv2

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
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "cz2", id)
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
}
