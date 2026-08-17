package kourtv2

import (
	"strconv"
	"strings"
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

// currentSetID concatenates every member into one string, so it costs O(n²) —
// and it sits on the SUSPEND path. An uncapped set could therefore be grown
// until the global DAO's and the meta court's emergency hammer no longer fit in
// a transaction: the set makes itself too big to suspend. The cap is enforced at
// canonicalMembers, the one chokepoint both entry points share.
func TestModSetSizeIsCapped(cur realm, t *testing.T) {
	creator := testutils.TestAddress("cap-creator")
	testCourt(cur, "capset", creator, 10_000_000_000)

	over := make([]address, maxModSetSize+1)
	for i := range over {
		over[i] = testutils.TestAddress("cap-m" + strconv.Itoa(i))
	}
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsContains(t, cur, "at most 32 members", func() {
		AppointMods(cross(cur), "capset", over, 1)
	})
	// The candidate registry is the other way in, and it must be capped too —
	// otherwise the same set arrives via a meta setmods install.
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsContains(t, cur, "at most 32 members", func() {
		RegisterModCandidate(cross(cur), "capset", over, 1)
	})
	// Exactly at the cap still works, so the bound is off-by-one clean.
	testing.SetRealm(testing.NewUserRealm(creator))
	AppointMods(cross(cur), "capset", over[:maxModSetSize], 1)
	if !IsCourtMod("capset", over[0]) {
		t.Fatal("a set exactly at the cap must install")
	}
}

// A moderation row must be allocated only once the m-of-n actually FIRES.
// Allocating on the first approval let one member of an m>1 set mint an empty
// claimMod per claim: rows carrying no act, costing storage, that renderModLog
// and every claims-tree walk must then step over. One member, many claims, no
// decision — pure griefing of a set the griefer cannot otherwise act for.
func TestUnfiredApprovalAllocatesNothing(cur realm, t *testing.T) {
	creator := testutils.TestAddress("noalloc-creator")
	m2 := testutils.TestAddress("noalloc-m2")
	c := testCourt(cur, "noalloc", creator, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(creator))
	AppointMods(cross(cur), "noalloc", []address{creator, m2}, 2)

	testing.SetRealm(testing.NewUserRealm(creator))
	id := OpenClaim(cross(cur), "noalloc", "a claim one mod dislikes")
	cm := ensureMod(c)
	before := cm.claims.Size()

	testing.SetRealm(testing.NewUserRealm(creator))
	HideItem(cross(cur), "noalloc", id, "spam") // 1 of 2 — must not fire
	if HiddenFromListing("noalloc", id) {
		t.Fatal("one of two approvals must not hide")
	}
	if got := cm.claims.Size(); got != before {
		t.Fatalf("an unfired approval allocated a moderation row: %d rows, want %d", got, before)
	}

	// The second approval fires, and only now is the row real.
	testing.SetRealm(testing.NewUserRealm(m2))
	HideItem(cross(cur), "noalloc", id, "spam")
	if !HiddenFromListing("noalloc", id) {
		t.Fatal("the second approval should hide")
	}
	if cm.claims.Size() != before+1 {
		t.Fatal("a fired act must allocate exactly one row")
	}
	// The guard still refuses a claim that does not exist at all.
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsContains(t, cur, "no such claim", func() {
		HideItem(cross(cur), "noalloc", 9999, "spam")
	})
}

// I11: purge must reach the moderation log itself. A row's reason is FREE TEXT
// a moderator wrote, so it can carry the very thing the purge was called in to
// remove — and "we removed the claim" is no answer when the removal notice
// repeats what it removed. The row survives with its height, actor and act
// code, so the audit trail still shows what happened and who did it; only the
// prose goes, and it goes from STATE, not merely from the render.
func TestPurgeReachesTheModerationLog(cur realm, t *testing.T) {
	alice := testutils.TestAddress("prow-alice")
	c := testCourt(cur, "prow", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "prow", "a claim")
	testing.SetRealm(testing.NewUserRealm(alice))
	HideItem(cross(cur), "prow", id, "contains a home address")

	page := Render("prow/mod")
	if !strings.Contains(page, "contains a home address") {
		t.Fatal("fixture: the reason should render before the purge")
	}
	if !strings.Contains(page, "row 1") {
		t.Fatal("the log must print row ids — PurgeModLogRow is addressed by one")
	}

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeModLogRow(cross(cur), "prow", id, 1, "DOXX-1")

	page = Render("prow/mod")
	if strings.Contains(page, "contains a home address") {
		t.Fatal("a purged row's reason must be gone from every surface")
	}
	if !strings.Contains(page, "reason removed on legal grounds") {
		t.Fatal("the row should stay, marked, so the audit trail survives")
	}
	// Gone from STATE, not just hidden at render — a purge that only stops
	// printing leaves the text on chain for anyone reading the tree.
	cm := ensureMod(c)
	clm := lookupClaimMod(cm, id)
	for _, a := range clm.log {
		if a.reason == "contains a home address" {
			t.Fatal("the purged text is still in state")
		}
	}

	// An id nobody can reach is refused before the m-of-n is spent on it.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "no such moderation-log row", func() {
		PurgeModLogRow(cross(cur), "prow", id, 9999, "DOXX-1")
	})
	// And only the global DAO may do it at all. The refuser must be an address
	// that provably is NOT a member: alice cannot play that role, because the
	// global DAO bootstraps from whoever created the FIRST court in the process
	// — run alone, that is alice, and this arm would assert nothing. The same
	// trap as kourtv1's TestDirectoryTiers, and the isolation sweep caught it
	// here too.
	outsider := testutils.TestAddress("prow-outsider")
	if outsider == dadmin {
		t.Fatal("fixture: the refuser must not be the global DAO admin")
	}
	testing.SetRealm(testing.NewUserRealm(outsider))
	uassert.AbortsContains(t, cur, "only a global DAO member", func() {
		PurgeModLogRow(cross(cur), "prow", id, 2, "DOXX-1")
	})
}

// Tier is moderation — hiding a court from the front page is the first power
// the global DAO was described as having — so it is a DAO power, not a lone
// key's, and it emits like every other act (I6).
func TestSetTierIsAGlobalDAOPower(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tier-alice")
	stranger := testutils.TestAddress("tier-stranger")
	testCourt(cur, "tierc", alice, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only a global DAO member", func() {
		SetTier(cross(cur), "tierc", int(tierHidden))
	})

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetTier(cross(cur), "tierc", int(tierHidden))
	if CourtTier("tierc") != int(tierHidden) {
		t.Fatal("a global DAO member should be able to hide a court")
	}

	// A second DAO member can act too — the point of the migration is that the
	// power is no longer one key's.
	second := testutils.TestAddress("tier-second")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	AddGlobalMod(cross(cur), second)
	testing.SetRealm(testing.NewUserRealm(second))
	SetTier(cross(cur), "tierc", int(tierFeatured))
	if CourtTier("tierc") != int(tierFeatured) {
		t.Fatal("any global DAO member may set a tier")
	}
}

// An approval must go stale. The defect was never storage — approvals are
// self-paid, bounded by a derived key space, and walked by nothing. It is that
// m-of-n meant "m members agreed at some point in history" rather than "m
// members agree now": a signature given in January sat at m-1 and could be
// completed in November by one colleague, on an irreversible act its author
// would have withdrawn if withdrawing existed.
func TestPendingApprovalsGoStale(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ttl-alice")
	m1 := testutils.TestAddress("ttl-m1")
	m2 := testutils.TestAddress("ttl-m2")
	testCourt(cur, "ttlc", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	AppointMods(cross(cur), "ttlc", []address{m1, m2}, 2)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "ttlc", "a claim")
	key := "hide:" + strconv.FormatUint(id, 10)

	testing.SetRealm(testing.NewUserRealm(m1))
	HideItem(cross(cur), "ttlc", id, "one")
	n, expires := PendingApproval("ttlc", key)
	if n != 1 || expires == 0 {
		t.Fatalf("the deadline must be visible: %d approvals, expires %d", n, expires)
	}

	// One block past the window: m2's approval starts a NEW proposal rather
	// than completing the old one.
	testing.SkipHeights(pendingTTLBlocks + 1)
	if n, _ := PendingApproval("ttlc", key); n != 0 {
		t.Fatal("an expired entry must read as absent, matching what the write path will do")
	}
	testing.SetRealm(testing.NewUserRealm(m2))
	HideItem(cross(cur), "ttlc", id, "two")
	if HiddenFromListing("ttlc", id) {
		t.Fatal("a stale signature completed the quorum")
	}
	if n, _ := PendingApproval("ttlc", key); n != 1 {
		t.Fatal("the evictor's own signature should seed the fresh proposal")
	}

	// EXPIRY IS A RESTART, NOT A BLOCK: the set can re-sign and fire at once.
	testing.SetRealm(testing.NewUserRealm(m1))
	HideItem(cross(cur), "ttlc", id, "two")
	if !HiddenFromListing("ttlc", id) {
		t.Fatal("two contemporaneous approvals must still fire immediately")
	}
}

// The deadline is FIXED at the first approval, not slid forward by each signer.
// Sliding would give an entry up to n x TTL of life, and a death height that
// depends on other members' behaviour is one a coordinated pair can steer.
func TestApprovalDeadlineIsFixedNotSliding(cur realm, t *testing.T) {
	alice := testutils.TestAddress("slide-alice")
	m1 := testutils.TestAddress("slide-m1")
	m2 := testutils.TestAddress("slide-m2")
	m3 := testutils.TestAddress("slide-m3")
	testCourt(cur, "slidec", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	AppointMods(cross(cur), "slidec", []address{m1, m2, m3}, 3)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "slidec", "a claim")

	testing.SetRealm(testing.NewUserRealm(m1))
	HideItem(cross(cur), "slidec", id, "one")
	testing.SkipHeights(pendingTTLBlocks - 10)
	testing.SetRealm(testing.NewUserRealm(m2))
	HideItem(cross(cur), "slidec", id, "two") // progress, but the clock is fixed
	testing.SkipHeights(20)                   // now past the ORIGINAL deadline
	testing.SetRealm(testing.NewUserRealm(m3))
	HideItem(cross(cur), "slidec", id, "three")
	if HiddenFromListing("slidec", id) {
		t.Fatal("a mid-window approval must not extend the original deadline")
	}
}
