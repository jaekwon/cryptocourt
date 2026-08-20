package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// The universal unbonding period: everyone waits on exit, winners do not.
//
// What these tests exist to pin, in order of how badly it would hurt to get
// wrong:
//
//  1. Cooling coin is UNSPENDABLE, not merely unreturned. Before court coins
//     became transferable there was no exit to GNOT at all, so "you get it back
//     later" was already a lock. There is an exit now, so a delay that left the
//     coin spendable would be worth nothing — the loser would sell on a DEX
//     instead of waiting. Every door has to be shut, which is why the wait is a
//     subtraction inside spendable() rather than a flag on a withdrawal.
//  2. Winning releases immediately, and NOTHING is taken from the loser.
//     Principal is 1x back either way; the penalty is idle capital.
//  3. Switching sides is free. Otherwise the mechanism punishes honest
//     belief-updating, which is the one thing F9 exists to prevent.
//  4. A claim that reached no decision exempts BOTH sides. Punishing everyone
//     for the court's failure to decide would turn an unanswerable claim into a
//     way to freeze other people's capital.

// unbondCourt is a court with the default cooling period and a funded staker.
func unbondCourt(cur realm, slug string, who address, cc int64) *Court {
	c := testCourt(cur, slug, who, cc)
	if c.params.unbondBlocks <= 0 {
		panic("fixture is vacuous: this court has no cooling period")
	}
	return c
}

// Unstaking before an answer cools, and the coin is unspendable while it does —
// through every door, which is the assertion that matters.
func TestUnstakingCoolsAndCoolingCoinIsUnspendable(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ub-alice")
	bob := testutils.TestAddress("ub-bob")
	c := unbondCourt(cur, "ub1", alice, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "ub1", "Does unstaking cool?")
	// AFTER the claim, because OpenClaim moves the deposit and its fee into the
	// escrow — that coin has left the balance entirely, which is a different
	// thing from being locked or cooling. Every figure below is relative to what
	// is actually held, so the deposit's size is not silently baked in.
	bal := c.coin.BalanceOf(alice)
	uassert.True(t, bal < 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "ub1", id, sideYES, 6_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Unstake(cross(cur), "ub1", id, sideYES, 6_000_000_000)

	// Off the lock ledger, onto the cooling ledger. The coin never left the
	// balance — it was never in custody — so the balance is unchanged and only
	// spendable moved.
	uassert.Equal(t, int64(0), LockedOf("ub1", alice))
	uassert.Equal(t, int64(6_000_000_000), CoolingOf("ub1", alice))
	uassert.Equal(t, bal, c.coin.BalanceOf(alice))
	uassert.Equal(t, bal-6_000_000_000, SpendableOf("ub1", alice))
	// And it still votes. That is deliberate: cooling is not disenfranchisement,
	// which is the mistake custody used to make court-wide.
	uassert.Equal(t, bal, c.coin.VotesOf(alice))

	// EVERY DOOR. A sale, a wrapper's pull, a fresh stake and a claim deposit all
	// narrow to spendable(), and each is refused for the cooling portion.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "not enough unstaked CC", func() {
		TransferCC(cross(cur), "ub1", bob, 5_000_000_000)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	ApproveCC(cross(cur), "ub1", bob, 5_000_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "not enough unstaked CC", func() {
		TransferFromCC(cross(cur), "ub1", alice, bob, 5_000_000_000)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "not enough unstaked CC", func() {
		Stake(cross(cur), "ub1", id, sideNO, 5_000_000_000)
	})

	// The spendable remainder still works, so none of the above is a blanket
	// refusal.
	rest := bal - 6_000_000_000
	testing.SetRealm(testing.NewUserRealm(alice))
	TransferCC(cross(cur), "ub1", bob, rest)
	uassert.Equal(t, rest, CoinBalanceOf("ub1", bob))
	uassert.Equal(t, int64(0), SpendableOf("ub1", alice))
}

// The wait ends, and the sweep is what ends it. Also pins that sweeping early
// frees nothing rather than partially releasing.
func TestCoolingMaturesAndTheSweepReleasesIt(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ub-alice2")
	unbondCourt(cur, "ub2", alice, 8_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "ub2", "Does the wait end?")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "ub2", id, sideYES, 5_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Unstake(cross(cur), "ub2", id, sideYES, 5_000_000_000)

	at := ReleaseAt("ub2", alice)
	uassert.True(t, at > heightNow())
	// The grid can only ever push a release later, never earlier — rounding down
	// would hand coins back before the period had elapsed, which is the one
	// direction that turns the row-bounding trick into a hole.
	uassert.True(t, at >= heightNow()+UnbondBlocks("ub2"))
	uassert.Equal(t, int64(0), at%unbondBucket)

	// One block short: nothing is due.
	testing.SkipHeights(at - heightNow() - 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, int64(0), ReleaseUnbonded(cross(cur), "ub2", alice))
	uassert.Equal(t, int64(5_000_000_000), CoolingOf("ub2", alice))

	// And now it is.
	testing.SkipHeights(1)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, int64(5_000_000_000), ReleaseUnbonded(cross(cur), "ub2", alice))
	uassert.Equal(t, int64(0), CoolingOf("ub2", alice))
	uassert.Equal(t, int64(0), ReleaseAt("ub2", alice))
	uassert.Equal(t, mustCourt("ub2").coin.BalanceOf(alice), SpendableOf("ub2", alice))

	// A second sweep of nothing is not an error, so a UI can sweep blindly.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, int64(0), ReleaseUnbonded(cross(cur), "ub2", alice))
}

// THE EXEMPTION, both halves in one claim so the asymmetry is measured rather
// than described: the winning side walks, the losing side waits, and neither
// loses a single coin of principal.
func TestTheWinnerWalksAndTheLoserWaits(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ub-alice3") // authors, stakes YES, answers YES
	bob := testutils.TestAddress("ub-bob3")     // stakes NO
	c := unbondCourt(cur, "ub3", alice, 50_000_000_000)
	c.coin.Mint(bob, 20_000_000_000)

	id := stakeAnswerDispute(cur, "ub3", alice, bob)
	aliceStake := StakeOf("ub3", id, sideYES, alice)
	bobStake := StakeOf("ub3", id, sideNO, bob)
	if aliceStake <= 0 || bobStake <= 0 {
		t.Fatal("fixture is vacuous: one of the sides holds nothing")
	}

	// Undisputed, so YES becomes the verdict.
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	SettleUndisputed(cross(cur), "ub3", id)
	uassert.Equal(t, sideYES, Verdict("ub3", id))

	testing.SetRealm(testing.NewUserRealm(alice))
	won := WithdrawStake(cross(cur), "ub3", id, sideYES)
	testing.SetRealm(testing.NewUserRealm(bob))
	lost := WithdrawStake(cross(cur), "ub3", id, sideNO)

	// PRINCIPAL IS 1x FOR BOTH. Nothing is slashed and nothing is burned; that is
	// the constraint the whole mechanism is shaped around, and it is why the
	// penalty had to be time rather than money.
	uassert.Equal(t, aliceStake, won)
	uassert.Equal(t, bobStake, lost)

	// The winner's is spendable now. The loser's is not.
	uassert.Equal(t, int64(0), CoolingOf("ub3", alice))
	uassert.Equal(t, bobStake, CoolingOf("ub3", bob))
	uassert.Equal(t, int64(0), ReleaseAt("ub3", alice))
	uassert.True(t, ReleaseAt("ub3", bob) > heightNow())

	// The winner can act on it immediately, which is what makes the exemption
	// feel like a reward rather than an accounting detail.
	testing.SetRealm(testing.NewUserRealm(alice))
	TransferCC(cross(cur), "ub3", testutils.TestAddress("ub-carol3"), won)

	// And the loser does get it, in full, once the wait is served.
	testing.SkipHeights(ReleaseAt("ub3", bob) - heightNow())
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.Equal(t, bobStake, ReleaseUnbonded(cross(cur), "ub3", bob))
	uassert.Equal(t, int64(0), CoolingOf("ub3", bob))
}

// Switching sides is free: no cooling, and the abandoned side keeps the integral
// it actually earned while the capital was on it.
func TestSwitchingSidesIsFreeAndBanksTheConviction(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ub-alice4")
	unbondCourt(cur, "ub4", alice, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "ub4", "Is changing your mind free?")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "ub4", id, sideYES, 6_000_000_000)

	testing.SkipHeights(1_000)
	earnedOnYes := ConvictionOf("ub4", id, sideYES, alice)
	if earnedOnYes <= 0 {
		t.Fatal("fixture is vacuous: no conviction on the side being abandoned")
	}
	lockedBefore := LockedOf("ub4", alice)

	testing.SetRealm(testing.NewUserRealm(alice))
	SwitchSide(cross(cur), "ub4", id, sideYES, sideNO, 6_000_000_000)

	// NOTHING COOLED and the lock is unchanged: the same coins are committed to
	// the same claim, so no exit happened.
	uassert.Equal(t, int64(0), CoolingOf("ub4", alice))
	uassert.Equal(t, lockedBefore, LockedOf("ub4", alice))
	uassert.Equal(t, mustCourt("ub4").coin.BalanceOf(alice)-6_000_000_000, SpendableOf("ub4", alice))

	// The stake moved.
	uassert.Equal(t, int64(0), StakeOf("ub4", id, sideYES, alice))
	uassert.Equal(t, int64(6_000_000_000), StakeOf("ub4", id, sideNO, alice))
	yes, no := StakePools("ub4", id)
	uassert.Equal(t, int64(0), yes)
	uassert.Equal(t, int64(6_000_000_000), no)

	// The abandoned side keeps what it earned and stops earning; the new side
	// starts from nothing. Carrying the integral across would be the real
	// exploit: earn conviction cheaply on an uncontested side, then move it to
	// whichever side wins.
	uassert.Equal(t, earnedOnYes, ConvictionOf("ub4", id, sideYES, alice))
	uassert.Equal(t, int64(0), ConvictionOf("ub4", id, sideNO, alice))
	testing.SkipHeights(1_000)
	uassert.Equal(t, earnedOnYes, ConvictionOf("ub4", id, sideYES, alice))
	uassert.True(t, ConvictionOf("ub4", id, sideNO, alice) > 0)
}

// SwitchSide refuses what it must, each paired with the call it must allow.
func TestSwitchSideRefusesWhatItMust(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ub-alice5")
	unbondCourt(cur, "ub5", alice, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "ub5", "What does switching refuse?")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "ub5", id, sideYES, 5_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "already on", func() {
		SwitchSide(cross(cur), "ub5", id, sideYES, sideYES, 1_000)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "must be positive", func() {
		SwitchSide(cross(cur), "ub5", id, sideYES, sideNO, 0)
	})
	// More than is on the side, which is the check that keeps a switch from
	// minting stake out of the other side's pool.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "switching more than is staked", func() {
		SwitchSide(cross(cur), "ub5", id, sideYES, sideNO, 5_000_000_001)
	})
	// Nothing on the NO side to switch away from.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "switching more than is staked", func() {
		SwitchSide(cross(cur), "ub5", id, sideNO, sideYES, 1)
	})
	// The pools are untouched by every refusal above.
	yes, no := StakePools("ub5", id)
	uassert.Equal(t, int64(5_000_000_000), yes)
	uassert.Equal(t, int64(0), no)

	// And the ordinary switch it must not refuse.
	testing.SetRealm(testing.NewUserRealm(alice))
	SwitchSide(cross(cur), "ub5", id, sideYES, sideNO, 5_000_000_000)
	yes, no = StakePools("ub5", id)
	uassert.Equal(t, int64(0), yes)
	uassert.Equal(t, int64(5_000_000_000), no)
}

// Once a claim is answered the conviction pins are set, so a switch would be
// reading the answer rather than updating a belief. Refused.
func TestSwitchSideIsRefusedAfterTheAnswer(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ub-alice6")
	bob := testutils.TestAddress("ub-bob6")
	c := unbondCourt(cur, "ub6", alice, 50_000_000_000)
	c.coin.Mint(bob, 20_000_000_000)

	id := stakeAnswerDispute(cur, "ub6", alice, bob)
	uassert.True(t, mustClaim(c, id).frozenAt != 0)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "stakes are frozen", func() {
		SwitchSide(cross(cur), "ub6", id, sideYES, sideNO, 1_000_000)
	})
}

// A claim that reached no decision exempts BOTH sides. Otherwise an unanswerable
// claim becomes a way to freeze other people's capital, which is an attack and
// not an incentive.
func TestNoDecisionExemptsBothSides(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ub-alice7")
	bob := testutils.TestAddress("ub-bob7")
	c := unbondCourt(cur, "ub7", alice, 20_000_000_000)
	c.coin.Mint(bob, 20_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "ub7", "Nobody will ever answer this")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "ub7", id, sideYES, 5_000_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "ub7", id, sideNO, 5_000_000_000)

	// Let it die unanswered, which is the cheapest no-decision ending to build.
	testing.SkipHeights(deadClaimTimeout + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	CloseDeadClaim(cross(cur), "ub7", id)
	cs := mustClaim(c, id)
	uassert.True(t, cs.closed)

	// UNSTAKE, not WithdrawStake. A dead close never sets verdictAt, so
	// WithdrawStake refuses with "no verdict yet" — measured, not assumed — and
	// Unstake is the only exit a dead claim has (it checks frozenAt, which a dead
	// claim never had set). That is exactly why the exemption has to live in
	// Unstake as well; in WithdrawStake alone it would be unreachable code.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "no verdict yet", func() {
		WithdrawStake(cross(cur), "ub7", id, sideYES)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	Unstake(cross(cur), "ub7", id, sideYES, 5_000_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Unstake(cross(cur), "ub7", id, sideNO, 5_000_000_000)

	// Nobody waits, because nobody was wrong.
	uassert.Equal(t, int64(0), CoolingOf("ub7", alice))
	uassert.Equal(t, int64(0), CoolingOf("ub7", bob))
	uassert.Equal(t, c.coin.BalanceOf(alice), SpendableOf("ub7", alice))
	uassert.Equal(t, c.coin.BalanceOf(bob), SpendableOf("ub7", bob))
}

// Two unbonds in different buckets are two rows that mature in order, and the
// sweep must not release the later one early. This is the ordering the zero
// padding in coolKey exists for: unpadded, "9" sorts after "10" and the walk
// would stop at the first row it mistook for the future.
func TestTranchesMatureInOrder(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ub-alice8")
	unbondCourt(cur, "ub8", alice, 20_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "ub8", "Do tranches mature in order?")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "ub8", id, sideYES, 9_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	Unstake(cross(cur), "ub8", id, sideYES, 3_000_000_000)
	first := ReleaseAt("ub8", alice)

	// Far enough ahead to land in a different bucket, so this is two rows.
	testing.SkipHeights(unbondBucket * 2)
	testing.SetRealm(testing.NewUserRealm(alice))
	Unstake(cross(cur), "ub8", id, sideYES, 4_000_000_000)
	second := ReleaseAt("ub8", alice)

	// ReleaseAt still answers with the EARLIEST, which is what a countdown needs.
	uassert.Equal(t, first, second)
	uassert.Equal(t, int64(7_000_000_000), CoolingOf("ub8", alice))

	// The first tranche matures alone.
	testing.SkipHeights(first - heightNow())
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, int64(3_000_000_000), ReleaseUnbonded(cross(cur), "ub8", alice))
	uassert.Equal(t, int64(4_000_000_000), CoolingOf("ub8", alice))
	uassert.True(t, ReleaseAt("ub8", alice) > heightNow())

	// Then the second.
	testing.SkipHeights(ReleaseAt("ub8", alice) - heightNow())
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, int64(4_000_000_000), ReleaseUnbonded(cross(cur), "ub8", alice))
	uassert.Equal(t, int64(0), CoolingOf("ub8", alice))
}

// Unbonds landing in the same bucket MERGE into one row. That is the property
// bounding per-address state: without it, ten thousand one-unit unstakes would be
// ten thousand rows of permanent court state paid for by everyone.
func TestSameBucketUnbondsMergeIntoOneRow(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ub-alice9")
	c := unbondCourt(cur, "ub9", alice, 20_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "ub9", "Do same-bucket unbonds merge?")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "ub9", id, sideYES, 9_000_000_000)

	for i := 0; i < 5; i++ {
		testing.SetRealm(testing.NewUserRealm(alice))
		Unstake(cross(cur), "ub9", id, sideYES, 1_000_000_000)
	}
	uassert.Equal(t, int64(5_000_000_000), CoolingOf("ub9", alice))

	rows := 0
	c.cooling.Iterate(string(alice)+"|", string(alice)+"|9999999999999999999",
		func(_ string, _ any) bool { rows++; return false })
	uassert.Equal(t, 1, rows)

	// One sweep frees all five.
	testing.SkipHeights(ReleaseAt("ub9", alice) - heightNow())
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, int64(5_000_000_000), ReleaseUnbonded(cross(cur), "ub9", alice))
}

// Anyone may sweep for anyone. It can only release what the schedule already
// released, so there is nothing to gain by doing it to a stranger — and a UI that
// wants to sweep on a holder's behalf should not need their key.
func TestAnyoneMaySweepForAnyone(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ub-alice10")
	stranger := testutils.TestAddress("ub-stranger")
	unbondCourt(cur, "ub10", alice, 8_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "ub10", "Who may sweep?")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "ub10", id, sideYES, 5_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Unstake(cross(cur), "ub10", id, sideYES, 5_000_000_000)

	testing.SkipHeights(ReleaseAt("ub10", alice) - heightNow())
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.Equal(t, int64(5_000_000_000), ReleaseUnbonded(cross(cur), "ub10", alice))

	// It landed with alice, not with the caller.
	uassert.Equal(t, mustCourt("ub10").coin.BalanceOf(alice), SpendableOf("ub10", alice))
	uassert.Equal(t, int64(0), CoolingOf("ub10", alice))
	uassert.Equal(t, int64(0), CoinBalanceOf("ub10", stranger))
}

// A court may opt out with unbondBlocks = 0, and then release is immediate as it
// was before this mechanism existed. Worth a test because zero is the value every
// pre-existing fixture in this suite implicitly wants, and because the guard on
// beginCooling is the only thing that keeps a zero from becoming an already-matured
// row rather than no row.
func TestACourtMayOptOut(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ub-alice11")
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "ub11", "No Cooling Court")
	c := mustCourt("ub11")
	c.params.unbondBlocks = 0
	c.coin.Mint(alice, 8_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "ub11", "Is opting out possible?")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "ub11", id, sideYES, 5_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Unstake(cross(cur), "ub11", id, sideYES, 5_000_000_000)

	uassert.Equal(t, int64(0), CoolingOf("ub11", alice))
	uassert.Equal(t, int64(0), ReleaseAt("ub11", alice))
	// Immediately spendable, and immediately sellable.
	all := SpendableOf("ub11", alice)
	uassert.Equal(t, c.coin.BalanceOf(alice), all)
	testing.SetRealm(testing.NewUserRealm(alice))
	TransferCC(cross(cur), "ub11", testutils.TestAddress("ub-bob11"), all)
}

// mustSane refuses a negative period, and refuses one longer than the dead-claim
// timeout — a lock outliving the claim that caused it by more than the claim's own
// maximum life is an expropriation with extra steps. Paired with the values it
// must accept, including 0.
func TestTheUnbondingPeriodIsBounded(cur realm, t *testing.T) {
	for _, ok := range []int64{0, 1, 120_960, deadClaimTimeout} {
		p := defaultParams()
		p.unbondBlocks = ok
		p.mustSane() // must not panic
	}
	// Panics, not aborts. mustSane is a plain method on a value in this package,
	// so there is no realm boundary to cross and no abort to catch — measured,
	// after AbortsContains let a correctly-firing guard through as a failure.
	uassert.PanicsContains(t, cur, "cannot be negative", func() {
		p := defaultParams()
		p.unbondBlocks = -1
		p.mustSane()
	})
	uassert.PanicsContains(t, cur, "cannot exceed the dead-claim timeout", func() {
		p := defaultParams()
		p.unbondBlocks = deadClaimTimeout + 1
		p.mustSane()
	})
}
