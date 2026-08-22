package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// A COURT'S FOLDER CAP, found by the first full-corpus pass rather than by a sweep.
//
// The row `folders: a court may hold unlimited folders` was in the corpus and verified
// caught when it was written; 983 rows later it is the ONE row that survived the pass,
// and it survives against HEAD too — so its catching test moved out from under it while
// the folder work grew. That is exactly the failure a full pass exists to find and a
// per-row check at insertion time cannot: a row's verdict is a fact about a moment.
//
// The cap is not decoration. maxFolders bounds a WRITE's cost, and folders.gno says why
// in its own comment: the nesting guards walk ancestors and measure subtree height, so
// an unbounded folder count makes creating one cost more than the last. The overlay
// assumed the bound too (CHAIN_FOLDER_CAP = 100) and stopped reading there, so without
// it a court silently holds folders no reader will ever see.
//
// FILLED DIRECTLY, like the folder ITEM cap next door: the guard reads
// cm.folders.Size() and nothing else, so occupying the size is the whole fixture, and
// creating a hundred folders through the front door would cost a hundred moderator
// transactions to measure one comparison.
func TestACourtStopsAtItsFolderCap(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fcnt-alice")
	testCourt(cur, "fcnt", alice, 10_000_000_000)
	c := mustCourt("fcnt")

	// ONE FOLDER THROUGH THE FRONT DOOR FIRST, because a court carries no moderation
	// state until something needs it — requireFolderMod creates it for the creator on
	// demand, so reaching for c.mod before that is a nil.
	testing.SetRealm(testing.NewUserRealm(alice))
	CreateFolder(cross(cur), "fcnt", "the first", "")
	cm := c.mod
	if cm == nil || cm.folders.Size() != 1 {
		t.Fatalf("setup: the first create must seat the moderation state, mod=%v", cm != nil)
	}

	// One short of the cap. The seq is advanced with the tree so the ids stay unique
	// and the next real CreateFolder does not collide with the fill.
	for i := 0; i < maxFolders-2; i++ {
		cm.folderSeq++
		cm.folders.Set(beClaimKey(cm.folderSeq), &folder{id: cm.folderSeq, name: "fill"})
	}
	if got := cm.folders.Size(); got != maxFolders-1 {
		t.Fatalf("setup: the fill must stop one short of the %d cap, got %d",
			maxFolders, got)
	}

	// The last slot is usable.
	testing.SetRealm(testing.NewUserRealm(alice))
	last := CreateFolder(cross(cur), "fcnt", "the hundredth", "")
	if last == 0 || cm.folders.Size() != maxFolders {
		t.Fatalf("the last folder must be creatable, id=%d size=%d",
			last, cm.folders.Size())
	}

	// And the next is refused, by the cap and with its own message.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "already has", func() {
		CreateFolder(cross(cur), "fcnt", "one too many", "")
	})
	if got := cm.folders.Size(); got != maxFolders {
		t.Fatalf("a refused create must not add a folder, size %d", got)
	}

	// CreateFolderIn shares the cap through the same field, and a nested create is the
	// route a curator actually uses once a court has structure — so it is asserted
	// too, rather than assumed to follow.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "already has", func() {
		CreateFolderIn(cross(cur), "fcnt", last, "nested and one too many", "")
	})
}
