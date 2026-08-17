package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// The claim lifecycle's guards, a cluster the mutation harness found entirely
// unpinned: CloseDeadClaim on an ANSWERED claim, a double close, and OpenClaim's title
// bounds all failed no test. The answered case is the serious one — a claim with an
// answer has a bond in escrow and a settle path, and "dying" instead would refund the
// deposit, mark it closed, and leave Crystallize panicking on `closed` forever. It is
// reachable because deadClaimTimeout and the answerability window are both 12 weeks, so
// an answer landing near the end leaves a claim that is both answered and past the
// timeout.
func TestCloseDeadClaimRefusesAnsweredAndRepeatCloses(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ded-alice")
	c := testCourt(cur, "ded", alice, 50_000_000_000)

	// An ANSWERED claim settles; it does not die.
	testing.SetRealm(testing.NewUserRealm(alice))
	answered := OpenClaim(cross(cur), "ded", "answered, so it settles")
	matureOI(cur, "ded", answered, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "ded", answered, sideYES)
	testing.SkipHeights(deadClaimTimeout + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "it settles, it does not die", func() {
		CloseDeadClaim(cross(cur), "ded", answered)
	})
	if acs := mustClaim(c, answered); acs.closed || acs.deposit == 0 {
		t.Fatalf("a refused close must not have closed or refunded: closed=%t deposit=%d",
			acs.closed, acs.deposit)
	}

	// An UNANSWERED claim past the timeout dies exactly once.
	testing.SetRealm(testing.NewUserRealm(alice))
	dead := OpenClaim(cross(cur), "ded", "nobody answered this")
	testing.SkipHeights(deadClaimTimeout + 1)
	before := c.coin.BalanceOf(alice)
	CloseDeadClaim(cross(cur), "ded", dead)
	dcs := mustClaim(c, dead)
	if !dcs.closed || dcs.deposit != 0 || dcs.fee != 0 {
		t.Fatalf("the close must refund the deposit and burn the fee: closed=%t dep=%d fee=%d",
			dcs.closed, dcs.deposit, dcs.fee)
	}
	refunded := c.coin.BalanceOf(alice) - before
	if refunded <= 0 {
		t.Fatalf("the author must get their deposit back: %d", refunded)
	}
	// And a second close is refused rather than paying again. The field zeroing above
	// already makes the payout exactly-once, so this pins the CONTRACT: the call is an
	// error, not a silent no-op a caller can loop on.
	uassert.AbortsContains(t, cur, "already closed", func() {
		CloseDeadClaim(cross(cur), "ded", dead)
	})
	if got := c.coin.BalanceOf(alice) - before; got != refunded {
		t.Fatalf("a refused second close must pay nothing more: %d vs %d", got, refunded)
	}
}

// OpenClaim's title bounds, also unpinned. The title is attacker-chosen and reaches
// every render path, so an unbounded one is storage and page cost; an empty one renders
// a claim nobody can identify.
func TestOpenClaimBoundsTheTitle(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tit-alice")
	testCourt(cur, "tit", alice, 50_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "1..200 characters", func() {
		OpenClaim(cross(cur), "tit", "")
	})
	long := ""
	for i := 0; i < 201; i++ {
		long += "x"
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "1..200 characters", func() {
		OpenClaim(cross(cur), "tit", long)
	})
	// Both boundaries are ACCEPTED, so the guard is not rejecting everything.
	testing.SetRealm(testing.NewUserRealm(alice))
	OpenClaim(cross(cur), "tit", "x")
	testing.SetRealm(testing.NewUserRealm(alice))
	OpenClaim(cross(cur), "tit", long[:200])
}

// StartCourt's slug uniqueness, unpinned: overwriting a taken slug replaces the Court
// value the tree holds, orphaning every claim, position and escrowed balance under it
// while the coin ledger keeps the funds. Three of my own test-slug collisions this
// session surfaced this panic as a SETUP failure, which is not the same as asserting it.
func TestStartCourtRefusesATakenSlug(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sct-alice")
	bob := testutils.TestAddress("sct-bob")
	c := testCourt(cur, "sct", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "sct", "a claim that must not be orphaned")

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "that slug is taken", func() {
		StartCourt(cross(cur), "sct", "Impostor Court")
	})
	// The original court and its claim survive untouched.
	if mustCourt("sct") != c {
		t.Fatal("a refused StartCourt must not replace the court")
	}
	if mustClaim(c, id).title != "a claim that must not be orphaned" {
		t.Fatal("the existing claim must survive")
	}
}
