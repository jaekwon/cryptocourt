package courtv2

import (
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
	slugs, ids := DirectoryStripPage(0, 50)
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
