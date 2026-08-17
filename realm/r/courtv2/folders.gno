// Folders: moderator-managed curation metadata (MODERATION.md §7). A folder is
// a named, ordered list of claim IDs in one court. Membership gates NOTHING —
// not answerability, not emission, not deposits, not votes ("zero economic
// weight" = zero on-chain coupling). The flat newest-first claim list always
// remains, so folders CURATE and can never BURY: an unfoldered claim is exactly
// as reachable as before folders existed.
//
// Decision rule: folder ops need one ACTIVE moderator (member + not suspended),
// not the m-of-n of consequential acts (hide/purge/suspend). A decoy or
// mis-filing moderator has zero blast radius here — folders are zero-weight and
// instantly reversible — so the m-of-n ceremony would only tax routine curation
// for no security gain (the round-7 R3 rationale is about bounding damage, and
// there is none to bound). Suspension still refuses folder writes.
package courtv2

import "strconv"

const maxFolderTextLen = 200

// folder is one curation list. name/desc are user text: sanitized at render,
// length-capped here, and purgeable as rows (PurgeFolder). items is ordered.
type folder struct {
	id     uint64
	name   string
	desc   string
	items  []uint64 // claim IDs, in curation order
	purged bool     // name/desc tombstoned behind a category code
	code   string
}

func (cm *courtMod) mustFolder(id uint64) *folder {
	v := cm.folders.Get(beClaimKey(id))
	if v == nil {
		panic("courtv2: no such folder")
	}
	return v.(*folder)
}

// requireFolderMod: an active moderator (member, not suspended). Single-signer.
func requireFolderMod(c *Court, who address) *courtMod {
	cm := ensureMod(c)
	requireActiveMod(cm, who)
	return cm
}

// CreateFolder makes a new empty folder and returns its id.
func CreateFolder(cur realm, courtSlug, name, desc string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	if len(name) == 0 || len(name) > maxFolderTextLen || len(desc) > maxFolderTextLen {
		panic("courtv2: a folder name is 1..200 and a description at most 200 characters")
	}
	cm.folderSeq++
	id := cm.folderSeq
	cm.folders.Set(beClaimKey(id), &folder{id: id, name: name, desc: desc})
	emitModAct(c.id, 0, "folder-create", who)
	return id
}

// AddToFolder appends a claim to a folder (idempotent: a claim already present
// is not duplicated). The claim must exist; folder membership couples nothing.
func AddToFolder(cur realm, courtSlug string, folderID, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	_ = mustClaim(c, claimID) // the claim must exist
	f := cm.mustFolder(folderID)
	for _, x := range f.items {
		if x == claimID {
			return
		}
	}
	f.items = append(f.items, claimID)
	emitModAct(c.id, claimID, "folder-add", who)
}

// RemoveFromFolder drops a claim from a folder (order-preserving).
func RemoveFromFolder(cur realm, courtSlug string, folderID, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	f := cm.mustFolder(folderID)
	out := f.items[:0]
	found := false
	for _, x := range f.items {
		if x == claimID {
			found = true
			continue
		}
		out = append(out, x)
	}
	if !found {
		panic("courtv2: that claim is not in the folder")
	}
	f.items = out
	emitModAct(c.id, claimID, "folder-remove", who)
}

// RenameFolder edits a folder's name/description (both user text).
func RenameFolder(cur realm, courtSlug string, folderID uint64, name, desc string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	if len(name) == 0 || len(name) > maxFolderTextLen || len(desc) > maxFolderTextLen {
		panic("courtv2: a folder name is 1..200 and a description at most 200 characters")
	}
	f := cm.mustFolder(folderID)
	if f.purged {
		panic("courtv2: this folder's text was purged and cannot be re-set")
	}
	f.name = name
	f.desc = desc
	emitModAct(c.id, 0, "folder-rename", who)
}

// PurgeFolder tombstones a folder's name/description behind a category code
// (the row-level purge for a §2-inventory folder row). Global DAO, m-of-n. The
// items list (claim IDs, no user text) is unaffected.
func PurgeFolder(cur realm, courtSlug string, folderID uint64, categoryCode string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	d := ensureGlobalDAO()
	if !d.members.Has(who.String()) {
		panic("courtv2: only a global DAO member may purge")
	}
	if len(categoryCode) == 0 || len(categoryCode) > maxReasonLen {
		panic("courtv2: purge needs a statutory category code")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	f := cm.mustFolder(folderID)
	fire, code := approveAction(d.pending, "purgefolder:"+c.id+":"+strconv.FormatUint(folderID, 10), who, categoryCode, d.purgeM)
	if !fire {
		return
	}
	f.purged = true
	f.code = code
	f.name = ""
	f.desc = ""
	emitPurge(c.id, 0, code, who)
}

// ---- reads (render; never a money path) -----------------------------------

// FolderCount is how many folders a court has.
func FolderCount(courtSlug string) int {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return 0
	}
	return c.mod.folders.Size()
}

// FolderName returns a folder's name (or its tombstone code if purged).
func FolderName(courtSlug string, folderID uint64) string {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		panic("courtv2: no such folder")
	}
	f := c.mod.mustFolder(folderID)
	if f.purged {
		return "[purged:" + f.code + "]"
	}
	return f.name
}

// FolderItems returns a copy of a folder's claim-ID list (a value slice — never
// a pointer into realm state, borrow rule #2).
func FolderItems(courtSlug string, folderID uint64) []uint64 {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		panic("courtv2: no such folder")
	}
	f := c.mod.mustFolder(folderID)
	out := make([]uint64, len(f.items))
	copy(out, f.items)
	return out
}

// FolderPurged reports whether a folder's text was tombstoned.
func FolderPurged(courtSlug string, folderID uint64) bool {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return false
	}
	return c.mod.mustFolder(folderID).purged
}
