package kourtv2

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

	// Both sides withdraw 1×: the loser loses nothing. Since v0.34 that is a lock
	// RELEASE, not a payment — bob's principal never left his balance, so the
	// withdrawal reports the full amount while the balance does not move. The
	// balance-unchanged assertion is the one that would catch a release path that
	// paid out as well as unlocking, which would mint principal from nothing.
	bobBefore := c.coin.BalanceOf(bob)
	if got := LockedOf("se1", bob); got != 300_000_000 {
		t.Fatalf("bob's stake should be locked, not escrowed: locked = %d", got)
	}
	testing.SetRealm(testing.NewUserRealm(bob))
	got := WithdrawStake(cross(cur), "se1", id, sideNO)
	if got != 300_000_000 {
		t.Fatalf("the losing side withdraws its full principal: got %d", got)
	}
	if c.coin.BalanceOf(bob) != bobBefore {
		t.Fatalf("withdrawal is a release, not a transfer: balance moved %d",
			c.coin.BalanceOf(bob)-bobBefore)
	}
	if got := LockedOf("se1", bob); got != 0 {
		t.Fatalf("withdrawal must clear the lock: locked = %d", got)
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
