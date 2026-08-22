package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// THE TIMELINE MUST NOT PUBLISH A DEADLINE THAT HAS BEEN OVERTAKEN. ClaimTimeline emits
// the settle line only while `cs.verdictAt == 0 && !cs.closed`, and widening that AND to
// an OR survived the whole suite — after which a claim with a verdict still advertises
// "settle:<date>" beside its own "verdict:<date>", because `false || true` holds for
// every decided-but-not-closed claim, which is what a settled claim IS.
//
// This is the client's own clock. ClaimTimeline exists so an overlay can print dates
// without re-deriving any gate, and testclock.gno names it as one of the two readers a
// fabricated chain must not lie to. A stale settle date there is not a cosmetic slip: it
// tells a reader a window is still open when the thing it gated has already happened.
//
// BOTH SIDES, on one claim, in order — the settle line is present while the claim is
// genuinely awaiting settlement, and gone once it is decided. Without the first half the
// second would pass on a timeline that never had a settle line at all.
func TestTheTimelineDropsTheSettleLineOnceThereIsAVerdict(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tml-alice")
	bob := testutils.TestAddress("tml-bob")
	c := testCourt(cur, "tml", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "tml", "settles by silence, then says so")
	matureOI(cur, "tml", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "tml", id, sideNO, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "tml", id, sideYES)

	// AWAITING SETTLEMENT: the line is there, and it is the only claim about the future
	// the timeline makes.
	before := ClaimTimeline("tml", id)
	if !strings.Contains(before, ";settle:") {
		t.Fatalf("setup: an answered, undecided claim must publish its settle "+
			"deadline: %s", before)
	}
	if strings.Contains(before, ";verdict:") {
		t.Fatalf("setup: there must be no verdict line yet: %s", before)
	}

	// DECIDED: the settle deadline has been overtaken by the verdict and must go.
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	SettleUndisputed(cross(cur), "tml", id)
	after := ClaimTimeline("tml", id)
	if !strings.Contains(after, ";verdict:") {
		t.Fatalf("setup: a settled claim must publish its verdict: %s", after)
	}
	if strings.Contains(after, ";settle:") {
		t.Fatalf("a decided claim must not still advertise a settle deadline: %s", after)
	}
}
