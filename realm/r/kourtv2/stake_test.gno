package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// testCourt creates a court and mints CC straight from the ledger (tests are
// in-package; Buy lands in buy.gno with the burn sink).
func testCourt(cur realm, slug string, who address, cc int64) *Court {
	testing.SetRealm(testing.NewUserRealm(who))
	StartCourt(cross(cur), slug, "Test Court "+slug)
	c := mustCourt(slug)
	c.coin.Mint(who, cc)
	return c
}

func TestStakeUnstakeConservesEscrow(cur realm, t *testing.T) {
	alice := testutils.TestAddress("s-alice")
	bob := testutils.TestAddress("s-bob")
	c := testCourt(cur, "st1", alice, 10_000_000_000)
	c.coin.Mint(bob, 5_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "st1", "Does staking conserve?")
	dep := c.params.minClaimDepositCC
	fee := dep * depositFeeBps / 10000

	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "st1", id, sideYES, 3_000_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "st1", id, sideNO, 2_000_000_000)

	if got := c.coin.BalanceOf(c.escrow); got != 5_000_000_000+dep+fee {
		t.Fatalf("escrow should hold stakes+deposit+fee, got %d", got)
	}
	yes, no := StakePools("st1", id)
	if yes != 3_000_000_000 || no != 2_000_000_000 {
		t.Fatalf("pools = %d/%d", yes, no)
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	Unstake(cross(cur), "st1", id, sideYES, 1_000_000_000)
	if StakeOf("st1", id, sideYES, alice) != 2_000_000_000 {
		t.Fatal("partial unstake should reduce the position")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	Unstake(cross(cur), "st1", id, sideYES, 2_000_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Unstake(cross(cur), "st1", id, sideNO, 2_000_000_000)
	// Everyone whole: escrow holds only the deposit+fee.
	if got := c.coin.BalanceOf(c.escrow); got != dep+fee {
		t.Fatalf("after full unstake escrow holds only deposit+fee, got %d", got)
	}
	if c.coin.BalanceOf(alice) != 10_000_000_000-dep-fee || c.coin.BalanceOf(bob) != 5_000_000_000 {
		t.Fatal("principals must return 1x")
	}
}

func TestConvictionAccruesExactly(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cv-alice")
	testCourt(cur, "cv1", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "cv1", "Conviction math")

	const S = int64(1_000_000_000) // 1,000 CC
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "cv1", id, sideYES, S)
	testing.SkipHeights(periodBlocks) // exactly one week at the launch rate

	// Expected CC-units: S × rateFP / 1e10. With no emission history the court
	// prices at the pure-r floor (audit-15 P1): rateFP = 255 × 25e6 / 100.
	rateFP := 255 * (r0WeeklyBps * 1_000_000) / 100
	want := int64(uint64(S) * uint64(rateFP) / 10_000_000_000)
	got := ConvictionOf("cv1", id, sideYES, alice)
	if got != want {
		t.Fatalf("one week of conviction on %d = %d CC-units, want %d", S, got, want)
	}

	// Unstake keeps history; the removed stake stops earning.
	testing.SetRealm(testing.NewUserRealm(alice))
	Unstake(cross(cur), "cv1", id, sideYES, S)
	testing.SkipHeights(periodBlocks)
	if after := ConvictionOf("cv1", id, sideYES, alice); after != got {
		t.Fatalf("conviction must persist after unstake and stop growing: %d vs %d", after, got)
	}
	// Restake resumes accrual.
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "cv1", id, sideYES, S)
	testing.SkipHeights(100)
	if resumed := ConvictionOf("cv1", id, sideYES, alice); resumed <= got {
		t.Fatal("restake must resume accrual")
	}
}

func TestFreezeStopsEverything(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fz-alice")
	c := testCourt(cur, "fz1", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "fz1", "Freeze semantics")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "fz1", id, sideYES, 1_000_000_000)
	testing.SkipHeights(1000)

	// Simulate the answer (answer.gno lands later; in-package set): touch
	// first so the era integral is exact at the freeze height, then pin it.
	touch(c)
	cs := mustClaim(c, id)
	cs.frozenAt = testingHeight()
	cs.rateAccAtFreeze = c.rateAccFP
	frozenConv := ConvictionOf("fz1", id, sideYES, alice)

	testing.SkipHeights(5000)
	if ConvictionOf("fz1", id, sideYES, alice) != frozenConv {
		t.Fatal("conviction must stop accruing at the freeze, exactly")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "frozen", func() {
		Stake(cross(cur), "fz1", id, sideYES, 1)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "frozen", func() {
		Unstake(cross(cur), "fz1", id, sideYES, 1)
	})
}

func TestDeadClaimCloses(cur realm, t *testing.T) {
	alice := testutils.TestAddress("dd-alice")
	bob := testutils.TestAddress("dd-bob")
	c := testCourt(cur, "dd1", alice, 10_000_000_000)
	c.coin.Mint(bob, 1_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "dd1", "Nobody will answer this")
	dep := c.params.minClaimDepositCC
	fee := dep * depositFeeBps / 10000
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "dd1", id, sideYES, 500_000_000)

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "timeout has not passed", func() {
		CloseDeadClaim(cross(cur), "dd1", id)
	})
	testing.SkipHeights(deadClaimTimeout)
	supplyBefore := c.coin.TotalSupply()
	aliceBefore := c.coin.BalanceOf(alice)
	testing.SetRealm(testing.NewUserRealm(bob))
	CloseDeadClaim(cross(cur), "dd1", id)

	if c.coin.BalanceOf(alice) != aliceBefore+dep {
		t.Fatal("the deposit must refund to the author")
	}
	if c.coin.TotalSupply() != supplyBefore-fee {
		t.Fatal("the fee must burn on a dead claim")
	}
	// Stakes were never locked: bob exits whole; new stakes are refused.
	testing.SetRealm(testing.NewUserRealm(bob))
	Unstake(cross(cur), "dd1", id, sideYES, 500_000_000)
	if c.coin.BalanceOf(bob) != 1_000_000_000 {
		t.Fatal("a dead claim's staker exits 1x")
	}
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "closed", func() {
		Stake(cross(cur), "dd1", id, sideYES, 1)
	})
}

func TestStakeGuards(cur realm, t *testing.T) {
	alice := testutils.TestAddress("g-alice")
	testCourt(cur, "g1", alice, 1_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "g1", "Guards")
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "side is 0", func() {
		Stake(cross(cur), "g1", id, 2, 1)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "must be positive", func() {
		Stake(cross(cur), "g1", id, sideYES, 0)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "more than is staked", func() {
		Unstake(cross(cur), "g1", id, sideYES, 1)
	})
}

// testingHeight reads the current height inside tests.
func testingHeight() int64 {
	return runtimeHeight()
}

func TestRawIntegralAccruesAndFreezeCaps(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rw-alice")
	c := testCourt(cur, "rw1", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "rw1", "Raw integral")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "rw1", id, sideYES, 400_000_000)
	testing.SkipHeights(1000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Unstake(cross(cur), "rw1", id, sideYES, 100_000_000) // settles the integral

	cs := mustClaim(c, id)
	p := cs.stakers.Get(posKey(alice, sideYES)).(*stakePos)
	if p.rawHi != 0 || p.rawLo != uint64(400_000_000)*1000 {
		t.Fatalf("raw = stake x blocks exactly: got %d/%d", p.rawHi, p.rawLo)
	}
	if cs.yesRawLo != p.rawLo {
		t.Fatal("the pool raw integral mirrors the position")
	}

	// Freeze caps the raw clock: blocks after frozenAt add nothing.
	touch(c)
	cs.frozenAt = runtimeHeight()
	cs.rateAccAtFreeze = c.rateAccFP
	before := p.rawLo
	testing.SkipHeights(2000)
	accrue(c, cs, p, sideYES)
	if p.rawLo != before {
		t.Fatalf("raw must stop at the freeze: %d -> %d", before, p.rawLo)
	}
}

// mulDiv128's two guards, both found SURVIVING by the mutation harness: removing
// either failed no test. They are fail-loud defence at magnitudes the protocol does
// not reach — audit C1 added the 128-bit intermediate because the naive uint64 product
// wraps at ~485k CC of supply, a silent 34x under-budget — so rather than crafting
// unreachable protocol state, this calls the function directly. It is a pure helper
// and its contract is testable on its own terms.
func TestMulDiv128RefusesItsDomainAndOverflow(cur realm, t *testing.T) {
	// The happy path first, so the guards are not passing by rejecting everything.
	if got := mulDiv128(6, 7, 3); got != 14 {
		t.Fatalf("mulDiv128(6,7,3) = %d, want 14", got)
	}
	if got := mulDiv128(0, 5, 1); got != 0 {
		t.Fatalf("a zero numerator is fine: %d", got)
	}

	// uassert.AbortsContains recovers panics from CROSSING calls; mulDiv128 is an
	// internal call, so its panic escapes it. Recover locally instead, the way the
	// grc20votes suite does for the same reason.
	mustPanicWith := func(want string, fn func()) {
		t.Helper()
		defer func() {
			r := recover()
			if r == nil {
				t.Fatalf("expected a panic saying %q; nothing panicked", want)
			}
			got, ok := r.(string)
			if !ok || !containsSub(got, want) {
				t.Fatalf("panic %v, want one saying %q", r, want)
			}
		}()
		fn()
	}

	// DOMAIN: negatives and a non-positive denominator are caller bugs, not values to
	// silently coerce — the u128 path has no sign.
	for _, c := range []struct{ a, b, den int64 }{
		{-1, 1, 1}, {1, -1, 1}, {-1, -1, 1}, {1, 1, 0}, {1, 1, -1},
	} {
		mustPanicWith("mulDiv128 domain", func() { mulDiv128(c.a, c.b, c.den) })
	}

	// QUOTIENT OVERFLOW, the hi>=den guard: a product whose 128-bit high word reaches
	// the denominator cannot yield a uint64 quotient at all.
	mustPanicWith("mulDiv128 quotient overflow", func() {
		mulDiv128(9223372036854775807, 9223372036854775807, 1)
	})
	// And the THIRD guard, which I did not know was there until this fixture hit it:
	// hi<den only bounds q to uint64, so a quotient in (MaxInt64, 2^64) would wrap
	// silently through int64(q). math-audit NOTE-6 fails loud instead, with its own
	// message. Both paths are unreachable at bounded inputs; both are pinned because
	// the discipline is fail-loud, never silent-wrong.
	mustPanicWith("mulDiv128 quotient exceeds int64", func() {
		mulDiv128(9223372036854775807, 4, 2)
	})
	// The boundary just inside every guard still computes.
	if got := mulDiv128(9223372036854775807, 2, 4); got <= 0 {
		t.Fatalf("a quotient that fits must be returned: %d", got)
	}
}

// containsSub is strings.Contains; the realm imports no strings package and a test
// should not be the first thing to.
func containsSub(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
