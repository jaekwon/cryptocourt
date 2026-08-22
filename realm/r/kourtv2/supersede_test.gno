package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// TWO FIXTURES FOR THE WHOLE FILE, AND THAT IS A BUDGET, NOT A STYLE. A claim can
// only die by SkipHeights(deadClaimTimeout), which is 1.45M blocks, and height is
// GLOBAL across the package: the suite already spends eight of these, and the
// first draft of this file added seven more. That pushed the chain far enough
// forward to break an unrelated test in strips_test.gno, inside CloseDeadClaim's
// deposit refund — a failure that named neither this file nor its cause. So each
// fixture is spent on as many properties as it can honestly carry.

func sid(id uint64) string { return strconv.FormatUint(id, 10) }

// supFixture: one claim that DIED unanswered, one sibling filed beside it (too
// early to be a re-filing of it), and one filed after it could have died. That
// ordering is the predicate's whole subject, so it is produced rather than
// asserted.
func supFixture(cur realm, t *testing.T, slug string) (address, *Court, uint64, uint64, uint64) {
	t.Helper()
	alice := testutils.TestAddress(slug + "-a")
	c := testCourt(cur, slug, alice, 200_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	old := OpenClaim(cross(cur), slug, "the question, put once")
	testing.SetRealm(testing.NewUserRealm(alice))
	sibling := OpenClaim(cross(cur), slug, "a different question, same day")
	testing.SkipHeights(deadClaimTimeout + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	CloseDeadClaim(cross(cur), slug, old)
	testing.SetRealm(testing.NewUserRealm(alice))
	neu := OpenClaim(cross(cur), slug, "the same question, put again")
	return alice, c, old, sibling, neu
}

// The edge itself: both directions, every term of the predicate, both caps, and
// removal.
func TestSupersedeTheWholeEdge(cur realm, t *testing.T) {
	alice, c, old, sibling, neu := supFixture(cur, t, "sup1")

	// BOTH DIRECTIONS FROM ONE OBJECT, the shape argument.gno established: `of`
	// is the one claim this re-files, `by` is everything that re-files this.
	testing.SetRealm(testing.NewUserRealm(alice))
	SupersedeClaim(cross(cur), "sup1", neu, old)
	uassert.Equal(t, "of:"+sid(old)+";by:", ClaimSupersedes("sup1", neu))
	uassert.Equal(t, "of:;by:"+sid(neu), ClaimSupersedes("sup1", old))

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "cannot supersede itself", func() {
		SupersedeClaim(cross(cur), "sup1", neu, neu)
	})
	// A LIVE claim cannot be superseded: nothing has died, so there is nothing to
	// re-file, and that is the entire meaning of the edge.
	testing.SetRealm(testing.NewUserRealm(alice))
	live := OpenClaim(cross(cur), "sup1", "still open, still answerable")
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "died unanswered", func() {
		SupersedeClaim(cross(cur), "sup1", live, sibling)
	})
	// THE ORDERING TERM, which is what makes cycles unrepresentable rather than
	// refused: `sibling` was filed beside `old`, so it cannot be a response to
	// `old` dying, whatever anybody asserts.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "must come after", func() {
		SupersedeClaim(cross(cur), "sup1", sibling, old)
	})
	// ONE OUTBOUND. A re-filing re-files one question, and that cap is what lets
	// supOf be keyed by `from` alone.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "already re-files one", func() {
		SupersedeClaim(cross(cur), "sup1", neu, old)
	})

	// THE ANTI-SYBIL TERM. Without it one address fills all eight inbound slots
	// with eight of its own claims, and the audit line that called the claim
	// deposit price enough was assuming the authorization rule it was meant to be
	// arguing for. `neu` already holds one of alice's two.
	testing.SetRealm(testing.NewUserRealm(alice))
	second := OpenClaim(cross(cur), "sup1", "alice asks it a third time")
	testing.SetRealm(testing.NewUserRealm(alice))
	SupersedeClaim(cross(cur), "sup1", second, old)
	testing.SetRealm(testing.NewUserRealm(alice))
	over := OpenClaim(cross(cur), "sup1", "and once more")
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "you already record", func() {
		SupersedeClaim(cross(cur), "sup1", over, old)
	})
	// ANOTHER address is still free: the cap is per author, not a first-come lock
	// on the claim — the distinction maxArgInPerAuthor draws.
	carol := testutils.TestAddress("sup1-c")
	c.coin.Mint(carol, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(carol))
	hers := OpenClaim(cross(cur), "sup1", "carol asks it again")
	testing.SetRealm(testing.NewUserRealm(carol))
	SupersedeClaim(cross(cur), "sup1", hers, old)
	uassert.Equal(t, "of:"+sid(old)+";by:", ClaimSupersedes("sup1", hers))

	// REMOVAL MUST CLEAR BOTH INDEXES — the specific failure a two-tree shape can
	// have, where the edge survives in one direction and the two reads disagree.
	//
	// BOTH ENDS ARE READ, and the second one is the whole test. A stale supBy row
	// lives under the TARGET's prefix, so checking only `hers` leaves the forward
	// index doing all the work and the arm for this went silent: deleting the
	// supBy.Remove changed nothing anybody looked at.
	before := ClaimSupersedes("sup1", old)
	uassert.True(t, strings.Contains(before, sid(hers)))
	testing.SetRealm(testing.NewUserRealm(carol))
	RemoveSupersede(cross(cur), "sup1", hers)
	uassert.Equal(t, "of:;by:", ClaimSupersedes("sup1", hers))
	uassert.False(t, strings.Contains(ClaimSupersedes("sup1", old), sid(hers)))
	testing.SetRealm(testing.NewUserRealm(carol))
	uassert.AbortsContains(t, cur, "re-files nothing", func() {
		RemoveSupersede(cross(cur), "sup1", hers)
	})
}

// Who may say it, and what a purge withholds.
func TestSupersedeAuthorityAndThePurgeGate(cur realm, t *testing.T) {
	alice, c, old, _, neu := supFixture(cur, t, "sup2")
	stranger := testutils.TestAddress("sup2-s")

	// Settled in docs/SUPERSEDES.md against a permissionless rule: outbound is
	// capped at one and removal belongs to the edge's author, so a stranger
	// squatting that slot would leave an assertion about somebody's filing that
	// they could not remove.
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "author or a court moderator", func() {
		SupersedeClaim(cross(cur), "sup2", neu, old)
	})
	uassert.Equal(t, "of:;by:", ClaimSupersedes("sup2", neu))

	// A MODERATOR MAY RECORD SOMEBODY ELSE'S, and this branch is what keeps the
	// record completable: the author of a claim that is itself long dead has no
	// reason to send another transaction, so without it the oldest links in a
	// chain of re-filings could never be written at all. Note this also exercises
	// a court whose moderation state has never been allocated — alice is a
	// moderator because ensureMod seeds the creator, which the first draft of
	// this entrypoint got wrong by reading `c.mod == nil` as "no moderators".
	bob := testutils.TestAddress("sup2-b")
	c.coin.Mint(bob, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	bobs := OpenClaim(cross(cur), "sup2", "bob asks it again too")
	testing.SetRealm(testing.NewUserRealm(alice))
	SupersedeClaim(cross(cur), "sup2", bobs, old)
	uassert.Equal(t, "of:"+sid(old)+";by:", ClaimSupersedes("sup2", bobs))

	// THE MODERATION GATE. The edge carries no text, but it POINTS at a claim
	// whose title a purge withheld — returning it would put the purged claim's id
	// back on another claim's page and invite the reader to go and look.
	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeClaim(cross(cur), "sup2", old, "CSAM")
	uassert.Equal(t, "of:;by:", ClaimSupersedes("sup2", bobs))
}

// A court that has never carried one answers without allocating, which
// check-read-purity.py enforces structurally and this pins behaviourally. No
// dead claim needed, so no height is spent.
func TestSupersedeOnUntouchedCourtReadsEmpty(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sup3-a")
	testCourt(cur, "sup3", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "sup3", "nothing re-files this")
	uassert.Equal(t, "of:;by:", ClaimSupersedes("sup3", id))
}
