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
	if c.coin.BalanceOf(alice) != beforeBond+bond {
		t.Fatal("the bond returns to the answerer")
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
	// Escrow now holds only the claim's deposit+fee (the finalize flow owns
	// their disposition) — every stake and the bond are out.
	dep := c.params.minClaimDepositCC
	if got := c.coin.BalanceOf(c.escrow); got != dep+dep*depositFeeBps/10000 {
		t.Fatalf("escrow must drain to deposit+fee: %d", got)
	}
	// Conviction survives withdrawal (the reward draws read it later).
	if ConvictionOf("se1", id, sideYES, alice) <= 0 {
		t.Fatal("conviction records must survive principal withdrawal")
	}
}
