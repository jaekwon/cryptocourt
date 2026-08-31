package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// A COURT CARRIES ONE IMAGE, on the same terms a folder does and on the same
// seat that writes its description. A court is a venue: it argues nothing, so
// its picture proves nothing and gates nothing — it is curation, and curation is
// the moderators'.
func TestACourtCarriesOneImage(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cimg-alice")
	testCourt(cur, "cimg", alice, 10_000_000_000)

	if got := CourtImage("cimg"); got != "[]" {
		t.Fatalf("a new court already has a picture: %q", got)
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	SetCourtImage(cross(cur), "cimg", clientImageLine)
	got := CourtImage("cimg")
	if !strings.Contains(got, strings.Repeat("1", 64)) {
		t.Fatalf("the court's image did not come back: %q", got)
	}
	// ONE LINE, like every other media read: the overlay's parseTyped splits raw
	// output on newlines before it matches a typed value.
	if strings.Contains(got, "\n") {
		t.Fatalf("CourtImage must answer on one line: %q", got)
	}

	// Exactly one, and an image. Two is a caller who has misunderstood
	// something; a video is a link the court cannot vouch for, which is a fair
	// thing to file as evidence and not a fair thing to make the face of a venue.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "exactly one image", func() {
		SetCourtImage(cross(cur), "cimg", clientImageLine+"\n"+clientImageLine)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "exactly one image", func() {
		SetCourtImage(cross(cur), "cimg", "")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "not a video link", func() {
		SetCourtImage(cross(cur), "cimg", clientVideoLine)
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	ClearCourtImage(cross(cur), "cimg")
	if got := CourtImage("cimg"); got != "[]" {
		t.Fatalf("the picture survived being cleared: %q", got)
	}
}

// THE SEAT IS THE MODERATOR'S, the same one SetCourtDesc uses. A court's face is
// the most visible thing about it, and "anyone may set it" is an open door onto
// the directory's front page.
func TestACourtImageIsTheModeratorsSeat(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cimg2-alice")
	mallory := testutils.TestAddress("cimg2-mallory")
	testCourt(cur, "cimg2", alice, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsContains(t, cur, "moderator", func() {
		SetCourtImage(cross(cur), "cimg2", clientImageLine)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	SetCourtImage(cross(cur), "cimg2", clientImageLine)
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsContains(t, cur, "moderator", func() {
		ClearCourtImage(cross(cur), "cimg2")
	})
	if CourtImage("cimg2") == "[]" {
		t.Fatal("a stranger cleared the court's picture")
	}
}

// CourtImages answers a whole directory page in one query, and sends nothing for
// the courts that have no picture — the directory is mostly those, and a record
// per court would make this read grow with the directory rather than with the
// number of images in it.
func TestCourtImagesPacksOnlyWhatIsSet(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cimg3-alice")
	for _, sl := range []string{"ci3a", "ci3b", "ci3c"} {
		testCourt(cur, sl, alice, 10_000_000_000)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	SetCourtImage(cross(cur), "ci3b", clientImageLine)

	got := CourtImages("ci3a,ci3b,ci3c,nosuchcourt")
	lines := strings.Split(strings.TrimRight(got, "\n"), "\n")
	if len(lines) != 1 {
		t.Fatalf("one court has a picture, %d records came back: %q", len(lines), got)
	}
	if !strings.HasPrefix(lines[0], "ci3b\t") {
		t.Fatalf("the record is not the court that has one: %q", lines[0])
	}
	// TAB, because a media line is pipe-delimited and carries a caption a person
	// typed — a comma or a pipe as the outer separator is a caption away from
	// splitting the record in the wrong place.
	if strings.Count(lines[0], "\t") != 1 {
		t.Fatalf("one tab separates slug from media line: %q", lines[0])
	}
	// and the packed line is the same line the single read gives
	if lines[0] != "ci3b\t"+CourtImage("ci3b") {
		t.Fatalf("packed %q disagrees with CourtImage %q", lines[0], CourtImage("ci3b"))
	}
	if CourtImages("") != "" || CourtImages("nosuchcourt") != "" {
		t.Fatal("nothing to send is the empty reply, not a panic")
	}
}
