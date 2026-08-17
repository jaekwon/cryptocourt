package kourtv2

import (
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
