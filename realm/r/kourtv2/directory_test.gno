package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// directory.gno had NO test file. Its one mutating entrypoint is access-controlled,
// and an untested caller-authentication guard is the class AGENTS.md flags as
// highest-risk: it is one line, it is invisible to every other fixture, and nothing
// else in the suite fails if it is deleted.
//
// Curation only, by design — a hidden court still works for anyone holding its
// address ("moderation, not custody"), so the guard protects the LISTING, not custody
// of funds. Note Court.tier here is the directory tier (hidden/listed/featured) and is
// unrelated to claimState.tier, the quality multiplier that drives the draw.
// NOTE (merge, v0.24): the guard this test was written against MOVED. SetTier was
// gated on the bare directoryAdmin; it is now a GLOBAL DAO power, because tier is
// moderation — hiding a court from the front page is the first power the global DAO
// was ever described as having — and leaving it on a lone key meant the realm had
// two unrelated moderation authorities, one with no m-of-n, no membership
// management and no handover. The test survives intact because directoryAdmin IS
// the DAO's founding member, so `owner` still curates for the right reason; only
// the refusal message changed.
func TestSetTierIsDAOOnlyAndRangeChecked(cur realm, t *testing.T) {
	admin := testutils.TestAddress("dir-admin")
	stranger := testutils.TestAddress("dir-stranger")
	// directoryAdmin latches to the FIRST court's creator process-wide and is never
	// cleared, so an earlier fixture in this package may already own it. Read it
	// rather than assuming, and drive the guard from whoever it actually is.
	c := testCourt(cur, "dir1", admin, 1_000_000_000)
	_ = c
	owner := DirectoryAdmin()
	if owner == "" {
		t.Fatal("the directory admin must latch at the first court")
	}
	// It must be the CREATING ACCOUNT, and the discriminating half of that is that it
	// is not the realm. Reading the admin from DirectoryAdmin() above is what lets
	// this test cope with the process-wide latch, but it also means the test cannot
	// see WHO latched — so `admin := cur.Address()` in StartCourt would pass every
	// assertion below, since the guard would compare the realm against itself and the
	// fixture would happily drive it from that same address. A realm-owned admin is
	// not a cosmetic error: no caller can produce a Previous equal to the realm, so
	// SetTier becomes uncallable and the directory's tiers freeze permanently at
	// Listed.
	if owner == cur.Address() {
		t.Fatalf("the directory admin must be the creating account, not the realm "+
			"itself (%s) — a realm-owned admin can never be called as, so tiering "+
			"would be frozen for ever", owner)
	}

	// A stranger cannot curate.
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only a global DAO member", func() {
		SetTier(cross(cur), "dir1", int(tierFeatured))
	})
	if got := CourtTier("dir1"); got != int(tierListed) {
		t.Fatalf("a refused SetTier must not move the tier: %d", got)
	}

	// The admin can, across the whole range.
	for _, want := range []uint8{tierHidden, tierFeatured, tierListed} {
		testing.SetRealm(testing.NewUserRealm(owner))
		SetTier(cross(cur), "dir1", int(want))
		if got := CourtTier("dir1"); got != int(want) {
			t.Fatalf("the admin's SetTier must land: got %d want %d", got, want)
		}
	}

	// Out of range is refused on both sides — uint8(tier) would otherwise wrap a
	// negative into a valid-looking tier.
	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.AbortsContains(t, cur, "tier is 0 (hidden)", func() {
		SetTier(cross(cur), "dir1", -1)
	})
	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.AbortsContains(t, cur, "tier is 0 (hidden)", func() {
		SetTier(cross(cur), "dir1", int(tierFeatured)+1)
	})
	if got := CourtTier("dir1"); got != int(tierListed) {
		t.Fatalf("a refused range must not move the tier: %d", got)
	}

	// An unknown slug is refused before any write.
	testing.SetRealm(testing.NewUserRealm(owner))
	uassert.AbortsContains(t, cur, "no such court", func() {
		SetTier(cross(cur), "dirnope", int(tierFeatured))
	})
}

// ListCourts and ListByTier are the directory's only reads, and both iterate the
// whole tree. Pins that ListByTier filters on the tier actually set (not the
// zero-value default) and that ListCourts is slug-ordered rather than age-ordered.
func TestDirectoryListsFilterAndOrder(cur realm, t *testing.T) {
	admin := testutils.TestAddress("dir2-admin")
	// Deliberately create out of lexicographic order to prove the ordering claim.
	testCourt(cur, "dir2z", admin, 1_000_000_000)
	testCourt(cur, "dir2a", admin, 1_000_000_000)
	owner := DirectoryAdmin()

	testing.SetRealm(testing.NewUserRealm(owner))
	SetTier(cross(cur), "dir2z", int(tierFeatured))

	var sawZ, sawA bool
	for _, s := range ListByTier(int(tierFeatured)) {
		if s == "dir2z" {
			sawZ = true
		}
		if s == "dir2a" {
			sawA = true
		}
	}
	if !sawZ {
		t.Fatal("ListByTier must include a court set to that tier")
	}
	if sawA {
		t.Fatal("ListByTier must exclude a court at a different tier")
	}

	// Slug order: dir2a must precede dir2z despite being created second.
	ia, iz := -1, -1
	for i, s := range ListCourts() {
		if s == "dir2a" {
			ia = i
		}
		if s == "dir2z" {
			iz = i
		}
	}
	if ia < 0 || iz < 0 {
		t.Fatalf("both courts must be listed: a=%d z=%d", ia, iz)
	}
	if ia > iz {
		t.Fatalf("ListCourts is slug-ordered, not age-ordered: a=%d z=%d", ia, iz)
	}
}
