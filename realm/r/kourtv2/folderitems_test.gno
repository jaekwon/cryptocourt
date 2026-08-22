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
