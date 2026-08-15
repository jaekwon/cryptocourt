package cshares

import "testing"

func mustPanic(t *testing.T, name string, fn func()) {
	t.Helper()
	defer func() {
		if recover() == nil {
			t.Fatalf("%s: expected a panic, got none", name)
		}
	}()
	fn()
}

// Reclaim is the settlement counterpart to Transfer — the ONLY mutator allowed after a
// claim resolves — yet it had zero direct tests (exercised only through the court). It
// must move escrowed shares on a Resolved/Closed claim (where Transfer is refused) and
// conserve supply.

func TestReclaimMovesAfterResolveAndConserves(t *testing.T) {
	venue := address("venue") // stands in for a market realm's escrow address
	l := newBinary()
	id := l.OpenClaim()
	l.MintSet(id, alice, 100)              // alice: 100 YES + 100 NO
	l.Transfer(id, YES, alice, venue, 100) // escrow the YES while the claim is Open
	l.Resolve(id, YES)                     // YES wins → Transfer now refused, Reclaim allowed

	mustPanic(t, "Transfer after resolve", func() {
		l.Transfer(id, YES, venue, alice, 100)
	})
	l.Reclaim(id, YES, venue, alice, 100) // settlement: return the escrowed winning shares
	if l.BalanceOf(id, YES, alice) != 100 {
		t.Fatalf("Reclaim should return the 100 escrowed YES, alice has %d", l.BalanceOf(id, YES, alice))
	}
	if paid := l.RedeemWinning(id, alice); paid != 100 {
		t.Fatalf("100 winning YES should redeem 100, got %d", paid)
	}
	if l.Supply(id) != 0 {
		t.Fatalf("every winning share redeemed → supply 0, got %d", l.Supply(id))
	}
}

func TestReclaimWorksOnClosedClaim(t *testing.T) {
	venue := address("venue")
	l := newBinary()
	id := l.OpenClaim()
	l.MintSet(id, alice, 100)              // 100 YES + 100 NO
	l.Transfer(id, YES, alice, venue, 100) // escrow the YES (Open)
	l.CloseAt(id, 1, 2)                    // close at 50/50; Transfer refused, Reclaim allowed

	l.Reclaim(id, YES, venue, alice, 100)
	if l.BalanceOf(id, YES, alice) != 100 {
		t.Fatal("Reclaim should move shares on a Closed claim")
	}
	// alice now holds 100 YES + 100 NO; at 1/2 each pays floor(100/2)+floor(100/2)=100.
	if paid := l.RedeemClosed(id, alice); paid != 100 {
		t.Fatalf("a 50/50 close on 100 sets should redeem 100, got %d", paid)
	}
}

func TestReclaimGuards(t *testing.T) {
	l := newBinary()
	id := l.OpenClaim()
	l.MintSet(id, alice, 100)
	l.Resolve(id, YES)

	mustPanic(t, "insufficient shares", func() { l.Reclaim(id, YES, bob, alice, 1) }) // bob holds none
	mustPanic(t, "unknown claim", func() { l.Reclaim(id+999, YES, alice, bob, 1) })   // no such claim
	mustPanic(t, "non-positive qty", func() { l.Reclaim(id, YES, alice, bob, 0) })
	mustPanic(t, "outcome out of range", func() { l.Reclaim(id, 5, alice, bob, 1) })
}

// TestRedeemSetAtomicOnLaterOutcome pins the fail-atomic two-loop RedeemSet where the
// existing test cannot: it shorts the LAST outcome of a 3-outcome claim, so a fused
// check-and-debit loop would have debited outcomes 0 and 1 before hitting the shortfall.
func TestRedeemSetAtomicOnLaterOutcome(t *testing.T) {
	l := NewLedger("triple", 3)
	id := l.OpenClaim()
	l.MintSet(id, alice, 10)          // 10 of outcomes 0, 1, 2
	l.Transfer(id, 2, alice, bob, 10) // sell away the LAST outcome
	defer func() {
		if recover() == nil {
			t.Fatal("redeeming a set without every outcome should panic")
		}
		if l.BalanceOf(id, 0, alice) != 10 || l.BalanceOf(id, 1, alice) != 10 {
			t.Fatal("a failed redeem must not partially debit the EARLIER outcomes")
		}
	}()
	l.RedeemSet(id, alice, 5)
}

// TestStatusMachineOneWay: a claim leaves Open exactly once. Every re-resolution or
// cross-status transition, and every redeem on the wrong status, must panic.
func TestStatusMachineOneWay(t *testing.T) {
	l := newBinary()
	res := l.OpenClaim()
	l.MintSet(res, alice, 10)
	l.Resolve(res, YES)
	mustPanic(t, "double resolve", func() { l.Resolve(res, NO) })
	mustPanic(t, "resolve then close", func() { l.CloseAt(res, 1, 2) })
	mustPanic(t, "RedeemClosed on a Resolved claim", func() { l.RedeemClosed(res, alice) })

	cl := l.OpenClaim()
	l.MintSet(cl, alice, 10)
	l.CloseAt(cl, 1, 2)
	mustPanic(t, "double close", func() { l.CloseAt(cl, 1, 3) })
	mustPanic(t, "close then resolve", func() { l.Resolve(cl, YES) })
	mustPanic(t, "RedeemWinning on a Closed claim", func() { l.RedeemWinning(cl, alice) })
}
