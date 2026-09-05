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

	bptree "gno.land/p/nt/bptree/v0"
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
// association.gno implements the argument edge and not that one.
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
	/* bornOf: the claim that carried this set into existence, or 0 for one a
	   moderator simply created. See governedset.gno — a 𓂀 claim that settles
	   YES gets a set bound to it, and this is the binding. Kept on the folder
	   rather than in a second index because the folder is the thing that can be
	   retired, purged and moved, and a separate map would be a second place to
	   remember to do that. */
	bornOf uint64
	// parent folder, 0 = a root heading. Zero on pre-nesting folders, which read
	// as roots — the same "zero on pre-upgrade" shape claimState.openedAtTime
	// already uses, so there is no migration step and no version field.
	parent uint64
	// Where this folder sits among its siblings, 1-based. ZERO MEANS UNPLACED,
	// and unplaced sorts LAST (see folderAfter) — which is the whole reason this
	// field costs nothing to adopt. A court that has never been ordered has every
	// ord at zero, so every folder is unplaced and the list falls back to id
	// order: exactly what it emitted before this field existed. And a folder
	// created AFTER an ordering lands at the end, where a new folder belongs,
	// instead of jumping to the front the way a plain 0-is-first rule would put
	// it. items has had curation order since MoveItemInFolder; this is the same
	// courtesy for the headings themselves.
	ord int
	// ONE image, or nil (owner ruling, CLAIM_MEDIA §10). A folder is a heading,
	// not a claim: it is arguing nothing, so it has nothing to prove and no
	// numbered exhibits to keep in order. What it has is a face on the map, and
	// one picture is a face. Seven would be a gallery for a thing that makes no
	// assertion.
	//
	// Same mediaItem the chain already stores for a claim, so the fingerprint,
	// the mirrors, the archive-first destination and the render-time
	// revalidation all come along unchanged.
	image *mediaItem
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

// folderAfter reports whether a sorts after b WITHIN ONE SIBLING GROUP, on
// (placed, ord, id).
//
// UNPLACED LAST is the load-bearing clause. `ord == 0` means nobody has ever
// placed this folder, so a group nobody has ordered sorts entirely by id — and a
// folder created after an ordering lands at the end, where a new folder belongs,
// rather than at the head of a list the curator just arranged.
func folderAfter(a, b *folder) bool {
	ap, bp := a.ord > 0, b.ord > 0
	if ap != bp {
		return bp // b is placed and a is not, so a goes after it
	}
	if ap && a.ord != b.ord {
		return a.ord > b.ord
	}
	return a.id > b.id
}

// folderRows is every folder in display order: the id-order spine the tree has
// always emitted, with each sibling group PERMUTED WITHIN THE SLOTS IT ALREADY
// OCCUPIED.
//
// The first version sorted globally by (parent, placed, ord, id), and grouping
// by parent broke the promise this whole feature is built on. TestFolderTree
// caught it: a nested court reads "1:0:-,2:1:-,3:0:-" and grouping re-emitted it
// as "1:0:-,3:0:-,2:1:-" — every already-deployed nested court's read changing
// shape on a feature nobody had used yet. Keeping the slots means an unordered
// court is byte-identical, whatever its shape, which is what "no migration"
// actually requires. It also keeps a parent ahead of its own children instead of
// letting ordered children overtake it.
//
// An insertion sort, and deliberately not an import: nothing in this tree
// imports "sort", the list is capped at maxFolders (100), and a realm's
// dependency surface is paid for at deploy time. n² on 100 rows stays in the
// same order of magnitude as the tree walk that produced it.
func (cm *courtMod) folderRows() []*folder {
	out := make([]*folder, 0, maxFolders)
	cm.folders.Iterate("", "", func(_ string, v any) bool {
		if f, ok := v.(*folder); ok {
			out = append(out, f)
		}
		return false
	})
	for i := range out {
		// Each group once, at its first slot.
		first := true
		for j := 0; j < i; j++ {
			if out[j].parent == out[i].parent {
				first = false
				break
			}
		}
		if !first {
			continue
		}
		p := out[i].parent
		slots := make([]int, 0, len(out))
		grp := make([]*folder, 0, len(out))
		for j, g := range out {
			if g.parent == p {
				slots = append(slots, j)
				grp = append(grp, g)
			}
		}
		for a := 1; a < len(grp); a++ {
			f := grp[a]
			b := a - 1
			for b >= 0 && folderAfter(grp[b], f) {
				grp[b+1] = grp[b]
				b--
			}
			grp[b+1] = f
		}
		for k, g := range grp {
			out[slots[k]] = g
		}
	}
	return out
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

// ---- the shared body, and who is allowed to call it ----------------------

/* ONE PLACE A FOLDER COMES INTO BEING, and it checks no authority.
   Three callers now reach it: CreateFolder and CreateFolderIn, which gate on
   requireFolderMod, and the meta court's `mod:newset` execution, whose
   authority is a carried verdict rather than an address. Putting the gate inside
   would make the verdict path need a moderator to exist; leaving it out and
   naming the rule here is the shape installModSet already uses for the same
   reason.
   THE CALLER CHECKS AUTHORITY. The body checks that the FOLDER is legal — the
   cap, the text lengths, the nesting — because those are true of a folder no
   matter who asked for it, and the verdict path has to re-check them at
   execution anyway: weeks pass between a proposal and the verdict that carries
   it, and a court can fill up in between. */
func folderTextOK(name, desc string) bool {
	return runeLen(name) > 0 && runeLen(name) <= maxFolderTextLen && runeLen(desc) <= maxFolderTextLen
}

// folderNameTaken reports whether a LIVE folder already carries this name. A
// retired one does not count: the row survives so ids stay contiguous, but the
// name is free again.
func folderNameTaken(cm *courtMod, name string) bool {
	taken := false
	if cm.folders == nil {
		return false
	}
	cm.folders.Iterate("", "", func(_ string, v any) bool {
		f := v.(*folder)
		if !f.retired && f.name == name {
			taken = true
			return true
		}
		return false
	})
	return taken
}

func newFolderCore(cm *courtMod, name, desc string, parent uint64) uint64 {
	if cm.folders.Size() >= maxFolders {
		panic("kourtv2: this court already has " + strconv.Itoa(maxFolders) + " folders")
	}
	if !folderTextOK(name, desc) {
		panic("kourtv2: a folder name is 1..200 and a description at most 200 characters")
	}
	if parent != 0 {
		// height 1: a folder being created has no subtree yet.
		cm.mustNestable(0, parent, 1)
	}
	cm.folderSeq++
	id := cm.folderSeq
	cm.folders.Set(beClaimKey(id), &folder{id: id, name: name, desc: desc, parent: parent})
	return id
}

// ---- a folder the court has not agreed to yet ----------------------------

/* A PROPOSAL IS NOT A FOLDER. It records what somebody wants filed and nothing
   else: no entry in cm.folders, no id in the contiguous folder range, nothing
   the overlay enumerates. Only a carried `mod:newset` verdict turns one into
   a folder, and it re-checks every rule at that moment. */
type folderProposal struct {
	id     uint64
	name   string
	desc   string
	parent uint64
	by     address
	at     int64
}

/* ANY HOLDER MAY PROPOSE, because proposing is the interactive half — the point
   of the verb is that the filing system stops being the moderators' alone. It
   creates nothing and costs gas, so an abusive proposer buys themselves an
   unreferenced row; the appeal that would ACT on it still has to carry a bonded
   answer and survive 72h of anyone's dispute, and the latch in meta.gno lets one
   court host only one live folder appeal at a time.
   VALIDATED HERE, where the caller can be told what is wrong. The alternative is
   failing inside an execution weeks later, which nobody is watching. */
func RegisterFolderProposal(cur realm, courtSlug, name, desc string, parentID uint64) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	if !folderTextOK(name, desc) {
		panic("kourtv2: a folder name is 1..200 and a description at most 200 characters")
	}
	if parentID != 0 {
		cm.mustNestable(0, parentID, 1)
	}
	if folderNameTaken(cm, name) {
		panic("kourtv2: this court already has a folder by that name")
	}
	if cm.folderProps == nil {
		cm.folderProps = bptree.NewBPTree32()
	}
	cm.folderPropSeq++
	id := cm.folderPropSeq
	cm.folderProps.Set(beClaimKey(id), &folderProposal{
		id: id, name: name, desc: desc, parent: parentID, by: who, at: heightNow(),
	})
	return id
}

func (cm *courtMod) mustFolderProposal(id uint64) *folderProposal {
	if cm.folderProps == nil {
		panic("kourtv2: no such folder proposal")
	}
	v := cm.folderProps.Get(beClaimKey(id))
	if v == nil {
		panic("kourtv2: no such folder proposal")
	}
	return v.(*folderProposal)
}

// CreateFolder makes a new empty folder and returns its id.
func CreateFolder(cur realm, courtSlug, name, desc string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	id := newFolderCore(cm, name, desc, 0)
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
	id := newFolderCore(cm, name, desc, parentID)
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
	if runeLen(name) == 0 || runeLen(name) > maxFolderTextLen || runeLen(desc) > maxFolderTextLen {
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
// SetFolderImage gives a folder its one picture, on the same seat that renames
// it: a folder's face is curation, and curation is the folder moderator's.
//
// The argument is ONE line of the same eight-field format a claim's evidence
// uses — kind|sha256|mime|w|h|bytes|caption|mirrors — so web/media.js builds it
// with the same code and this realm parses it with the same parser. A second
// line is refused rather than truncated: a caller passing two has misunderstood
// something, and taking the first silently would hide that.
//
// An image only. A video is a link the court cannot vouch for, which is a
// reasonable thing to file as EVIDENCE, where the claim page says so in as many
// words — and an unreasonable thing to make the face of a heading.
func SetFolderImage(cur realm, courtSlug string, folderID uint64, media string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	f := cm.mustFolder(folderID)
	if f.purged {
		panic("kourtv2: this folder's text was purged and cannot be re-set")
	}
	items := parseMediaArg(media)
	if len(items) != 1 {
		panic("kourtv2: a folder carries exactly one image")
	}
	if items[0].kind != mediaKindImage {
		panic("kourtv2: a folder's image is an image, not a video link")
	}
	f.image = &items[0]
	emitModAct(c.id, 0, "folder-image", who)
}

// ClearFolderImage takes it off again. Same seat, and separate from SetFolderImage
// because "no picture" reached by passing an empty string is a state somebody
// arrives at by accident.
func ClearFolderImage(cur realm, courtSlug string, folderID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	cm.mustFolder(folderID).image = nil
	emitModAct(c.id, 0, "folder-image-clear", who)
}

// FolderImage answers with the folder's picture as one line of JSON, or [] — the
// same shape ClaimMedia uses, so the overlay parses both with one function.
//
// A purged folder answers with nothing, exactly as a purged claim does. Nothing
// here is a second gate: f.image is already nil after a purge, and this reads
// what is there.
func FolderImage(courtSlug string, folderID uint64) string {
	c := mustCourt(courtSlug)
	cm := c.mod
	if cm == nil {
		return "[]"
	}
	f := cm.mustFolder(folderID)
	if f.image == nil {
		return "[]"
	}
	return encodeMedia([]mediaItem{*f.image})
}

func PurgeFolder(cur realm, courtSlug string, folderID uint64, categoryCode string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	d := ensureGlobalDAO()
	if !d.members.Has(who.String()) {
		panic("kourtv2: only a global DAO member may purge")
	}
	mustCategoryCode(categoryCode)
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
	// The image is the folder's text as much as its name is: a picture chosen to
	// stand for a heading says something, and a purge that left it would leave
	// the part somebody is most likely to have objected to.
	f.image = nil
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

// ClaimFolders is FolderItems read backwards: which folders is this claim filed
// in. A claim page needs it to answer the question its own heading asks — where
// this claim sits — and until it existed the only answer was to walk every
// folder in the court, which is FolderCount + FolderTree + a name and an item
// list per folder. Fourteen round trips on a six-folder court, to print one
// name. The overlay declined to pay that, so a claim on a chain court said
// nothing at all about its folder while a curated one said "filed under X".
//
// PURGED FOLDERS ARE SKIPPED, and that is not tidiness. PurgeFolder blanks the
// name and the picture but deliberately leaves the item list alone — retiring is
// what un-files claims — so a purged folder still knows which claims it held.
// Answering with it would send a reader to a tombstone with no name on it, and
// would republish the association a purge exists to sever.
//
// Retired folders need no such guard: RetireFolder clears the item list, so they
// cannot match. Said rather than assumed, because the two verbs are one word
// apart and only one of them empties the folder.
//
// Order is the tree's own — folderRows, the curator's ordering — so a claim in
// two folders lists them the way the court lists them, not the way the avl tree
// happens to key them.
func ClaimFolders(courtSlug string, claimID uint64) []uint64 {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return nil
	}
	var out []uint64
	for _, f := range c.mod.folderRows() {
		if f.purged {
			continue
		}
		for _, it := range f.items {
			if it == claimID {
				out = append(out, f.id)
				break
			}
		}
	}
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

// OrderFolders sets the display order of every folder under one heading.
//
// parentID is the heading; 0 means the root headings. ids is a comma-separated
// list of folder ids, and the folders are placed in that order, 1..n. Sending
// the list again with a different order is how you reorder; the call is
// idempotent and nothing is written unless the whole list validates.
//
// THE LIST MUST BE EXACTLY THE SIBLING SET — every folder under that heading,
// each exactly once, and nothing else. A subset is refused rather than accepted
// as a partial order: unlisted folders would keep ord 0 and sort last, so
// ordering three of five would silently demote the other two. An unknown id is
// refused rather than ignored, so a typo cannot become a silent no-op.
//
// Retired and purged siblings are IN the set. Their rows survive, they still
// appear in FolderTree behind their flags, and one left out would come back
// wherever it happened to fall.
//
// An active court moderator, single-signer. Refused when the court does not
// exist, the caller is not an active moderator, the heading does not exist, the
// heading holds no folders, `ids` is longer than a list of folder ids could be,
// an entry is not a number, an id is not under that heading, or an id repeats.
func OrderFolders(cur realm, courtSlug string, parentID uint64, ids string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := requireFolderMod(c, who)
	if parentID != 0 {
		cm.mustFolder(parentID)
	}
	// BOUND THE PARSE BEFORE IT HAPPENS. strings.Split allocates one entry per
	// comma, so a megabyte of commas is a megabyte of work done before any check
	// could refuse it — the cost is paid in the argument, not in the state. 21
	// bytes is a uint64 at its longest plus its separator.
	if len(ids) > maxFolders*21 {
		panic("kourtv2: that is too long to be a list of folder ids")
	}
	sibs := make([]*folder, 0, maxFolders)
	cm.folders.Iterate("", "", func(_ string, v any) bool {
		if f, ok := v.(*folder); ok && f.parent == parentID {
			sibs = append(sibs, f)
		}
		return false
	})
	if len(sibs) == 0 {
		panic("kourtv2: there are no folders under that heading to order")
	}
	parts := strings.Split(ids, ",")
	if len(parts) != len(sibs) {
		panic("kourtv2: that heading holds " + strconv.Itoa(len(sibs)) +
			" folders and the order lists " + strconv.Itoa(len(parts)) +
			"; it must list every one of them, exactly once")
	}
	order := make([]*folder, 0, len(parts))
	for _, p := range parts {
		id, err := strconv.ParseUint(strings.TrimSpace(p), 10, 64)
		if err != nil {
			panic("kourtv2: an order is a comma-separated list of folder ids")
		}
		var f *folder
		for _, s := range sibs {
			if s.id == id {
				f = s
				break
			}
		}
		if f == nil {
			panic("kourtv2: folder " + strconv.FormatUint(id, 10) +
				" is not under that heading")
		}
		// NAME THE REPEAT, because the count check above cannot see it: a list
		// that repeats one id and drops another is the right LENGTH, and without
		// this it would silently leave the dropped folder unplaced.
		for _, x := range order {
			if x.id == id {
				panic("kourtv2: folder " + strconv.FormatUint(id, 10) +
					" is listed twice")
			}
		}
		order = append(order, f)
	}
	// Nothing above this line has written. A refusal halfway through a list would
	// otherwise leave half a court reordered.
	for i, f := range order {
		f.ord = i + 1
	}
	emitModAct(c.id, 0, "folder-sort", who)
}

// FolderTree is a court's whole folder structure in one read: "id:parent:flags"
// per folder, comma separated, in display order.
//
// parent is 0 for a root heading. flags is "r" retired, "p" purged, "i" has a
// picture, in that order, or "-" for none of them. Children follow the parent
// they belong to, and each sibling group
// sits in the order a curator gave it with OrderFolders; folders nobody has
// ordered come last within their group, ids ascending. A court nobody has
// ordered reads in plain id order.
//
// STRUCTURE ONLY. Names and descriptions are one read each — FolderName,
// FolderDesc — because they are user text a client only needs for the folders it
// actually draws. A purged folder's flags say so, so a client knows to expect a
// tombstone rather than a name.
//
// Ungated: a court's filing structure is not secret. The two things that ARE
// gated, a purged folder's name and description, are gated in the reads that
// return them.
//
// Bounded at 100 folders, so the answer cannot exceed about a kilobyte whatever
// anybody writes. Returns the empty string for a court that has no folders yet.
// Refused only on a court that does not exist.
func FolderTree(courtSlug string) string {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return ""
	}
	var b strings.Builder
	n := 0
	for _, f := range c.mod.folderRows() {
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
		// "i" — this folder has a picture, so a client knows to spend the read.
		// It rides here rather than in a read of its own because the alternative
		// is one FolderImage per folder on every map draw, a hundred at the cap,
		// for a field most folders will never set. The flag costs a byte and the
		// read is paid only where there is something to fetch.
		if f.image != nil {
			flags += "i"
		}
		if flags == "" {
			flags = "-"
		}
		b.WriteString(strconv.FormatUint(f.id, 10) + ":" +
			strconv.FormatUint(f.parent, 10) + ":" + flags)
		n++
	}
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
