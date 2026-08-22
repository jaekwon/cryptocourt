package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// THE DEPTH CAP AT ITS OWN BOUNDARY. TestFolderNesting pins the refusals — a cycle,
// a self-parent, a subtree too tall for its new parent — and pairs them with a move
// that must still work. But that pairing sits at depth 2 against a cap of 4, two
// levels clear of the edge, so the cap's arithmetic was free either side of it.
//
// An operator sweep of the nesting code measured the cost: five mutations, two caught
// by TestFolderNesting (a leaf reporting zero height, the cap admitting one level
// more) and TWO SURVIVING, both at the boundary that test never reaches:
//
//	`folderDepth(parent)+height > maxFolderDepth` narrowed to `>=`, which refuses a
//	nesting that lands exactly ON the cap — so a court can nest only 3 deep while
//	the panic message keeps promising 4.
//
//	folderDepth's `d := 0` started at 1, so every folder reports one level deeper
//	than it is. Same visible effect, opposite cause, and neither is an error
//	anybody would see except as folders that will not nest as deep as documented.
//
// ONE TEST CLOSES BOTH, because both make an exactly-at-cap nesting fail: this
// asserts the cap is REACHABLE and not merely that overshooting it is refused. That
// is the standing rule — pair every "must be refused" with the ordinary input it must
// NOT refuse — applied where it bites, which is the last legal value rather than a
// comfortable one.
//
// BOTH PATHS INTO mustNestable, since the two callers reach it with different
// heights: CreateFolderIn always nests a 1-high leaf, while MoveFolder carries a
// whole subtree, and the `+height` term is only exercised by the second. A cap that
// is right for creations and off by one for moves would otherwise pass.
func TestFoldersNestExactlyToTheirCapAndNoFurther(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fdep-alice")
	testCourt(cur, "fdep", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	AppointMods(cross(cur), "fdep", 1, alice)

	// THE CAP IS 4, and this is the assertion that makes the fixture honest: if the
	// constant ever moves, the chain below stops being "exactly at the cap" and this
	// test would go on passing while measuring the wrong depth.
	if maxFolderDepth != 4 {
		t.Fatalf("this fixture builds a chain by hand and assumes a cap of 4, got %d",
			maxFolderDepth)
	}

	// A chain of EXACTLY maxFolderDepth levels, one creation per level. Every one of
	// these must be accepted; the last is the one that lands on the cap.
	testing.SetRealm(testing.NewUserRealm(alice))
	d1 := CreateFolder(cross(cur), "fdep", "Level one", "root")
	ids := []uint64{d1}
	for i := 2; i <= maxFolderDepth; i++ {
		testing.SetRealm(testing.NewUserRealm(alice))
		ids = append(ids, CreateFolderIn(cross(cur), "fdep", ids[len(ids)-1],
			"Level "+itoa(int64(i)), ""))
	}
	for i, id := range ids {
		want := uint64(0)
		if i > 0 {
			want = ids[i-1]
		}
		uassert.Equal(t, want, FolderParent("fdep", id))
	}

	// ...and one level further is refused. Without this the test would pass on a cap
	// that had been removed altogether.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "kourtv2: folders nest at most", func() {
		CreateFolderIn(cross(cur), "fdep", ids[len(ids)-1], "Level five", "")
	})

	// THE MOVE PATH, at the same boundary and with a real subtree. A 2-high section
	// under a 2-deep parent makes exactly 4, which must be allowed; the same section
	// under a 3-deep parent makes 5, which must not.
	testing.SetRealm(testing.NewUserRealm(alice))
	tall := CreateFolder(cross(cur), "fdep", "Tall", "a 2-high subtree")
	testing.SetRealm(testing.NewUserRealm(alice))
	CreateFolderIn(cross(cur), "fdep", tall, "Its child", "")

	// ids[1] is two deep, ids[2] three deep.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "kourtv2: folders nest at most", func() {
		MoveFolder(cross(cur), "fdep", tall, ids[2])
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	MoveFolder(cross(cur), "fdep", tall, ids[1])
	uassert.Equal(t, ids[1], FolderParent("fdep", tall))
}
