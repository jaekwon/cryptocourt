package courtv2

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

// H1, an audit-named invariant found SURVIVING by the mutation harness: removing
// effectiveRateAcc's freeze cap failed no test. The cap is what stops a claim's FROZEN
// conviction being repriced by later d_eff moves — without it, every position's
// settlement changes retroactively whenever the court's rate moves after the answer,
// so a payout computed today differs from the same payout computed next week on
// identical votes and identical stake.
//
// Exercised on effectiveRateAcc directly: it is the single function the invariant lives
// in, and driving a d_eff move through natural emission would take more periods than a
// harness can run while proving the same one comparison.
func TestFrozenConvictionIsNotRepricedByLaterRateMoves(cur realm, t *testing.T) {
	alice := testutils.TestAddress("h1c-alice")
	c := testCourt(cur, "h1c", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "h1c", "frozen means frozen")
	matureOI(cur, "h1c", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "h1c", id, sideYES)

	cs := mustClaim(c, id)
	if cs.frozenAt == 0 || cs.rateAccAtFreeze <= 0 {
		t.Fatalf("setup: the answer must pin the era integral: frozenAt=%d accAtFreeze=%d",
			cs.frozenAt, cs.rateAccAtFreeze)
	}
	atFreeze := effectiveRateAcc(c, cs)
	if atFreeze != cs.rateAccAtFreeze {
		t.Fatalf("setup: a frozen claim settles against its pin: %d vs %d",
			atFreeze, cs.rateAccAtFreeze)
	}

	// The court's era integral keeps growing after the freeze — that is normal, other
	// claims are still live.
	testing.SkipHeights(epochBlocks * 24 * 30)
	touch(c)
	if c.rateAccFP <= cs.rateAccAtFreeze {
		t.Fatalf("setup: the COURT's integral must advance past the pin: %d vs %d",
			c.rateAccFP, cs.rateAccAtFreeze)
	}

	// THE GUARD: this claim still settles against the pin, not the court's new total.
	if got := effectiveRateAcc(c, cs); got != cs.rateAccAtFreeze {
		t.Fatalf("H1: a frozen claim must not be repriced by later rate moves: "+
			"got %d want %d (court is at %d)", got, cs.rateAccAtFreeze, c.rateAccFP)
	}

	// And the cap is a cap, not an override: a claim that is NOT frozen tracks the
	// court's integral, so the guard cannot pass by pinning everything.
	testing.SetRealm(testing.NewUserRealm(alice))
	live := OpenClaim(cross(cur), "h1c", "still open")
	lcs := mustClaim(c, live)
	if lcs.frozenAt != 0 {
		t.Fatal("setup: the second claim must be unfrozen")
	}
	if got := effectiveRateAcc(c, lcs); got != c.rateAccFP {
		t.Fatalf("an unfrozen claim tracks the court: got %d want %d", got, c.rateAccFP)
	}
}

// A fresh stake earns nothing for time before it existed. Two mutations survive
// here and both are free-conviction bugs — the reward weight is the whole draw, so
// conviction created out of nothing is minted money.
//
//	getPos's baseline. A new position records lastRateAcc = the court's era
//	integral NOW. Zero it and the first accrue credits stake × the WHOLE court
//	history, so a latecomer's first stake arrives with the conviction of somebody
//	who had been there since the court opened.
//
//	Stake's touch(c). Without it the era integral is stale at the moment of
//	staking, so the interval since anyone last walked it stays uncredited — and the
//	NEXT settle credits that interval at the new, larger stake. Adding to a position
//	therefore back-pays the addition for time it was not staked.
//
// The court has to be AGED and untouched for either to show, which is why the
// existing fixtures miss both: they stake into a court whose integral is still ~0.
func TestAFreshStakeEarnsNothingForTimeBeforeIt(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fs-alice")
	testCourt(cur, "fs1", alice, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "fs1", "conviction starts at zero")

	// Age the court without touching it, so rateAccFP is behind the clock.
	testing.SkipHeights(periodBlocks / 2)

	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "fs1", id, sideYES, 1_000_000)
	// Nothing has elapsed WHILE staked, so there is nothing to have earned.
	if got := ConvictionOf("fs1", id, sideYES, alice); got != 0 {
		t.Errorf("a fresh stake already holds %d conviction — it was credited for "+
			"time before it existed", got)
	}

	// Now let time pass at 1_000_000, and record what that interval is worth.
	testing.SkipHeights(periodBlocks / 4)
	small := ConvictionOf("fs1", id, sideYES, alice)
	if small <= 0 {
		t.Fatalf("setup: a live stake must accrue over time, got %d", small)
	}

	// Add a thousand times as much, then immediately read again. The addition
	// cannot have earned anything yet, so the total must still be about `small` —
	// not `small` scaled by the new stake.
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "fs1", id, sideYES, 1_000_000_000)
	after := ConvictionOf("fs1", id, sideYES, alice)
	if after > small*2 {
		t.Errorf("adding to a position back-paid it: conviction went %d -> %d with "+
			"no time elapsed between the two reads", small, after)
	}
}

// Unstake debits its OWN side's pool. The same defect was found and fixed in
// WithdrawStake (TestWithdrawStakeDebitsItsOwnSidesPool); its pre-answer sibling
// was left, and swapping the branches here goes unnoticed for the same reason it
// did there — the unstaker receives the right coin either way, and the damage is
// left behind in the claim's per-side totals, which feed the conviction integrals
// every reward is drawn against.
func TestUnstakeDebitsItsOwnSidesPool(cur realm, t *testing.T) {
	alice := testutils.TestAddress("up-alice")
	bob := testutils.TestAddress("up-bob")
	c := testCourt(cur, "up1", alice, 20_000_000_000)
	c.coin.Mint(bob, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "up1", "whose pool an unstake leaves")

	// Unequal on purpose: equal pools hide a swap by symmetry.
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "up1", id, sideYES, 400_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "up1", id, sideNO, 900_000_000)

	testing.SetRealm(testing.NewUserRealm(bob))
	Unstake(cross(cur), "up1", id, sideNO, 300_000_000)
	yes, no := StakePools("up1", id)
	if no != 600_000_000 {
		t.Errorf("the NO pool is %d after a 300M NO exit, want 600000000", no)
	}
	if yes != 400_000_000 {
		t.Errorf("the YES pool moved to %d on somebody else's exit, want 400000000", yes)
	}
}

// Both trailing rings track their own series, which nothing held.
//
// cs.oi is TOTAL open interest — it is X̄'s source, so the answerability gate and
// every %-of-X̄ quantity read it; cs.yes is the YES side alone, and the two are
// divided against each other for the rendered trailing ratio. Point either at the
// wrong total and X̄ halves or the ratio inverts, with no other symptom.
func TestBothTrailingRingsTrackTheirOwnSeries(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tr-alice")
	c := testCourt(cur, "tr1", alice, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "tr1", "two rings")
	cs := mustClaim(c, id)

	// Set the totals outright and observe once: this is the recorder under test.
	// Unequal, and not a multiple of each other, so no swap can coincide.
	cs.yesStake, cs.noStake = 100_000, 700_000
	observePools(cs)
	h := runtimeHeight()
	// A sub-width window widens to one bucket, so this reads the value just written.
	if got, _ := cs.oi.Average(h, 1); got != 800_000 {
		t.Errorf("the OI ring recorded %d, want the 800000 TOTAL", got)
	}
	if got, _ := cs.yes.Average(h, 1); got != 100_000 {
		t.Errorf("the YES ring recorded %d, want the 100000 YES side", got)
	}
}

// The lifetime average counts BOTH sides. It is the P6 base — PostAnswer takes
// max(3h trailing, this) and every bond, slash, bar and clamp is priced off the
// result — so dropping a side halves the price of contesting a claim.
//
// Called directly with the integrals set, because reaching a chosen lifetime
// average through the machine means solving for it, and a test that does
// arithmetic to check arithmetic proves nothing.
func TestTheLifetimeAverageCountsBothSides(cur realm, t *testing.T) {
	alice := testutils.TestAddress("la-alice")
	c := testCourt(cur, "la1", alice, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "la1", "both sides count")
	cs := mustClaim(c, id)

	cs.openedAt = 0
	cs.yesRawHi, cs.yesRawLo = 0, 1_000
	cs.noRawHi, cs.noRawLo = 0, 3_000
	if got := lifeAvgStake(cs, 100); got != 40 {
		t.Errorf("the lifetime average is %d, want (1000+3000)/100 = 40", got)
	}
}

// One staker on BOTH sides keeps two positions. posKey's "|y"/"|n" suffix is the
// only thing separating them, and collapsing it went unnoticed because nothing in
// the suite had a single address staking both ways: the pool totals stay correct
// either way, and StakeOf reads through the same key it was written with, so both
// sides report the merged figure and agree with each other.
//
// What merges is the stakePos — one conviction accumulator and one bonusPaid latch
// for two positions, so the winner draw is paid once for a staker who earned it on
// the winning side and staked the losing one too.
func TestOneStakerOnBothSidesKeepsTwoPositions(cur realm, t *testing.T) {
	alice := testutils.TestAddress("bs-alice")
	testCourt(cur, "bs1", alice, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "bs1", "hedged both ways")

	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "bs1", id, sideYES, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "bs1", id, sideNO, 500_000_000)

	if got := StakeOf("bs1", id, sideYES, alice); got != 200_000_000 {
		t.Errorf("the YES position reads %d, want 200000000", got)
	}
	if got := StakeOf("bs1", id, sideNO, alice); got != 500_000_000 {
		t.Errorf("the NO position reads %d, want 500000000", got)
	}
	// And the pools agree, so the two positions are separate rather than the reads
	// being separately wrong.
	if yes, no := StakePools("bs1", id); yes != 200_000_000 || no != 500_000_000 {
		t.Errorf("the pools read %d/%d, want 200000000/500000000", yes, no)
	}
}
