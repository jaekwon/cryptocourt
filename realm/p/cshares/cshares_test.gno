package cshares

import "testing"

const (
	alice = address("alice")
	bob   = address("bob")
	carol = address("carol")
)

const (
	YES = 0
	NO  = 1
)

func newBinary() *Ledger { return NewLedger("test", 2) }

// sumOutcome totals a set of known holders' shares of one outcome — the ledger
// does not iterate, so a test tracks its own holders to check conservation.
func sumOutcome(l *Ledger, id uint64, outcome int, holders ...address) int64 {
	var s int64
	for _, h := range holders {
		s += l.BalanceOf(id, outcome, h)
	}
	return s
}

func TestMintSetGivesEveryOutcomeAndRaisesSupply(t *testing.T) {
	l := newBinary()
	id := l.OpenClaim()
	l.MintSet(id, alice, 100)
	if l.BalanceOf(id, YES, alice) != 100 || l.BalanceOf(id, NO, alice) != 100 {
		t.Fatal("a set is one share of every outcome")
	}
	if l.Supply(id) != 100 {
		t.Fatalf("supply should be 100, got %d", l.Supply(id))
	}
}

func TestRedeemSetReturnsCollateralAndLowersSupply(t *testing.T) {
	l := newBinary()
	id := l.OpenClaim()
	l.MintSet(id, alice, 100)
	l.RedeemSet(id, alice, 40)
	if l.BalanceOf(id, YES, alice) != 60 || l.BalanceOf(id, NO, alice) != 60 {
		t.Fatal("redeeming a set burns one of each")
	}
	if l.Supply(id) != 60 {
		t.Fatalf("supply should be 60, got %d", l.Supply(id))
	}
}

func TestRedeemSetNeedsEveryOutcome(t *testing.T) {
	l := newBinary()
	id := l.OpenClaim()
	l.MintSet(id, alice, 100)
	// Sell away the YES side; now alice cannot redeem a set.
	l.Transfer(id, YES, alice, bob, 100)
	defer func() {
		if recover() == nil {
			t.Fatal("redeeming a set without every outcome should panic")
		}
		// And nothing was debited: alice still holds her 100 NO.
		if l.BalanceOf(id, NO, alice) != 100 {
			t.Fatal("a failed redeem must not partially debit")
		}
	}()
	l.RedeemSet(id, alice, 50)
}

func TestTransferLeavesSupplyUntouched(t *testing.T) {
	l := newBinary()
	id := l.OpenClaim()
	l.MintSet(id, alice, 100)
	l.Transfer(id, YES, alice, bob, 30)
	if l.Supply(id) != 100 {
		t.Fatalf("a transfer moves no collateral; supply should stay 100, got %d", l.Supply(id))
	}
	if l.BalanceOf(id, YES, alice) != 70 || l.BalanceOf(id, YES, bob) != 30 {
		t.Fatal("transfer did not move the shares")
	}
}

func TestConservationHoldsWhileOpen(t *testing.T) {
	l := newBinary()
	id := l.OpenClaim()
	l.MintSet(id, alice, 100)
	l.MintSet(id, bob, 50)
	l.Transfer(id, YES, alice, carol, 25)
	l.Transfer(id, NO, bob, carol, 10)
	l.RedeemSet(id, alice, 5)
	// Every outcome must sum to supply.
	s := l.Supply(id)
	if sumOutcome(l, id, YES, alice, bob, carol) != s {
		t.Fatalf("YES shares (%d) != supply (%d)", sumOutcome(l, id, YES, alice, bob, carol), s)
	}
	if sumOutcome(l, id, NO, alice, bob, carol) != s {
		t.Fatalf("NO shares (%d) != supply (%d)", sumOutcome(l, id, NO, alice, bob, carol), s)
	}
}

func TestResolveThenRedeemWinningPaysAndDrains(t *testing.T) {
	l := newBinary()
	id := l.OpenClaim()
	l.MintSet(id, alice, 100)           // alice: 100 YES, 100 NO
	l.Transfer(id, NO, alice, bob, 100) // alice keeps 100 YES; bob holds 100 NO
	l.Resolve(id, YES)

	paidA := l.RedeemWinning(id, alice)
	if paidA != 100 {
		t.Fatalf("alice's 100 YES should pay 100, got %d", paidA)
	}
	// bob's losing shares pay nothing and are cleared.
	paidB := l.RedeemWinning(id, bob)
	if paidB != 0 {
		t.Fatalf("bob's losing shares should pay 0, got %d", paidB)
	}
	if l.BalanceOf(id, YES, alice) != 0 || l.BalanceOf(id, NO, bob) != 0 {
		t.Fatal("redeeming winning clears all of a holder's shares")
	}
	if l.Supply(id) != 0 {
		t.Fatalf("all winners redeemed; supply should drain to 0, got %d", l.Supply(id))
	}
}

func TestTotalPaidEqualsCollateral(t *testing.T) {
	// The coin the court must pay out equals the collateral it took in — the
	// conservation the whole design rests on.
	l := newBinary()
	id := l.OpenClaim()
	l.MintSet(id, alice, 70)
	l.MintSet(id, bob, 30)              // 100 sets in, 100 collateral escrowed
	l.Transfer(id, YES, bob, alice, 30) // alice: 100 YES; bob: 0 YES, 30 NO...
	l.Resolve(id, YES)
	paid := l.RedeemWinning(id, alice) + l.RedeemWinning(id, bob)
	if paid != 100 {
		t.Fatalf("total paid should equal the 100 collateral in, got %d", paid)
	}
}

func TestApprovalGovernsTransferFrom(t *testing.T) {
	l := newBinary()
	id := l.OpenClaim()
	l.MintSet(id, alice, 100)
	// bob cannot move alice's shares without approval.
	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("unapproved TransferFrom should panic")
			}
		}()
		l.TransferFrom(bob, alice, id, YES, carol, 10)
	}()
	l.SetOperatorApproval(alice, bob, true)
	l.TransferFrom(bob, alice, id, YES, carol, 10)
	if l.BalanceOf(id, YES, carol) != 10 {
		t.Fatal("approved TransferFrom did not move shares")
	}
	l.SetOperatorApproval(alice, bob, false)
	if l.IsApproved(alice, bob) {
		t.Fatal("approval revoke did not take")
	}
}

func TestThreeOutcomeClaim(t *testing.T) {
	l := NewLedger("3way", 3)
	id := l.OpenClaim()
	l.MintSet(id, alice, 10) // 10 of each of 3 outcomes
	for o := 0; o < 3; o++ {
		if l.BalanceOf(id, o, alice) != 10 {
			t.Fatalf("outcome %d should be 10", o)
		}
	}
	l.Resolve(id, 2)
	if l.RedeemWinning(id, alice) != 10 {
		t.Fatal("winning outcome 2 should pay 10")
	}
}

func TestGuards(t *testing.T) {
	l := newBinary()
	id := l.OpenClaim()
	l.MintSet(id, alice, 10)

	// THE SETUP IS OUTSIDE THE CLOSURE, and that is the whole point. shouldPanic
	// asserts only that SOMETHING panicked — its label is a description, never
	// matched against the recovered value — so every statement inside the closure
	// is a way for this assertion to be satisfied by the wrong failure. Measured
	// on this very test: with Resolve patched to panic unconditionally, the old
	// four-statement-setup version still reported PASS.
	//
	// Hoisted, a setup that breaks fails the test where it breaks, and the closure
	// holds only the call whose refusal is being asserted. The other four
	// assertions below were already one call each.
	l2 := newBinary()
	i2 := l2.OpenClaim()
	l2.MintSet(i2, alice, 1)
	l2.Resolve(i2, YES)
	shouldPanic(t, "mint on resolved", func() {
		l2.MintSet(i2, alice, 1)
	})
	shouldPanic(t, "redeem-winning while open", func() {
		l.RedeemWinning(id, alice)
	})
	shouldPanic(t, "negative qty", func() {
		l.MintSet(id, alice, -1)
	})
	shouldPanic(t, "resolve to a non-outcome", func() {
		l.Resolve(id, 5)
	})
	shouldPanic(t, "unknown claim", func() {
		l.Supply(9999)
	})
}

func shouldPanic(t *testing.T, name string, fn func()) {
	defer func() {
		if recover() == nil {
			t.Fatalf("%s should have panicked", name)
		}
	}()
	fn()
}

func TestNoTradingAfterResolve(t *testing.T) {
	l := newBinary()
	id := l.OpenClaim()
	l.MintSet(id, alice, 100)
	l.Resolve(id, YES)
	shouldPanic(t, "transfer after resolve", func() {
		l.Transfer(id, YES, alice, bob, 10)
	})
}

func TestApprovalKeysDoNotCollide(t *testing.T) {
	// Without a delimiter, ("ab","c") and ("a","bc") would share a key. With one
	// they are independent.
	l := newBinary()
	l.SetOperatorApproval(address("ab"), address("c"), true)
	if l.IsApproved(address("a"), address("bc")) {
		t.Fatal("approval keys collided across a differently-split pair")
	}
	if !l.IsApproved(address("ab"), address("c")) {
		t.Fatal("the real approval was lost")
	}
}

func TestBalanceOfRangeChecks(t *testing.T) {
	l := newBinary()
	id := l.OpenClaim()
	shouldPanic(t, "out-of-range outcome read", func() {
		l.BalanceOf(id, 2, alice) // binary claim has outcomes 0,1
	})
}

func TestCloseAtFractionalPayout(t *testing.T) {
	l := newBinary()
	id := l.OpenClaim()
	l.MintSet(id, alice, 100)           // alice: 100 YES, 100 NO
	l.Transfer(id, NO, alice, bob, 100) // alice: 100 YES; bob: 100 NO
	l.CloseAt(id, 1, 4)                 // p = 1/4: YES pays 1/4, NO pays 3/4
	if got := l.RedeemClosed(id, alice); got != 25 {
		t.Fatalf("alice's 100 YES at p=1/4 should pay 25, got %d", got)
	}
	if got := l.RedeemClosed(id, bob); got != 75 {
		t.Fatalf("bob's 100 NO at 1-p=3/4 should pay 75, got %d", got)
	}
	if l.Supply(id) != 0 {
		t.Fatalf("total paid was 100 = supply; supply should drain to 0, got %d", l.Supply(id))
	}
	if n, d := l.CloseFractionOf(id); n != 1 || d != 4 {
		t.Fatalf("CloseFractionOf should read 1/4, got %d/%d", n, d)
	}
}

func TestCloseAtConserves(t *testing.T) {
	// Any price conserves: a holder with matched y=n is paid exactly y (p+(1−p)=1);
	// the floor leaves at most ~1 dust per holder in the pool (safe).
	l := newBinary()
	id := l.OpenClaim()
	l.MintSet(id, alice, 70)
	l.MintSet(id, bob, 30) // supply 100; each holds y == n
	l.CloseAt(id, 3, 7)
	paid := l.RedeemClosed(id, alice) + l.RedeemClosed(id, bob)
	if paid > 100 {
		t.Fatalf("payout %d exceeds supply 100", paid)
	}
	if 100-paid > 2 {
		t.Fatalf("payout %d too far below supply 100 (dust)", paid)
	}
}

func TestCloseAtGuards(t *testing.T) {
	l3 := NewLedger("3way", 3)
	i3 := l3.OpenClaim()
	shouldPanic(t, "close a non-binary claim", func() { l3.CloseAt(i3, 1, 2) })

	l := newBinary()
	id := l.OpenClaim()
	l.MintSet(id, alice, 10)
	shouldPanic(t, "num > den", func() { l.CloseAt(id, 3, 2) })
	shouldPanic(t, "den zero", func() { l.CloseAt(id, 0, 0) })
	shouldPanic(t, "redeem-closed while open", func() { l.RedeemClosed(id, alice) })
	l.CloseAt(id, 1, 2)
	shouldPanic(t, "trade after close", func() { l.Transfer(id, YES, alice, bob, 1) })
	shouldPanic(t, "mint after close", func() { l.MintSet(id, alice, 1) })
	shouldPanic(t, "redeem-winning a closed claim", func() { l.RedeemWinning(id, alice) })
}

func TestSelfTransferIsANoOp(t *testing.T) {
	l := newBinary()
	id := l.OpenClaim()
	l.MintSet(id, alice, 100)
	l.Transfer(id, YES, alice, alice, 30) // self-transfer moves nothing
	if l.BalanceOf(id, YES, alice) != 100 {
		t.Fatalf("a self-transfer must leave the balance unchanged, got %d", l.BalanceOf(id, YES, alice))
	}
	shouldPanic(t, "self-transfer beyond balance", func() {
		l.Transfer(id, YES, alice, alice, 200)
	})
}

func TestPackedOutcomesAreIndependent(t *testing.T) {
	// The packed (id,holder) position must keep outcomes independent: moving one
	// must not disturb the others' slots.
	l := NewLedger("3way", 3)
	id := l.OpenClaim()
	l.MintSet(id, alice, 10) // 10 of each of 3 outcomes
	l.Transfer(id, 1, alice, bob, 4)
	if l.BalanceOf(id, 0, alice) != 10 || l.BalanceOf(id, 1, alice) != 6 || l.BalanceOf(id, 2, alice) != 10 {
		t.Fatalf("moving outcome 1 disturbed another slot: %d/%d/%d",
			l.BalanceOf(id, 0, alice), l.BalanceOf(id, 1, alice), l.BalanceOf(id, 2, alice))
	}
	if l.BalanceOf(id, 1, bob) != 4 {
		t.Fatalf("bob should hold the 4 moved outcome-1 shares, got %d", l.BalanceOf(id, 1, bob))
	}
}

func TestMintSetIsAtomicOnSupplyOverflow(t *testing.T) {
	// MintSet must validate the supply BEFORE crediting any outcome, so a caller
	// that recovers the overflow panic cannot be left with a half-credited claim
	// (some outcomes credited, supply unchanged) — which would break conservation.
	l := newBinary()
	id := l.OpenClaim()
	huge := int64(9223372036854775807) // MaxInt64; one more set overflows supply
	l.MintSet(id, alice, huge)
	shouldPanic(t, "overflowing mint", func() { l.MintSet(id, bob, 1) })
	// The failed mint credited nothing and left supply intact.
	if l.BalanceOf(id, YES, bob) != 0 || l.BalanceOf(id, NO, bob) != 0 {
		t.Fatal("a failed mint must not credit any outcome")
	}
	if l.Supply(id) != huge {
		t.Fatalf("supply must be unchanged after a failed mint, got %d", l.Supply(id))
	}
}

func TestApprovalKeyNulBoundaryDoesNotForge(t *testing.T) {
	// The exploit a bare-delimiter key would allow: a NUL inside one address
	// shifting the owner/operator split so an unrelated pair reads as approved.
	// The length prefix makes the split independent of address content.
	l := newBinary()
	l.SetOperatorApproval(address("a\x00b"), address("c"), true)
	if l.IsApproved(address("a"), address("b\x00c")) {
		t.Fatal("a NUL inside an address must not forge approval for a different pair")
	}
	if !l.IsApproved(address("a\x00b"), address("c")) {
		t.Fatal("the real approval must still read back")
	}
}
