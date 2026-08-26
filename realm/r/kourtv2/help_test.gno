package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// The help page is reachable, and reachable from the pages a stranger actually
// lands on — which is the whole difference between a help page and a file.
func TestTheHelpPageIsReachableFromWhereStrangersLand(cur realm, t *testing.T) {
	alice := testutils.TestAddress("hp1-alice")
	c, id := boardFixture(cur, "hp1", alice)
	_ = c
	sid := strconv.FormatUint(id, 10)

	page := Render(helpPath)
	if !strings.Contains(page, "# How Kourt works") {
		t.Fatal("the help route must render the help page")
	}
	// The load-bearing surprise has to be IN it. A help page that omits the one
	// thing a reader's prior model gets wrong is decoration.
	for _, must := range []string{
		"cannot lose your stake",
		"1×",
		"A court is a subject",
		"Comments are where the argument is",
		"entry pass",
		"moderation log",
	} {
		if !strings.Contains(page, must) {
			t.Fatal("the help page must explain: " + must)
		}
	}

	// LINKED FROM EVERY COLD ENTRY POINT. Each of these is somewhere a reader
	// can arrive without having seen any other page.
	for _, from := range []string{
		"",                  // the directory — the front door
		"hp1",               // a court — reached from a court list anywhere
		"hp1/" + sid + "/board", // a comment board — every comment is a deep link
	} {
		if !strings.Contains(Render(from), "/r/kourt/kourtv2:"+helpPath) {
			t.Fatalf("no way to reach help from %q", from)
		}
	}
}

// The route cannot be taken by a court, and does not take a court's route.
func TestTheHelpRouteCannotCollideWithACourt(cur realm, t *testing.T) {
	// It is longer than any slug may be, so the sets are disjoint by
	// construction — this is the property the carve relies on, asserted rather
	// than assumed.
	if len(helpPath) <= maxSlugLen {
		t.Fatal("the help path must be too long to be a slug, or a court can shadow it")
	}
	mod := testutils.TestAddress("hp2-mod")
	testing.SetRealm(testing.NewUserRealm(mod))
	uassert.AbortsContains(t, cur, "a slug is 1..11 characters", func() {
		StartCourt(cross(cur), helpPath, "Impostor")
	})

	// And the carve did not eat an ordinary court: a real slug still renders its
	// court, not the help page.
	testing.SetRealm(testing.NewUserRealm(mod))
	StartCourt(cross(cur), "hp2", "Ordinary Court")
	got := Render("hp2")
	if strings.Contains(got, "How Kourt works\n") && !strings.Contains(got, "# Ordinary Court") {
		t.Fatal("the help carve swallowed a court")
	}
	if !strings.Contains(got, "# Ordinary Court") {
		t.Fatal("an ordinary slug must still render its court")
	}
}

// The claims come before the accounting, and the accounting is still all there.
func TestACourtLeadsWithItsClaimsNotItsPlumbing(cur realm, t *testing.T) {
	alice := testutils.TestAddress("hp3-alice")
	c, _ := boardFixture(cur, "hp3", alice)
	_ = c
	page := Render("hp3")

	claims := strings.Index(page, "## Claims")
	coin := strings.Index(page, "## This court's coin")
	if claims < 0 || coin < 0 {
		t.Fatal("a court page needs both its claims and its coin")
	}
	if claims > coin {
		t.Fatal("the claims must come before the coin accounting, not after it")
	}
	// NOTHING WAS DROPPED IN THE MOVE. Every figure that was above the claims is
	// still on the page — this is a reordering, not a deletion.
	for _, must := range []string{
		"ugnot per coin", "in circulation:", "paid out as rewards so far:",
		"reward reservoir:", "already owed to earlier earners",
	} {
		if !strings.Contains(page, must) {
			t.Fatal("the move lost a figure: " + must)
		}
	}
	// Each house term is glossed where it is printed, not in a legend elsewhere.
	for _, gloss := range []string{"waiting to be earned", "there is no sell side"} {
		if !strings.Contains(page, gloss) {
			t.Fatal("an unglossed house term: " + gloss)
		}
	}
}

// A court with no claims still shows its coin — somebody deciding whether to be
// early is exactly who wants the price.
func TestAnEmptyCourtStillShowsItsCoin(cur realm, t *testing.T) {
	mod := testutils.TestAddress("hp4-mod")
	testing.SetRealm(testing.NewUserRealm(mod))
	StartCourt(cross(cur), "hp4", "Empty Court")
	page := Render("hp4")
	if !strings.Contains(page, "_No claims yet._") {
		t.Fatal("an empty court says so")
	}
	if !strings.Contains(page, "## This court's coin") {
		t.Fatal("an empty court must still show its coin and price")
	}
}

// The two "put your address on the end of the path" hints give the WHOLE path.
//
// Both elided the court slug — "…/9/<your-address>" and "covid/me/<address>" —
// which is precisely the half a reader cannot supply from the page they are on.
// A hint that assumes the convention it is explaining is not a hint.
func TestThePathHintsAreCompleteEnoughToFollow(cur realm, t *testing.T) {
	mod := testutils.TestAddress("hp5-mod")
	poster := testutils.TestAddress("hp5-poster")
	modFixture(cur, "hp5", mod, poster)
	testing.SetRealm(testing.NewUserRealm(poster))
	cid := OpenClaim(cross(cur), "hp5", "A claim to have a position on.")

	claim := Render("hp5/" + strconv.FormatUint(cid, 10))
	want := "/r/kourt/kourtv2:hp5/" + strconv.FormatUint(cid, 10) + "/<your address>"
	if !strings.Contains(claim, want) {
		t.Fatal("the claim page must give the positions path in full")
	}
	if strings.Contains(claim, "…/") {
		t.Fatal("a path hint must not elide the part a reader cannot supply")
	}

	me := Render("hp5/me")
	if !strings.Contains(me, "/r/kourt/kourtv2:hp5/me/<address>") {
		t.Fatal("the standing index must give its path in full")
	}
	// AND IT DEFINES ITS OWN JARGON. The three thresholds below it are quoted in
	// bps and are meaningless without it.
	if !strings.Contains(me, "hundredth of a percent") {
		t.Fatal("a page that quotes bps must say what a bp is")
	}
}
