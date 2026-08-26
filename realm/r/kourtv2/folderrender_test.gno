package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// The filing tree, which rendered NOWHERE until this. A moderator could build a
// whole curation and no page in the realm drew it.
func TestAFolderIsReachableFromItsCourt(cur realm, t *testing.T) {
	mod := testutils.TestAddress("fr1-mod")
	poster := testutils.TestAddress("fr1-poster")
	c, _ := modFixture(cur, "fr1", mod, poster)
	_ = c

	testing.SetRealm(testing.NewUserRealm(mod))
	id := CreateFolder(cross(cur), "fr1", "Origins", "Where it came from.")
	testing.SetRealm(testing.NewUserRealm(mod))
	kid := CreateFolderIn(cross(cur), "fr1", id, "Funding", "Who paid.")

	// THE INDEX LINE, on the court page. A folder nobody can navigate to is the
	// defect this closes, so the link is the assertion.
	court := Render("fr1")
	if !strings.Contains(court, "Filed under: ") {
		t.Fatal("the court page must name its root folders")
	}
	href := "/r/kourt/kourtv2:fr1/folder/" + strconv.FormatUint(id, 10)
	if !strings.Contains(court, href) {
		t.Fatal("the court page must LINK the folder, not just name it")
	}
	// A CHILD IS NOT A ROOT. The index is one line, so a nested heading listed
	// there would make a court with a deep tree unreadable at the top.
	if strings.Contains(court, "/folder/"+strconv.FormatUint(kid, 10)) {
		t.Fatal("only root headings belong on the court's index line")
	}

	// THE PAGE ITSELF: name, description, children, and the way back.
	page := Render("fr1/folder/" + strconv.FormatUint(id, 10))
	for _, must := range []string{"# Origins", "Where it came from.", "Funding",
		"/r/kourt/kourtv2:fr1)"} {
		if !strings.Contains(page, must) {
			t.Fatal("the folder page is missing: " + must)
		}
	}
	// The promise the module was founded on, said on the page that could
	// otherwise be read as a moderator's private index.
	if !strings.Contains(page, "can never bury") {
		t.Fatal("a folder page must say that nothing is reachable only from it")
	}

	// A NESTED PAGE SAYS WHERE IT SITS. Somebody arriving by deep link is
	// otherwise stranded inside a tree with no way up.
	child := Render("fr1/folder/" + strconv.FormatUint(kid, 10))
	if !strings.Contains(child, "Origins](/r/kourt/kourtv2:fr1/folder/"+
		strconv.FormatUint(id, 10)+")") {
		t.Fatal("a child folder must breadcrumb to its parent")
	}
}

// The claims filed in a folder are the ones a moderator filed there, with the
// same status wording the court's own list uses.
func TestAFolderShowsTheClaimsFiledInIt(cur realm, t *testing.T) {
	mod := testutils.TestAddress("fr2-mod")
	poster := testutils.TestAddress("fr2-poster")
	modFixture(cur, "fr2", mod, poster)

	testing.SetRealm(testing.NewUserRealm(poster))
	cid := OpenClaim(cross(cur), "fr2", "A filed claim about a filed thing.")
	testing.SetRealm(testing.NewUserRealm(mod))
	fid := CreateFolder(cross(cur), "fr2", "Docket", "")

	empty := Render("fr2/folder/" + strconv.FormatUint(fid, 10))
	if !strings.Contains(empty, "Nothing filed here yet.") {
		t.Fatal("an empty folder must say it is empty, not render a blank list")
	}

	testing.SetRealm(testing.NewUserRealm(mod))
	AddToFolder(cross(cur), "fr2", fid, cid)
	page := Render("fr2/folder/" + strconv.FormatUint(fid, 10))
	// NO TRAILING PERIOD IN THE ASSERTION. Titles go through
	// sanitize.InlineText, which backslash-escapes "." and "-", so the rendered
	// text is "…filed thing\." — matching on the punctuation asserts the
	// escaper's behaviour rather than the page's.
	if !strings.Contains(page, "A filed claim about a filed thing") {
		t.Fatal("a filed claim must appear on its folder's page")
	}
	if !strings.Contains(page, "/r/kourt/kourtv2:fr2/"+strconv.FormatUint(cid, 10)+")") {
		t.Fatal("a filed claim must link to the claim itself")
	}
	// The SAME status wording as the court's list. A reader who learned what
	// "open — stake YES or NO" means on one page should not meet a synonym here.
	if !strings.Contains(page, claimStatus(mustClaim(mustCourt("fr2"), cid))) {
		t.Fatal("a folder must use the court's own status wording")
	}
}

// A retired heading still resolves and says so; the court stops advertising it.
func TestARetiredFolderResolvesAndSaysSo(cur realm, t *testing.T) {
	mod := testutils.TestAddress("fr3-mod")
	poster := testutils.TestAddress("fr3-poster")
	modFixture(cur, "fr3", mod, poster)

	testing.SetRealm(testing.NewUserRealm(mod))
	fid := CreateFolder(cross(cur), "fr3", "Struck", "")
	testing.SetRealm(testing.NewUserRealm(mod))
	RetireFolder(cross(cur), "fr3", fid)

	// OFF THE INDEX: a retired heading is one a moderator took out of the tree.
	if strings.Contains(Render("fr3"), "/folder/"+strconv.FormatUint(fid, 10)) {
		t.Fatal("a retired folder must not be advertised on the court page")
	}
	// STILL RESOLVES: the row survives so older links do not rot, and the page
	// says which it is rather than 404ing, which would make "retired" look like
	// "never existed".
	page := Render("fr3/folder/" + strconv.FormatUint(fid, 10))
	if !strings.Contains(page, "retired by a moderator") {
		t.Fatal("a retired folder's page must say it was retired")
	}
	if strings.Contains(page, "## Not found") {
		t.Fatal("a retired folder must still resolve")
	}
}

// The route refuses what is not a folder, naming WHICH thing is wrong.
//
// EACH REFUSAL ASSERTED BY ITS OWN MESSAGE, not by the words "Not found" that
// all four share. Both weaker forms survived mutation: dropping the id parse
// left fid at zero, which lands on the no-such-folder branch and still says
// "Not found", so a test matching the common prefix passed against a router
// that had stopped parsing.
func TestTheFolderRouteRefusesWhatIsNotOne(cur realm, t *testing.T) {
	mod := testutils.TestAddress("fr4-mod")
	poster := testutils.TestAddress("fr4-poster")
	modFixture(cur, "fr4", mod, poster)
	// A REAL FOLDER FIRST. Without one c.mod is nil and every request short-
	// circuits on "this court has no folders" — so the branch that refuses a
	// bad id is never reached, and a mutant deleting it survives.
	testing.SetRealm(testing.NewUserRealm(mod))
	fid := CreateFolder(cross(cur), "fr4", "Real", "")

	for _, tc := range []struct{ path, want string }{
		{"fr4/folder", "A folder is /<court>/folder/<id>."},
		{"fr4/folder/notanum", "A folder id must be a number."},
		{"fr4/folder/999", "No folder by that id."},
		{"fr4/folder/" + strconv.FormatUint(fid, 10) + "/extra", "A folder is /<court>/folder/<id>."},
		{"nosuchct/folder/1", "No court by that slug."},
	} {
		got := Render(tc.path)
		if !strings.Contains(got, tc.want) {
			t.Fatalf("%q must be refused with %q", tc.path, tc.want)
		}
	}
	// And the real one still renders, so the five refusals are about the inputs
	// rather than about a route that refuses everything.
	if !strings.Contains(Render("fr4/folder/"+strconv.FormatUint(fid, 10)), "# Real") {
		t.Fatal("a real folder must still render")
	}
}
