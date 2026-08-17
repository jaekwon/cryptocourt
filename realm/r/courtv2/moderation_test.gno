package courtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// A hidden claim's lifecycle is byte-identical to an unhidden one's (I1): hiding
// changes no money-path read, and the claim still dead-closes and refunds.
func TestModHideDoesNotTouchLifecycle(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mod-l-alice")
	c := testCourt(cur, "modl", alice, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "modl", "a claim to hide")
	dep := c.params.minClaimDepositCC
	fee := dep * depositFeeBps / 10000
	escrow0 := c.coin.BalanceOf(c.escrow)

	// alice is the creator, hence the sole 1-of-1 moderator.
	testing.SetRealm(testing.NewUserRealm(alice))
	HideItem(cross(cur), "modl", id, "off-topic")
	if !HiddenFromListing("modl", id) {
		t.Fatal("the claim should be hidden from listings")
	}
	// Money-path reads unchanged.
	if ClaimAuthor("modl", id) != alice || ClaimClosed("modl", id) {
		t.Fatal("hiding must not touch author/closed state")
	}
	if c.coin.BalanceOf(c.escrow) != escrow0 {
		t.Fatal("hiding must not move escrow")
	}
	// Lifecycle still runs: dead-close after the timeout refunds the deposit.
	testing.SkipHeights(deadClaimTimeout + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	CloseDeadClaim(cross(cur), "modl", id)
	if !ClaimClosed("modl", id) {
		t.Fatal("a hidden claim must still dead-close")
	}
	if c.coin.BalanceOf(c.escrow) != escrow0-dep-fee {
		t.Fatal("the deposit must refund and the fee burn, hidden or not")
	}
	if ModLogLen("modl", id) != 1 {
		t.Fatal("the hide should have logged exactly one row (I6)")
	}
}

// Unhide clears the court's own bit; the log grows.
func TestModUnhide(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mod-u-alice")
	testCourt(cur, "modu", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "modu", "hide then unhide")
	testing.SetRealm(testing.NewUserRealm(alice))
	HideItem(cross(cur), "modu", id, "spam")
	testing.SetRealm(testing.NewUserRealm(alice))
	UnhideItem(cross(cur), "modu", id, "on reflection, fine")
	if HiddenFromListing("modu", id) {
		t.Fatal("unhide should clear the court bit")
	}
	if ModLogLen("modu", id) != 2 {
		t.Fatal("hide + unhide = two log rows")
	}
}

// The m-of-n decision rule (round-7 R3): with 2-of-3, one moderator's hide does
// nothing; a second distinct moderator's approval fires it.
func TestModMofN(cur realm, t *testing.T) {
	creator := testutils.TestAddress("mod-n-creator")
	m1 := testutils.TestAddress("mod-n-1")
	m2 := testutils.TestAddress("mod-n-2")
	m3 := testutils.TestAddress("mod-n-3")
	testCourt(cur, "modn", creator, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	id := OpenClaim(cross(cur), "modn", "needs two mods")

	testing.SetRealm(testing.NewUserRealm(creator))
	AppointMods(cross(cur), "modn", []address{m1, m2, m3}, 2)
	if m, n := ModThreshold("modn"); m != 2 || n != 3 {
		t.Fatalf("threshold = %d-of-%d", m, n)
	}
	// A non-member cannot act.
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsContains(t, cur, "not a moderator", func() {
		HideItem(cross(cur), "modn", id, "x")
	})
	// One approval: not yet hidden.
	testing.SetRealm(testing.NewUserRealm(m1))
	HideItem(cross(cur), "modn", id, "off-topic")
	if HiddenFromListing("modn", id) {
		t.Fatal("one of two approvals must not hide")
	}
	// The same member re-approving is a no-op.
	testing.SetRealm(testing.NewUserRealm(m1))
	HideItem(cross(cur), "modn", id, "off-topic")
	if HiddenFromListing("modn", id) {
		t.Fatal("a repeat approval must not reach the threshold")
	}
	// A second distinct member fires it.
	testing.SetRealm(testing.NewUserRealm(m2))
	HideItem(cross(cur), "modn", id, "off-topic")
	if !HiddenFromListing("modn", id) {
		t.Fatal("two distinct approvals should hide")
	}
}

// Suspension masks the set and refuses its writes except clearing own bits
// (I10); global recovery lifts the suspension.
func TestModSuspension(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mod-s-alice")
	testCourt(cur, "mods", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "mods", "suspend test")
	testing.SetRealm(testing.NewUserRealm(alice))
	HideItem(cross(cur), "mods", id, "spam")

	c := mustCourt("mods")
	suspendSet(c, alice) // internal hook (module 7 calls it via a verdict)
	if !CourtSuspended("mods") {
		t.Fatal("the set should be suspended")
	}
	// A suspended set cannot hide a second claim...
	testing.SetRealm(testing.NewUserRealm(alice))
	id2 := OpenClaim(cross(cur), "mods", "second")
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "suspended", func() {
		HideItem(cross(cur), "mods", id2, "x")
	})
	// ...but it CAN clear its own bit (de-escalatory).
	testing.SetRealm(testing.NewUserRealm(alice))
	UnhideItem(cross(cur), "mods", id, "clearing own bit under suspension")
	if HiddenFromListing("mods", id) {
		t.Fatal("clearing own bit must survive suspension")
	}
	// Global recovery lifts the suspension.
	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	ClearCourtSuspension(cross(cur), "mods")
	if CourtSuspended("mods") {
		t.Fatal("global recovery should lift the suspension")
	}
}

// Purge is m-of-n and tombstones text on every surface (I11), without touching
// the claim's money state (I1).
func TestModPurgeMofN(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mod-p-alice")
	g2 := testutils.TestAddress("mod-p-g2")
	c := testCourt(cur, "modp", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "modp", "purge me")
	escrow0 := c.coin.BalanceOf(c.escrow)

	// Grow the global DAO to 2 members, purge threshold 2.
	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	AddGlobalMod(cross(cur), g2)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 2)

	// One purge approval: not yet purged.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeClaim(cross(cur), "modp", id, "CSAM")
	if ClaimPurged("modp", id) {
		t.Fatal("one of two purge approvals must not purge")
	}
	// The second global member fires it.
	testing.SetRealm(testing.NewUserRealm(g2))
	PurgeClaim(cross(cur), "modp", id, "CSAM")
	if !ClaimPurged("modp", id) || !TextRedacted("modp", id) {
		t.Fatal("two approvals should purge and redact")
	}
	// Money untouched (I1): escrow still holds the deposit+fee.
	if c.coin.BalanceOf(c.escrow) != escrow0 {
		t.Fatal("purge must not move money")
	}
}

// Global redaction: single-key to set, explicit clear, and clear-any recovery.
func TestModGlobalRedactAndRecovery(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mod-g-alice")
	testCourt(cur, "modg", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "modg", "redact me")
	// Court-hide it too, to test clear-any reaching the court bit.
	testing.SetRealm(testing.NewUserRealm(alice))
	HideItem(cross(cur), "modg", id, "spam")

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHide(cross(cur), "modg", id, "DMCA")
	if !TextRedacted("modg", id) || !HiddenFromListing("modg", id) {
		t.Fatal("global hide should redact and hide")
	}
	// Clear-any recovery lifts the court + meta bits (not the global bit).
	testing.SetRealm(testing.NewUserRealm(dadmin))
	ClearAnyBit(cross(cur), "modg", id)
	if HiddenFromListing("modg", id) == false {
		t.Fatal("the global bit still hides after clear-any (global not cleared)")
	}
	// The explicit global clear is the only reversal.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalClear(cross(cur), "modg", id)
	if TextRedacted("modg", id) || HiddenFromListing("modg", id) {
		t.Fatal("global clear should fully un-redact and un-hide")
	}
}
