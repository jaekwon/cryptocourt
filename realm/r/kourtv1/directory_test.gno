package kourtv1

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

func TestDirectoryTiers(cur realm, t *testing.T) {
	// The directory admin is whoever created the FIRST court in the process.
	// This used to just read DirectoryAdmin() and trust a neighbour to have
	// created one; run alone, "dir-court" below WAS the first court, so `other`
	// became the admin and the non-admin case asserted nothing. Seed a court
	// from a separate address so an admin exists either way, then read it back
	// — if a neighbour did get there first, theirs is still a real admin, and
	// it is never `other`.
	seed := testutils.TestAddress("dir-seed")
	testing.SetRealm(testing.NewUserRealm(seed))
	StartCourt(cross(cur), "dirseed", "Directory Seed")
	admin := DirectoryAdmin()
	other := testutils.TestAddress("dir-other")
	if admin == other {
		t.Fatal("fixture: the curator and the non-curator must be different addresses")
	}

	testing.SetRealm(testing.NewUserRealm(other))
	StartCourt(cross(cur), "dir-court", "Directory Court")
	if CourtTier("dir-court") != int(tierListed) {
		t.Fatalf("a new court should default to listed, got %d", CourtTier("dir-court"))
	}

	// A non-admin cannot curate.
	testing.SetRealm(testing.NewUserRealm(other))
	uassert.AbortsContains(t, cur, "only the directory admin", func() {
		SetTier(cross(cur), "dir-court", int(tierFeatured))
	})

	// The admin can feature it, and it shows in the featured listing.
	testing.SetRealm(testing.NewUserRealm(admin))
	SetTier(cross(cur), "dir-court", int(tierFeatured))
	if CourtTier("dir-court") != int(tierFeatured) {
		t.Fatal("the court should be featured after promotion")
	}
	found := false
	for _, s := range ListByTier(int(tierFeatured)) {
		if s == "dir-court" {
			found = true
		}
	}
	if !found {
		t.Fatal("the featured listing should include the promoted court")
	}
}

func TestSlugCharsetIsEnforced(cur realm, t *testing.T) {
	who := testutils.TestAddress("slug-who")
	testing.SetRealm(testing.NewUserRealm(who))
	uassert.AbortsContains(t, cur, "lowercase letters, digits, and hyphens", func() {
		StartCourt(cross(cur), "Bad Slug!", "Nope")
	})
}
