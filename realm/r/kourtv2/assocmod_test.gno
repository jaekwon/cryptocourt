package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// A MODERATOR CAN REMOVE AN EDGE ON A COURT THAT HAS NEVER BEEN MODERATED.
//
// RemoveAssociation's doc says "the edge's OWN AUTHOR, always; an active court
// moderator, always". The second half was false on most courts. The check read
//
//	if c.mod == nil { panic("only the edge's author or a court moderator...") }
//
// and `c.mod` is allocated LAZILY — it appears the first time anyone files a
// folder, seeds a claim, or hides something. On a court where none of that has
// happened yet it is nil, so the branch fired and refused the creator, who
// ensureMod would have seeded as the court's first and only moderator. The
// entrypoint refused the one person guaranteed to be a moderator, precisely on
// the courts where nothing had happened.
//
// It survived because the existing authority test has alice author BOTH claims
// AND the edge, so the moderator branch is never reached: the stranger case
// tests refusal, the author case tests the author. Nobody exercised a moderator
// removing SOMEBODY ELSE'S edge. That is what this does, and the fixture is
// deliberately bare — no folder, no seeded claim, no hide — because a court with
// any moderation history at all would have hidden the bug.
func TestAModeratorRemovesAnEdgeOnACourtWithNoModerationHistory(cur realm, t *testing.T) {
	alice := testutils.TestAddress("amod-a")
	bob := testutils.TestAddress("amod-b")
	c := testCourt(cur, "amod", alice, 50_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	one := OpenClaim(cross(cur), "amod", "the first claim")
	testing.SetRealm(testing.NewUserRealm(alice))
	two := OpenClaim(cross(cur), "amod", "the second claim")

	// Anybody may still ADD one (§5) — bob just posts the association bond,
	// because he authored neither claim and moderates nothing. Fund him for it.
	c.coin.Mint(bob, 10_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	AddAssociation(cross(cur), "amod", one, two, "contests")
	uassert.True(t, strings.Contains(ClaimAssociations("amod", one), "out:2:c"))

	// alice moderates by virtue of having created the court, and has never used
	// it. She is not the edge's author.
	testing.SetRealm(testing.NewUserRealm(alice))
	RemoveAssociation(cross(cur), "amod", one, two)
	uassert.Equal(t, "out:;in:", ClaimAssociations("amod", one))

	// And the refusal still names both parties rather than falling through to
	// requireMod's "not a moderator of this court", which is true and unhelpful
	// to somebody who is simply not the author.
	testing.SetRealm(testing.NewUserRealm(bob))
	AddAssociation(cross(cur), "amod", one, two, "supports")
	stranger := testutils.TestAddress("amod-s")
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only the edge's author or a court moderator", func() {
		RemoveAssociation(cross(cur), "amod", one, two)
	})
}
