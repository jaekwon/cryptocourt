package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

func TestFolderCurationZeroCoupling(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fld-alice")
	c := testCourt(cur, "fld", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id1 := OpenClaim(cross(cur), "fld", "claim one")
	testing.SetRealm(testing.NewUserRealm(alice))
	id2 := OpenClaim(cross(cur), "fld", "claim two")

	// A non-moderator cannot curate.
	bob := testutils.TestAddress("fld-bob")
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "not a moderator", func() {
		CreateFolder(cross(cur), "fld", "Bob's folder", "")
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	f := CreateFolder(cross(cur), "fld", "Highlights", "the good ones")
	if FolderCount("fld") != 1 || FolderName("fld", f) != "Highlights" {
		t.Fatal("folder should exist with its name")
	}
	// Add is idempotent and order-preserving.
	testing.SetRealm(testing.NewUserRealm(alice))
	AddToFolder(cross(cur), "fld", f, id1)
	testing.SetRealm(testing.NewUserRealm(alice))
	AddToFolder(cross(cur), "fld", f, id2)
	testing.SetRealm(testing.NewUserRealm(alice))
	AddToFolder(cross(cur), "fld", f, id1) // dup: ignored
	items := FolderItems("fld", f)
	if len(items) != 2 || items[0] != id1 || items[1] != id2 {
		t.Fatalf("folder items = %v", items)
	}
	// Zero coupling: foldering a claim changes nothing about it.
	escrow := c.coin.BalanceOf(c.escrow)
	if ClaimAuthor("fld", id1) != alice || escrow == 0 {
		t.Fatal("foldering must not touch the claim or its money")
	}

	// Remove.
	testing.SetRealm(testing.NewUserRealm(alice))
	RemoveFromFolder(cross(cur), "fld", f, id1)
	if got := FolderItems("fld", f); len(got) != 1 || got[0] != id2 {
		t.Fatalf("after remove, items = %v", got)
	}

	// Rename.
	testing.SetRealm(testing.NewUserRealm(alice))
	RenameFolder(cross(cur), "fld", f, "Renamed", "new desc")
	if FolderName("fld", f) != "Renamed" {
		t.Fatal("rename should change the name")
	}
}

func TestFolderSuspensionRefuses(cur realm, t *testing.T) {
	alice := testutils.TestAddress("flds-alice")
	testCourt(cur, "flds", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	f := CreateFolder(cross(cur), "flds", "before suspension", "")

	c := mustCourt("flds")
	suspendSet(c, alice)
	// A suspended set cannot create or add to folders.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "suspended", func() {
		CreateFolder(cross(cur), "flds", "nope", "")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "flds", "x")
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "suspended", func() {
		AddToFolder(cross(cur), "flds", f, id)
	})
}

func TestFolderPurgeMofN(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fldp-alice")
	g2 := testutils.TestAddress("fldp-g2")
	testCourt(cur, "fldp", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "fldp", "in a folder")
	testing.SetRealm(testing.NewUserRealm(alice))
	f := CreateFolder(cross(cur), "fldp", "Defamatory Name", "and desc")
	testing.SetRealm(testing.NewUserRealm(alice))
	AddToFolder(cross(cur), "fldp", f, id)

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	AddGlobalMod(cross(cur), g2)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 2)

	// One approval: not purged.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeFolder(cross(cur), "fldp", f, "DEFAMATION")
	if FolderPurged("fldp", f) {
		t.Fatal("one of two approvals must not purge a folder")
	}
	// Second global member fires it.
	testing.SetRealm(testing.NewUserRealm(g2))
	PurgeFolder(cross(cur), "fldp", f, "DEFAMATION")
	if !FolderPurged("fldp", f) {
		t.Fatal("two approvals should purge the folder text")
	}
	// The name is tombstoned but the items (claim IDs, no text) survive.
	if got := FolderItems("fldp", f); len(got) != 1 || got[0] != id {
		t.Fatal("purge tombstones text, not the claim-ID list")
	}
}

// The three folder reads must agree about a folder that does not exist,
// whatever moderation state the court happens to hold. FolderPurged used to
// return false on a court with no mod object while its two siblings panicked —
// so the same bad id answered differently depending on whether the court had
// ever been moderated, and a caller would only meet the discrepancy on the
// second kind of court. Same rule as IsCourtMod: a lazily-created read's
// not-yet-materialised branch must answer what the materialised one would.
func TestFolderReadsAgreeOnAMissingFolder(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fld-agree")

	// A court with NO moderation state at all.
	testCourt(cur, "fldag1", alice, 10_000_000_000)
	if FolderCount("fldag1") != 0 {
		t.Fatal("a fresh court has no folders")
	}
	for _, probe := range []struct {
		name string
		fn   func()
	}{
		{"FolderName", func() { FolderName("fldag1", 999) }},
		{"FolderItems", func() { FolderItems("fldag1", 999) }},
		{"FolderPurged", func() { FolderPurged("fldag1", 999) }},
	} {
		// PanicsContains, not AbortsContains: these are plain reads, not
		// crossing calls, so they panic rather than abort a cross-realm frame.
		uassert.PanicsContains(t, cur, "no such folder", probe.fn)
	}

	// And a court that HAS moderation state answers the same way.
	testCourt(cur, "fldag2", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	CreateFolder(cross(cur), "fldag2", "a real folder", "")
	if FolderCount("fldag2") != 1 {
		t.Fatal("fixture: the folder should exist")
	}
	uassert.PanicsContains(t, cur, "no such folder", func() {
		FolderPurged("fldag2", 999)
	})
}

// folders.gno's six distinct rules, every one of which survived the mutation batch:
// the two text-length bounds, the not-in-the-folder guard, the purged-text latch, and
// the purge's authority and category-code requirements. The file had folder tests
// already — they simply pinned none of these.
//
// Each refusal is PAIRED WITH A SUCCESS. Curation is m-of-n and needs an active
// moderator, so without the paired call every refusal below would pass just as well
// if the caller simply lacked authority, which is a different guard entirely.
func TestFolderRulesAreEnforced(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fru-alice")
	stranger := testutils.TestAddress("fru-stranger")
	testCourt(cur, "fru", alice, 10_000_000_000)
	long := strings.Repeat("x", maxFolderTextLen+1)

	// CreateFolder's text bounds. alice is the creator, hence the sole 1-of-1 mod.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "a folder name is 1..200", func() {
		CreateFolder(cross(cur), "fru", "", "empty name")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "a folder name is 1..200", func() {
		CreateFolder(cross(cur), "fru", long, "over-long name")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "a folder name is 1..200", func() {
		CreateFolder(cross(cur), "fru", "fine", long)
	})
	// THE CONTROL: a valid folder is created, so the three refusals are the bound
	// and not a missing authority.
	testing.SetRealm(testing.NewUserRealm(alice))
	fid := CreateFolder(cross(cur), "fru", "Evidence", "the good stuff")
	if FolderCount("fru") != 1 || FolderName("fru", fid) != "Evidence" {
		t.Fatal("a valid folder must be created")
	}

	// RenameFolder's bounds, same shape.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "a folder name is 1..200", func() {
		RenameFolder(cross(cur), "fru", fid, "", "empty")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "a folder name is 1..200", func() {
		RenameFolder(cross(cur), "fru", fid, "fine", long)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	RenameFolder(cross(cur), "fru", fid, "Exhibits", "renamed")
	if FolderName("fru", fid) != "Exhibits" {
		t.Fatal("a valid rename must land")
	}

	// RemoveFromFolder refuses a claim the folder does not hold. Removing something
	// absent is not a harmless no-op: it is how a curator learns their view of the
	// folder is stale.
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "fru", "a claim to file")
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "not in the folder", func() {
		RemoveFromFolder(cross(cur), "fru", fid, id)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	AddToFolder(cross(cur), "fru", fid, id)
	testing.SetRealm(testing.NewUserRealm(alice))
	RemoveFromFolder(cross(cur), "fru", fid, id) // the control: present, so removable
	if len(FolderItems("fru", fid)) != 0 {
		t.Fatal("a present claim must be removable")
	}

	// The purge's authority and its category code. Curation is a moderator power;
	// PURGING is the global DAO's, because it is the one that cannot be undone.
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "only a global DAO member may purge", func() {
		PurgeFolder(cross(cur), "fru", fid, "DOXX-1")
	})
	dadmin := DirectoryAdmin()
	// ESTABLISH the threshold rather than assume it. PurgeFolder is m-of-n on the
	// global DAO's purgeM, which is package-global and outlives every test that
	// moves it — so a lone approval BANKS instead of firing if a neighbour left it
	// above one, and this fixture passed alone and failed in company until it said
	// so out loud.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "purge needs a statutory category code", func() {
		PurgeFolder(cross(cur), "fru", fid, "")
	})
	// THE CONTROL: the DAO member purges with a code, so both refusals above are
	// their own rule rather than a folder that could not be purged at all.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeFolder(cross(cur), "fru", fid, "DOXX-1")
	if !FolderPurged("fru", fid) {
		t.Fatal("a coded purge by a DAO member must land")
	}

	// And the purged text is a LATCH: a rename cannot walk it back, or purge would
	// be a suggestion rather than the legal-compliance power it is.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "was purged and cannot be re-set", func() {
		RenameFolder(cross(cur), "fru", fid, "Back Again", "undo the purge")
	})
}

// NESTING (COURTS_STRUCTURE.md §6 sections). The guards are the whole feature:
// a tree that can cycle is not a tree, and a depth cap nobody enforces is a
// comment.
func TestFolderNesting(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fn-alice")
	testCourt(cur, "fnest", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	AppointMods(cross(cur), "fnest", 1, alice)

	testing.SetRealm(testing.NewUserRealm(alice))
	root := CreateFolder(cross(cur), "fnest", "Origins", "top")
	testing.SetRealm(testing.NewUserRealm(alice))
	mid := CreateFolderIn(cross(cur), "fnest", root, "Laboratory", "second level")
	testing.SetRealm(testing.NewUserRealm(alice))
	leaf := CreateFolderIn(cross(cur), "fnest", mid, "Sequence features", "third")

	uassert.Equal(t, uint64(0), FolderParent("fnest", root))
	uassert.Equal(t, root, FolderParent("fnest", mid))
	uassert.Equal(t, mid, FolderParent("fnest", leaf))

	// A CYCLE, refused. Putting the root inside its own grandchild.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "inside itself", func() {
		MoveFolder(cross(cur), "fnest", root, leaf)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "cannot contain itself", func() {
		MoveFolder(cross(cur), "fnest", mid, mid)
	})

	// THE DEPTH CAP COUNTS THE SUBTREE, not just the new parent. `root` is a
	// 3-high subtree; hanging it under a 2-deep folder would make 5. Checking
	// only the parent's depth would have allowed this, which is the bug the
	// height walk exists for.
	testing.SetRealm(testing.NewUserRealm(alice))
	other := CreateFolder(cross(cur), "fnest", "Elsewhere", "another root")
	testing.SetRealm(testing.NewUserRealm(alice))
	deep := CreateFolderIn(cross(cur), "fnest", other, "One down", "")
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "nest at most", func() {
		MoveFolder(cross(cur), "fnest", root, deep)
	})

	// A LEAF still moves, and 0 returns a folder to the root.
	testing.SetRealm(testing.NewUserRealm(alice))
	MoveFolder(cross(cur), "fnest", leaf, other)
	uassert.Equal(t, other, FolderParent("fnest", leaf))
	testing.SetRealm(testing.NewUserRealm(alice))
	MoveFolder(cross(cur), "fnest", leaf, 0)
	uassert.Equal(t, uint64(0), FolderParent("fnest", leaf))
}

// A COURT WITHOUT MODERATION STATE answers 0 rather than allocating one — the
// read-purity rule, pinned where it is easy to break by reaching for ensureMod.
func TestFolderParentOnUnmoderatedCourt(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fp-alice")
	testCourt(cur, "fpar", alice, 10_000_000_000)
	uassert.Equal(t, uint64(0), FolderParent("fpar", 1))
}

// THE DESCRIPTION READ. The field has been stored and capped since folders
// existed; it just had no way out. The gate is the only thing worth pinning: a
// purged folder's description goes, and its NAME keeps the tombstone that says
// why — one explanation per row, not two.
func TestFolderDescReadAndPurgeGate(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fd-alice")
	testCourt(cur, "fdsc", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	AppointMods(cross(cur), "fdsc", 1, alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := CreateFolder(cross(cur), "fdsc", "Document trail", "Claims resting on released records.")

	uassert.True(t, strings.Contains(FolderDesc("fdsc", id), "released records"))

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeFolder(cross(cur), "fdsc", id, "CSAM")

	// ERASED, not hidden. This assertion is the one that survives arming: the
	// read has no purge branch to break, because PurgeFolder zeroes the text
	// itself. The name still carries the tombstone, which is what tells a reader
	// the row exists and why it is blank.
	uassert.Equal(t, "", FolderDesc("fdsc", id))
	uassert.True(t, strings.Contains(FolderName("fdsc", id), "purged"))
	uassert.True(t, strings.Contains(FolderName("fdsc", id), "CSAM"))
}

// RETIREMENT, which is this realm's "delete" and deliberately is not one. The
// overlay walks ids 1..FolderCount, so the row has to survive or every folder
// above the deleted one renumbers under a client that is already reading them.
func TestRetireFolderKeepsTheRowAndTheNumbering(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fr-alice")
	testCourt(cur, "fret", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	AppointMods(cross(cur), "fret", 1, alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	a := CreateFolder(cross(cur), "fret", "First", "")
	testing.SetRealm(testing.NewUserRealm(alice))
	b := CreateFolder(cross(cur), "fret", "Second", "")
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "fret", "a claim to file")
	testing.SetRealm(testing.NewUserRealm(alice))
	AddToFolder(cross(cur), "fret", a, id)

	before := FolderCount("fret")
	testing.SetRealm(testing.NewUserRealm(alice))
	RetireFolder(cross(cur), "fret", a)

	uassert.True(t, FolderRetired("fret", a))
	uassert.Equal(t, before, FolderCount("fret")) // the row survives
	uassert.Equal(t, "Second", FolderName("fret", b))
	uassert.Equal(t, 0, len(FolderItems("fret", a))) // the claim is un-filed
	// and the claim itself is untouched — folders curate, they never bury
	uassert.True(t, strings.Contains(ClaimTitle("fret", id), "a claim to file"))

	testing.SetRealm(testing.NewUserRealm(alice))
	RestoreFolder(cross(cur), "fret", a)
	uassert.False(t, FolderRetired("fret", a))
}

// A PARENT CANNOT BE RETIRED OUT FROM UNDER ITS CHILDREN, or the tree grows
// orphans that no walk from the roots can reach.
func TestRetireFolderRefusesAParent(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fro-alice")
	testCourt(cur, "frorp", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	AppointMods(cross(cur), "frorp", 1, alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	top := CreateFolder(cross(cur), "frorp", "Top", "")
	testing.SetRealm(testing.NewUserRealm(alice))
	CreateFolderIn(cross(cur), "frorp", top, "Inside", "")

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "retire the folders inside it first", func() {
		RetireFolder(cross(cur), "frorp", top)
	})
}

// ORDER. "Claim IDs, in curation order" was whatever order they were added in;
// curation you cannot re-order is a log.
func TestMoveItemInFolder(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fo-alice")
	testCourt(cur, "ford", alice, 100_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	AppointMods(cross(cur), "ford", 1, alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	f := CreateFolder(cross(cur), "ford", "Ordered", "")
	ids := []uint64{}
	for i := 0; i < 3; i++ {
		testing.SetRealm(testing.NewUserRealm(alice))
		id := OpenClaim(cross(cur), "ford", "claim "+strings.Repeat("y", i+1))
		ids = append(ids, id)
		testing.SetRealm(testing.NewUserRealm(alice))
		AddToFolder(cross(cur), "ford", f, id)
	}
	// last to first
	testing.SetRealm(testing.NewUserRealm(alice))
	MoveItemInFolder(cross(cur), "ford", f, ids[2], 0)
	got := FolderItems("ford", f)
	uassert.Equal(t, ids[2], got[0])
	uassert.Equal(t, ids[0], got[1])
	uassert.Equal(t, ids[1], got[2])
	uassert.Equal(t, 3, len(got)) // nothing lost, nothing duplicated

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "outside the folder", func() {
		MoveItemInFolder(cross(cur), "ford", f, ids[0], 9)
	})
}

// THE SHAPE READ. One round trip for what would otherwise be three per folder —
// 300 at the cap — so the thing worth pinning is that it reports the structure
// FAITHFULLY, including the two states a client must not mistake for a normal
// folder.
func TestFolderTree(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ft-alice")
	testCourt(cur, "ftree", alice, 50_000_000_000)
	uassert.Equal(t, "", FolderTree("ftree")) // no moderation state yet

	testing.SetRealm(testing.NewUserRealm(alice))
	AppointMods(cross(cur), "ftree", 1, alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	top := CreateFolder(cross(cur), "ftree", "Top", "")
	testing.SetRealm(testing.NewUserRealm(alice))
	kid := CreateFolderIn(cross(cur), "ftree", top, "Inside", "")
	testing.SetRealm(testing.NewUserRealm(alice))
	gone := CreateFolder(cross(cur), "ftree", "Mistake", "")

	// parents are reported, so a client can build the tree without asking again
	uassert.Equal(t, "1:0:-:0,2:1:-:0,3:0:-:0", FolderTree("ftree"))

	testing.SetRealm(testing.NewUserRealm(alice))
	RetireFolder(cross(cur), "ftree", gone)
	uassert.Equal(t, "1:0:-:0,2:1:-:0,3:0:r:0", FolderTree("ftree"))

	// A PURGED ROW IS FLAGGED, so a client knows to expect a tombstone from
	// FolderName rather than a name — the shape is not secret, the text is.
	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeFolder(cross(cur), "ftree", kid, "CSAM")
	uassert.Equal(t, "1:0:-:0,2:1:p:0,3:0:r:0", FolderTree("ftree"))
}


// A FOLDER CARRIES ONE IMAGE (owner ruling, CLAIM_MEDIA §10). A folder is a
// heading, not a claim: it argues nothing, so it has nothing to prove and no
// numbered exhibits to keep in order. What it has is a face on the map.
func TestAFolderCarriesOneImage(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fimg-alice")
	testCourt(cur, "fimg", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	f := CreateFolder(cross(cur), "fimg", "Municipal record", "filings and audits")

	if got := FolderImage("fimg", f); got != "[]" {
		t.Fatalf("a new folder already has a picture: %q", got)
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	SetFolderImage(cross(cur), "fimg", f, clientImageLine)
	got := FolderImage("fimg", f)
	if !strings.Contains(got, strings.Repeat("1", 64)) {
		t.Fatalf("the folder's image did not come back: %q", got)
	}
	// ONE LINE, like every other media read: the overlay's parseTyped splits raw
	// output on newlines before it matches a typed value.
	if strings.Contains(got, "\n") {
		t.Fatalf("FolderImage must answer on one line: %q", got)
	}

	// THE FLAG IS HOW A CLIENT KNOWS TO SPEND THE READ. A map draw asks for the
	// tree once and would otherwise have to ask FolderImage per folder — a
	// hundred reads at the cap for a field most folders never set.
	if tree := FolderTree("fimg"); !strings.Contains(tree, ":0:i") {
		t.Fatalf("FolderTree does not mark the folder as having a picture: %q", tree)
	}

	// Exactly one. Two is a caller who has misunderstood something, and taking
	// the first silently would hide that.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "exactly one image", func() {
		SetFolderImage(cross(cur), "fimg", f, clientImageLine+"\n"+clientImageLine)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "exactly one image", func() {
		SetFolderImage(cross(cur), "fimg", f, "")
	})
	// And an image. A video is a link the court cannot vouch for, which is a fair
	// thing to file as evidence — where the claim page says so — and not a fair
	// thing to make the face of a heading.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "not a video link", func() {
		SetFolderImage(cross(cur), "fimg", f, clientVideoLine)
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	ClearFolderImage(cross(cur), "fimg", f)
	if got := FolderImage("fimg", f); got != "[]" {
		t.Fatalf("the picture survived being cleared: %q", got)
	}
	if tree := FolderTree("fimg"); strings.Contains(tree, "i") {
		t.Fatalf("FolderTree still marks a picture that was cleared: %q", tree)
	}
}

// A PURGE TAKES THE PICTURE TOO. A folder's image is its text as much as its name
// is: somebody chose it to stand for a heading, and a purge that left it would
// leave the part most likely to have been objected to.
func TestPurgingAFolderTakesItsImage(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fpim-alice")
	testCourt(cur, "fpim", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	f := CreateFolder(cross(cur), "fpim", "A heading", "with a face")
	testing.SetRealm(testing.NewUserRealm(alice))
	SetFolderImage(cross(cur), "fpim", f, clientImageLine)

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeFolder(cross(cur), "fpim", f, "DEFAMATION")

	if !FolderPurged("fpim", f) {
		t.Fatal("the folder was not purged")
	}
	if got := FolderImage("fpim", f); got != "[]" {
		t.Fatalf("a purged folder still shows its picture: %q", got)
	}
	// And it cannot be given a new one, for the same reason its name cannot.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "purged", func() {
		SetFolderImage(cross(cur), "fpim", f, clientImageLine)
	})
}

/* THE PROPOSAL HALF OF `mod:newset`, tested here rather than in meta_test
   because none of it needs the meta court: registering is an ordinary call any
   holder may make, and what it must NOT do is create anything.

   The execution half — a carried verdict turning a proposal into a folder —
   lives in meta_test's single sequential scenario, for the reason stated there:
   the meta court is a singleton and gno resets the block height between test
   functions, so every test that drives its lifecycle has to share one. */
func TestFolderProposalCreatesNothing(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fp-alice")
	testCourt(cur, "fp", alice, 10_000_000_000)

	// ANY HOLDER MAY PROPOSE. This is the whole point of the verb: the filing
	// system stops being the moderators' alone. bob is not a moderator.
	bob := testutils.TestAddress("fp-bob")
	testing.SetRealm(testing.NewUserRealm(bob))
	pid := RegisterFolderProposal(cross(cur), "fp", "Origins", "where it began", 0)
	if pid == 0 {
		t.Fatal("a proposal should get an id")
	}
	// ...AND IT CREATES NOTHING. A proposal that quietly made a folder would
	// hand every holder the moderator power the appeal exists to gate.
	if FolderCount("fp") != 0 {
		t.Fatal("registering a proposal must not create a folder")
	}

	// The rules are checked HERE, where the caller can be told, rather than
	// weeks later inside an execution nobody is watching.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "1..200", func() {
		RegisterFolderProposal(cross(cur), "fp", "", "empty name", 0)
	})
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "no such folder", func() {
		RegisterFolderProposal(cross(cur), "fp", "Nested", "", 99)
	})

	// A name already taken by an ordinary moderator folder is refused at
	// registration too — the cheap place to find out.
	testing.SetRealm(testing.NewUserRealm(alice))
	CreateFolder(cross(cur), "fp", "Taken", "")
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "already has a folder by that name", func() {
		RegisterFolderProposal(cross(cur), "fp", "Taken", "", 0)
	})

	// A RETIRED name is free again: the row survives so ids stay contiguous,
	// but the heading is gone from the tree and the word is available.
	testing.SetRealm(testing.NewUserRealm(alice))
	RetireFolder(cross(cur), "fp", 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	if RegisterFolderProposal(cross(cur), "fp", "Taken", "", 0) == 0 {
		t.Fatal("a retired folder's name should be proposable again")
	}
}
