package courtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

func TestSettleUndisputedAndWithdraw(cur realm, t *testing.T) {
	alice := testutils.TestAddress("se-alice")
	bob := testutils.TestAddress("se-bob")
	c := testCourt(cur, "se1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "se1", "Settles by silence")
	matureOI(cur, "se1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "se1", id, sideNO, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "se1", id, sideYES)
	bond := AnswerBond("se1", id)

	// Too early; then no withdrawals before the verdict.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "has not aged", func() {
		SettleUndisputed(cross(cur), "se1", id)
	})
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "no verdict yet", func() {
		WithdrawStake(cross(cur), "se1", id, sideNO)
	})

	testing.SkipHeights(settleDelay)
	beforeBond := c.coin.BalanceOf(alice)
	testing.SetRealm(testing.NewUserRealm(bob))
	SettleUndisputed(cross(cur), "se1", id) // permissionless
	if !Settled("se1", id) || Verdict("se1", id) != sideYES || VerdictRoute("se1", id) != "undisputed" {
		t.Fatal("the verdict must record with its route")
	}
	// Settle returns the bond MINUS a slash-sized reserve held through the
	// quality slot (M3-HIGH-1); the reserve returns at crystallize if unslashed.
	reserve := XBarFrozen("se1", id) * slashXBps / 10000
	if c.coin.BalanceOf(alice) != beforeBond+bond-reserve {
		t.Fatalf("settle returns bond minus the slash reserve: got %d want %d",
			c.coin.BalanceOf(alice)-beforeBond, bond-reserve)
	}
	// Double settle refused; bond cannot double-return.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "already settled", func() {
		SettleUndisputed(cross(cur), "se1", id)
	})

	// Both sides withdraw 1×: the loser loses nothing.
	bobBefore := c.coin.BalanceOf(bob)
	testing.SetRealm(testing.NewUserRealm(bob))
	got := WithdrawStake(cross(cur), "se1", id, sideNO)
	if got != 300_000_000 || c.coin.BalanceOf(bob) != bobBefore+300_000_000 {
		t.Fatal("the losing side withdraws its full principal")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	WithdrawStake(cross(cur), "se1", id, sideYES)
	// Second withdrawal: nothing left.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "nothing staked", func() {
		WithdrawStake(cross(cur), "se1", id, sideNO)
	})
	// Escrow now holds the claim's deposit+fee AND the retained slash reserve
	// (crystallize owns their disposition) — every stake and the freed bond
	// are out.
	dep := c.params.minClaimDepositCC
	if got := c.coin.BalanceOf(c.escrow); got != dep+dep*depositFeeBps/10000+reserve {
		t.Fatalf("escrow must drain to deposit+fee+reserve: %d", got)
	}
	// Conviction survives withdrawal (the reward draws read it later).
	if ConvictionOf("se1", id, sideYES, alice) <= 0 {
		t.Fatal("conviction records must survive principal withdrawal")
	}
}

// WithdrawStake's per-side bookkeeping, found SURVIVING: swap the two branches so a
// withdrawal debits the OTHER side's pool and no test objected. Every other guard in
// the function is pinned — the zeroing, the empty position, both clauses of the
// early-withdrawal gate — because they all abort or change what the caller receives.
// This one changes neither: the withdrawer gets the right coin either way, and the
// damage is left behind in the claim.
//
// It is not cosmetic. advancePools builds the per-side integral-of-stake-over-time
// from these totals (its own comment requires it to run BEFORE any mutation of them),
// and that integral is the F9 cap base every bonus is clamped against; the totals also
// feed the OI and YES observations. A withdrawal debited to the wrong side therefore
// corrupts the conviction accounting of a side that did nothing, and — since the losing
// side may leave EARLY, while the claim is still live (F7/A12) — it can do so before
// the numbers are finished being used.
//
// The discriminating assertion is the one after the FIRST withdrawal. Once both sides
// have withdrawn, a swapped debit has subtracted both amounts either way, and the only
// trace left is in the two totals separately.
func TestWithdrawStakeDebitsItsOwnSidesPool(cur realm, t *testing.T) {
	alice := testutils.TestAddress("wsp1-alice")
	bob := testutils.TestAddress("wsp1-bob")
	c := testCourt(cur, "wsp1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "wsp1", "Whose pool a withdrawal comes out of")
	matureOI(cur, "wsp1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "wsp1", id, sideNO, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "wsp1", id, sideYES)

	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "wsp1", id)

	// Read the pools HERE, after the settle, rather than asserting figures: matureOI
	// stakes repeatedly to mature the observation window, so the YES total is a
	// multiple of its argument and not the argument. What this fixture actually needs
	// of the setup is only that both pools are live and UNEQUAL — equal pools would
	// hide a swapped debit by symmetry.
	yes0, no0 := StakePools("wsp1", id)
	if yes0 <= 0 || no0 <= 0 || yes0 == no0 {
		t.Fatalf("setup: both pools must be live and unequal, got %d/%d", yes0, no0)
	}

	// The NO side leaves. Its own pool must fall to zero and YES must not move.
	testing.SetRealm(testing.NewUserRealm(bob))
	if got := WithdrawStake(cross(cur), "wsp1", id, sideNO); got != no0 {
		t.Fatalf("the NO side withdraws its whole stake: got %d want %d", got, no0)
	}
	yes1, no1 := StakePools("wsp1", id)
	if no1 != 0 {
		t.Fatalf("the withdrawn side's pool must drain to zero, got %d", no1)
	}
	if yes1 != yes0 {
		t.Fatalf("the OTHER side's pool must not move: %d became %d", yes0, yes1)
	}

	// And the YES side after it, leaving both at zero rather than one negative.
	testing.SetRealm(testing.NewUserRealm(alice))
	if got := WithdrawStake(cross(cur), "wsp1", id, sideYES); got != yes0 {
		t.Fatalf("the YES side withdraws its whole stake: got %d want %d", got, yes0)
	}
	if yes2, no2 := StakePools("wsp1", id); yes2 != 0 || no2 != 0 {
		t.Fatalf("both pools must end empty, got %d/%d", yes2, no2)
	}
}
