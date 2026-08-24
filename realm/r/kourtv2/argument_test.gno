package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// argFixture: a court with `n` claims, all by alice, so a test can wire edges
// between them without each one re-stating the setup.
func argFixture(cur realm, t *testing.T, slug string, n int) (address, []uint64) {
	t.Helper()
	alice := testutils.TestAddress(slug + "-a")
	testCourt(cur, slug, alice, 200_000_000_000)
	ids := make([]uint64, 0, n)
	for i := 0; i < n; i++ {
		testing.SetRealm(testing.NewUserRealm(alice))
		ids = append(ids, OpenClaim(cross(cur), slug, "claim "+strings.Repeat("x", i+1)))
	}
	return alice, ids
}

// BOTH DIRECTIONS FROM ONE OBJECT. argOut and argIn hold the same *argEdge, and
// the whole point of paying for a second index is that "what does this claim
// argue" and "what is argued about this claim" are each ONE prefix scan.
func TestArgumentEdgeReadsBothWays(cur realm, t *testing.T) {
	alice, ids := argFixture(cur, t, "arg1", 2)
	testing.SetRealm(testing.NewUserRealm(alice))
	AddArgument(cross(cur), "arg1", ids[0], ids[1], "supports")

	out := ClaimArguments("arg1", ids[0])
	in := ClaimArguments("arg1", ids[1])
	uassert.True(t, strings.Contains(out, "out:2:s"))
	uassert.True(t, strings.Contains(in, "in:1:s"))
	// and neither direction invents the other
	uassert.True(t, strings.HasSuffix(out, ";in:"))
	uassert.True(t, strings.HasPrefix(in, "out:;"))
}

// REMOVAL MUST CLEAR BOTH INDEXES. This is the specific failure the two-tree
// shape can have: drop one Remove and the edge survives in one direction, so the
// two reads disagree about whether it exists and no test of a single direction
// would notice.
func TestRemoveArgumentClearsBothIndexes(cur realm, t *testing.T) {
	alice, ids := argFixture(cur, t, "arg2", 2)
	testing.SetRealm(testing.NewUserRealm(alice))
	AddArgument(cross(cur), "arg2", ids[0], ids[1], "contests")
	testing.SetRealm(testing.NewUserRealm(alice))
	RemoveArgument(cross(cur), "arg2", ids[0], ids[1])

	uassert.Equal(t, "out:;in:", ClaimArguments("arg2", ids[0]))
	uassert.Equal(t, "out:;in:", ClaimArguments("arg2", ids[1]))
}

// WHO MAY REMOVE. The author, always. A stranger, never. A moderator, always —
// and NOT the target claim's author, which is the rule worth being unable to
// bend: an author deleting "this is contested by #2" is the censorship the graph
// exists to resist. Here alice authors both claims AND the edge, so the stranger
// case is the one that isolates authority from ownership.
func TestRemoveArgumentAuthority(cur realm, t *testing.T) {
	alice, ids := argFixture(cur, t, "arg3", 2)
	stranger := testutils.TestAddress("arg3-s")
	testing.SetRealm(testing.NewUserRealm(alice))
	AddArgument(cross(cur), "arg3", ids[0], ids[1], "supports")

	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only the edge's author or a court moderator", func() {
		RemoveArgument(cross(cur), "arg3", ids[0], ids[1])
	})
	// still there
	uassert.True(t, strings.Contains(ClaimArguments("arg3", ids[0]), "out:2:s"))

	testing.SetRealm(testing.NewUserRealm(alice))
	RemoveArgument(cross(cur), "arg3", ids[0], ids[1])
	uassert.Equal(t, "out:;in:", ClaimArguments("arg3", ids[0]))
}

// ANYBODY MAY STILL ADD (§5), which is the point — a stranger's counter-evidence
// is the thing an argument graph is for. What changed is that a stranger posts a
// REFUNDABLE bond for the privilege, and the refund is what keeps this on §5's
// side of the line: the toll is on griefing, not on speaking. A bond that never
// came back would be the priced-out counter-evidence the old note warned of.
//
// Asserted in both directions here: the edge lands, and the money is HELD rather
// than taken — a stranger is out the bond until somebody judges, and no further.
func TestAnybodyMayAddAnArgument(cur realm, t *testing.T) {
	alice, ids := argFixture(cur, t, "arg4", 2)
	c := mustCourt("arg4")
	stranger := testutils.TestAddress("arg4-s")
	bond := AssociationBond("arg4")
	c.coin.Mint(stranger, bond*3)
	before := c.coin.BalanceOf(stranger)

	testing.SetRealm(testing.NewUserRealm(stranger))
	AddArgument(cross(cur), "arg4", ids[1], ids[0], "contests")
	uassert.True(t, strings.Contains(ClaimArguments("arg4", ids[0]), "in:2:c"))
	uassert.Equal(t, before-bond, c.coin.BalanceOf(stranger))

	// And it comes back when a moderator agrees it was worth carrying. The court
	// creator moderates by default, so alice is the judge here.
	testing.SetRealm(testing.NewUserRealm(alice))
	ApproveAssociation(cross(cur), "arg4", ids[1], ids[0])
	uassert.Equal(t, before, c.coin.BalanceOf(stranger))
	uassert.True(t, strings.Contains(ClaimArguments("arg4", ids[0]), "in:2:c"))
}

// THE MODERATION GATE. An edge carries no text of its own, but it POINTS at a
// claim whose title a purge withheld — so a read that returned the edge anyway
// would put the purged claim's id back on another claim's page and invite the
// reader to go and look. The title gate and the edge gate have to agree.
func TestArgumentsHidePurgedEndpoints(cur realm, t *testing.T) {
	alice, ids := argFixture(cur, t, "arg5", 2)
	testing.SetRealm(testing.NewUserRealm(alice))
	AddArgument(cross(cur), "arg5", ids[0], ids[1], "supports")
	uassert.True(t, strings.Contains(ClaimArguments("arg5", ids[0]), "out:2:s"))

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeClaim(cross(cur), "arg5", ids[1], "CSAM")

	// the edge is gone from the surviving claim's page, in both directions
	uassert.Equal(t, "out:;in:", ClaimArguments("arg5", ids[0]))
}

// THE REFUSALS, which are cheap to get wrong and cheap to pin.
func TestArgumentRefusals(cur realm, t *testing.T) {
	alice, ids := argFixture(cur, t, "arg6", 2)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "cannot bear on itself", func() {
		AddArgument(cross(cur), "arg6", ids[0], ids[0], "supports")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "a stance is", func() {
		AddArgument(cross(cur), "arg6", ids[0], ids[1], "maybe")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	AddArgument(cross(cur), "arg6", ids[0], ids[1], "supports")
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "already exists", func() {
		AddArgument(cross(cur), "arg6", ids[0], ids[1], "contests")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "no such argument edge", func() {
		RemoveArgument(cross(cur), "arg6", ids[1], ids[0])
	})
}

// THE ANTI-SYBIL TERM. The inbound cap bounds a claim page's render, and the
// per-author cap is what stops one address filling that bound on its own — which
// is what makes the inbound cap a bound rather than a griefing vector.
// And the bond is the term that makes the SYBIL route cost something too: the
// cap stops one address at four, and sixteen addresses can still reach the
// inbound bound — but each of the sixteen now posts CC to do it, refundable only
// if a moderator agrees the edge was worth carrying.
func TestArgumentPerAuthorInboundCap(cur realm, t *testing.T) {
	_, ids := argFixture(cur, t, "arg7", maxArgInPerAuthor+2)
	c := mustCourt("arg7")
	spammer := testutils.TestAddress("arg7-x")
	target := ids[0]
	// Neither authored a claim here, so both pay per edge.
	c.coin.Mint(spammer, AssociationBond("arg7")*int64(maxArgInPerAuthor+2))
	c.coin.Mint(testutils.TestAddress("arg7-y"), AssociationBond("arg7")*2)
	for i := 1; i <= maxArgInPerAuthor; i++ {
		testing.SetRealm(testing.NewUserRealm(spammer))
		AddArgument(cross(cur), "arg7", ids[i], target, "contests")
	}
	testing.SetRealm(testing.NewUserRealm(spammer))
	uassert.AbortsContains(t, cur, "you already hold", func() {
		AddArgument(cross(cur), "arg7", ids[maxArgInPerAuthor+1], target, "contests")
	})
	// ANOTHER address is still free to argue — the cap is per author, not a
	// first-come lock on the claim.
	other := testutils.TestAddress("arg7-y")
	testing.SetRealm(testing.NewUserRealm(other))
	AddArgument(cross(cur), "arg7", ids[maxArgInPerAuthor+1], target, "supports")
}

// A COURT THAT HAS NEVER CARRIED AN EDGE answers without allocating. The nil
// trees are what keep the read pure — check-read-purity.py enforces the rule
// structurally, and this pins the behaviour it protects.
func TestArgumentsOnAnUntouchedCourtReadEmpty(cur realm, t *testing.T) {
	_, ids := argFixture(cur, t, "arg8", 1)
	uassert.Equal(t, "out:;in:", ClaimArguments("arg8", ids[0]))
}
