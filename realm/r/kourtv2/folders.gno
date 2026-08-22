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

import (
	"strconv"
	"strings"
)

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
	// One folder's claim list. FolderItems returns the WHOLE list in one read, and
	// AddToFolder scans it for duplicates on every add — so without a cap the read
	// grows with what a moderator wrote and filling a folder costs O(n²). 200
	// claims under one heading is already more than a heading is for.
	maxFolderItems = 200
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
	// retired: struck from the tree, but the ROW SURVIVES. Not a delete, and the
	// difference is forced by a client: the overlay enumerates folders by walking
	// ids 1..FolderCount and calls that contiguity load-bearing, so removing an
	// entry would renumber the world underneath it. FolderCount is folders.Size(),
	// so a retired folder still counts and every id still resolves.
	retired bool
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
	if len(f.items) >= maxFolderItems {
		panic("kourtv2: a folder holds at most " + strconv.Itoa(maxFolderItems) + " claims")
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

// FolderDesc returns a folder's description. The field has been written and
// length-capped since folders existed and had no way out, which the overlay has
// been carrying as "stored but unreadable — wishlisted". This is that.
//
// NO PURGE BRANCH, and its absence is the point rather than an omission. This
// read was first written with `if f.purged { return "" }` and the test for it
// passed — then failed to fail when the branch was deleted, because PurgeFolder
// does not flag this text, it ERASES it (name and desc are both set to ""). The
// branch was dead code, and dead code in a moderation path is worse than absent:
// it reads as the thing standing between a purge and a leak when the erasure is
// what actually stands there.
//
// Worth knowing, because the two differ: a purged CLAIM keeps its title and body
// in state and every read gates on the flag, so the bytes are still on chain. A
// purged FOLDER's text is gone. FolderName still needs its branch — it
// substitutes the "[purged:CODE]" tombstone for the erased name.
func FolderDesc(courtSlug string, folderID uint64) string {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		panic("kourtv2: no such folder")
	}
	return c.mod.mustFolder(folderID).desc
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

// RetireFolder strikes a folder from the tree. The gap this fills is small and
// real: a folder created by mistake could not be got rid of at all — PurgeFolder
// is the global DAO's m-of-n act carrying a statutory category code, for illegal
// content, not for "that was a typo".
//
// It does NOT remove the row. See the `retired` field: the overlay walks ids
// 1..FolderCount, so deleting an entry would renumber every folder above it.
//
// Refuses a folder that still has children, so the tree cannot grow orphans and
// a moderator retires bottom-up. Clears the claim list, which un-files those
// claims — safe by this module's founding promise, since the flat newest-first
// docket always remains and folders "curate and can never bury".
func RetireFolder(cur realm, courtSlug string, folderID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	f := cm.mustFolder(folderID)
	if cm.folderHeight(folderID) > 1 {
		panic("kourtv2: retire the folders inside it first")
	}
	f.retired = true
	f.items = nil
	emitModAct(c.id, 0, "folder-retire", who)
}

// RestoreFolder puts a retired folder back. Folder acts are "instantly
// reversible" by this module's own decision rule, which is the stated reason they
// need only one moderator rather than m-of-n — so the reverse has to exist, or
// that rule was only ever half true.
func RestoreFolder(cur realm, courtSlug string, folderID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	f := cm.mustFolder(folderID)
	if f.purged {
		panic("kourtv2: a purged folder cannot be restored")
	}
	f.retired = false
	emitModAct(c.id, 0, "folder-restore", who)
}

// MoveItemInFolder puts a claim at a given position in a folder's list. The list
// is documented as "claim IDs, in curation order" and until now that order was
// whatever order they were added in — curation you cannot re-order is a log.
// Bounded by maxFolderItems, like every other walk of this list.
func MoveItemInFolder(cur realm, courtSlug string, folderID, claimID uint64, to int) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	f := cm.mustFolder(folderID)
	at := -1
	for i, x := range f.items {
		if x == claimID {
			at = i
			break
		}
	}
	if at < 0 {
		panic("kourtv2: that claim is not in the folder")
	}
	if to < 0 || to >= len(f.items) {
		panic("kourtv2: that position is outside the folder")
	}
	if to == at {
		return
	}
	// Rebuild rather than slide in place: f.items is realm state, and an
	// in-place shuffle writes through the persisted backing array on every step,
	// so a rebuild is the version whose intermediate states are never stored.
	out := make([]uint64, 0, len(f.items))
	for i, x := range f.items {
		if i == at {
			continue
		}
		if len(out) == to {
			out = append(out, claimID)
		}
		out = append(out, x)
	}
	if len(out) == to {
		out = append(out, claimID)
	}
	f.items = out
	emitModAct(c.id, claimID, "folder-order", who)
}

// FolderTree is every folder's SHAPE in one read: "id:parent:flags" per folder,
// comma separated, ids ascending. flags is "r" retired, "p" purged, "rp" both,
// "-" neither.
//
// STRUCTURE ONLY, AND THAT IS THE POINT. A client assembling the tree otherwise
// needs FolderParent + FolderRetired + FolderPurged per folder — three round
// trips each, 300 for a court at the cap, to learn something that fits in about
// a kilobyte. Names and descriptions stay one read per folder because they are
// unbounded-ish user text that a client only needs for the folders it actually
// draws, and because splicing them into a delimited string would mean escaping
// user text into a format this realm would then have to keep escaping correctly
// for ever.
//
// Bounded by maxFolders, so this read cannot grow past ~1.2KB whatever anybody
// writes. No moderation gate: the shape of a court's filing system is not
// secret, and the two things that ARE gated — a purged folder's name and its
// description — are gated in the reads that return them. The flags say a row is
// purged so a client knows to expect a tombstone rather than a name.
func FolderTree(courtSlug string) string {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return ""
	}
	var b strings.Builder
	n := 0
	c.mod.folders.Iterate("", "", func(_ string, v any) bool {
		f, ok := v.(*folder)
		if !ok {
			return false
		}
		if n > 0 {
			b.WriteString(",")
		}
		flags := ""
		if f.retired {
			flags += "r"
		}
		if f.purged {
			flags += "p"
		}
		if flags == "" {
			flags = "-"
		}
		b.WriteString(strconv.FormatUint(f.id, 10) + ":" +
			strconv.FormatUint(f.parent, 10) + ":" + flags)
		n++
		return false
	})
	return b.String()
}

// FolderRetired reports whether a folder has been struck from the tree. The row
// still exists and still counts toward FolderCount; this is how a reader knows
// to skip it.
func FolderRetired(courtSlug string, folderID uint64) bool {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return false
	}
	v := c.mod.folders.Get(beClaimKey(folderID))
	if v == nil {
		return false
	}
	return v.(*folder).retired
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
