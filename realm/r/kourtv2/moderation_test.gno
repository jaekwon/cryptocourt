package kourtv2

import (
	"chain/runtime"
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// A hidden claim's lifecycle is byte-identical to an unhidden one's (I1): hiding
// changes no money-path read, and the claim still dead-closes and refunds.
// Enforces I2 (a moderation entrypoint moves no money) and part of I1 (a
// hidden claim's lifecycle is byte-identical, including the refund).
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
	AppointMods(cross(cur), "modn", 2, m1, m2, m3)
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
// Enforces I3's global arm: a global redact removes TEXT and nothing else.
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
	// THE TEXT ITSELF, not just the bit. This test asserted the flags and never the
	// rendering, so the substitution that makes a redaction mean anything — the title
	// replaced by a withheld notice — could be deleted with nothing noticing. A bit
	// that is set while the words still render is not a redaction.
	if got := claimTitleFor(mustCourt("modg"), mustClaim(mustCourt("modg"), id)); got != "[text withheld]" {
		t.Fatalf("a globally redacted claim must render a withheld notice, got %q", got)
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
	// ...and the words come back, which is the half that makes the assertion above a
	// substitution rather than a permanent blank.
	if got := claimTitleFor(mustCourt("modg"), mustClaim(mustCourt("modg"), id)); got != "redact me" {
		t.Fatalf("a cleared claim must render its title again, got %q", got)
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
	AppointMods(cross(cur), "rms", 1, puppet)
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
		AppointMods(cross(cur), "scr", 1, other)
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
	cand := RegisterModCandidate(cross(cur), "mis", 1, puppet)
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
	AppointMods(cross(cur), "ics", 1, a1)
	cm := ensureMod(c)

	suspendSet(c, creator)
	if !CourtSuspended("ics") {
		t.Fatal("set should be suspended")
	}
	// Re-installing the identical set must NOT clear the suspension.
	testing.SetRealm(testing.NewUserRealm(creator))
	same := RegisterModCandidate(cross(cur), "ics", 1, a1)
	installModSet(c, cm, cm.mustCandidate(same), 200, true)
	if !CourtSuspended("ics") {
		t.Fatal("re-seating the judged set must not escape the suspension")
	}
	// Installing a genuinely different set clears it.
	testing.SetRealm(testing.NewUserRealm(creator))
	diff := RegisterModCandidate(cross(cur), "ics", 1, a2)
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
		AppointMods(cross(cur), "capset", 1, over...)
	})
	// The candidate registry is the other way in, and it must be capped too —
	// otherwise the same set arrives via a meta setmods install.
	testing.SetRealm(testing.NewUserRealm(creator))
	uassert.AbortsContains(t, cur, "at most 32 members", func() {
		RegisterModCandidate(cross(cur), "capset", 1, over...)
	})
	// Exactly at the cap still works, so the bound is off-by-one clean.
	testing.SetRealm(testing.NewUserRealm(creator))
	AppointMods(cross(cur), "capset", 1, over[:maxModSetSize]...)
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
	AppointMods(cross(cur), "noalloc", 2, creator, m2)

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
	AppointMods(cross(cur), "ttlc", 2, m1, m2)
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
	AppointMods(cross(cur), "slidec", 3, m1, m2, m3)
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

// The three cheapest of the nine guards the moderation mutation batch showed to
// be unpinned: two range gates and one authority gate, each deletable today
// without a single test noticing. They are cheap precisely because they need no
// membership choreography — a call with a bad argument, and a control proving the
// refusal came from the range check rather than from a blanket refusal.
func TestModerationRangeAndAuthorityGates(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mrg-alice")
	stranger := testutils.TestAddress("mrg-stranger")
	testCourt(cur, "mrgc", alice, 10_000_000_000)

	// AppointMods' m-of-n range. alice is the creator, so she holds the
	// appointment power until an election spends it.
	pair := []address{
		testutils.TestAddress("mrg-m1"),
		testutils.TestAddress("mrg-m2"),
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "m-of-n threshold must be in 1..n", func() {
		AppointMods(cross(cur), "mrgc", 0, pair...)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "m-of-n threshold must be in 1..n", func() {
		AppointMods(cross(cur), "mrgc", 3, pair...)
	})
	// THE CONTROL: 2-of-2 installs. Without it both refusals above would pass
	// just as well if AppointMods refused everything for an unrelated reason.
	testing.SetRealm(testing.NewUserRealm(alice))
	AppointMods(cross(cur), "mrgc", 2, pair...)
	if m, n := ModThreshold("mrgc"); m != 2 || n != 2 {
		t.Fatalf("an in-range threshold must install: got %d-of-%d", m, n)
	}

	// SetPurgeThreshold's authority gate. The global DAO bootstraps with the
	// directory admin as its sole member, so that address is the only one that may
	// move the threshold.
	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only the global DAO admin sets the purge threshold", func() {
		SetPurgeThreshold(cross(cur), 1)
	})

	// ...and its range gate. 9999 rather than n+1: other tests add DAO members, so
	// n is order-dependent, and a bound that has to be computed is a bound that can
	// be computed wrong.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "purge threshold must be in 1..n", func() {
		SetPurgeThreshold(cross(cur), 0)
	})
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "purge threshold must be in 1..n", func() {
		SetPurgeThreshold(cross(cur), 9999)
	})
	// THE CONTROL: 1 is in range for any n >= 1, which holds by construction.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
}

// AppointMods discards the outgoing set's banked approvals. Same class as the
// election-install case (v0.25), reached by the other route: the creator holds the
// appointment power until an election spends it, so a creator can swap the set
// directly, and a signature banked by the old set must not complete the new set's
// quorum.
//
// Observable in a way ResetModSet's clear is not: the new set can act immediately
// after an appointment, with no other clear in between. Mutation-verified.
func TestAppointModsDiscardsTheOutgoingSetsApprovals(cur realm, t *testing.T) {
	alice := testutils.TestAddress("apnt-alice")
	oldA := testutils.TestAddress("apnt-oldA")
	oldB := testutils.TestAddress("apnt-oldB")
	newX := testutils.TestAddress("apnt-newX")
	newY := testutils.TestAddress("apnt-newY")
	testCourt(cur, "apnt", alice, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	AppointMods(cross(cur), "apnt", 2, oldA, oldB)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "apnt", "a claim the old set wanted buried")

	// The outgoing set banks one of the two it needs.
	testing.SetRealm(testing.NewUserRealm(oldA))
	HideItem(cross(cur), "apnt", id, "pretextual")
	if HiddenFromListing("apnt", id) {
		t.Fatal("fixture: one of two must not fire")
	}
	hideAt := runtime.ChainHeight()
	hideKey := "hide:" + strconv.FormatUint(id, 10)
	if n, _ := PendingApproval("apnt", hideKey); n != 1 {
		t.Fatalf("fixture: the old set must have ONE banked approval, got %d", n)
	}

	// The creator swaps in a DISJOINT set.
	testing.SetRealm(testing.NewUserRealm(alice))
	AppointMods(cross(cur), "apnt", 2, newX, newY)
	if IsCourtMod("apnt", oldA) {
		t.Fatal("fixture: the old set must be gone")
	}

	// The premise, asserted rather than assumed: the approval is gone because the
	// APPOINTMENT discarded it, not because it timed out.
	if runtime.ChainHeight() >= hideAt+pendingTTLBlocks {
		t.Fatal("fixture went vacuous: the pending TTL elapsed, so the banked " +
			"approval would have expired with or without the clear")
	}

	// ONE member of the incoming set acts. Under the bug, oldA's banked signature
	// completes the 2-of-2 and this hides the claim.
	testing.SetRealm(testing.NewUserRealm(newX))
	HideItem(cross(cur), "apnt", id, "reviewing")
	if HiddenFromListing("apnt", id) {
		t.Fatal("a deposed set's signature completed the incoming set's quorum")
	}
	// ...and the incoming set CAN act on its own two signatures, so the refusal
	// above is the stale approval being discarded and not a broken set.
	testing.SetRealm(testing.NewUserRealm(newY))
	HideItem(cross(cur), "apnt", id, "reviewing")
	if !HiddenFromListing("apnt", id) {
		t.Fatal("the incoming set's own 2-of-2 must fire")
	}
}

// The global DAO discards its banked approvals whenever WHO MAY ACT changes, or
// how many must agree. Four call sites share this body — AddGlobalMod,
// RemoveGlobalMod, TransferGlobalAdmin and SetPurgeThreshold — and each was
// deletable without a test noticing.
//
// The assertion is direct rather than behavioural: bank one approval, make the
// change, and require the pending count to be ZERO. Driving it through
// fire/no-fire would need a third approver per case and would fire irreversible
// actions to prove a negative; reading the count says the same thing in one line.
//
// The control is the middle case. WITHOUT a membership change the banked approval
// SURVIVES, which is what proves a zero came from the clear rather than from
// banking never having worked at all.
func TestGlobalDAODiscardsApprovalsOnMembershipChange(cur realm, t *testing.T) {
	alice := testutils.TestAddress("gdao-alice")
	memB := testutils.TestAddress("gdao-memB")
	memC := testutils.TestAddress("gdao-memC")
	memD := testutils.TestAddress("gdao-memD")
	for _, slug := range []string{"gdao1", "gdao2", "gdao3", "gdao4"} {
		testCourt(cur, slug, alice, 1_000_000_000)
	}
	dadmin := DirectoryAdmin()

	// A body of at least three, and a threshold of two, so a single approval BANKS
	// instead of firing. The DAO bootstraps n=1/purgeM=1, where one approval is
	// already a quorum and there is no banked state to discard.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	AddGlobalMod(cross(cur), memB)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	AddGlobalMod(cross(cur), memC)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 2)

	bank := func(slug string) int64 {
		testing.SetRealm(testing.NewUserRealm(memB))
		GlobalSuspendSet(cross(cur), slug)
		if CourtSuspended(slug) {
			t.Fatalf("fixture: one of two must not fire on %s", slug)
		}
		if n, _ := PendingApproval("", "gsuspend:"+slug); n != 1 {
			t.Fatalf("fixture: %s must have ONE banked approval, got %d", slug, n)
		}
		return runtime.ChainHeight()
	}
	gone := func(slug, what string) {
		if n, _ := PendingApproval("", "gsuspend:"+slug); n != 0 {
			t.Fatalf("%s left %d banked approval(s) standing; a member who no "+
				"longer counts can still complete the threshold", what, n)
		}
	}

	// THE CONTROL, first: with no membership change the approval survives. Every
	// zero below means something only because this one is not zero.
	at := bank("gdao1")
	if n, _ := PendingApproval("", "gsuspend:gdao1"); n != 1 {
		t.Fatal("control: an untouched approval must still be banked")
	}
	if runtime.ChainHeight() >= at+pendingTTLBlocks {
		t.Fatal("fixture went vacuous: the pending TTL elapsed, so every clear " +
			"below would read as effective whether or not it ran")
	}

	// ADDING a member: the threshold is now met by a different set of people.
	bank("gdao2")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	AddGlobalMod(cross(cur), memD)
	gone("gdao2", "AddGlobalMod")

	// REMOVING one: their signature must not still count. Note this also clamps
	// purgeM down to n if it would exceed it, so the threshold is restored after.
	bank("gdao3")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	RemoveGlobalMod(cross(cur), memD)
	gone("gdao3", "RemoveGlobalMod")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 2)

	// MOVING THE ADMIN SEAT TO A FRESH KEY. This was the strictly better route for
	// an admin wanting to complete a stuck purge: seat a new key without resetting
	// the banked signatures. It must be a NON-member — the clear sits inside the
	// branch that ADDS the new admin, and that conditionality is deliberate, not an
	// oversight (see the next assertion).
	memE := testutils.TestAddress("gdao-memE")
	bank("gdao4")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	TransferGlobalAdmin(cross(cur), memE)
	gone("gdao4", "TransferGlobalAdmin")

	// ...and the seat moving between EXISTING members deliberately does NOT clear,
	// which is why the fixture above had to use a fresh address. Membership is
	// unchanged, so every banked signature still belongs to a current member and no
	// consent has gone stale; the admin's own extra powers are unilateral and were
	// never approved by m-of-n in the first place. Pinned so that nobody "fixes"
	// the conditional into an unconditional wipe and quietly makes a stuck purge
	// un-completable by rotating a key.
	at3 := bank("gdao2")
	_ = at3
	testing.SetRealm(testing.NewUserRealm(memE))
	TransferGlobalAdmin(cross(cur), dadmin)
	if n, _ := PendingApproval("", "gsuspend:gdao2"); n != 1 {
		t.Fatalf("a seat moving between existing members must NOT clear: got %d", n)
	}

	// CHANGING THE THRESHOLD. Consent is half "who must agree", so lowering the bar
	// re-scores every banked signature against it. memB holds the admin seat now.
	at2 := bank("gdao3")
	_ = at2
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 3)
	gone("gdao3", "SetPurgeThreshold")

	// Restore the body: the global DAO is package-global and never reset, so a test
	// that grows it owes the next one a tidy state.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	for _, m := range []address{memB, memC, memE} {
		testing.SetRealm(testing.NewUserRealm(dadmin))
		RemoveGlobalMod(cross(cur), m)
	}
}

// THE GLOBAL DAO'S AUTHORITY PERIMETER. Eleven entrypoints carry the most
// dangerous powers in the design — irreversible purge, global hide, clearing any
// bit, suspending a court's moderator set — and every one of their authority
// guards could be deleted with the whole suite still green. The reason is
// structural and worth stating: the DAO bootstraps with the directory admin as
// its sole member, so every test that exercises a global power acts AS the
// authority, and an authority check nothing ever calls as a NON-member is never
// exercised at all. Eleven mutations, eleven survivors, one cause.
//
// The authority check is the FIRST substantive guard in each of these — before
// mustCourt, before mustClaim, before any category-code or state test — so each
// refusal below is unambiguously about who called and not about what they asked
// for. The court and claim are real anyway, so that with a guard deleted the call
// would proceed rather than trip over a bogus argument.
//
// Two powers are asserted ONLY as refusals, deliberately: a successful
// TransferGlobalAdmin or AddGlobalMod would move package-global DAO state that
// every other test reads — TestModerationRangeAndAuthorityGates already avoids
// computing a bound off `n` for exactly that reason.
func TestGlobalDAOPowersRefuseAStranger(cur realm, t *testing.T) {
	alice := testutils.TestAddress("perim-alice")
	// A prefix no other test uses, because a stranger who is a DAO member
	// somewhere else in the package would make every assertion below vacuous.
	stranger := testutils.TestAddress("perim-stranger")
	c := testCourt(cur, "perim", alice, 10_000_000_000)
	_ = c

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "perim", "a claim the stranger will fail to touch")

	// --- the admin-only seat: membership and succession -------------------
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only the global DAO admin manages membership", func() {
		AddGlobalMod(cross(cur), stranger)
	})
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only the global DAO admin manages membership", func() {
		RemoveGlobalMod(cross(cur), DirectoryAdmin())
	})
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only the global DAO admin transfers the seat", func() {
		TransferGlobalAdmin(cross(cur), stranger)
	})

	// --- the member-only recovery and redaction powers --------------------
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only a global DAO member may global-hide", func() {
		GlobalHide(cross(cur), "perim", id, "dmca")
	})
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only a global DAO member may clear a global hide", func() {
		GlobalClear(cross(cur), "perim", id)
	})
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only a global DAO member may clear bits (recovery)", func() {
		ClearAnyBit(cross(cur), "perim", id)
	})
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only a global DAO member may clear a suspension (recovery)", func() {
		ClearCourtSuspension(cross(cur), "perim")
	})

	// --- the member-only irreversible powers ------------------------------
	// PurgeClaim and PurgeCourt share one message, so each is called on its own
	// entrypoint: the message cannot tell them apart and only the call can.
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only a global DAO member may purge", func() {
		PurgeClaim(cross(cur), "perim", id, "csam")
	})
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only a global DAO member may purge", func() {
		PurgeCourt(cross(cur), "perim", "csam")
	})
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only a global DAO member may suspend a moderator set", func() {
		GlobalSuspendSet(cross(cur), "perim")
	})
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only a global DAO member may reset a moderator set", func() {
		ResetModSet(cross(cur), "perim")
	})

	// THE CONTROL. Without it every refusal above would read the same if the
	// fixture were simply incapable of a successful global act — a wrong slug, a
	// claim that does not exist, a DAO with no members. The directory admin IS
	// the bootstrap member, so the same call it just refused from a stranger goes
	// through, and its reverse puts the claim back so no later test inherits a
	// globally hidden claim.
	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHide(cross(cur), "perim", id, "dmca")
	if !TextRedacted("perim", id) {
		t.Fatal("the bootstrap DAO member's own global-hide must land, or the eleven refusals above prove nothing")
	}
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalClear(cross(cur), "perim", id)
	if TextRedacted("perim", id) {
		t.Fatal("a global clear must lift the redaction it just set")
	}
}

// The STATE guards behind the same powers — the refusals that are not about who
// called but about whether there is anything to do. Every one survived its
// mutation for the same structural reason the authority perimeter did: the suite
// exercises these powers only on state where they succeed, so the no-op arms were
// never reached. An idempotence guard that nothing ever calls twice is not a
// guard, it is a comment.
func TestGlobalDAOStateGuardsRefuseNoOps(cur realm, t *testing.T) {
	alice := testutils.TestAddress("noop-alice")
	stranger := testutils.TestAddress("noop-stranger")
	testCourt(cur, "noopc", alice, 10_000_000_000)
	// AFTER the court, never before. directoryAdmin is empty until the FIRST
	// court in the package is created, so reading it earlier yields the ZERO
	// address — and RemoveGlobalMod(zero) is a silent no-op rather than a
	// refusal, which made the admin-cannot-be-removed arm below vacuous when
	// this test ran alone and correct only because a neighbour had made a court
	// first. A test that depends on package-global state must ESTABLISH it.
	dadmin := DirectoryAdmin()
	if dadmin == "" {
		t.Fatal("the directory admin must exist before any global-DAO arm runs")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "noopc", "a claim with nothing done to it")

	// Nothing to clear: no global hide, no bits, no suspension.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "no global hide on that claim", func() {
		GlobalClear(cross(cur), "noopc", id)
	})
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "nothing to clear on that claim", func() {
		ClearAnyBit(cross(cur), "noopc", id)
	})
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "that court's set is not suspended", func() {
		ClearCourtSuspension(cross(cur), "noopc")
	})

	// The mirror image: suspending a set that is already suspended. The FIRST
	// call has to succeed, which also controls the three refusals above — without
	// it they would all read the same if the fixture were simply incapable of a
	// global act that lands.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalSuspendSet(cross(cur), "noopc")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "that set is already suspended", func() {
		GlobalSuspendSet(cross(cur), "noopc")
	})
	// Lifted again, both to pin the clear's success arm and to leave the court as
	// it was found — a suspended set refuses every court-level act below.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	ClearCourtSuspension(cross(cur), "noopc")

	// A court cannot unhide what it is not hiding. alice is the creator and hence
	// the sole 1-of-1 moderator, so this is a court-level refusal, not a global
	// one, and it is reached only because the suspension above was lifted.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "this court is not hiding that claim", func() {
		UnhideItem(cross(cur), "noopc", id, "never hidden")
	})

	// The reason cap. checkReason is a SHARED chokepoint — HideItem, UnhideItem
	// and GlobalHide all pass through it — so one call pins it for all three, the
	// same way canonicalMembers' size cap covers both ways a moderator set enters.
	long := ""
	for i := 0; i < maxReasonLen+1; i++ {
		long += "x"
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "at most 200 characters", func() {
		HideItem(cross(cur), "noopc", id, long)
	})

	// The purge trio each validate the category code in their own body, and the
	// message is byte-identical at all three sites, so each entrypoint is called
	// on its own — the message cannot tell them apart and only the call can.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "purge needs a statutory category code", func() {
		PurgeClaim(cross(cur), "noopc", id, "")
	})
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "purge needs a statutory category code", func() {
		PurgeCourt(cross(cur), "noopc", "")
	})
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "purge needs a statutory category code", func() {
		PurgeModLogRow(cross(cur), "noopc", id, 1, "")
	})
	// And a log row cannot be purged from a claim that has no log — the code is
	// valid here, so this refusal is about the claim and not about the code.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "that claim has no moderation log", func() {
		PurgeModLogRow(cross(cur), "noopc", id, 1, "dmca")
	})

	// The admin seat is vacated by TRANSFER only. Removal would leave a DAO with
	// no admin and therefore no way to appoint one — unrecoverable, which is why
	// the guard names the remedy.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "the admin cannot be removed; transfer admin first", func() {
		RemoveGlobalMod(cross(cur), dadmin)
	})

	// AppointMods is the creator's power until an election spends it. Paired
	// deliberately: the first refusal is about the caller, the second about the
	// argument, so neither can stand in for the other.
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only the court creator appoints moderators", func() {
		AppointMods(cross(cur), "noopc", 1, alice)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "a moderator set may not be empty", func() {
		AppointMods(cross(cur), "noopc", 1)
	})
}
