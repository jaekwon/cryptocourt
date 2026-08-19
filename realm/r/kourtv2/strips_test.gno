package kourtv2

import (
	"strconv"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// I9 / M-A13, THE named fixture: the undisputed, unflagged, all-bits-set
// answered claim — the exact row a colluding moderator would want invisible
// while it settles at the paying MID default — still appears on its court's
// policing strip and on the realm-wide directory strip.
func TestStripShowsHiddenAnsweredClaim(cur realm, t *testing.T) {
	alice := testutils.TestAddress("str-alice")
	testCourt(cur, "str1", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "str1", "hidden but policeable")
	matureOI(cur, "str1", id, alice, 200_000_000)

	// Not policeable before an answer: no strip row.
	if OnStrip("str1", id) {
		t.Fatal("an unanswered claim is not on the strip")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "str1", id, sideYES)
	if !OnStrip("str1", id) {
		t.Fatal("an answered claim must enter the strip")
	}

	// Now set EVERY hide bit that exists.
	testing.SetRealm(testing.NewUserRealm(alice))
	HideItem(cross(cur), "str1", id, "spam") // courtMod bit (alice is 1-of-1)
	c := mustCourt("str1")
	setMetaBit(c, id, alice) // meta bit
	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHide(cross(cur), "str1", id, "DMCA") // global bit
	if !HiddenFromListing("str1", id) {
		t.Fatal("the claim should be hidden from ordinary listings")
	}

	// ...and it is STILL on both policing surfaces. This is the guarantee.
	page := StripPage("str1", 0, 50)
	found := false
	for _, x := range page {
		if x == id {
			found = true
		}
	}
	if !found {
		t.Fatal("the strip must ignore courtMod/meta/global hide bits")
	}
	// The WHOLE index, not a fixed 50-row window. globalStripIdx is ordered by
	// deadline and every test in the package contributes rows to it, so a
	// hardcoded window silently stops covering this claim as the suite grows —
	// which is exactly what happened. The per-court cap does not hide it either:
	// str1 holds one row, well under stripActorCap.
	slugs, ids := DirectoryStripPage(0, DirectoryStripSize())
	dfound := false
	for i := range ids {
		if ids[i] == id && slugs[i] == "str1" {
			dfound = true
		}
	}
	if !dfound {
		t.Fatal("the directory strip must carry the row too (tier-hidden courts included)")
	}
}

// Ordering is nearest-deadline (oldest answer) first, and rows exit when the
// claim stops being policeable.
func TestStripOrderingAndExit(cur realm, t *testing.T) {
	alice := testutils.TestAddress("str2-alice")
	testCourt(cur, "str2", alice, 200_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	idA := OpenClaim(cross(cur), "str2", "answered first")
	matureOI(cur, "str2", idA, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "str2", idA, sideYES)

	testing.SkipHeights(epochBlocks)
	testing.SetRealm(testing.NewUserRealm(alice))
	idB := OpenClaim(cross(cur), "str2", "answered second")
	matureOI(cur, "str2", idB, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "str2", idB, sideYES)

	page := StripPage("str2", 0, 50)
	if len(page) < 2 || page[0] != idA {
		t.Fatalf("nearest-deadline (oldest answer) must sort first: %v", page)
	}
	if StripSize("str2") < 2 {
		t.Fatal("both rows should be resident")
	}
	// Pagination: offset skips.
	if p := StripPage("str2", 1, 1); len(p) != 1 || p[0] != idB {
		t.Fatalf("offset paging is wrong: %v", p)
	}
	// Exit: settle + crystallize the first claim.
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	SettleUndisputed(cross(cur), "str2", idA)
	testing.SkipHeights(priorityWindowBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "str2", idA)
	if OnStrip("str2", idA) {
		t.Fatal("a crystallized claim must leave the strip")
	}
	page = StripPage("str2", 0, 50)
	for _, x := range page {
		if x == idA {
			t.Fatal("the crystallized row must be gone from the page")
		}
	}
}

// A dead-closed claim leaves the pending list; a seeded claim starts there and
// moves to the strip when answered.
func TestSeededPendingToStrip(cur realm, t *testing.T) {
	alice := testutils.TestAddress("str3-alice")
	testCourt(cur, "str3", alice, 50_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaimSeeded(cross(cur), "str3", "seeded starter")
	if !OnPending("str3", id) || OnStrip("str3", id) {
		t.Fatal("an unanswered seeded claim belongs on the pending list, not the strip")
	}
	if PendingSize("str3") < 1 {
		t.Fatal("the pending list should hold the seeded row")
	}
	if p := PendingPage("str3", 0, 50); len(p) == 0 || p[0] != id {
		t.Fatalf("the pending page should list it: %v", p)
	}
	matureOI(cur, "str3", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "str3", id, sideYES)
	if OnPending("str3", id) || !OnStrip("str3", id) {
		t.Fatal("answering must move the row pending -> strip")
	}
}

func TestDeadClaimLeavesPending(cur realm, t *testing.T) {
	alice := testutils.TestAddress("str4-alice")
	testCourt(cur, "str4", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaimSeeded(cross(cur), "str4", "never answered")
	if !OnPending("str4", id) {
		t.Fatal("seeded rows start pending")
	}
	testing.SkipHeights(deadClaimTimeout + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	CloseDeadClaim(cross(cur), "str4", id)
	if OnPending("str4", id) {
		t.Fatal("a dead-closed claim must leave the pending list")
	}
}

// I5: a seeded claim mints NO author slice — neither in the draw nor at the
// payout site.
func TestSeededAuthorDrawIsZero(cur realm, t *testing.T) {
	alice := testutils.TestAddress("str5-alice")
	c := testCourt(cur, "str5", alice, 200_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaimSeeded(cross(cur), "str5", "seeded, will win")
	matureOI(cur, "str5", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "str5", id, sideYES)
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	SettleUndisputed(cross(cur), "str5", id)
	testing.SkipHeights(priorityWindowBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "str5", id)

	cs := mustClaim(c, id)
	if cs.drawAuthor != 0 {
		t.Fatalf("a seeded claim's author draw must be zero, got %d", cs.drawAuthor)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	if pay := AuthorBonus(cross(cur), "str5", id); pay != 0 {
		t.Fatalf("a seeded claim's AuthorBonus must pay zero, got %d", pay)
	}
}

// I9's ANTI-FLOOD SPINE, every arm of which survived the mutation batch: the
// per-actor caps on both strips, the seeded exemption, and the page bound. All six
// could be deleted with nothing noticing, which made the strips' sybil-blockade
// property a claim in the spec and nowhere else.
//
// The rows are CONSTRUCTED, not answered. Driving 51 claims through matureOI and
// PostAnswer would cost far more than it proves: the answer-to-strip path already
// has its own test above, and what is under test here is stripPageIDs' cap and
// bound arithmetic. Deadlines are set LATE on purpose — the strip is
// deadline-ordered and globalStripIdx is package-global and never reset, so early
// deadlines would push another test's row off the first directory page.
func TestStripCapsBindOnAContendedPage(cur realm, t *testing.T) {
	flooder := testutils.TestAddress("scp-flood")
	c := testCourt(cur, "scp", flooder, 500_000_000_000)

	const rows = 60 // > renderPageSize, which is what makes capBinds true
	made := []*claimState{}
	base := heightNow() + 1_000_000
	for i := 0; i < rows; i++ {
		testing.SetRealm(testing.NewUserRealm(flooder))
		id := OpenClaim(cross(cur), "scp", "flood "+strconv.Itoa(i))
		cs := mustClaim(c, id)
		cs.answerer = flooder
		cs.author = flooder
		cs.answerHeight = base + int64(i)
		if i == rows-1 {
			// One SEEDED row, owned by THE FLOODER and last by deadline. Both halves
			// are the point: an exemption only means anything when the exempt row's
			// owner is already OVER quota, so giving this row to an innocent third
			// party made the test pass whether or not the exemption existed. Owned by
			// the flooder and reached last, it is excluded without the exemption and
			// present with it.
			cs.seeded = true
		}
		stripEnter(c, cs)
		made = append(made, cs)
	}
	if StripSize("scp") <= renderPageSize {
		t.Fatalf("fixture: the strip must EXCEED one page or the cap cannot bind, got %d",
			StripSize("scp"))
	}

	// ONE ACTOR CANNOT HOLD A CONTENDED PAGE. Without the cap the flooder takes all
	// 50 slots and the page becomes their billboard, which is the blockade the
	// deadline spine exists to prevent.
	page := StripPage("scp", 0, renderPageSize)
	mine, seen := 0, false
	for _, id := range page {
		cs := mustClaim(c, id)
		// The cap bounds NON-EXEMPT rows; a seeded row is outside it by rule, so
		// counting it here would make the cap look breached by its own exemption.
		if cs.answerer == flooder && !cs.seeded {
			mine++
		}
		if cs.seeded {
			seen = true
		}
	}
	if mine > stripActorCap {
		t.Fatalf("one actor holds %d rows of a contended page; the cap is %d", mine, stripActorCap)
	}
	if mine == 0 {
		t.Fatal("fixture: the flooder must still hold its SHARE — a cap is not a ban")
	}
	// THE SEEDED EXEMPTION: seeded rows are force-visible, so the cap must not
	// count them out. Without it the one row a court seeded to bootstrap itself is
	// the first thing a flood buries.
	if !seen {
		t.Fatal("a seeded row must survive the per-actor cap")
	}

	// THE PAGE BOUND, which the cap above hides: with the flooder held to its share
	// the page is short, so a missing limit would never show. Give every row a
	// DISTINCT actor and the cap stops cutting — then only the bound holds the page
	// to one page.
	for i, cs := range made {
		a := testutils.TestAddress("scp-a" + strconv.Itoa(i))
		cs.answerer = a
		cs.author = a
		cs.seeded = false
	}
	wide := StripPage("scp", 0, renderPageSize)
	if len(wide) != renderPageSize {
		t.Fatalf("with distinct actors the page must fill to exactly the bound: got %d, want %d",
			len(wide), renderPageSize)
	}
	small := StripPage("scp", 0, 7)
	if len(small) != 7 {
		t.Fatalf("the caller's limit must bind too: got %d, want 7", len(small))
	}

	// THE DIRECTORY STRIP's own per-court cap: one court must not fill the
	// realm-wide policing page either, or a single flooded court hides every other.
	dslugs, _ := DirectoryStripPage(0, renderPageSize*4)
	fromScp := 0
	for _, s := range dslugs {
		if s == "scp" {
			fromScp++
		}
	}
	if fromScp > stripActorCap {
		t.Fatalf("one court holds %d rows of the directory strip; the cap is %d",
			fromScp, stripActorCap)
	}

	// Leave globalStripIdx as it was found: it is package-global and never reset, so
	// sixty rows left behind would follow every later test.
	for _, cs := range made {
		stripExit(c, cs)
	}
}
