package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// A PURGED FOLDER STAYS STRUCK, and nothing held that until now.
//
// RestoreFolder refuses a purged folder — the guard is three lines and has been
// there since retire/restore shipped — but no test named it, so deleting it
// survived the whole suite. What it prevents is not hypothetical: purge is the
// LEGAL removal. It erases the folder's name and description behind a statutory
// category code and takes a global-DAO threshold to fire. Restore is a court
// moderator acting alone. Without the refusal, one moderator could put a folder
// the global DAO had purged back among the court's headings — a single signer
// undoing an m-of-n act, which is the one direction this realm's authority
// levels must never run.
//
// The row survives either way (ids stay contiguous for the overlay's walk), so
// what is asserted is that it stays RETIRED and that the refusal names itself.
func TestAPurgedFolderCannotBeRestored(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fpr-a")
	testCourt(cur, "fpr", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	f := CreateFolder(cross(cur), "fpr", "Struck", "to be purged")
	testing.SetRealm(testing.NewUserRealm(alice))
	RetireFolder(cross(cur), "fpr", f)
	uassert.True(t, FolderRetired("fpr", f))

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeFolder(cross(cur), "fpr", f, "CSAM")

	// The moderator who retired it cannot bring it back.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "a purged folder cannot be restored", func() {
		RestoreFolder(cross(cur), "fpr", f)
	})
	// And it is still struck afterwards — a refusal that left the folder
	// restored would satisfy the abort assertion above and still be the bug.
	uassert.True(t, FolderRetired("fpr", f))
}

// The ordinary case, so the refusal above is not satisfied by a version that
// refuses everything. An unpurged folder restores.
func TestAnUnpurgedFolderStillRestores(cur realm, t *testing.T) {
	alice := testutils.TestAddress("fpr2-a")
	testCourt(cur, "fpr2", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	f := CreateFolder(cross(cur), "fpr2", "Back soon", "")
	testing.SetRealm(testing.NewUserRealm(alice))
	RetireFolder(cross(cur), "fpr2", f)
	testing.SetRealm(testing.NewUserRealm(alice))
	RestoreFolder(cross(cur), "fpr2", f)
	uassert.False(t, FolderRetired("fpr2", f))
}
