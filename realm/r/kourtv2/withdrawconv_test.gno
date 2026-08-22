package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// TAKING YOUR PRINCIPAL BACK MUST NOT FORFEIT THE CONVICTION YOU EARNED. WithdrawStake
// calls accrue before it zeroes the position — "settles to the freeze pin (a no-op if
// already settled)" — and deleting that line survived an operator sweep of the whole
// settlement path, the only one of eleven that did.
//
// What it costs is the withdrawer's reward, not their principal. accrue integrates
// stake x time up to the freeze pin, and once the stake is zero there is nothing left to
// integrate: WithdrawBonus reads the STORED convHi/convLo, and its own accrue call adds
// nothing for a position holding nothing. So the interval between the last settle and the
// freeze silently disappears from the withdrawer's share of the winners' slice.
//
// WHY ConvictionOf CANNOT SEE IT, which is why the assertion is on the bonus. That read
// previews the un-accrued tail on a transient copy — deliberately, so a read never
// mutates — and therefore reports the same number whether or not the stored integral was
// settled. A test that watched the read would have watched the one surface immune to the
// defect.
//
// THE SHAPE IS A PAIR, because the absolute figure depends on the whole fixture. Two
// stakers, same side, same amount, same blocks; one takes their principal back before
// crystallize and one leaves it. Their accuracy bonuses must be equal — the withdrawal is
// a claim on principal, not a waiver of what the stake already earned.
func TestWithdrawingPrincipalKeepsTheConvictionItEarned(cur realm, t *testing.T) {
	alice := testutils.TestAddress("wcv-alice")
	bob := testutils.TestAddress("wcv-bob")
	carol := testutils.TestAddress("wcv-carol")
	c := testCourt(cur, "wcv", alice, 60_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "wcv", "who keeps what they earned")
	matureOI(cur, "wcv", id, alice, 200_000_000)

	// Both on the side the answer will make the winner, same size, same moment.
	const stake = int64(400_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "wcv", id, sideYES, stake)
	testing.SetRealm(testing.NewUserRealm(carol))
	Stake(cross(cur), "wcv", id, sideYES, stake)

	// TIME BEFORE THE FREEZE, or neither staker earns any conviction to argue about:
	// the integral runs from the stake to the freeze pin, and the first version put the
	// answer on the very next statement, so both convictions were ZERO and the setup
	// guard caught it as bob=0 carol=0. Measured on that fixture: the pool integral was
	// 22,767 CC-units, all of it from the OI maturing before they staked, and bob's own
	// was 0.
	testing.SkipHeights(20_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "wcv", id, sideYES)
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	SettleUndisputed(cross(cur), "wcv", id)

	// CROSS THE FIRST WEEKLY PERIOD BOUNDARY, or there is no draw to share and both
	// bonuses are zero: the reservoir starts EMPTY and the first budget lands at the
	// first roll. The setup guard below caught exactly that — bob=0 carol=0 — which is
	// the difference between a fixture that cannot fail and one that does.
	testing.SkipHeights(100_000)

	// BOB takes his principal back first. This is the call whose accrue is his only
	// chance to settle: after it his stake is zero, and every later accrue adds nothing.
	testing.SetRealm(testing.NewUserRealm(bob))
	back := WithdrawStake(cross(cur), "wcv", id, sideYES)
	if back != stake {
		t.Fatalf("setup: the whole principal must come back, got %d of %d", back, stake)
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "wcv", id)

	testing.SetRealm(testing.NewUserRealm(bob))
	bobBonus := WithdrawBonus(cross(cur), "wcv", id, sideYES)
	testing.SetRealm(testing.NewUserRealm(carol))
	carolBonus := WithdrawBonus(cross(cur), "wcv", id, sideYES)

	// The fixture has to be able to fail: if neither earns anything, equality is empty.
	if bobBonus <= 0 || carolBonus <= 0 {
		t.Fatalf("setup: both stakers must earn a bonus at all, bob=%d carol=%d",
			bobBonus, carolBonus)
	}
	if bobBonus != carolBonus {
		t.Fatalf("withdrawing principal must not forfeit conviction: the withdrawer "+
			"earned %d and the holder %d on identical stakes", bobBonus, carolBonus)
	}
}
