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
package kourtv2

import "strconv"

const maxFolderTextLen = 200

// NESTING (COURTS_STRUCTURE.md §6). "A section is a heading with a slug, holding
// claims and other sections" — which is what a folder becomes once it can hold
// another folder, so this is §6's V1 sections, moderator-written rather than
// founder-written. What §6 DEFERS is *governed* sections (the heading is itself a
// claim, affirmed by vote, its slug bound on affirmation); plain nested headings
// are not deferred and this is them.
//
// It also completes §5's containment story rather than contradicting it. §5's
// guard is "only sections may be containment parents": a claim's container is a
// FOLDER (AddToFolder, already here), a folder's container is another folder
// (this change), and claim→claim containment stays forbidden — which is why
// argument.gno implements the argument edge and not that one.
const (
	// Four, matching the depth the overlay's own curation schema has validated
	// since before the chain could nest at all.
	maxFolderDepth = 4
	// A CAP THE OVERLAY ALREADY ASSUMED AND THE CHAIN DID NOT ENFORCE. web's
	// CHAIN_FOLDER_CAP is 100 and it stops reading there; the realm had no limit,
	// so a court could hold folders the overlay would silently truncate. It is
	// also what makes the nesting guards affordable: the cycle walk and the
	// subtree-height check below are scans, and an unbounded folder count would
	// make a WRITE cost grow with what was already written.
	maxFolders = 100
)

// folder is one curation list. name/desc are user text: sanitized at render,
// length-capped here, and purgeable as rows (PurgeFolder). items is ordered.
type folder struct {
	id     uint64
	name   string
	desc   string
	items  []uint64 // claim IDs, in curation order
	purged bool     // name/desc tombstoned behind a category code
	code   string
	// parent folder, 0 = a root heading. Zero on pre-nesting folders, which read
	// as roots — the same "zero on pre-upgrade" shape claimState.openedAtTime
	// already uses, so there is no migration step and no version field.
	parent uint64
}

// folderDepth counts headings above this one. A root is 1. Bounded by maxFolders
// rather than by maxFolderDepth so that state which somehow holds a cycle
// terminates here instead of hanging the transaction that found it.
func (cm *courtMod) folderDepth(id uint64) int {
	d := 0
	for id != 0 && d <= maxFolders {
		d++
		v := cm.folders.Get(beClaimKey(id))
		if v == nil {
			break
		}
		id = v.(*folder).parent
	}
	return d
}

// folderHeight is how deep the subtree UNDER id goes (a leaf is 1). Needed
// because re-parenting moves a whole subtree: dropping a 2-high section under a
// 3-deep parent would make 5, and checking only the parent's depth would miss it.
func (cm *courtMod) folderHeight(id uint64) int {
	h := 1
	cm.folders.Iterate("", "", func(_ string, v any) bool {
		f, ok := v.(*folder)
		if !ok || f.parent != id {
			return false
		}
		if ch := 1 + cm.folderHeight(f.id); ch > h {
			h = ch
		}
		return false
	})
	return h
}

// mustNestable checks a proposed parent for a folder: it exists, it is not the
// folder itself, it is not inside the folder (a cycle), and the result fits the
// depth cap.
func (cm *courtMod) mustNestable(id, parent uint64, height int) {
	if parent == 0 {
		return
	}
	if parent == id {
		panic("kourtv2: a folder cannot contain itself")
	}
	cm.mustFolder(parent)
	for up, n := parent, 0; up != 0 && n <= maxFolders; n++ {
		if up == id {
			panic("kourtv2: that would put a folder inside itself")
		}
		v := cm.folders.Get(beClaimKey(up))
		if v == nil {
			break
		}
		up = v.(*folder).parent
	}
	if cm.folderDepth(parent)+height > maxFolderDepth {
		panic("kourtv2: folders nest at most " + strconv.Itoa(maxFolderDepth) + " deep")
	}
}

func (cm *courtMod) mustFolder(id uint64) *folder {
	v := cm.folders.Get(beClaimKey(id))
	if v == nil {
		panic("kourtv2: no such folder")
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
	if cm.folders.Size() >= maxFolders {
		panic("kourtv2: this court already has " + strconv.Itoa(maxFolders) + " folders")
	}
	if len(name) == 0 || len(name) > maxFolderTextLen || len(desc) > maxFolderTextLen {
		panic("kourtv2: a folder name is 1..200 and a description at most 200 characters")
	}
	cm.folderSeq++
	id := cm.folderSeq
	cm.folders.Set(beClaimKey(id), &folder{id: id, name: name, desc: desc})
	emitModAct(c.id, 0, "folder-create", who)
	return id
}

// CreateFolderIn makes a folder INSIDE another one. Additive rather than a wider
// CreateFolder: that entrypoint is called by every committed scenario and txtar
// in the tree, and a fourth argument would rewrite all of them for a value most
// callers want to be 0 anyway.
func CreateFolderIn(cur realm, courtSlug string, parentID uint64, name, desc string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	if len(name) == 0 || len(name) > maxFolderTextLen || len(desc) > maxFolderTextLen {
		panic("kourtv2: a folder name is 1..200 and a description at most 200 characters")
	}
	if cm.folders.Size() >= maxFolders {
		panic("kourtv2: this court already has " + strconv.Itoa(maxFolders) + " folders")
	}
	// height 1: a folder being created has no subtree yet.
	cm.mustNestable(0, parentID, 1)
	cm.folderSeq++
	id := cm.folderSeq
	cm.folders.Set(beClaimKey(id), &folder{id: id, name: name, desc: desc, parent: parentID})
	emitModAct(c.id, 0, "folder-create", who)
	return id
}

// MoveFolder re-parents a folder, subtree and all. 0 moves it back to the root.
// One active moderator, like every other folder op and for the stated reason:
// zero economic weight, instantly reversible, so the m-of-n ceremony would tax
// routine curation for no security gain.
func MoveFolder(cur realm, courtSlug string, folderID, newParent uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	f := cm.mustFolder(folderID)
	cm.mustNestable(folderID, newParent, cm.folderHeight(folderID))
	f.parent = newParent
	emitModAct(c.id, 0, "folder-move", who)
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
		panic("kourtv2: that claim is not in the folder")
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
		panic("kourtv2: a folder name is 1..200 and a description at most 200 characters")
	}
	f := cm.mustFolder(folderID)
	if f.purged {
		panic("kourtv2: this folder's text was purged and cannot be re-set")
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
		panic("kourtv2: only a global DAO member may purge")
	}
	if len(categoryCode) == 0 || len(categoryCode) > maxReasonLen {
		panic("kourtv2: purge needs a statutory category code")
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
		panic("kourtv2: no such folder")
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
		panic("kourtv2: no such folder")
	}
	f := c.mod.mustFolder(folderID)
	out := make([]uint64, len(f.items))
	copy(out, f.items)
	return out
}

// FolderParent is the folder this one sits in, 0 for a root heading. The overlay
// assembles the tree from FolderCount + this, one cheap read each, rather than
// the chain returning a nested structure — no read here grows with the shape of
// what somebody built.
func FolderParent(courtSlug string, folderID uint64) uint64 {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return 0
	}
	v := c.mod.folders.Get(beClaimKey(folderID))
	if v == nil {
		return 0
	}
	return v.(*folder).parent
}

// FolderPurged reports whether a folder's text was tombstoned.
//
// The nil branch PANICS, matching FolderName and FolderItems above and the
// mustFolder they share. It used to return false, which made the same
// nonexistent folder answer two different ways depending on whether the court
// happened to hold any moderation state at all: false on a court with no mod
// object, "no such folder" on one that had ever been moderated. A caller
// probing an id it had not validated would see the discrepancy only on the
// second kind of court. The v0.19 rule again — a lazily-created read's
// not-yet-materialised branch must answer what the materialised one would.
func FolderPurged(courtSlug string, folderID uint64) bool {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		panic("kourtv2: no such folder")
	}
	return c.mod.mustFolder(folderID).purged
}
