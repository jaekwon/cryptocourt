package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// The point of the switch: a claim's published deadlines are DATES. A chain
// that changes pace must not re-time them, and a claim opened before the
// stamps existed must keep exactly the deadline it was opened under.

func TestPublishedDeadlinesAreStamped(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ck-alice")
	c := testCourt(cur, "ck1", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "ck1", "Is the clock a date?")
	cs := mustClaim(c, id)

	if cs.openedAtTime == 0 {
		t.Fatal("OpenClaim must stamp the block's own time, not only its height")
	}
	if cs.openedAt == 0 {
		t.Error("the reference height must be kept beside the stamp")
	}
	tl := ClaimTimeline("ck1", id)
	if !strings.HasPrefix(tl, "opened:") || !strings.Contains(tl, ";now:") {
		t.Errorf("timeline grammar: %q", tl)
	}
	// Every field is <name>:<unix>:<height> — three parts, both clocks.
	for _, part := range strings.Split(tl, ";") {
		if n := len(strings.Split(part, ":")); n != 3 {
			t.Errorf("field %q has %d parts, want name:unix:height", part, n)
		}
	}
}

// A pace change must not move a deadline. The harness advances 5s per block,
// so "the chain halved its speed" is modelled by advancing time far past the
// block count that used to encode 72 hours.
func TestSettleGateFollowsTheDateNotTheHeight(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ck-b")
	bob := testutils.TestAddress("ck-c")
	c := testCourt(cur, "ck2", alice, 50_000_000_000)
	c.coin.Mint(bob, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "ck2", "Does the date govern?")
	Stake(cross(cur), "ck2", id, sideYES, 9_000_000_000)
	cs := mustClaim(c, id)

	// Freeze in-package (the answerability floor is another lane's concern).
	testing.SkipHeights(100)
	touch(c)
	cs.frozenAt = testingHeight()
	cs.rateAccAtFreeze = c.rateAccFP
	cs.answerHeight = testingHeight()
	cs.answeredAtTime = nowTime()
	cs.answer = sideYES
	cs.answerer = bob

	// One second short of 72h: refused, on the DATE.
	testing.SkipHeights(settleDelay - 1)
	uassert.AbortsContains(t, cur, "has not aged", func() {
		SettleUndisputed(cross(cur), "ck2", id)
	})

	// Past it: allowed.
	testing.SkipHeights(2)
	SettleUndisputed(cross(cur), "ck2", id)
	if cs.verdictAt == 0 {
		t.Fatal("the settle should have landed once the date passed")
	}
	if cs.verdictAtTime == 0 {
		t.Error("the verdict must be stamped in wall-clock time too")
	}
	if got := ClaimTimeline("ck2", id); !strings.Contains(got, ";verdict:") {
		t.Errorf("the timeline must carry the verdict: %q", got)
	}
}

// A claim carrying no stamp (opened before this change) keeps its original
// height gate — the fallback is the whole reason old state stays correct.
func TestPreStampClaimsKeepTheirHeightGate(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ck-d")
	bob := testutils.TestAddress("ck-e")
	c := testCourt(cur, "ck3", alice, 50_000_000_000)
	c.coin.Mint(bob, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "ck3", "Does old state still settle?")
	Stake(cross(cur), "ck3", id, sideYES, 9_000_000_000)
	cs := mustClaim(c, id)
	testing.SkipHeights(100)
	touch(c)
	cs.frozenAt = testingHeight()
	cs.rateAccAtFreeze = c.rateAccFP
	cs.answerHeight = testingHeight()
	cs.answer = sideYES
	cs.answerer = bob
	cs.answeredAtTime = 0 // the pre-upgrade shape
	cs.openedAtTime = 0

	testing.SkipHeights(settleDelay - 1)
	uassert.AbortsContains(t, cur, "has not aged", func() {
		SettleUndisputed(cross(cur), "ck3", id)
	})
	testing.SkipHeights(2)
	SettleUndisputed(cross(cur), "ck3", id) // and still allow it at the height
	if cs.verdictAt == 0 {
		t.Error("a pre-stamp claim must settle on its original height gate")
	}
	// Its timeline says so honestly: a zero stamp, a real height.
	if got := ClaimTimeline("ck3", id); !strings.Contains(got, "opened:0:") {
		t.Errorf("a pre-stamp claim's timeline must show 0 for the unknown date: %q", got)
	}
}
