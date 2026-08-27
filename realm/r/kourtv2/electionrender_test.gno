package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// With no ballot open, the page still answers — because "no election is open"
// is the state a holder is most often in and the one they can act from.
func TestTheBallotPageAnswersWhenNoBallotIsOpen(cur realm, t *testing.T) {
	creator := testutils.TestAddress("er1-creator")
	holder := testutils.TestAddress("er1-holder")
	electionCourt(cur, "er1", creator, []address{holder}, []int64{500_000_000})

	page := Render("er1/election")
	if strings.Contains(page, "Not found") {
		t.Fatal("a court with no open ballot must still render its ballot page")
	}
	if !strings.Contains(page, "## No election is open") {
		t.Fatal("the page must say plainly that none is open")
	}
	// WHAT MODERATORS CAN DO, before the mechanics — a reader cannot judge
	// whether the page matters without it, and the powers are not guessable
	// from the word "moderator".
	for _, power := range []string{"hide a claim", "slash somebody's standing",
		"freeze an address", "only way the court's holders replace them"} {
		if !strings.Contains(page, power) {
			t.Fatal("the page must say what is at stake: " + power)
		}
	}
	// AND HOW TO OPEN ONE. Naming only one of the two calls leaves a reader with
	// a panic and no page to explain it.
	if !strings.Contains(page, "RegisterModCandidate") || !strings.Contains(page, "OpenElection") {
		t.Fatal("the page must name both calls that open a ballot")
	}
	if !strings.Contains(page, "can be opened now") {
		t.Fatal("a court out of cooldown must be told so")
	}
}

// A live ballot: the phase, the field, retain beside the challengers, and the
// turnout bar with the warning that has to travel with it.
func TestTheBallotPageShowsALiveElection(cur realm, t *testing.T) {
	creator := testutils.TestAddress("er2-creator")
	honest := testutils.TestAddress("er2-honest")
	newMod := testutils.TestAddress("er2-newmod")
	c := electionCourt(cur, "er2", creator,
		[]address{honest}, []int64{690_000_000})
	c.coin.Mint(honest, 50_000_000)

	testing.SetRealm(testing.NewUserRealm(honest))
	cand := RegisterModCandidate(cross(cur), "er2", 1, newMod)
	testing.SetRealm(testing.NewUserRealm(honest))
	OpenElection(cross(cur), "er2", cand)

	// PHASE ONE: nominating. A reader who nominates in the vote window, or votes
	// in the nomination window, gets a panic — so the page derives the phase
	// rather than leaving two block numbers to be compared against a third.
	page := Render("er2/election")
	if !strings.Contains(page, "**Nominating.**") {
		t.Fatalf("the open ballot must name its phase:\n%s", page)
	}
	if !strings.Contains(page, "set #"+strconv.FormatUint(cand, 10)) {
		t.Fatal("the ballot must list the candidate set")
	}
	if !strings.Contains(page, newMod.String()) {
		t.Fatal("a candidate set must name who it would seat")
	}
	// RETAIN IS A LINE ON THE BALLOT, not a footnote: it is what wins if nobody
	// clears the bar, so it belongs in the list a reader is comparing.
	if !strings.Contains(page, "keep the current moderators") {
		t.Fatal("retain must be listed beside the challengers")
	}
	if !strings.Contains(page, "weights are pinned") {
		t.Fatal("the page must say buying coin now adds no weight")
	}

	// PHASE TWO: voting.
	testing.SkipHeights(nominationWindow)
	testing.SetRealm(testing.NewUserRealm(honest))
	ApproveCandidate(cross(cur), "er2", cand)
	voting := Render("er2/election")
	if !strings.Contains(voting, "**Voting.**") {
		t.Fatalf("the phase must advance with the windows:\n%s", voting)
	}
	if !strings.Contains(voting, "cast so far: **690000000") {
		t.Fatalf("turnout must render:\n%s", voting)
	}
	if !strings.Contains(voting, "the bar is cleared") {
		t.Fatal("a cleared bar must say so")
	}
}

// The hazard, which is the part of this page that had to be right.
//
// install requires turnout >= floor, and below it NOTHING installs and the
// current set stands. So falling short is not a null result — it is a win for
// the incumbents, and a page that lets a reader read it as a draw has misled
// them in the direction that costs them the court.
func TestTheBallotPageSaysFallingShortRetainsTheIncumbents(cur realm, t *testing.T) {
	creator := testutils.TestAddress("er3-creator")
	small := testutils.TestAddress("er3-small")
	newMod := testutils.TestAddress("er3-newmod")
	c := electionCourt(cur, "er3", creator,
		[]address{small}, []int64{900_000_000})
	c.coin.Mint(small, 50_000_000)

	testing.SetRealm(testing.NewUserRealm(small))
	cand := RegisterModCandidate(cross(cur), "er3", 1, newMod)
	testing.SetRealm(testing.NewUserRealm(small))
	OpenElection(cross(cur), "er3", cand)
	page := Render("er3/election")

	if !strings.Contains(page, "Falling short is not a draw") {
		t.Fatal("the page must say a short ballot keeps the incumbents")
	}
	if !strings.Contains(page, "the same outcome as a vote to retain them") {
		t.Fatal("the page must name the outcome, not merely that nothing installs")
	}
	// THE POOL THE BAR IS MEASURED ON INCLUDES COIN NO KEY CAN VOTE. A reader
	// reasoning "we need 5% of the pool" is reasoning about a pool part of which
	// cannot turn out, and the error runs in the incumbents' favour.
	if !strings.Contains(page, "including coin that cannot vote") {
		t.Fatal("the page must warn that the bar's pool includes unvotable coin")
	}
	if !strings.Contains(page, "larger than the bar looks") {
		t.Fatal("the page must say which DIRECTION that error runs")
	}
	// The bar and the shortfall are both figures, not adjectives.
	if !strings.Contains(page, "- the bar: **") || !strings.Contains(page, "- still needed: **") {
		t.Fatalf("the bar and the shortfall must be numbers:\n%s", page)
	}
}

// It is reachable, and refuses what is not it.
func TestTheBallotPageIsLinkedAndItsRouteIsExact(cur realm, t *testing.T) {
	mod := testutils.TestAddress("er4-mod")
	poster := testutils.TestAddress("er4-poster")
	modFixture(cur, "er4", mod, poster)

	// A page nobody can navigate to is the defect this closes, so the link is
	// the assertion — from the moderation log, where somebody looking at who
	// holds power already is.
	if !strings.Contains(Render("er4/mod"), "/r/kourt/kourtv2:er4/election") {
		t.Fatal("the moderation log must link the ballot")
	}
	for _, bad := range []string{"er4/election/1", "er4/election/x"} {
		if !strings.Contains(Render(bad), "The ballot is /<court>/election.") {
			t.Fatal("the ballot route must refuse a deeper path: " + bad)
		}
	}
	if !strings.Contains(Render("nosuchct/election"), "No court by that slug.") {
		t.Fatal("an unknown court must not render a ballot")
	}
}
