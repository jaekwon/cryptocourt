package kourtv1

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// The reopen / bond-doubling / 3-round-close machine (V2). A provisional verdict is
// reopenable during its escrow window; each failed reopen doubles the disputer's bond
// and counts toward a three-failed-round close at the pre-answer price.

// TestReopenDoublesBondAndKeepsEscrowClock: a failed dispute leaves a standing verdict
// that a FRESH disputer can reopen — for double the bond (sybil-proof), without resetting
// the escrow clock.
func TestReopenDoublesBondAndKeepsEscrowClock(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rd-alice")
	d1 := testutils.TestAddress("rd-d1")
	d2 := testutils.TestAddress("rd-d2") // a FRESH address for round 2 — the multiplier must not reset

	fundAndBuy(cur, "rd", "Reopen Bond Court", alice, 300_000_000)
	buyCoin(cur, "rd", d1, 60_000_000)
	buyCoin(cur, "rd", d2, 60_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	cid := OpenClaim(cross(cur), "rd", "Disputed twice")
	matureOI(cur, "rd", cid, alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "rd", cid, outcomeYES)

	// Round 1: dispute, nobody votes → fails quorum.
	testing.SetRealm(testing.NewUserRealm(d1))
	OpenDispute(cross(cur), "rd", cid)
	b1 := DisputeBond("rd", cid)
	testing.SkipHeights(121000)
	testing.SetRealm(testing.NewUserRealm(d1))
	ResolveDispute(cross(cur), "rd", cid)
	if FailedRounds("rd", cid) != 1 {
		t.Fatalf("round 1 should fail quorum, failedRounds=%d", FailedRounds("rd", cid))
	}
	escrowAfter1 := EscrowUntil("rd", cid)
	if !Reopenable("rd", cid) {
		t.Fatal("a standing verdict inside its escrow window should be reopenable")
	}

	// Round 2 (reopen, fresh address): the bond DOUBLES and the escrow clock is untouched.
	testing.SetRealm(testing.NewUserRealm(d2))
	OpenDispute(cross(cur), "rd", cid)
	if b2 := DisputeBond("rd", cid); b2 != 2*b1 {
		t.Fatalf("a reopen's bond should double: b1=%d b2=%d", b1, b2)
	}
	if EscrowUntil("rd", cid) != escrowAfter1 {
		t.Fatal("a reopen must NOT reset the escrow clock")
	}
	testing.SkipHeights(121000)
	testing.SetRealm(testing.NewUserRealm(d2))
	ResolveDispute(cross(cur), "rd", cid)
	if FailedRounds("rd", cid) != 2 {
		t.Fatalf("a second failed round should tick failedRounds to 2, got %d", FailedRounds("rd", cid))
	}
}

// TestReopenOverturnsSettledClaim: the optimistic path's safety net — an undisputed
// settlement (which earmarks a settlement fee) is reopened during escrow and OVERTURNED;
// the verdict flips, the fee flips settlement→adjudication (never both), and the answer
// bond — already returned at settlement — is not double-paid.
func TestReopenOverturnsSettledClaim(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ro-alice") // founder, answerer
	carol := testutils.TestAddress("ro-carol") // the reopening disputer + overturn voter (majority)

	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "ro", "Reopen Overturn Court")
	buyCoin(cur, "ro", carol, 500_000_000)
	buyCoin(cur, "ro", alice, 100_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	cid := OpenClaim(cross(cur), "ro", "Settled then reopened")
	matureOI(cur, "ro", cid, alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "ro", cid, outcomeYES)

	// Settle undisputed: settlement-fee earmark, answer bond returned to alice (and zeroed).
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	SettleUndisputed(cross(cur), "ro", cid)
	if FeeKind("ro", cid) != "settlement" {
		t.Fatalf("an undisputed settle should earmark a settlement fee, got %s", FeeKind("ro", cid))
	}
	escrowAfterSettle := EscrowUntil("ro", cid)

	// Reopen during escrow; carol overturns.
	testing.SetRealm(testing.NewUserRealm(carol))
	OpenDispute(cross(cur), "ro", cid)
	if EscrowUntil("ro", cid) != escrowAfterSettle {
		t.Fatal("a reopen must not reset the escrow clock")
	}
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "ro", cid, "yes")
	testing.SkipHeights(130000)
	testing.SetRealm(testing.NewUserRealm(carol))
	ResolveDispute(cross(cur), "ro", cid)

	if Provisional("ro", cid) != outcomeNO {
		t.Fatalf("the reopen should overturn YES to NO, got %d", Provisional("ro", cid))
	}
	if FeeKind("ro", cid) != "adjudication" {
		t.Fatalf("a reopen that decides pays the adjudication fee (never both), got %s", FeeKind("ro", cid))
	}

	testing.SkipHeights(130000)
	testing.SetRealm(testing.NewUserRealm(carol))
	Finalize(cross(cur), "ro", cid)

	// The replaced settlement fee is no longer claimable; the overturn voter gets the adj fee.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "no settlement fee", func() { ClaimSettleFee(cross(cur), "ro", cid) })
	testing.SetRealm(testing.NewUserRealm(carol))
	if got := ClaimAdjFee(cross(cur), "ro", cid); got <= 0 {
		t.Fatal("the overturn voter should claim the adjudication fee")
	}
}

// TestThreeFailedRoundsCloseAtPreAnswer: a griefer (or an apathetic court) that fails
// three dispute rounds closes the claim WITHOUT a decision, redeeming every share at the
// pre-answer price. The escrow window must span three 7-day votes, so this uses a
// high-value court whose window scales toward the 3-week max. All rounds fail quorum.
func TestThreeFailedRoundsCloseAtPreAnswer(cur realm, t *testing.T) {
	alice := testutils.TestAddress("3r-alice")
	d1 := testutils.TestAddress("3r-d1")
	d2 := testutils.TestAddress("3r-d2")
	d3 := testutils.TestAddress("3r-d3")

	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "3r", "Three Round Court")
	buyCoin(cur, "3r", alice, 50_000_000_000_000_000) // high curve position → long escrow window
	buyCoin(cur, "3r", d1, 100_000_000_000)
	buyCoin(cur, "3r", d2, 100_000_000_000)
	buyCoin(cur, "3r", d3, 100_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	cid := OpenClaim(cross(cur), "3r", "Nobody can decide this")
	matureOI(cur, "3r", cid, alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "3r", cid, outcomeYES)

	base := int64(0)
	for i, d := range []address{d1, d2, d3} {
		testing.SetRealm(testing.NewUserRealm(d))
		OpenDispute(cross(cur), "3r", cid)
		bond := DisputeBond("3r", cid)
		if i == 0 {
			base = bond
		} else if bond != base<<uint(i) {
			t.Fatalf("round %d bond should be base<<%d = %d, got %d", i+1, i, base<<uint(i), bond)
		}
		testing.SkipHeights(121000) // close the (unvoted) vote
		testing.SetRealm(testing.NewUserRealm(d))
		ResolveDispute(cross(cur), "3r", cid)
	}
	if !ProvClose("3r", cid) {
		t.Fatalf("three failed rounds should close without a decision (failedRounds=%d)", FailedRounds("3r", cid))
	}
	if FeeKind("3r", cid) != "none" {
		t.Fatalf("a close-without-decision charges no fee, got %s", FeeKind("3r", cid))
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "3r", cid)
	if !Finalized("3r", cid) {
		t.Fatal("the closed claim should finalize")
	}
	// The claim never traded, so the pre-answer price is the 50/50 default: alice, holding
	// every set, redeems ~the whole collateral back.
	testing.SetRealm(testing.NewUserRealm(alice))
	if paid := RedeemClosed(cross(cur), "3r", cid); paid <= 0 {
		t.Fatal("a closed claim should redeem at the pre-answer price")
	}
}

// TestReopenRefusedOutsideWindow: a reopen is refused once the escrow window has passed
// (the verdict is then final) and once the claim is closing without a decision.
func TestReopenRefusedOutsideWindow(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rw-alice")
	d1 := testutils.TestAddress("rw-d1")
	fundAndBuy(cur, "rw", "Reopen Window Court", alice, 300_000_000)
	buyCoin(cur, "rw", d1, 60_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	cid := OpenClaim(cross(cur), "rw", "Window closes")
	matureOI(cur, "rw", cid, alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "rw", cid, outcomeYES)

	testing.SetRealm(testing.NewUserRealm(d1))
	OpenDispute(cross(cur), "rw", cid)
	testing.SkipHeights(121000)
	testing.SetRealm(testing.NewUserRealm(d1))
	ResolveDispute(cross(cur), "rw", cid) // fails → standing verdict, escrow window set

	// Skip well past the escrow window; a reopen is now refused.
	testing.SkipHeights(400000)
	if Reopenable("rw", cid) {
		t.Fatal("a claim past its escrow window should not be reopenable")
	}
	testing.SetRealm(testing.NewUserRealm(d1))
	uassert.AbortsContains(t, cur, "escrow window has passed", func() {
		OpenDispute(cross(cur), "rw", cid)
	})
}
