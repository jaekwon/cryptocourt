package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// A SUPERSEDED CLAIM SAYS SO, ABOVE EVERYTHING ELSE.
//
// This is the edge that costs something to miss. An argument edge is a view
// somebody holds; a supersede edge is a verified statement about the docket's
// own history — this claim's question died unanswered and was re-filed as
// another. A reader sitting on the dead one, with coin staked, had no way to
// learn that the live version of their question is somewhere else.
func TestASupersededClaimPointsAtItsReplacement(cur realm, t *testing.T) {
	alice, c, old, _, neu := supFixture(cur, t, "rel1")
	testing.SetRealm(testing.NewUserRealm(alice))
	SupersedeClaim(cross(cur), "rel1", neu, old)

	// The DEAD claim carries the redirection.
	dead := Render("rel1/" + strconv.FormatUint(old, 10))
	if !strings.Contains(dead, "This question was asked again") {
		t.Fatalf("a superseded claim must say so:\n%s", dead)
	}
	if !strings.Contains(dead, "/r/kourt/kourtv2:rel1/"+strconv.FormatUint(neu, 10)+")") {
		t.Fatal("it must link the claim that replaced it")
	}
	if !strings.Contains(dead, "the same question, put again") {
		t.Fatal("it must name the replacement, not just link an id")
	}
	// ABOVE THE SIGNAL. The notice changes whether the page below is worth
	// reading, so it goes where the hide banner goes — not in a footer.
	if strings.Index(dead, "This question was asked again") > strings.Index(dead, "## Signal") {
		t.Fatal("the redirection must precede the claim's own numbers")
	}

	// The LIVE claim says what it re-files, quietly — it is context, not a
	// redirection, so it does not shout.
	live := Render("rel1/" + strconv.FormatUint(neu, 10))
	if !strings.Contains(live, "Re-files [") || !strings.Contains(live, "died unanswered") {
		t.Fatalf("the re-filing claim must name what it re-files:\n%s", live)
	}
	if strings.Contains(live, "This question was asked again") {
		t.Fatal("the live claim must not carry the redirection meant for the dead one")
	}
	_ = c
}

// The argument graph, in both directions, named for what it is.
func TestAClaimShowsWhatSupportsAndContestsIt(cur realm, t *testing.T) {
	poster := testutils.TestAddress("rel2-poster")
	c := testCourt(cur, "rel2", poster, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(poster))
	a := OpenClaim(cross(cur), "rel2", "The claim under the microscope")
	testing.SetRealm(testing.NewUserRealm(poster))
	b := OpenClaim(cross(cur), "rel2", "A claim that backs it up")
	testing.SetRealm(testing.NewUserRealm(poster))
	d := OpenClaim(cross(cur), "rel2", "A claim that cuts against it")

	testing.SetRealm(testing.NewUserRealm(poster))
	AddAssociation(cross(cur), "rel2", a, b, "supports")
	testing.SetRealm(testing.NewUserRealm(poster))
	AddAssociation(cross(cur), "rel2", d, a, "contests")

	page := Render("rel2/" + strconv.FormatUint(a, 10))
	if !strings.Contains(page, "## Related claims") {
		t.Fatalf("the argument graph must render:\n%s", page)
	}
	// DIRECTION IS SPELLED OUT BOTH WAYS. "out" and "in" mean nothing to a
	// reader, and an edge this claim asserts is not the same fact as one
	// somebody else pointed at it — conflating them puts words in its mouth.
	if !strings.Contains(page, "This claim says:") {
		t.Fatal("edges this claim asserts must be labelled as its own")
	}
	if !strings.Contains(page, "Others say about this claim:") {
		t.Fatal("edges pointed at this claim must be labelled as somebody else's")
	}
	if !strings.Contains(page, "supports [A claim that backs it up]") {
		t.Fatal("an outgoing support edge must name its target")
	}
	if !strings.Contains(page, "contests it [A claim that cuts against it]") {
		t.Fatal("an incoming contest edge must read as somebody else's assertion")
	}
	// AND THAT THEY ARE OPINIONS. Anyone may draw one and the chain checks
	// nothing, so a reader who took this for an adjudicated finding would be
	// reading a stranger's claim as the court's.
	if !strings.Contains(page, "the court does not rule on") {
		t.Fatal("the page must say these links are assertions, not findings")
	}
	_ = c
}

// A claim with no edges renders no section at all.
func TestAClaimWithNoRelationsSaysNothingAboutThem(cur realm, t *testing.T) {
	poster := testutils.TestAddress("rel3-poster")
	testCourt(cur, "rel3", poster, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(poster))
	id := OpenClaim(cross(cur), "rel3", "A claim standing on its own")

	page := Render("rel3/" + strconv.FormatUint(id, 10))
	for _, absent := range []string{"## Related claims", "This question was asked again", "Re-files ["} {
		if strings.Contains(page, absent) {
			t.Fatal("a claim with no edges must not render: " + absent)
		}
	}
}

// A WITHHELD CLAIM IS NOT SURFACED BY A RELATION.
//
// This is the gate whose failure undoes a purge. Both packed reads
// (ClaimAssociations, ClaimSupersedes) drop an edge whose other end is purged or
// globally redacted, precisely so a withheld claim's id cannot reappear on
// somebody else's page. A render that showed what the read withholds would put
// it back by a side door — and both mutants that removed these checks survived a
// version of this file that never put a withheld claim in a relation at all.
func TestARelationCannotSurfaceAWithheldClaim(cur realm, t *testing.T) {
	poster := testutils.TestAddress("rel4-poster")
	c := testCourt(cur, "rel4", poster, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(poster))
	visible := OpenClaim(cross(cur), "rel4", "The claim a reader is looking at")
	testing.SetRealm(testing.NewUserRealm(poster))
	doomed := OpenClaim(cross(cur), "rel4", "A claim about to be taken down")

	// Edges in BOTH directions, so the outgoing and incoming walks are each
	// exercised against a withheld endpoint.
	testing.SetRealm(testing.NewUserRealm(poster))
	AddAssociation(cross(cur), "rel4", visible, doomed, "supports")
	testing.SetRealm(testing.NewUserRealm(poster))
	AddAssociation(cross(cur), "rel4", doomed, visible, "contests")

	page := Render("rel4/" + strconv.FormatUint(visible, 10))
	if !strings.Contains(page, "A claim about to be taken down") {
		t.Fatal("the fixture must show the edge BEFORE the takedown, or the " +
			"assertion after it proves nothing")
	}

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHide(cross(cur), "rel4", doomed, "LEGAL")

	after := Render("rel4/" + strconv.FormatUint(visible, 10))
	if strings.Contains(after, "A claim about to be taken down") {
		t.Fatalf("a globally-hidden claim's TITLE must not appear on another "+
			"claim's page:\n%s", after)
	}
	if strings.Contains(after, "kourtv2:rel4/"+strconv.FormatUint(doomed, 10)+")") {
		t.Fatalf("nor its id, as a link — the title is gated separately by "+
			"claimTitleFor, so the id is what actually leaks:\n%s", after)
	}
	// The render must agree with the read: whatever ClaimAssociations withholds,
	// the page withholds.
	if strings.Contains(ClaimAssociations("rel4", visible),
		strconv.FormatUint(doomed, 10)) {
		t.Fatal("the fixture assumes the packed read drops the edge; it did not")
	}
	_ = c
}

// The same gate, on the supersede edge.
func TestASupersedeCannotSurfaceAWithheldClaim(cur realm, t *testing.T) {
	alice, _, old, _, neu := supFixture(cur, t, "rel5")
	testing.SetRealm(testing.NewUserRealm(alice))
	SupersedeClaim(cross(cur), "rel5", neu, old)

	dead := Render("rel5/" + strconv.FormatUint(old, 10))
	if !strings.Contains(dead, "the same question, put again") {
		t.Fatal("the fixture must show the redirection before the takedown")
	}

	// Take down the REPLACEMENT. The dead claim must stop pointing at it rather
	// than pointing at a claim whose text has been withheld.
	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHide(cross(cur), "rel5", neu, "LEGAL")

	after := Render("rel5/" + strconv.FormatUint(old, 10))
	if strings.Contains(after, "the same question, put again") {
		t.Fatalf("a withheld replacement must not be named:\n%s", after)
	}
	if strings.Contains(after, "This question was asked again") {
		t.Fatal("with its only replacement withheld, the notice must not render " +
			"an empty redirection")
	}
}
