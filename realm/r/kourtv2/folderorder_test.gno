package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// row builds one FolderTree row, so these tests assert against the ids the court
// actually handed out rather than against numbers that happen to be right today.
func row(id, parent uint64, flags string) string {
	if flags == "" {
		flags = "-"
	}
	// ":0" is bornOf — the claim that carried the set into existence, or 0 for
	// one a moderator simply made. Every folder in this file is the second kind,
	// so it is appended here rather than threaded through every caller. The
	// affirmed case is asserted where AffirmSet is, in governedset_test.
	return strconv.FormatUint(id, 10) + ":" + strconv.FormatUint(parent, 10) + ":" + flags + ":0"
}

// orderFixture: a court whose creator moderates it, with n root folders.
func orderFixture(cur realm, t *testing.T, slug string, n int) (address, []uint64) {
	t.Helper()
	alice := testutils.TestAddress(slug + "-a")
	testCourt(cur, slug, alice, 10_000_000_000)
	ids := make([]uint64, 0, n)
	for i := 0; i < n; i++ {
		testing.SetRealm(testing.NewUserRealm(alice))
		ids = append(ids, CreateFolder(cross(cur), slug, "heading "+strconv.Itoa(i), ""))
	}
	return alice, ids
}

// The feature itself: a curator's sequence, not the accident of creation order.
func TestOrderFoldersChangesTheTree(cur realm, t *testing.T) {
	alice, f := orderFixture(cur, t, "ford1", 3)
	// Before: creation order, which is id order.
	uassert.Equal(t, row(f[0], 0, "")+","+row(f[1], 0, "")+","+row(f[2], 0, ""),
		FolderTree("ford1"))

	testing.SetRealm(testing.NewUserRealm(alice))
	OrderFolders(cross(cur), "ford1", 0,
		strconv.FormatUint(f[2], 10)+","+strconv.FormatUint(f[0], 10)+","+
			strconv.FormatUint(f[1], 10))

	uassert.Equal(t, row(f[2], 0, "")+","+row(f[0], 0, "")+","+row(f[1], 0, ""),
		FolderTree("ford1"))
}

// THE ZERO RULE, and it is the reason this field costs nothing to adopt. A
// folder created after an ordering is UNPLACED, and unplaced sorts LAST — where
// a new folder belongs. Under a plain "ord defaults to 0, 0 sorts first" rule it
// would jump to the head of a list the curator had just arranged.
func TestANewFolderLandsLastAfterAnOrdering(cur realm, t *testing.T) {
	alice, f := orderFixture(cur, t, "ford2", 3)
	testing.SetRealm(testing.NewUserRealm(alice))
	OrderFolders(cross(cur), "ford2", 0,
		strconv.FormatUint(f[2], 10)+","+strconv.FormatUint(f[0], 10)+","+
			strconv.FormatUint(f[1], 10))

	testing.SetRealm(testing.NewUserRealm(alice))
	late := CreateFolder(cross(cur), "ford2", "filed later", "")

	uassert.Equal(t, row(f[2], 0, "")+","+row(f[0], 0, "")+","+row(f[1], 0, "")+
		","+row(late, 0, ""), FolderTree("ford2"))
}

// THE MIGRATION CASE. A court nobody has ever ordered must read exactly as it
// read before the field existed: every ord is zero, so every folder is unplaced,
// so the whole list falls back to id order. This is what makes an already
// deployed court need no backfill and no version.
func TestAnUnorderedCourtReadsInIdOrder(cur realm, t *testing.T) {
	_, f := orderFixture(cur, t, "ford3", 4)
	want := row(f[0], 0, "") + "," + row(f[1], 0, "") + "," +
		row(f[2], 0, "") + "," + row(f[3], 0, "")
	uassert.Equal(t, want, FolderTree("ford3"))
}

// A RETIRED SIBLING STILL HOLDS A POSITION. Its row survives and still appears
// in the tree behind its flag, so excluding it from the order would mean a
// restored folder comes back wherever it happened to fall.
func TestOrderIncludesRetiredSiblings(cur realm, t *testing.T) {
	alice, f := orderFixture(cur, t, "ford4", 2)
	testing.SetRealm(testing.NewUserRealm(alice))
	RetireFolder(cross(cur), "ford4", f[1])

	testing.SetRealm(testing.NewUserRealm(alice))
	OrderFolders(cross(cur), "ford4", 0,
		strconv.FormatUint(f[1], 10)+","+strconv.FormatUint(f[0], 10))

	uassert.Equal(t, row(f[1], 0, "r")+","+row(f[0], 0, ""), FolderTree("ford4"))
}

// Ordering under a heading touches that heading's children and nothing else.
func TestOrderFoldersUnderAHeading(cur realm, t *testing.T) {
	alice, f := orderFixture(cur, t, "ford5", 1)
	parent := f[0]
	testing.SetRealm(testing.NewUserRealm(alice))
	c1 := CreateFolderIn(cross(cur), "ford5", parent, "first child", "")
	testing.SetRealm(testing.NewUserRealm(alice))
	c2 := CreateFolderIn(cross(cur), "ford5", parent, "second child", "")

	testing.SetRealm(testing.NewUserRealm(alice))
	OrderFolders(cross(cur), "ford5", parent,
		strconv.FormatUint(c2, 10)+","+strconv.FormatUint(c1, 10))

	// Roots first (parent 0), then this heading's children in the given order.
	uassert.Equal(t, row(parent, 0, "")+","+row(c2, parent, "")+","+row(c1, parent, ""),
		FolderTree("ford5"))
}

// EVERY SIBLING, EXACTLY ONCE. Each of these is a way a partial list would
// silently leave a folder unplaced — which sorts it last, so the damage is a
// reordering the curator did not ask for rather than an error they can see.
func TestOrderFoldersMustListEverySiblingOnce(cur realm, t *testing.T) {
	alice, f := orderFixture(cur, t, "ford6", 3)
	before := FolderTree("ford6")
	s0 := strconv.FormatUint(f[0], 10)
	s1 := strconv.FormatUint(f[1], 10)
	// EVERY BAD LIST BELOW STARTS WITH THE LAST SIBLING, and that is not
	// decoration. A refusal is only observable if the list it refused would have
	// MOVED something: the first draft began each list with f[0], so a
	// write-as-you-parse bug assigned ord 1,2,3 in the order the folders already
	// sat and the tree came out identical. The arm for it went silent, and the
	// test was the thing at fault. Leading with f[2] means any partial write
	// shows up in the very first row.
	s2 := strconv.FormatUint(f[2], 10)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "it must list every one of them", func() {
		OrderFolders(cross(cur), "ford6", 0, s2+","+s1)
	})
	// A list of the right LENGTH that repeats one and drops another: the count
	// check cannot see this, which is why the repeat is named separately.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "is listed twice", func() {
		OrderFolders(cross(cur), "ford6", 0, s2+","+s2+","+s0)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "is not under that heading", func() {
		OrderFolders(cross(cur), "ford6", 0, s2+","+s0+",4242")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "comma-separated list of folder ids", func() {
		OrderFolders(cross(cur), "ford6", 0, s2+",nope,"+s0)
	})
	// EVERY refusal is total. A write that got halfway through the list would
	// leave half a court reordered, which is worse than the call failing.
	uassert.Equal(t, before, FolderTree("ford6"))
}

// The cheap refusals: a heading with nothing under it, and an argument long
// enough that parsing it is itself the attack.
func TestOrderFoldersBoundsItsArgument(cur realm, t *testing.T) {
	alice, f := orderFixture(cur, t, "ford7", 1)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "no folders under that heading", func() {
		OrderFolders(cross(cur), "ford7", f[0], "1")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "too long to be a list", func() {
		OrderFolders(cross(cur), "ford7", 0, strings.Repeat("1,", maxFolders*11))
	})
}

// Moderator-gated, like every other act on the filing system.
func TestOrderFoldersAuthority(cur realm, t *testing.T) {
	_, f := orderFixture(cur, t, "ford8", 2)
	bob := testutils.TestAddress("ford8-bob")
	before := FolderTree("ford8")

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "not a moderator", func() {
		OrderFolders(cross(cur), "ford8", 0,
			strconv.FormatUint(f[1], 10)+","+strconv.FormatUint(f[0], 10))
	})
	uassert.Equal(t, before, FolderTree("ford8"))
}
