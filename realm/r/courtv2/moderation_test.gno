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

// Set-level global recovery (setmods vet, unanimous): ClearAnyBit is per-claim,
// so a hostile SET needs its own cure. ResetModSet disarms it — and does not
// appoint, so the court's own electorate still chooses who moderates.
func TestResetModSetIsTheSetLevelCure(cur realm, t *testing.T) {
	creator := testutils.TestAddress("rms-creator")
	puppet := testutils.TestAddress("rms-puppet")
	g2 := testutils.TestAddress("rms-g2")
	testCourt(cur, "rms", creator, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	AppointMods(cross(cur), "rms", []address{puppet}, 1)
	if !IsCourtMod("rms", puppet) {
		t.Fatal("the puppet should be seated for the test")
	}

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	AddGlobalMod(cross(cur), g2)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 2)

	// One approval is not enough.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	ResetModSet(cross(cur), "rms")
	if !IsCourtMod("rms", puppet) {
		t.Fatal("one of two approvals must not reset the set")
	}
	// The second fires it: the set is emptied, so nothing can act.
	testing.SetRealm(testing.NewUserRealm(g2))
	ResetModSet(cross(cur), "rms")
	if IsCourtMod("rms", puppet) {
		t.Fatal("the reset must disarm the hostile set")
	}
	if _, n := ModThreshold("rms"); n != 0 {
		t.Fatalf("the set should be empty, got n=%d", n)
	}
}

// A suspended creator may not re-appoint around the suspension: AppointMods is
// free and creator-only, so allowing it would make meta's bonded, voted disarm
// a no-op.
func TestSuspendedCreatorCannotReappoint(cur realm, t *testing.T) {
	creator := testutils.TestAddress("scr-creator")
	other := testutils.TestAddress("scr-other")
	testCourt(cur, "scr", creator, 10_000_000_000)
	c := mustCourt("scr")
	suspendSet(c, creator)
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsContains(t, cur, "suspended", func() {
		AppointMods(cross(cur), "scr", []address{other}, 1)
	})
}

// A meta-installed set may not seed claims (setmods vet 2/3): seeding waives
// the deposit AND fee while winner/answerer slices still mint, so a captured
// meta must not be able to hand puppets a free claim faucet. Locally-installed
// sets seed normally.
func TestMetaInstalledSetCannotSeed(cur realm, t *testing.T) {
	creator := testutils.TestAddress("mis-creator")
	puppet := testutils.TestAddress("mis-puppet")
	c := testCourt(cur, "mis", creator, 10_000_000_000)
	cm := ensureMod(c)

	// Seeding works for the creator-appointed set.
	testing.SetRealm(testing.NewUserRealm(creator))
	OpenClaimSeeded(cross(cur), "mis", "creator seed is fine")

	// Now simulate a meta verdict seating a puppet set.
	testing.SetRealm(testing.NewUserRealm(creator))
	cand := RegisterModCandidate(cross(cur), "mis", []address{puppet}, 1)
	installModSet(c, cm, cm.mustCandidate(cand), 100, false) // byElection=false => meta
	testing.SetRealm(testing.NewUserRealm(puppet))
	uassert.AbortsContains(t, cur, "may not seed", func() {
		OpenClaimSeeded(cross(cur), "mis", "puppet faucet")
	})
	// The puppet can still do ordinary render-layer moderation.
	c.coin.Mint(puppet, 10_000_000)
	testing.SetRealm(testing.NewUserRealm(puppet))
	id := OpenClaim(cross(cur), "mis", "ordinary claim")
	testing.SetRealm(testing.NewUserRealm(puppet))
	HideItem(cross(cur), "mis", id, "puppet hides")
	if !HiddenFromListing("mis", id) {
		t.Fatal("a meta-installed set still moderates; only seeding is denied")
	}
}

// Re-installing the SAME set does not escape a suspension; installing a
// different one does (otherwise suspension is escapable at zero cost).
func TestInstallClearsSuspensionOnlyIfSetChanges(cur realm, t *testing.T) {
	creator := testutils.TestAddress("ics-creator")
	a1 := testutils.TestAddress("ics-a1")
	a2 := testutils.TestAddress("ics-a2")
	c := testCourt(cur, "ics", creator, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	AppointMods(cross(cur), "ics", []address{a1}, 1)
	cm := ensureMod(c)

	suspendSet(c, creator)
	if !CourtSuspended("ics") {
		t.Fatal("set should be suspended")
	}
	// Re-installing the identical set must NOT clear the suspension.
	testing.SetRealm(testing.NewUserRealm(creator))
	same := RegisterModCandidate(cross(cur), "ics", []address{a1}, 1)
	installModSet(c, cm, cm.mustCandidate(same), 200, true)
	if !CourtSuspended("ics") {
		t.Fatal("re-seating the judged set must not escape the suspension")
	}
	// Installing a genuinely different set clears it.
	testing.SetRealm(testing.NewUserRealm(creator))
	diff := RegisterModCandidate(cross(cur), "ics", []address{a2}, 1)
	installModSet(c, cm, cm.mustCandidate(diff), 300, true)
	if CourtSuspended("ics") {
		t.Fatal("installing a different set delivers it ARMED")
	}
}

// The global DAO can SET a suspension, not only clear one (m-of-n).
func TestGlobalSuspendSet(cur realm, t *testing.T) {
	creator := testutils.TestAddress("gss-creator")
	g2 := testutils.TestAddress("gss-g2")
	testCourt(cur, "gss", creator, 10_000_000_000)
	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	AddGlobalMod(cross(cur), g2)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 2)

	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalSuspendSet(cross(cur), "gss")
	if CourtSuspended("gss") {
		t.Fatal("one of two approvals must not suspend")
	}
	testing.SetRealm(testing.NewUserRealm(g2))
	GlobalSuspendSet(cross(cur), "gss")
	if !CourtSuspended("gss") {
		t.Fatal("two approvals should suspend the set")
	}
}
