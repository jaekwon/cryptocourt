package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// THE 200-CLAIM CAP ON A FOLDER, which was the one guard of its commit that nothing
// held. Deleting `len(f.items) >= maxFolderItems` survived the whole suite: every
// folder test adds two or three claims, so the boundary was a hundred and ninety-seven
// items away from any fixture. The cap is not decoration — folders.gno's own comment
// says AddToFolder scans the list for duplicates on every add, so an uncapped folder
// makes filling it cost O(n^2) and makes a WRITE grow with what was already written.
//
// FILLED DIRECTLY, and that is the whole reason this test can exist. AddToFolder
// requires the claim to exist (`mustClaim`), so reaching the cap through the front door
// costs 199 opened claims and 199 deposits. The guard reads len(f.items) and nothing
// else, so occupying the length is enough — the same move as driving the reservoir to
// its cap with one junior draw instead of waiting years for it. The filler ids sit far
// above any claim this court opens, so the duplicate scan cannot match them and the
// fill cannot mask the thing being measured.
//
// THREE STATES, and the third is an ordering rather than a value. One below the cap the
// add must LAND; at the cap it must be REFUSED; and at the cap a claim ALREADY IN the
// folder must still be accepted, because the duplicate scan runs BEFORE the cap check.
// Swap those two and a full folder starts refusing an idempotent re-add — a change no
// test that only counts items would ever see.
func TestAFolderStopsAtItsCap(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fcap-alice")
	testCourt(cur, "fcap", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	fits := OpenClaim(cross(cur), "fcap", "the claim that fits")
	testing.SetRealm(testing.NewUserRealm(alice))
	overflows := OpenClaim(cross(cur), "fcap", "the claim that does not")
	testing.SetRealm(testing.NewUserRealm(alice))
	fid := CreateFolder(cross(cur), "fcap", "Full", "")

	f := mustCourt("fcap").mod.mustFolder(fid)
	for i := 0; i < maxFolderItems-1; i++ {
		f.items = append(f.items, uint64(1_000_000+i))
	}
	if len(f.items) != maxFolderItems-1 {
		t.Fatalf("setup: the fill must stop one short of the cap, got %d of %d",
			len(f.items), maxFolderItems)
	}

	// One below the cap: the last space is usable.
	testing.SetRealm(testing.NewUserRealm(alice))
	AddToFolder(cross(cur), "fcap", fid, fits)
	if len(f.items) != maxFolderItems {
		t.Fatalf("the last space in a folder must be usable, %d items", len(f.items))
	}

	// At the cap: refused, and nothing lands.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "holds at most", func() {
		AddToFolder(cross(cur), "fcap", fid, overflows)
	})
	if len(f.items) != maxFolderItems {
		t.Fatalf("a refused add must not append, %d items", len(f.items))
	}

	// At the cap, a claim already present is still idempotent rather than refused.
	testing.SetRealm(testing.NewUserRealm(alice))
	AddToFolder(cross(cur), "fcap", fid, fits)
	if len(f.items) != maxFolderItems {
		t.Fatalf("an idempotent re-add must neither append nor abort, %d items",
			len(f.items))
	}
}

// A MOVE MUST NOT BE AN ADD. MoveItemInFolder locates the claim in the list and
// refuses `at < 0`, and deleting that refusal survived the whole suite. What the
// mutant does is worse than a missing error: with at = -1 the rebuild skips nothing
// and the insert still fires, so the folder GAINS a claim it never held — under the
// act code "folder-order", which a reader takes to mean a reorder of what was already
// there. It is also a way around the cap this file's other test pins, since a full
// folder can be grown one "move" at a time.
//
// The pairing is a real reorder, on the same folder in the same test, because a guard
// that refused every move would satisfy the refusal on its own.
func TestMovingAClaimThatIsNotInTheFolderIsRefused(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fmov-alice")
	testCourt(cur, "fmov", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	first := OpenClaim(cross(cur), "fmov", "the first member")
	testing.SetRealm(testing.NewUserRealm(alice))
	second := OpenClaim(cross(cur), "fmov", "the second member")
	testing.SetRealm(testing.NewUserRealm(alice))
	stranger := OpenClaim(cross(cur), "fmov", "never filed here")
	testing.SetRealm(testing.NewUserRealm(alice))
	fid := CreateFolder(cross(cur), "fmov", "Ordered", "")
	testing.SetRealm(testing.NewUserRealm(alice))
	AddToFolder(cross(cur), "fmov", fid, first)
	testing.SetRealm(testing.NewUserRealm(alice))
	AddToFolder(cross(cur), "fmov", fid, second)

	// Refused, and the list is exactly as it was.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "not in the folder", func() {
		MoveItemInFolder(cross(cur), "fmov", fid, stranger, 0)
	})
	items := FolderItems("fmov", fid)
	if len(items) != 2 || items[0] != first || items[1] != second {
		t.Fatalf("a refused move must leave the list alone, got %v", items)
	}

	// PAIRED: a member does move, so the refusal above is about membership and not
	// about moves.
	testing.SetRealm(testing.NewUserRealm(alice))
	MoveItemInFolder(cross(cur), "fmov", fid, first, 1)
	if got := FolderItems("fmov", fid); len(got) != 2 || got[0] != second || got[1] != first {
		t.Fatalf("a member must move, got %v", got)
	}
}

// THE REVERSE READ, and the three things it must not get wrong.
//
// ClaimFolders exists so a claim page can say where the claim sits without
// walking the court. The forward read is FolderItems; this asserts they agree,
// and then asserts the two cases where agreeing would be wrong.
func TestClaimFoldersAnswersTheReverseOfFolderItems(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cf-alice")
	testCourt(cur, "cf", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "cf", "filed somewhere")
	testing.SetRealm(testing.NewUserRealm(alice))
	other := OpenClaim(cross(cur), "cf", "filed nowhere")

	// Nothing filed yet: an empty answer, not a panic and not a nil surprise.
	uassert.Equal(t, 0, len(ClaimFolders("cf", id)))

	testing.SetRealm(testing.NewUserRealm(alice))
	f1 := CreateFolder(cross(cur), "cf", "First", "")
	testing.SetRealm(testing.NewUserRealm(alice))
	f2 := CreateFolder(cross(cur), "cf", "Second", "")
	testing.SetRealm(testing.NewUserRealm(alice))
	AddToFolder(cross(cur), "cf", f1, id)

	got := ClaimFolders("cf", id)
	if len(got) != 1 || got[0] != f1 {
		t.Fatal("a filed claim must name the folder it is filed in")
	}
	// And the claim nobody filed still says so, on the same court, with folders
	// that exist — the case a "return every folder" bug would pass the first
	// assertion and fail here.
	uassert.Equal(t, 0, len(ClaimFolders("cf", other)))

	// A CLAIM MAY SIT IN TWO FOLDERS, which is the whole reason this returns a
	// list. AddToFolder checks membership within ONE folder, so cross-filing is
	// allowed by design and a reverse read that stopped at the first match would
	// quietly pick one.
	testing.SetRealm(testing.NewUserRealm(alice))
	AddToFolder(cross(cur), "cf", f2, id)
	got = ClaimFolders("cf", id)
	if len(got) != 2 || got[0] != f1 || got[1] != f2 {
		t.Fatal("a cross-filed claim must name both folders, in the tree's order")
	}
}

// A PURGED FOLDER IS NOT AN ANSWER. PurgeFolder blanks the name and the picture
// and deliberately leaves the item list — TestFolderPurgeMofN pins exactly that
// — so the forward read still reports the claim. The reverse read must not,
// because it is used to LINK: naming a purged folder sends a reader to a
// tombstone and republishes the association the purge severed.
func TestClaimFoldersSkipsAPurgedFolder(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cfp-alice")
	g2 := testutils.TestAddress("cfp-g2")
	testCourt(cur, "cfp", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "cfp", "in a folder about to go")
	testing.SetRealm(testing.NewUserRealm(alice))
	keep := CreateFolder(cross(cur), "cfp", "Kept", "")
	testing.SetRealm(testing.NewUserRealm(alice))
	doomed := CreateFolder(cross(cur), "cfp", "Defamatory Name", "")
	testing.SetRealm(testing.NewUserRealm(alice))
	AddToFolder(cross(cur), "cfp", keep, id)
	testing.SetRealm(testing.NewUserRealm(alice))
	AddToFolder(cross(cur), "cfp", doomed, id)
	uassert.Equal(t, 2, len(ClaimFolders("cfp", id)))

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	AddGlobalMod(cross(cur), g2)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 2)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeFolder(cross(cur), "cfp", doomed, "DEFAMATION")
	testing.SetRealm(testing.NewUserRealm(g2))
	PurgeFolder(cross(cur), "cfp", doomed, "DEFAMATION")
	if !FolderPurged("cfp", doomed) {
		t.Fatal("fixture: the folder should be purged by now")
	}

	// The forward read still holds the claim — that is the documented shape.
	if got := FolderItems("cfp", doomed); len(got) != 1 {
		t.Fatal("fixture: purge tombstones text, not the claim-ID list")
	}
	// The reverse read must not offer it.
	got := ClaimFolders("cfp", id)
	if len(got) != 1 || got[0] != keep {
		t.Fatal("a purged folder must not be named as where a claim sits")
	}
}

// A court that has never been moderated has no folder store at all. The other
// folder reads panic or return zero on it; this one answers "nowhere", which is
// the truthful answer and the one a claim page can render without a branch.
func TestClaimFoldersOnAnUnmoderatedCourt(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cfu-alice")
	testCourt(cur, "cfu", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "cfu", "no folders anywhere")
	uassert.Equal(t, 0, len(ClaimFolders("cfu", id)))
}
