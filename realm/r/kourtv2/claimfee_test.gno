package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// THE FEE IS PART OF WHAT THE LOCK MUST COVER. openClaim checks
// `mustSpendable(c, who, dep+fee)` and then moves `dep+fee`; narrowing the check to
// `dep` survived every test in the repo. The two are not interchangeable, because
// mustSpendable is the only thing that consults the LOCKS — the transfer beneath it is
// the raw ledger move and knows nothing about staked or voted coin. So a check that
// under-counts by the fee lets exactly that much leave a balance that had it committed.
//
// The fee is 10% of the deposit (depositFeeBps = 1000), so each open leaks a tenth of a
// deposit out of locked coin, and a holder can repeat it until their disposable balance
// is gone. The lock is meant to be inviolable; this makes it porous by a known fraction.
//
// THE DISCRIMINATING STATE is one unit short of the true cost. At disposable ==
// dep+fee the correct code and the narrowed one both allow the open, and at
// dep+fee-1 they disagree — which is why this test arranges that exact figure and says
// so before asserting anything. The pairing is the same court one unit later.
func TestOpeningAClaimCannotDipIntoLockedCoinForItsFee(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cfee-alice")
	c := testCourt(cur, "cfee", alice, 40_000_000_000)

	// Read the cost AFTER the only mint, because effMinDeposit is a fraction of
	// SUPPLY (supplyFloor) — minting again below would move the target.
	dep := effMinDeposit(c)
	fee := dep * depositFeeBps / 10000
	if dep <= 0 || fee <= 0 {
		t.Fatalf("setup: both halves of the cost must be positive, dep=%d fee=%d", dep, fee)
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	first := OpenClaim(cross(cur), "cfee", "a claim to stake against")

	// Stake so that exactly one unit LESS than the true cost is disposable.
	bal := c.coin.BalanceOf(alice)
	lock := bal - (dep + fee - 1)
	if lock <= 0 {
		t.Fatalf("setup: the fixture needs room to lock, balance=%d cost=%d", bal, dep+fee)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "cfee", first, sideYES, lock)
	if got := DisposableOf("cfee", alice); got != dep+fee-1 {
		t.Fatalf("setup: disposable must be one unit short of %d, got %d", dep+fee, got)
	}

	// One unit short: refused, and refused by the LOCK rather than by the balance —
	// the balance is still far larger than the cost.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "not enough unstaked CC", func() {
		OpenClaim(cross(cur), "cfee", "a claim funded out of staked coin")
	})
	if c.coin.BalanceOf(alice) <= dep+fee {
		t.Fatal("setup: the refusal must be the lock's, not a balance that is short")
	}

	// PAIRED: release one unit and the same open goes through, so the refusal above is
	// the fee's own unit and not a court that stopped accepting claims.
	testing.SetRealm(testing.NewUserRealm(alice))
	Unstake(cross(cur), "cfee", first, sideYES, 1)
	if got := DisposableOf("cfee", alice); got != dep+fee {
		t.Fatalf("setup: disposable must now be exactly %d, got %d", dep+fee, got)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	second := OpenClaim(cross(cur), "cfee", "a claim funded out of free coin")
	if second == first {
		t.Fatal("the second claim must be its own claim")
	}
	// And the escrow really took both halves, which is what the check was protecting.
	if got := DisposableOf("cfee", alice); got != 0 {
		t.Errorf("the open must consume the whole cost, %d left disposable", got)
	}
}
