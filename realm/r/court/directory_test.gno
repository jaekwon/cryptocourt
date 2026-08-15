package court

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

func TestDirectoryTiers(cur realm, t *testing.T) {
	admin := DirectoryAdmin() // the first court's creator, set across the suite
	other := testutils.TestAddress("dir-other")

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
