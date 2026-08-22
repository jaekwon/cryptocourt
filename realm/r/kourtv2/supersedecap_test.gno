package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// THE INBOUND RE-FILING CAP AT ITS OWN BOUNDARY. maxSupIn bounds a READ — the claim
// page lists who re-filed this claim — so the cap is what stops that list growing
// without bound. A sweep of every cap comparison in the realm left this one
// surviving: `if inN >= maxSupIn` widened to `>` lets a ninth re-filing land, and
// nothing noticed.
//
// THE EDGES ARE SEEDED, NOT FILED, and that is the whole reason this test is cheap
// enough to exist. Reaching eight inbound edges through the public path needs eight
// distinct `from` claims — eight deposits, eight ordering windows — and at least four
// authors, because maxSupInPerAuthor is 2. The cap under test counts rows under one
// prefix of c.supBy, so the fixture writes rows there directly and then drives the
// NINTH through SupersedeClaim, which is the call that does the counting. Same idiom
// as the series tests writing straight into the archive: the subject is the count, not
// how the rows arrived.
//
// Both sides of the boundary, in one court with two targets: eight seeded rows must
// refuse the next re-filing, seven must accept it. The accepting arm is the one the
// mutation breaks — with `>` a target already holding eight accepts a ninth — and the
// refusing arm is what stops the test passing on a cap that was deleted outright.
func TestTheInboundRefilingCapHoldsAtExactlyEight(cur realm, t *testing.T) {
	alice := testutils.TestAddress("scap2-alice")
	c := testCourt(cur, "scap2", alice, 40_000_000_000)

	// seed writes n inbound edges against `to`, each from a DIFFERENT author so the
	// per-author cap (2) never binds instead of the one under test — that would be a
	// fixture passing for the wrong reason, with the wrong message.
	seed := func(to uint64, n int) {
		ensureSup(c)
		for i := 0; i < n; i++ {
			ghost := uint64(10_000 + i)
			e := &supEdge{
				to:     to,
				author: testutils.TestAddress("scap2-ghost" + strings.Repeat("z", i)),
				at:     heightNow(),
			}
			c.supBy.Set(beClaimKey(to)+beClaimKey(ghost), e)
		}
	}
	// inbound counts what SupersedeClaim's own walk would count, so the fixture can
	// prove it seeded what it meant to rather than assume the key shape.
	inbound := func(to uint64) int {
		n, p := 0, beClaimKey(to)
		c.supBy.Iterate(p, "", func(key string, _ any) bool {
			if !strings.HasPrefix(key, p) {
				return true
			}
			n++
			return false
		})
		return n
	}

	// A dead target and a re-filing far enough after it, from the top-level helper
	// below. It takes `cur realm` as a parameter rather than capturing it, which is
	// what every other crossing helper in this suite does (stakeAnswerDispute is the
	// pattern).
	fullDead, fullRefile := deadAndRefile(cur, c, "full")
	seed(fullDead, maxSupIn)
	if got := inbound(fullDead); got != maxSupIn {
		t.Fatalf("setup: the full target must hold exactly %d inbound edges, holds %d",
			maxSupIn, got)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "has already been re-filed 8 times", func() {
		SupersedeClaim(cross(cur), "scap2", fullRefile, fullDead)
	})
	uassert.Equal(t, maxSupIn, inbound(fullDead))

	// ...and one short of the cap still accepts. This is the arm that fails when the
	// comparison is widened, because a target holding eight would then accept too.
	nearDead, nearRefile := deadAndRefile(cur, c, "nearly full")
	seed(nearDead, maxSupIn-1)
	if got := inbound(nearDead); got != maxSupIn-1 {
		t.Fatalf("setup: the nearly-full target must hold %d inbound edges, holds %d",
			maxSupIn-1, got)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	SupersedeClaim(cross(cur), "scap2", nearRefile, nearDead)
	if got := inbound(nearDead); got != maxSupIn {
		t.Fatalf("the eighth re-filing is legal and must be recorded: %d inbound", got)
	}
}

// deadAndRefile opens a claim, marks it died-unanswered, and opens a second one
// stamped twelve weeks later so supersedeOrdered accepts the pair. openedAtTime is
// set directly rather than winding a clock twelve weeks forward: the ordering rule
// has its own boundary test (TestARefilingIsLegalExactlyAtTheDeathDeadline) and this
// fixture only needs it satisfied.
func deadAndRefile(cur realm, c *Court, title string) (dead, refile uint64) {
	testing.SetRealm(testing.NewUserRealm(c.admin))
	dead = OpenClaim(cross(cur), c.id, title+" (died unanswered)")
	testing.SetRealm(testing.NewUserRealm(c.admin))
	refile = OpenClaim(cross(cur), c.id, title+" (re-filed)")
	d, r := mustClaim(c, dead), mustClaim(c, refile)
	d.closed = true
	d.openedAtTime = 1_000_000
	r.openedAtTime = 1_000_000 + deadClaimSecs
	return dead, refile
}
