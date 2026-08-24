// Moderation: render-layer authority only. No money path reads any state in
// this file, and no entrypoint here writes coin/escrow/emission/verdict/stake
// state (MODERATION.md §2, the constitution). Moderation controls DISCOVERY —
// what appears in listings and on the front page — never money. A hidden claim's
// full lifecycle (stake, answer, vote, settle, withdraw) runs byte-identically;
// hiding it only removes it from browse surfaces (it stays reachable by direct
// link). This is what makes even a fully captured moderator harmless to funds.
//
// This file is module 1: the hide-bit model, per-court moderator sets with an
// m-of-n decision rule, suspension, the global moderator DAO, and purge (the one
// power that removes text, reserved for legal compliance). Strips (module 3/6),
// folders and the election (modvote), the meta court's ExecuteMetaVerdict
// (module 7), and render (module 6) land in sibling files and call the internal
// helpers here.
package kourtv2

import (
	"chain"
	"strconv"

	bptree "gno.land/p/nt/bptree/v0"
)

const (
	maxReasonLen = 200
	// maxModSetSize bounds currentSetID's O(n²) concatenation, which sits on the
	// suspend path — see canonicalMembers. 32 is far above any real m-of-n.
	maxModSetSize = 32
	// The re-set window mirrors the DMCA §512(g) counter-notice period (~2
	// weeks): re-setting a global redaction that a global act cleared inside
	// this window needs m-of-n (MODERATION.md §3.2, round-4 F5). Outside it a
	// fresh notice is a fresh single-key hide.
	reSetWindowBlocks = int64(241_920) // ~14 days at 17_280 blocks/day

	// Moderation event names. Events carry act metadata and a category/act code
	// only — NEVER reason/annotation/title text (I6): events are unpurgeable
	// history, so leaking user text through one would defeat purge.
	modActEvent    = "ModAct"    // a courtMod / meta bit change or annotation
	globalActEvent = "GlobalAct" // a global-DAO bit / tier change
	purgeEvent     = "Purge"     // a row/court text tombstone
)

// ---- the global moderator DAO (realm-wide) --------------------------------

// daoState is the realm's global moderator set: the operator's legal backstop
// (MODERATION.md §3.2). It generalizes directoryAdmin — the first court creator
// bootstraps it as the sole member/admin. Powers: court tiers, an all-surface
// text-redaction hide anywhere, clear-any-bit recovery, and purge (m-of-n).
type daoState struct {
	admin   address
	members *bptree.BPTree // addr -> true
	n       int
	purgeM  int            // m-of-n for purge and windowed re-set
	pending *bptree.BPTree // actionKey -> *approval
}

var globalDAO *daoState

// ensureGlobalDAO lazily migrates directoryAdmin into the DAO on first use.
func ensureGlobalDAO() *daoState {
	if globalDAO != nil {
		return globalDAO
	}
	// THIS PANIC IS IN NO MUTATION BATCH, AND THAT IS DELIBERATE. It fires only
	// when globalDAO is still nil AND directoryAdmin is still empty, and both are
	// package-globals that never reset: directoryAdmin is set by the first
	// StartCourt (court.gno) and globalDAO, once built, stays built. So a test
	// asserting this refusal would pass ALONE and fail TOGETHER with its package,
	// and check-isolation.py requires both — the guard is unpinnable by
	// construction. Note the near miss it protects against anyway: reading
	// DirectoryAdmin() before any court exists yields the ZERO address, which is
	// not a DAO member and not the admin, so calls made with it are silently
	// no-ops rather than refusals. A fixture that reads it must create its court
	// first.
	if directoryAdmin == "" {
		panic("kourtv2: no court exists yet; the global DAO has no admin")
	}
	d := &daoState{
		admin:   directoryAdmin,
		members: bptree.NewBPTree32(),
		n:       1,
		purgeM:  1,
		pending: bptree.NewBPTree32(),
	}
	d.members.Set(directoryAdmin.String(), true)
	globalDAO = d
	return d
}

func isGlobalMod(who address) bool {
	d := ensureGlobalDAO()
	return d.members.Has(who.String())
}

// AddGlobalMod / RemoveGlobalMod / SetPurgeThreshold: admin-managed membership
// (MODERATION.md §3.2; DAO-ification is V3, the shape matters more than the
// governance for now).
func AddGlobalMod(cur realm, who address) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin manages membership")
	}
	seatGlobalMember(d, who)
}

// seatGlobalMember adds an address to the DAO's member set, or does nothing at
// all if it is already in it.
//
// ITS TWO CALLERS HAD ALREADY DRIFTED ON THESE FOUR LINES, which is the reason
// they are one block now. AddGlobalMod cleared the banked m-of-n approvals when
// the member set changed and TransferGlobalAdmin did not, and that made the
// transfer the STRICTLY BETTER route for an admin wanting to complete a stuck
// purge: seat a fresh key without resetting the signatures banked against the
// old set. Both clear now. Sharing the lines is what stops the next one added
// here from reaching one caller and missing the other.
//
// ONLY THE ADD IS SHARED. Removal is not the mirror of it — RemoveGlobalMod
// also has to pull purgeM down to the smaller n — and seating cannot put m
// above n, so there is nothing to clamp on this side.
func seatGlobalMember(d *daoState, who address) {
	if d.members.Has(who.String()) {
		return
	}
	d.members.Set(who.String(), true)
	d.n++
	clearPendingOnMembershipChange(&d.pending) // stale approvals must not carry over
}

func RemoveGlobalMod(cur realm, who address) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin manages membership")
	}
	if who == d.admin {
		panic("kourtv2: the admin cannot be removed; transfer admin first")
	}
	if d.members.Has(who.String()) {
		d.members.Remove(who.String())
		d.n--
		if d.purgeM > d.n {
			d.purgeM = d.n
		}
		clearPendingOnMembershipChange(&d.pending) // a removed member's approval must not still count
	}
}

// SetPurgeThreshold sets m for the m-of-n purge/re-set rule, 1..n.
func SetPurgeThreshold(cur realm, m int) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin sets the purge threshold")
	}
	if m < 1 || m > d.n {
		panic("kourtv2: the purge threshold must be in 1..n")
	}
	if m != d.purgeM {
		// Lowering the bar re-scores every banked signature against it: five
		// approvals gathered under 7-of-7 become executable the moment the
		// admin sets 5, at their sole discretion. The threshold is half of
		// "who must agree", so changing it invalidates consent just as
		// membership does.
		clearPendingOnMembershipChange(&d.pending)
	}
	d.purgeM = m
}

// TransferGlobalAdmin hands the admin seat to another member.
func TransferGlobalAdmin(cur realm, to address) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin transfers the seat")
	}
	// Seating an EXISTING member changes no set and clears nothing, here as in
	// AddGlobalMod: the banked approvals are consent to a membership, and this
	// path has not altered one.
	seatGlobalMember(d, to)
	d.admin = to
}

// ---- per-court moderator set + per-claim hide state -----------------------

// courtMod is one court's moderation state (MODERATION.md §3.1, §4). The set
// decides by m-of-n (round-7 R3), so a single captured or decoy member can act
// on nothing.
type courtMod struct {
	members *bptree.BPTree // addr -> true
	n       int
	m       int // m-of-n decision threshold

	suspended   bool
	suspendedAt int64 // when the CURRENT suspension began (render)
	// suspendActByGlobal stamps the two GLOBAL DAO suspension verbs. The meta
	// staleness guard reads it so a verdict cannot silently overturn a global
	// decision taken after the appeal was filed — see meta.gno's guard 7.
	suspendActByGlobal int64
	suspendedSetID     string // WHICH membership was judged — a re-seat of the same one must not clear the flag
	suspendedM         int    // ...and how tightly it had to agree; only TIGHTENING earns a lift
	setActHeight       int64  // last membership change (for the meta staleness stamp)
	lastElectionAt     int64
	// installedByMeta: this set was seated by a meta verdict rather than by the
	// court's own creator or electorate. Such a set may not SEED claims — the
	// seeding waiver skips the CC deposit and fee while winner/answerer slices
	// still mint, so it is an economic privilege, and a captured meta must not
	// be able to hand an attacker-chosen principal a free claim faucet.
	installedByMeta bool

	courtPurged    bool   // whole-court text tombstone (global DAO, m-of-n)
	courtTombstone string // the category code

	claims  *bptree.BPTree // claimID (be64) -> *claimMod
	pending *bptree.BPTree // actionKey -> *approval

	folders   *bptree.BPTree // folderID (be64) -> *folder (folders.gno)
	folderSeq uint64

	// The replacement election (modvote.gno) and the candidate registry it and
	// the meta court's `mod:setmods` peer path share.
	candidates            *bptree.BPTree // candidateID (be64) -> *modCandidate
	candSeq               uint64
	election              *election
	electionSeq           uint64
	electionCooldownUntil int64 // this court's OWN cooldown slot (not the per-claim flag field)
	creatorUnseated       bool  // an election has installed a set; the creator no longer appoints

	// election / strip-index state land in modvote.gno / the strip module; they
	// hang off this struct so a court's whole moderation footprint is one
	// lazily-created object.
}

// claimMod is the per-claim hide word + log. Created only for a claim that is
// actually moderated (so an unmoderated claim costs nothing). Bits are
// independent (union): an item lists only if none is set.
type claimMod struct {
	court  bool // courtMod hide bit
	meta   bool // meta-court hide bit (set/cleared by ExecuteMetaVerdict)
	global bool // global DAO all-surface text-redaction hide

	purged    bool   // claim title tombstoned (global purge)
	tombstone string // the category code shown in place of text

	// There were once three more stamps here — courtActByOthers, metaActByOthers
	// and globalActHeight — carrying a per-claim "a third party already acted"
	// term for the meta staleness guard. That refusal was deliberately REMOVED
	// (see verbUnhide in meta.gno: refusing on a same-direction third-party
	// clear let a moderator re-hide for free), and nothing ever read them again.
	// They are gone rather than left looking load-bearing; the mod log carries
	// the same who/when for render. A stripEnteredAt field went the same way —
	// the strip key already encodes the deadline it would have duplicated.
	globalClearedAt int64 // for the windowed-m-of-n re-set rule
	executedAt      int64 // meta-verdict cooldown anchor (module 7)

	logSeq uint64
	log    []modAct
}

// modAct is one append-only moderation-log row. rowID lets purge address a
// single row.
//
// code is an act tag, and it is NOT AN ENUM. This said "a category/act code (an
// enum), never user text", and that was wrong in the way that matters: eight of
// the eleven acts that write a row do pass a fixed string ("hide", "unhide",
// "meta-clear" and the like), but three CONCATENATE a caller-supplied statutory
// code into it — "global-hide:"+categoryCode, "purge:"+code and
// "purgerow:"+code — and mustCategoryCode validates LENGTH ONLY, with no alphabet
// and no membership test. So those three carry free text with every punctuation
// mark available.
//
// renderModLog therefore sanitises code exactly as it sanitises reason, and that
// is not belt-and-braces. A "never user text" claim on a field that IS user text
// is precisely what licenses a later reader to render it raw, which is how the
// same mistake reached ccwrap's page. Pinned by
// TestAPurgeCodeCannotWriteMarkupIntoTheModLog.
//
// reason is the stored text, sanitized at render, and purgeable.
type modAct struct {
	rowID  uint64
	actor  address
	code   string
	reason string
	height int64
	purged bool
}

// pendingTTLBlocks is how long an unfired m-of-n approval stays valid: 7 days,
// the same duration as flagCooldownBlocks and the default votingBlocks. This
// realm's unit for "a body gets this long to decide" — and a set of at most 32
// self-selected moderators should not get longer than a whole court electorate
// gets for a dispute. §3.2's own runbook targets an m-of-n purge "within 72h",
// so a week is already 2.3× the operating target.
//
// Deliberately NOT reSetWindowBlocks (14d): that measures the DMCA §512(g)
// counter-notice period, an external statutory clock that counsel must be able
// to retune alone. Coupling an internal quorum rule to it means one of the two
// eventually gets changed for the other's reasons.
const pendingTTLBlocks = flagCooldownBlocks

// approval accumulates distinct-member approvals for an m-of-n action.
//
// openedAt is read (unlike the actor0 that was deleted alongside it in v0.16
// and stays deleted, still having no reader). It exists because THE REAL DEFECT
// here was never storage — approvals are self-paid via the storage deposit,
// bounded by a derived key space, and walked by nothing. It is that an approval
// could never go stale: m-of-n meant "m members agreed at some point in
// history", not "m members agree now". A signature given in January sat at m-1
// and could be completed in November by one careless colleague, on an
// irreversible purge its author would have withdrawn if withdrawing existed.
type approval struct {
	approvers *bptree.BPTree // addr -> true
	reason    string
	openedAt  int64
}

// ensureMod lazily creates a court's moderation object with a 1-of-1 creator
// set (the creator bootstraps; an election or AppointMods reshapes it).
func ensureMod(c *Court) *courtMod {
	if c.mod != nil {
		return c.mod
	}
	cm := &courtMod{
		members: bptree.NewBPTree32(),
		n:       1,
		m:       1,
		claims:  bptree.NewBPTree32(),
		pending: bptree.NewBPTree32(),
		folders: bptree.NewBPTree32(),
	}
	cm.members.Set(c.admin.String(), true)
	c.mod = cm
	return cm
}

// AppointMods lets the court creator set the moderator addresses and the m-of-n
// threshold, until a replacement election unseats the appointment power
// (modvote.gno). Addresses-only; no free text.
func AppointMods(cur realm, courtSlug string, m int, mods ...address) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	if cur.Previous().Address() != c.admin {
		panic("kourtv2: only the court creator appoints moderators (until an election)")
	}
	if c.mod != nil && c.mod.creatorUnseated {
		panic("kourtv2: an election has installed a set; the creator's appointment power is spent")
	}
	// A suspended set may not be re-appointed around. AppointMods is
	// creator-only and FREE, so if it cleared (or ignored) the suspension a
	// suspended creator would self-unsuspend for zero cost — turning meta's
	// bonded, voted disarm into a no-op. Only the bonded/voted peers (an
	// election install or a meta verdict) clear a suspension.
	if c.mod != nil && c.mod.suspended {
		panic("kourtv2: this moderator set is suspended; only an election or a meta verdict may reinstate it")
	}
	// Canonicalize FIRST, then validate: checking m against the raw list let
	// {A,A,B} with m=3 install n=2/m=3 — a set in which no action can ever reach
	// its own threshold, including UnhideItem, so any standing hide became
	// locally permanent.
	canon := canonicalMembers(mods)
	if len(canon) == 0 {
		panic("kourtv2: a moderator set may not be empty")
	}
	if m < 1 || m > len(canon) {
		panic("kourtv2: the m-of-n threshold must be in 1..n")
	}
	cm := ensureMod(c)
	fresh := bptree.NewBPTree32()
	n := 0
	for _, a := range canon {
		fresh.Set(a.String(), true)
		n++
	}
	cm.members = fresh
	cm.n = n
	cm.m = m
	cm.setActHeight = heightNow()
	cm.installedByMeta = false // a creator appointment is a local act
	clearPendingOnMembershipChange(&cm.pending)
}

func requireMod(cm *courtMod, who address) {
	if !cm.members.Has(who.String()) {
		panic("kourtv2: not a moderator of this court")
	}
}

// clearPendingOnMembershipChange discards a body's pending m-of-n approvals.
//
// Approvals record approver ADDRESSES and are never re-validated at fire time,
// so a surviving entry lets a deposed moderator's signature still count toward
// the threshold — including toward an irreversible purge. Any change to WHO is
// in a set, or to HOW MANY of them must agree, therefore invalidates every
// approval collected under the old rule.
//
// This existed only as a comment and four hand-written copies of one line, and
// the three membership paths added later each forgot it (three identical
// adversarial reviewers found the same hole independently). Naming an invariant
// is not enforcing it; a helper every mutating path calls is.
func clearPendingOnMembershipChange(pending **bptree.BPTree) {
	*pending = bptree.NewBPTree32()
}

// Pending m-of-n approvals are DISCARDED whenever the set changes. They record
// approver addresses and are never re-validated at fire time, so a surviving
// entry lets a deposed moderator's signature still count toward the threshold —
// including toward an irreversible purge. Same reasoning for the global DAO.
//
// requireActiveMod additionally forbids the act while the set is suspended —
// a suspended set may only CLEAR its own bits (de-escalatory), never hide,
// annotate, seed, or fold (MODERATION.md §3.1).
func requireActiveMod(cm *courtMod, who address) {
	requireMod(cm, who)
	if cm.suspended {
		panic("kourtv2: this moderator set is suspended; only clearing its own bits is allowed")
	}
}

// isActiveMod answers what requireActiveMod refuses, without the panic: it is
// for the paths that PRICE a caller rather than stop them. A suspended set's
// member is deliberately not active here — a suspension leaves a set able only
// to clear its own bits, so while it holds, its members are strangers to
// everything else and pay a stranger's bond.
func isActiveMod(cm *courtMod, who address) bool {
	return !cm.suspended && cm.members.Has(who.String())
}

// requireEdgeRemover gates removal of a claim-to-claim edge: its author may
// always take it back, and so may an active moderator of the court.
//
// ONE COPY BECAUSE THIS BLOCK ALREADY DRIFTED. RemoveAssociation tested
// `c.mod == nil` where RemoveSupersede called ensureMod, and those are not the
// same question: a nil c.mod means nobody has moderated this court YET, not that
// it has no moderators — ensureMod seeds the creator. The old form refused a
// genuine moderator on every court where no folder had ever been filed, which is
// most of them, and contradicted RemoveAssociation's own doc comment. Fixing it
// meant copying this shape across, after which association.gno's note read "see
// supersede.gno for the full note" — a site that can only explain itself by
// pointing at another site.
//
// The membership test is spelled out rather than left to requireMod so the
// refusal keeps naming BOTH parties who may act. "not a moderator of this court"
// is true and unhelpful to someone who is simply not the author.
func requireEdgeRemover(c *Court, author, who address) {
	if author == who {
		return
	}
	cm := ensureMod(c)
	if !cm.members.Has(who.String()) {
		panic("kourtv2: only the edge's author or a court moderator may remove it")
	}
	requireActiveMod(cm, who)
}

// mustCategoryCode gates the statutory code every PURGE carries. Purge is the
// LEGAL removal — it erases text behind a code and takes a global-DAO threshold to
// fire — and the code is the record of WHY, so an empty one makes the act
// unauditable and an unbounded one makes the record itself the abuse.
//
// ONE SITE FOR FOUR VERBS. This block was written out inline in PurgeClaim,
// PurgeCourt, PurgeModLogRow and PurgeFolder, four byte-identical copies of the
// same three lines. None had drifted yet, which is the only reason collapsing them
// is a refactor and not a bug fix: two copies of one check is how the second comes
// to disagree with the first, and four copies on the realm's most
// authority-sensitive path is four chances. It also made the boundary unpinnable —
// a corpus row needs an anchor that matches once, and three identical texts in one
// file have none.
// mustCategoryCode bounds the code by LENGTH ONLY, deliberately, and the reason
// is worth stating because an alphabet here looks like an easy win and is not.
//
// Where this value ends up: emitPurge writes it into an event, and an event is
// permanent — so this is the one field on the purge path where a bad value cannot
// be undone afterwards. That argues for an alphabet at the door. Against it: the
// escaping at render is what actually defends the pages, it is TESTED on four
// surfaces with a code that forges structure, and `reason` sits beside this field
// carrying prose that can never be constrained at all. Narrowing the code would
// retire a live, exercised defence for one field while its free-text sibling
// keeps needing it — strengthening the lock on one of two doors.
//
// So the code stays free text and every surface escapes it. What callers get
// instead is this note: purge is m-of-n precisely because it is irreversible, and
// the code is the part of it that outlives the claim.
func mustCategoryCode(code string) {
	if len(code) == 0 || len(code) > maxReasonLen {
		panic("kourtv2: purge needs a statutory category code")
	}
}

func checkReason(reason string) {
	if len(reason) > maxReasonLen {
		panic("kourtv2: a moderation reason is at most 200 characters")
	}
}

func ensureClaimMod(c *Court, cm *courtMod, claimID uint64) *claimMod {
	_ = mustClaim(c, claimID) // the claim must exist
	k := beClaimKey(claimID)
	if v := cm.claims.Get(k); v != nil {
		return v.(*claimMod)
	}
	clm := &claimMod{}
	cm.claims.Set(k, clm)
	return clm
}

func lookupClaimMod(cm *courtMod, claimID uint64) *claimMod {
	if v := cm.claims.Get(beClaimKey(claimID)); v != nil {
		return v.(*claimMod)
	}
	return nil
}

// appendLog records an act and returns its rowID.
func (clm *claimMod) appendLog(actor address, code, reason string) uint64 {
	clm.logSeq++
	clm.log = append(clm.log, modAct{
		rowID:  clm.logSeq,
		actor:  actor,
		code:   code,
		reason: reason,
		height: heightNow(),
	})
	return clm.logSeq
}

// approveAction records who's approval for key and returns (fire, reason). When
// the m-th distinct member approves, the pending entry is cleared and fire=true;
// with m==1 the first call fires. Re-approving is a no-op (returns false).
//
// EXPIRY IS LAZY, AND ONLY LAZY — there is no sweep entrypoint, by design.
//
// The deadline is FIXED at the first approval, not slid forward by each new
// signer. Sliding would give an entry up to n×TTL of life (32 × 7 days ≈ 224
// days), reintroducing the problem; and a fixed death height is a public,
// deterministic function of chain state, identical for attacker and defender,
// which is what makes this unweaponisable. A permissionless sweep with a hard
// cutoff WOULD be a veto: watch for the m-th signature, front-run it, and the
// entry vanishes — profitably, since the storage refund pays the caller. Lazy
// eviction has no such surface. The predicate is only ever evaluated by a
// member already authorised for that exact key, and eviction is a REPLACEMENT,
// not a deletion: the evictor's own signature seeds the fresh entry, so they
// cannot leave the key empty. Racing to touch an already-expired key is not a
// veto, it is authorship of a new proposal, and the others can re-sign and fire
// in the same block.
//
// It is also the reclaim. The overwriting Set drops the old approval and its
// approvers tree in the same transaction, and gno refunds the released bytes to
// that caller — so every entry anyone revisits is collected automatically, and
// the entries nobody revisits are exactly the ones whose existence costs
// nothing. Expiry is silent: no cooldown, no cap, no event. Punishing a lapse
// would tax the honest first mover, and an m-of-n set whose members are afraid
// to sign first never acts at all.
func approveAction(pending *bptree.BPTree, key string, who address, reason string, m int) (bool, string) {
	now := heightNow()
	var a *approval
	if v := pending.Get(key); v != nil {
		a = v.(*approval)
		if now >= a.openedAt+pendingTTLBlocks {
			a = nil // stale by rule; this caller opens a fresh proposal
		}
	}
	if a == nil {
		a = &approval{approvers: bptree.NewBPTree32(), reason: reason, openedAt: now}
	}
	if a.approvers.Has(who.String()) {
		return false, ""
	}
	a.approvers.Set(who.String(), true)
	if a.approvers.Size() >= m {
		pending.Remove(key)
		return true, a.reason
	}
	pending.Set(key, a)
	return false, ""
}

// pendingOpenedAt is the height an OPEN m-of-n proposal started at, or 0 when
// there is none — either because nobody has signed yet or because the one on
// file has gone stale and approveAction is about to replace it.
//
// IT SITS HERE, TOUCHING approveAction, BECAUSE IT REPEATS THAT FUNCTION'S
// STALENESS RULE. One rule in two places is how the second copy comes to
// disagree with the first, and the cheapest available guard against it is
// adjacency: the two `openedAt+pendingTTLBlocks` tests are eight lines apart and
// a reader changing either sees the other. Returning it from approveAction would
// be better still and was rejected on cost — eleven callers and their corpus
// rows would move for one of them.
//
// WHAT NEEDS IT: a bulk act must consent to a FIXED set. DisapproveAllAssociations
// burns money, and between the first signature and the m-th a stranger may post
// an honest bond that no moderator has ever looked at. Bounding the burn to
// edges that predate the proposal is what keeps "unjudged means approved" true
// for them, and it is also what stops the mirror attack — a griefer who could
// invalidate the proposal by adding one edge a day would stall the remedy
// forever.
func pendingOpenedAt(pending *bptree.BPTree, key string) int64 {
	v := pending.Get(key)
	if v == nil {
		return 0
	}
	a := v.(*approval)
	if heightNow() >= a.openedAt+pendingTTLBlocks {
		return 0
	}
	return a.openedAt
}

// ---- court-moderator hide / unhide (m-of-n) -------------------------------

// HideItem removes a claim from this court's discovery surfaces. Render-layer:
// the claim's lifecycle is untouched, and it stays reachable by direct link
// (with a banner). m-of-n.
func HideItem(cur realm, courtSlug string, claimID uint64, reason string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireActiveMod(cm, who)
	checkReason(reason)
	_ = mustClaim(c, claimID) // the claim must exist, whether or not this fires
	// The re-hide cooldown (I8). Without reading executedAt, a moderator who
	// LOST an unhide appeal — after the appellant spent weeks and real bonds —
	// re-hid in the very next block for free, nullifying the restorative half of
	// the appeals layer. Global-DAO verbs and meta executions do not route here.
	// Read through lookupClaimMod: an absent row means no verdict ever landed.
	if clm := lookupClaimMod(cm, claimID); clm != nil && clm.executedAt != 0 &&
		heightNow() < clm.executedAt+c.params.votingBlocks {
		panic("kourtv2: a review verdict just cleared this; the set may not re-hide yet")
	}
	fire, r := approveAction(cm.pending, "hide:"+strconv.FormatUint(claimID, 10), who, reason, cm.m)
	if !fire {
		return
	}
	// Allocate only now that the act is FIRING. Allocating before the m-of-n
	// resolves let a single member of an m>1 set mint an empty claimMod per
	// claim — rows that carry no act, cost storage, and that renderModLog and
	// every claims-tree walk must then step over.
	clm := ensureClaimMod(c, cm, claimID)
	clm.court = true
	clm.appendLog(who, "hide", r)
	emitModAct(c.id, claimID, "hide", who)
}

// UnhideItem clears this court's own hide bit. Allowed even while suspended (it
// is strictly de-escalatory). m-of-n.
func UnhideItem(cur realm, courtSlug string, claimID uint64, reason string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireMod(cm, who) // NOT requireActiveMod — clearing own bits survives suspension
	checkReason(reason)
	clm := lookupClaimMod(cm, claimID)
	if clm == nil || !clm.court {
		panic("kourtv2: this court is not hiding that claim")
	}
	fire, r := approveAction(cm.pending, "unhide:"+strconv.FormatUint(claimID, 10), who, reason, cm.m)
	if !fire {
		return
	}
	clm.court = false
	clm.appendLog(who, "unhide", r)
	emitModAct(c.id, claimID, "unhide", who)
}

// ---- global DAO: redaction, clear-any recovery, purge ---------------------

// GlobalHide sets the all-surface text-redaction bit: on every surface the row
// renders banner + IDs + state + deadlines + money, no user text (MODERATION.md
// §3.2). Single-key to SET (legal speed); reason is a category code only. The
// DMCA disable-access verb.
func GlobalHide(cur realm, courtSlug string, claimID uint64, categoryCode string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	if !isGlobalMod(who) {
		panic("kourtv2: only a global DAO member may global-hide")
	}
	checkReason(categoryCode)
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	_ = mustClaim(c, claimID) // the claim must exist, whether or not this fires
	now := heightNow()
	// Windowed m-of-n re-set (round-4 F5): re-setting a redaction a global act
	// cleared within the counter-notice window needs m-of-n, so a lone rogue
	// key can't win the reversal race and camp a competitor redacted.
	if prev := lookupClaimMod(cm, claimID); prev != nil && !prev.global &&
		prev.globalClearedAt != 0 && now < prev.globalClearedAt+reSetWindowBlocks {
		d := ensureGlobalDAO()
		fire, _ := approveAction(d.pending, "reset:"+c.id+":"+strconv.FormatUint(claimID, 10), who, categoryCode, d.purgeM)
		if !fire {
			return
		}
	}
	clm := ensureClaimMod(c, cm, claimID) // only once the hide is certain
	clm.global = true
	clm.appendLog(who, "global-hide:"+categoryCode, "")
	emitGlobalAct(c.id, claimID, "global-hide", who)
}

// GlobalClear clears the global bit — the ONLY way it is reversed (never by
// silence/timer/meta). Explicit, logged. This is the DMCA put-back.
func GlobalClear(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	if !isGlobalMod(who) {
		panic("kourtv2: only a global DAO member may clear a global hide")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	clm := lookupClaimMod(cm, claimID)
	if clm == nil || !clm.global {
		panic("kourtv2: no global hide on that claim")
	}
	clm.global = false
	clm.globalClearedAt = heightNow()
	clm.appendLog(who, "global-clear", "")
	emitGlobalAct(c.id, claimID, "global-clear", who)
}

// ClearAnyBit is the recovery power: a global DAO member may clear ANY hide bit
// (courtMod or meta) and lift a court's suspension flag, so a captured meta
// court's bits/suspensions are always reversible (MODERATION.md §3.2, round-2).
func ClearAnyBit(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	if !isGlobalMod(who) {
		panic("kourtv2: only a global DAO member may clear bits (recovery)")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	clm := lookupClaimMod(cm, claimID)
	if clm == nil {
		panic("kourtv2: nothing to clear on that claim")
	}
	clm.court = false
	clm.meta = false
	clm.appendLog(who, "clear-any", "")
	emitGlobalAct(c.id, claimID, "clear-any", who)
}

// ClearCourtSuspension lifts a court's suspension flag (the recovery power
// reaching the flag, not just bits — round-2 M-A22).
func ClearCourtSuspension(cur realm, courtSlug string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	if !isGlobalMod(who) {
		panic("kourtv2: only a global DAO member may clear a suspension (recovery)")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	if !cm.suspended {
		panic("kourtv2: that court's set is not suspended")
	}
	cm.suspended = false
	cm.suspendActByGlobal = heightNow()
	emitGlobalAct(c.id, 0, "clear-suspension", who)
}

// PurgeClaim tombstones a claim's title behind a category code on EVERY surface
// (the one power that removes text). m-of-n. Irreversible, unappealable. Never
// touches a vote or lifecycle (I1/I2): the deposit still refunds, the verdict
// still settles — only the text is gone.
func PurgeClaim(cur realm, courtSlug string, claimID uint64, categoryCode string) {
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
	_ = mustClaim(c, claimID) // the claim must exist, whether or not this fires
	fire, code := approveAction(d.pending, "purge:"+c.id+":"+strconv.FormatUint(claimID, 10), who, categoryCode, d.purgeM)
	if !fire {
		return
	}
	clm := ensureClaimMod(c, cm, claimID) // only once the purge is certain
	clm.purged = true
	clm.tombstone = code
	if c.id == metaSlug {
		// A purge BEFORE the binding persists makes the appeal render-only; a
		// purge after it never blocks execution (meta.gno).
		poisonMetaParse(claimID)
	}
	clm.appendLog(who, "purge:"+code, "")
	emitPurge(c.id, claimID, code, who)
}

// GlobalSuspendSet lets the global DAO SET a court's suspension, not only clear
// it (setmods vet): the global verb set could previously only lower that flag,
// so a hostile-but-not-yet-replaceable set had no fast global disarm. m-of-n —
// disarming a court's moderation is consequential and is never time-critical
// the way a legal-hold hide is.
func GlobalSuspendSet(cur realm, courtSlug string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	d := ensureGlobalDAO()
	if !d.members.Has(who.String()) {
		panic("kourtv2: only a global DAO member may suspend a moderator set")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	if cm.suspended {
		panic("kourtv2: that set is already suspended")
	}
	fire, _ := approveAction(d.pending, "gsuspend:"+c.id, who, "", d.purgeM)
	if !fire {
		return
	}
	suspendSet(c, who)
	cm.suspendActByGlobal = heightNow()
	emitGlobalAct(c.id, 0, "global-suspend-set", who)
}

// ResetModSet is the SET-LEVEL global recovery verb (setmods vet, unanimous):
// `ClearAnyBit` is per-claim, so before this existed a hostile moderator set —
// e.g. puppets seated by a captured meta court — was globally irreversible, and
// the constitution's "backstopped by the global DAO" claim was false for
// installs. Whack-a-mole on individual bits does not work against a set that
// keeps setting new ones, and the only other set-level hammer was the nuclear,
// permanent PurgeCourt.
//
// It DISARMS rather than appoints: the set is emptied, so nobody can act until
// the court's own electorate installs one (or, if no election has yet unseated
// them, the creator re-appoints). That preserves subsidiarity — the global DAO
// gets a cure, never the power to choose a court's moderators. m-of-n, because
// wiping a set is consequential.
func ResetModSet(cur realm, courtSlug string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	d := ensureGlobalDAO()
	if !d.members.Has(who.String()) {
		panic("kourtv2: only a global DAO member may reset a moderator set")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	fire, _ := approveAction(d.pending, "resetmods:"+c.id, who, "", d.purgeM)
	if !fire {
		return
	}
	cm.members = bptree.NewBPTree32()
	cm.n = 0
	cm.m = 1                                    // n==0 means nobody is a member, so nothing can act
	clearPendingOnMembershipChange(&cm.pending) // stale approvals die with the set
	cm.suspended = false
	cm.setActHeight = heightNow()
	emitGlobalAct(c.id, 0, "reset-mod-set", who)
}

// PurgeCourt tombstones a whole court's text and gates new claims: on a purged
// court `OpenClaim`/`OpenClaimSeeded` refuse (constitution carve-out #2), so an
// illegal-theme court accretes no new content. Existing lifecycle still runs to
// completion (I1) — stakers unwind, verdicts settle, deposits refund; only new
// content and text are stopped. m-of-n.
func PurgeCourt(cur realm, courtSlug string, categoryCode string) {
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
	fire, code := approveAction(d.pending, "purgecourt:"+c.id, who, categoryCode, d.purgeM)
	if !fire {
		return
	}
	cm.courtPurged = true
	cm.courtTombstone = code
	emitPurge(c.id, 0, code, who)
}

// courtIsPurged is the OpenClaim gate (MODERATION.md §2 build guardrail: this
// is read ONLY by OpenClaim/OpenClaimSeeded, never by PostAnswer/Stake/withdraw,
// so no answered claim's stakers can ever strand).
func courtIsPurged(c *Court) bool {
	return c.mod != nil && c.mod.courtPurged
}

// CourtPurged is the render/test read.
func CourtPurged(courtSlug string) bool {
	return courtIsPurged(mustCourt(courtSlug))
}

// ---- meta / suspension internal hooks (called by ExecuteMetaVerdict) ------
// These are unexported: only module 7's verdict executor reaches them, after
// the I8 guards. They write only the meta bit / suspension flag — never money.

func setMetaBit(c *Court, claimID uint64, by address) {
	cm := ensureMod(c)
	clm := ensureClaimMod(c, cm, claimID)
	clm.meta = true
	clm.executedAt = heightNow()
	clm.appendLog(by, "meta-hide", "")
	emitModAct(c.id, claimID, "meta-hide", by)
}

func clearMetaBit(c *Court, claimID uint64, by address) {
	cm := ensureMod(c)
	clm := lookupClaimMod(cm, claimID)
	if clm == nil || !clm.meta {
		return // idempotent no-op
	}
	clm.meta = false
	clm.appendLog(by, "meta-clear", "")
	emitModAct(c.id, claimID, "meta-clear", by)
}

// clearCourtBitByMeta clears the courtMod bit via a meta unhide verdict. It
// stamps executedAt, which arms the I8 re-hide cooldown — that is what stops
// the losing set re-hiding in the next block for free. It does NOT stamp a
// "by a third party" marker: that refusal was removed deliberately (see
// verbUnhide in meta.gno), and the stamps for it are gone (v0.16).
func clearCourtBitByMeta(c *Court, claimID uint64, by address) {
	cm := ensureMod(c)
	clm := lookupClaimMod(cm, claimID)
	if clm == nil || !clm.court {
		return
	}
	clm.court = false
	clm.executedAt = heightNow()
	clm.appendLog(by, "meta-unhide", "")
	emitModAct(c.id, claimID, "meta-unhide", by)
}

func suspendSet(c *Court, by address) {
	cm := ensureMod(c)
	cm.suspended = true
	cm.suspendedAt = heightNow()
	cm.suspendedSetID = currentSetID(cm) // remember WHICH membership was judged
	cm.suspendedM = cm.m                 // ...and the decision rule it was judged under
	emitModAct(c.id, 0, "suspend", by)
}

// currentSetID is a canonical identity for a moderator set's MEMBERSHIP: its
// sorted members, and nothing else. Sets are stored canonically, so equal
// memberships produce equal IDs.
//
// The THRESHOLD is deliberately not part of this. It used to be, as an `m:`
// prefix, and folding the two into one string meant the suspension rule could
// only compare them together — which let a judged set loosen its own threshold
// and walk out of its suspension. installModSet weighs the two separately now,
// and both callers of this function (suspendSet, installModSet) are that rule.
func currentSetID(cm *courtMod) string {
	s := ""
	cm.members.Iterate("", "", func(k string, _ any) bool {
		s += k + ","
		return false
	})
	return s
}

func unsuspendSet(c *Court, by address) {
	cm := ensureMod(c)
	cm.suspended = false
	emitModAct(c.id, 0, "unsuspend", by)
}

// ---- reads (render + tests; never read by a money path) -------------------

// HiddenFromListing reports whether a claim is hidden from ordinary discovery
// surfaces — the union of all three bits. Strips (module 3) override this for
// policeable claims; this is the plain browse-listing predicate.
func HiddenFromListing(courtSlug string, claimID uint64) bool {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return false
	}
	clm := lookupClaimMod(c.mod, claimID)
	if clm == nil {
		return false
	}
	return clm.court || clm.meta || clm.global
}

// TextRedacted reports whether a claim's user text must be withheld on every
// surface (global hide or purge).
func TextRedacted(courtSlug string, claimID uint64) bool {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return false
	}
	clm := lookupClaimMod(c.mod, claimID)
	if clm == nil {
		return false
	}
	return clm.global || clm.purged
}

// ClaimPurged / ClaimTombstone expose the purge state for render.
func ClaimPurged(courtSlug string, claimID uint64) bool {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return false
	}
	clm := lookupClaimMod(c.mod, claimID)
	return clm != nil && clm.purged
}

// PurgeModLogRow tombstones ONE moderation-log row's text, addressed by its
// stable rowID. m-of-n, irreversible, unappealable — the same terms as
// PurgeClaim, because it is the same power (MODERATION.md I11).
//
// It exists because the moderation log is itself a text surface, and until now
// the only power that removes text could not reach it. A row's `reason` is FREE
// TEXT a moderator wrote: it can carry the very thing a purge was called in to
// remove — a name, a slur, a link — and "we removed the claim" is no answer
// when the removal notice repeats what it removed. The row itself stays, with
// its height, actor and act code, so the audit trail still shows that something
// happened and who did it; only the prose goes.
//
// renderModLog has honoured modAct.purged since it was written. Nothing set it,
// which is the inverse of the v0.16 sweep's complaint: state that LOOKS
// load-bearing but is never WRITTEN is the same hazard as one never read.
func PurgeModLogRow(cur realm, courtSlug string, claimID, rowID uint64, categoryCode string) {
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
	clm := lookupClaimMod(cm, claimID)
	if clm == nil {
		panic("kourtv2: that claim has no moderation log")
	}
	// Resolve the row BEFORE the vote, so an unreachable id is refused on the
	// first approval rather than after m-of-n has been spent on it.
	idx := -1
	for i := range clm.log {
		if clm.log[i].rowID == rowID {
			idx = i
			break
		}
	}
	if idx < 0 {
		panic("kourtv2: no such moderation-log row")
	}
	if clm.log[idx].purged {
		return // already tombstoned; a second purge is a no-op, not an error
	}
	key := "purgerow:" + c.id + ":" + strconv.FormatUint(claimID, 10) + ":" +
		strconv.FormatUint(rowID, 10)
	fire, code := approveAction(d.pending, key, who, categoryCode, d.purgeM)
	if !fire {
		return
	}
	clm.log[idx].purged = true
	clm.log[idx].reason = "" // gone from state, not merely hidden at render
	clm.appendLog(who, "purgerow:"+code, "")
	emitPurge(c.id, claimID, code, who)
}

// PendingApproval reports how many approvals an action key has collected and
// the height its window closes. A deadline nobody can see is a trap: a set that
// gathered signatures over six days needs to know it has one left.
//
// Non-allocating, and reports an already-expired entry as absent — the same
// answer approveAction will act on, so the read cannot disagree with the write
// path (the v0.19 rule). courtSlug "" reads the global DAO's tree.
func PendingApproval(courtSlug, actionKey string) (approvals int, expiresAt int64) {
	var pending *bptree.BPTree
	if courtSlug == "" {
		if globalDAO == nil {
			return 0, 0
		}
		pending = globalDAO.pending
	} else {
		c := mustCourt(courtSlug)
		if c.mod == nil {
			return 0, 0
		}
		pending = c.mod.pending
	}
	v := pending.Get(actionKey)
	if v == nil {
		return 0, 0
	}
	a := v.(*approval)
	if heightNow() >= a.openedAt+pendingTTLBlocks {
		return 0, 0
	}
	return a.approvers.Size(), a.openedAt + pendingTTLBlocks
}

// CourtSuspended reports whether a court's moderator set is suspended (masked).
func CourtSuspended(courtSlug string) bool {
	c := mustCourt(courtSlug)
	return c.mod != nil && c.mod.suspended
}

// IsCourtMod reports set membership (render shows the set; tests assert it).
//
// A court's moderation state is created LAZILY — ensureMod bootstraps the
// admin as a 1-of-1 on the first act — so before any act there is no object to
// read. Answering "no" then was wrong, and wrong in the direction that
// misleads: HideItem(admin) SUCCEEDS on a court whose IsCourtMod(admin) said
// false, so a UI would tell the one person who can moderate that they cannot.
// The read now reports the set the write path will actually act on. Found by
// the moderation txtar, which is the first thing to ask this question of a
// court that had not been moderated yet.
func IsCourtMod(courtSlug string, who address) bool {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return who == c.admin
	}
	return c.mod.members.Has(who.String())
}

// ModThreshold returns a court's m and n — 1-of-1 before the set materialises,
// for the same reason IsCourtMod does.
func ModThreshold(courtSlug string) (m, n int) {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return 1, 1
	}
	return c.mod.m, c.mod.n
}

// GlobalModCount is the size of the global DAO set.
func GlobalModCount() int {
	if globalDAO == nil {
		return 0
	}
	return globalDAO.n
}

// ModLogLen is how many log rows a claim's moderation has accrued.
func ModLogLen(courtSlug string, claimID uint64) int {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return 0
	}
	clm := lookupClaimMod(c.mod, claimID)
	if clm == nil {
		return 0
	}
	return len(clm.log)
}

// ---- events (metadata + category/act code only; never user text) ----------

func emitModAct(slug string, claimID uint64, code string, actor address) {
	chain.Emit(modActEvent,
		"court", slug,
		"claim", strconv.FormatUint(claimID, 10),
		"act", code,
		"by", actor.String(),
		"height", eventHeight(),
	)
}

func emitGlobalAct(slug string, claimID uint64, code string, actor address) {
	chain.Emit(globalActEvent,
		"court", slug,
		"claim", strconv.FormatUint(claimID, 10),
		"act", code,
		"by", actor.String(),
		"height", eventHeight(),
	)
}

func emitPurge(slug string, claimID uint64, categoryCode string, actor address) {
	chain.Emit(purgeEvent,
		"court", slug,
		"claim", strconv.FormatUint(claimID, 10),
		// Caller-supplied and bounded by LENGTH ONLY — see mustCategoryCode, which
		// says why there is no alphabet. It said "a statutory category enum, not
		// user text", which was wrong: nothing makes it an enum. The section header
		// above is still accurate, because a category code is what it allows.
		"code", categoryCode,
		"by", actor.String(),
		"height", eventHeight(),
	)
}
