package kourtv2

import (
	"strconv"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// strips.gno calls itself "the load-bearing guarantee of the whole moderation design":
// a hidden claim must never fall off EVERY surface while it is still policeable,
// because V2's junk defense is discovery-driven and a claim nobody discovers is a claim
// nobody flags. Six of thirteen mutations of that file survived the full 17-suite run —
// every one of them a way for a row to vanish from a policing surface, or for the
// anti-flood ordering to stop being what the header says it is.

// THE ANTI-FLOOD SPINE IS THE DEADLINE, not the open time. The header's claim is exact:
// rows sort by the actionable deadline, "a mill cannot manufacture a past deadline, and
// it cannot keep its own about-to-settle target off the top of the page". Swap
// answerHeight for openedAt in that key and the sort becomes something a mill CHOOSES —
// open early, and your rows sit at the top for ever while the target you want ignored
// sinks. Nothing failed.
//
// The fixture is built so the two orderings DISAGREE: the claim opened first is answered
// last. Under the deadline key the later-opened claim leads; under an openedAt key the
// earlier-opened one does.
func TestTheStripSortsByDeadlineAndNotByOpenTime(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sdl-alice")
	c := testCourt(cur, "sdl", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	early := OpenClaim(cross(cur), "sdl", "opened first, answered last")
	testing.SkipHeights(50)
	testing.SetRealm(testing.NewUserRealm(alice))
	late := OpenClaim(cross(cur), "sdl", "opened second, answered first")

	csE, csL := mustClaim(c, early), mustClaim(c, late)
	if csE.openedAt >= csL.openedAt {
		t.Fatalf("setup: the first claim must have opened earlier, %d vs %d",
			csE.openedAt, csL.openedAt)
	}
	base := heightNow() + 1_000_000
	csE.answerHeight = base + 500 // answered LAST
	csL.answerHeight = base       // answered FIRST
	stripEnter(c, csE)
	stripEnter(c, csL)

	page := StripPage("sdl", 0, 10)
	if len(page) != 2 {
		t.Fatalf("setup: both claims must be on the strip, got %v", page)
	}
	if page[0] != late {
		t.Fatalf("the nearest DEADLINE must lead the strip, got %d first (claims: "+
			"early=%d answered at %d, late=%d answered at %d)",
			page[0], early, csE.answerHeight, late, csL.answerHeight)
	}
	stripExit(c, csE)
	stripExit(c, csL)
}

// A SHARED DEADLINE MUST NOT COLLIDE. stripKey is the deadline followed by the claim id,
// and dropping the id survived: two claims answered in the same block write the same
// key, so the second Set overwrites the first and a claim silently leaves the policing
// surface while it is still policeable. Same block is not exotic — one transaction per
// claim in one block does it.
//
// The pending list carries the identical shape (openedAt plus the id) and the identical
// hole, so both are asserted here.
func TestTwoClaimsSharingAKeyBothStayOnTheirSurface(cur realm, t *testing.T) {
	alice := testutils.TestAddress("skey-alice")
	c := testCourt(cur, "skey", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	one := OpenClaim(cross(cur), "skey", "answered in the same block as its neighbour")
	testing.SetRealm(testing.NewUserRealm(alice))
	two := OpenClaim(cross(cur), "skey", "the neighbour")

	cs1, cs2 := mustClaim(c, one), mustClaim(c, two)
	same := heightNow() + 1_000_000
	cs1.answerHeight, cs2.answerHeight = same, same
	stripEnter(c, cs1)
	stripEnter(c, cs2)
	if got := StripSize("skey"); got != 2 {
		t.Fatalf("two claims answered in one block must both hold a strip row, size %d",
			got)
	}
	if !OnStrip("skey", one) || !OnStrip("skey", two) {
		t.Fatalf("both must be findable: one=%v two=%v",
			OnStrip("skey", one), OnStrip("skey", two))
	}
	stripExit(c, cs1)
	stripExit(c, cs2)

	// The pending list, same shape: openedAt plus the id. These two opened in the same
	// block, which is what makes the key collide.
	if cs1.openedAt != cs2.openedAt {
		t.Fatalf("setup: the two claims must share an open height, %d vs %d",
			cs1.openedAt, cs2.openedAt)
	}
	pendingEnter(c, cs1)
	pendingEnter(c, cs2)
	if got := PendingSize("skey"); got != 2 {
		t.Fatalf("two claims opened in one block must both hold a pending row, size %d",
			got)
	}
	pendingExit(c, cs1)
	pendingExit(c, cs2)
}

// THE REALM-WIDE STRIP IS KEYED BY COURT AS WELL. globalStripKey is deadline + slug +
// id, and dropping the slug survived — so claim #1 of one court and claim #1 of another,
// answered in the same block, write the same key and one of them disappears from the
// directory strip. Every court's first claims share low ids, which makes this the
// likeliest collision in the realm rather than the rarest.
func TestTheDirectoryStripKeepsBothCourtsClaims(cur realm, t *testing.T) {
	alice := testutils.TestAddress("gs-alice")
	bob := testutils.TestAddress("gs-bob")
	ca := testCourt(cur, "gsa", alice, 10_000_000_000)
	cb := testCourt(cur, "gsb", bob, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	ida := OpenClaim(cross(cur), "gsa", "first claim of the first court")
	testing.SetRealm(testing.NewUserRealm(bob))
	idb := OpenClaim(cross(cur), "gsb", "first claim of the second court")

	csa, csb := mustClaim(ca, ida), mustClaim(cb, idb)
	if csa.id != csb.id {
		t.Fatalf("setup: the two claims must share an id for the key to collide, %d vs %d",
			csa.id, csb.id)
	}
	same := heightNow() + 2_000_000
	csa.answerHeight, csb.answerHeight = same, same

	before := DirectoryStripSize()
	stripEnter(ca, csa)
	stripEnter(cb, csb)
	if got := DirectoryStripSize() - before; got != 2 {
		t.Fatalf("both courts' claims must hold a directory row, grew by %d", got)
	}
	stripExit(ca, csa)
	stripExit(cb, csb)
}

// EITHER ACTOR CAP BINDS ON ITS OWN. stripPageIDs holds a row back when the answerer OR
// the author is already at its share of a contended page, and narrowing that to AND
// survived — because the existing cap test gives every row the SAME address as answerer
// and author, so the two operands are identical and the operator between them cannot be
// measured at all. That is a fixture that cannot fail, not a test that passes.
//
// Here one answerer answers sixty claims by sixty DIFFERENT authors. Under the shipped
// rule the answerer's cap binds alone; under AND no author ever reaches five and the
// mill takes the whole page.
func TestOneActorsCapBindsEvenWhenTheOtherSideIsSpread(cur realm, t *testing.T) {
	mill := testutils.TestAddress("sac-mill")
	c := testCourt(cur, "sac", mill, 500_000_000_000)

	const rows = 60 // > renderPageSize, which is what makes the caps bind at all
	made := []*claimState{}
	base := heightNow() + 3_000_000
	for i := 0; i < rows; i++ {
		testing.SetRealm(testing.NewUserRealm(mill))
		id := OpenClaim(cross(cur), "sac", "spread "+strconv.Itoa(i))
		cs := mustClaim(c, id)
		// ONE answerer, SIXTY authors: the mill answers everything, and every claim is
		// filed by a different address, so perAuthor never reaches the cap.
		cs.answerer = mill
		cs.author = testutils.TestAddress("sac-author-" + strconv.Itoa(i))
		cs.answerHeight = base + int64(i)
		stripEnter(c, cs)
		made = append(made, cs)
	}
	if StripSize("sac") <= renderPageSize {
		t.Fatalf("setup: the page must be contended, size %d", StripSize("sac"))
	}

	page := StripPage("sac", 0, renderPageSize)
	if len(page) > stripActorCap {
		t.Fatalf("one answerer may hold at most %d rows of a contended page, got %d",
			stripActorCap, len(page))
	}
	for _, cs := range made {
		stripExit(c, cs)
	}
}

// AND THE READ MUST NOT PANIC ON A COURT THAT HAS NEVER ANSWERED ANYTHING. The nil
// check is `stripIdx == nil || limit <= 0`, and narrowing it to AND survived: a court
// whose strip index was never created dereferences nil on Size(). strips.gno's own
// header says every write here is called BY the money path and must never panic — the
// READ has the same obligation for a different reason, since a render that aborts takes
// the whole page with it.
func TestAFreshCourtsPolicingSurfacesReadEmpty(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sfresh-alice")
	testCourt(cur, "sfresh", alice, 1_000_000)
	if got := StripSize("sfresh"); got != 0 {
		t.Fatalf("setup: a court with no answered claim has no strip, size %d", got)
	}
	if got := StripPage("sfresh", 0, 10); len(got) != 0 {
		t.Fatalf("a never-answered court's strip must read empty, got %v", got)
	}
	if got := PendingPage("sfresh", 0, 10); len(got) != 0 {
		t.Fatalf("a never-seeded court's pending list must read empty, got %v", got)
	}
	// And a zero limit is still nothing, on a court that HAS a strip — the other half
	// of the same condition.
	if got := StripPage("sfresh", 0, 0); len(got) != 0 {
		t.Fatalf("a zero limit must return nothing, got %v", got)
	}
}
