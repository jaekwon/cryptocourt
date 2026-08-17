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
package courtv2

import (
	"chain"
	"chain/runtime"
	"strconv"

	bptree "gno.land/p/nt/bptree/v0"
)

const (
	maxReasonLen = 200
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
	if directoryAdmin == "" {
		panic("courtv2: no court exists yet; the global DAO has no admin")
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
		panic("courtv2: only the global DAO admin manages membership")
	}
	if !d.members.Has(who.String()) {
		d.members.Set(who.String(), true)
		d.n++
	}
}

func RemoveGlobalMod(cur realm, who address) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("courtv2: only the global DAO admin manages membership")
	}
	if who == d.admin {
		panic("courtv2: the admin cannot be removed; transfer admin first")
	}
	if d.members.Has(who.String()) {
		d.members.Remove(who.String())
		d.n--
		if d.purgeM > d.n {
			d.purgeM = d.n
		}
	}
}

// SetPurgeThreshold sets m for the m-of-n purge/re-set rule, 1..n.
func SetPurgeThreshold(cur realm, m int) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("courtv2: only the global DAO admin sets the purge threshold")
	}
	if m < 1 || m > d.n {
		panic("courtv2: the purge threshold must be in 1..n")
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
		panic("courtv2: only the global DAO admin transfers the seat")
	}
	if !d.members.Has(to.String()) {
		d.members.Set(to.String(), true)
		d.n++
	}
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

	suspended      bool
	suspendedAt    int64
	setActHeight   int64 // last membership change (for the meta staleness stamp)
	lastElectionAt int64

	courtPurged    bool   // whole-court text tombstone (global DAO, m-of-n)
	courtTombstone string // the category code

	claims  *bptree.BPTree // claimID (be64) -> *claimMod
	pending *bptree.BPTree // actionKey -> *approval

	folders   *bptree.BPTree // folderID (be64) -> *folder (folders.gno)
	folderSeq uint64

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

	// Per-bit last-act height, split by actor CLASS so a respondent's own act
	// never sets the refusing stamp the meta staleness guard reads (§3.3 g4).
	courtActByOthers int64 // global/meta writes to the court bit
	metaActByOthers  int64
	globalActHeight  int64
	globalClearedAt  int64 // for the windowed-m-of-n re-set rule
	executedAt       int64 // meta-verdict cooldown anchor (module 7)

	stripEnteredAt int64 // strip membership key (module 3); 0 = not resident

	logSeq uint64
	log    []modAct
}

// modAct is one append-only moderation-log row. rowID lets purge address a
// single row. code is a category/act code (an enum), never user text; reason
// is the stored (sanitized-at-render) text, purgeable.
type modAct struct {
	rowID  uint64
	actor  address
	code   string
	reason string
	height int64
	purged bool
}

// approval accumulates distinct-member approvals for an m-of-n action.
type approval struct {
	approvers *bptree.BPTree // addr -> true
	reason    string
	actor0    address
	height    int64
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
func AppointMods(cur realm, courtSlug string, mods []address, m int) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	if cur.Previous().Address() != c.admin {
		panic("courtv2: only the court creator appoints moderators (until an election)")
	}
	if len(mods) == 0 {
		panic("courtv2: a moderator set may not be empty")
	}
	if m < 1 || m > len(mods) {
		panic("courtv2: the m-of-n threshold must be in 1..len(mods)")
	}
	cm := ensureMod(c)
	fresh := bptree.NewBPTree32()
	n := 0
	for _, a := range mods {
		if a == "" {
			panic("courtv2: a moderator address may not be zero")
		}
		if !fresh.Has(a.String()) {
			fresh.Set(a.String(), true)
			n++
		}
	}
	cm.members = fresh
	cm.n = n
	cm.m = m
	cm.setActHeight = runtime.ChainHeight()
}

func requireMod(cm *courtMod, who address) {
	if !cm.members.Has(who.String()) {
		panic("courtv2: not a moderator of this court")
	}
}

// requireActiveMod additionally forbids the act while the set is suspended —
// a suspended set may only CLEAR its own bits (de-escalatory), never hide,
// annotate, seed, or fold (MODERATION.md §3.1).
func requireActiveMod(cm *courtMod, who address) {
	requireMod(cm, who)
	if cm.suspended {
		panic("courtv2: this moderator set is suspended; only clearing its own bits is allowed")
	}
}

func checkReason(reason string) {
	if len(reason) > maxReasonLen {
		panic("courtv2: a moderation reason is at most 200 characters")
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
		height: runtime.ChainHeight(),
	})
	return clm.logSeq
}

// approveAction records who's approval for key and returns (fire, reason). When
// the m-th distinct member approves, the pending entry is cleared and fire=true;
// with m==1 the first call fires. Re-approving is a no-op (returns false).
func approveAction(pending *bptree.BPTree, key string, who address, reason string, m int) (bool, string) {
	var a *approval
	if v := pending.Get(key); v != nil {
		a = v.(*approval)
	} else {
		a = &approval{approvers: bptree.NewBPTree32(), reason: reason, actor0: who, height: runtime.ChainHeight()}
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
	clm := ensureClaimMod(c, cm, claimID)
	fire, r := approveAction(cm.pending, "hide:"+strconv.FormatUint(claimID, 10), who, reason, cm.m)
	if !fire {
		return
	}
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
		panic("courtv2: this court is not hiding that claim")
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
		panic("courtv2: only a global DAO member may global-hide")
	}
	checkReason(categoryCode)
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	clm := ensureClaimMod(c, cm, claimID)
	now := runtime.ChainHeight()
	// Windowed m-of-n re-set (round-4 F5): re-setting a redaction a global act
	// cleared within the counter-notice window needs m-of-n, so a lone rogue
	// key can't win the reversal race and camp a competitor redacted.
	if !clm.global && clm.globalClearedAt != 0 && now < clm.globalClearedAt+reSetWindowBlocks {
		d := ensureGlobalDAO()
		fire, _ := approveAction(d.pending, "reset:"+c.id+":"+strconv.FormatUint(claimID, 10), who, categoryCode, d.purgeM)
		if !fire {
			return
		}
	}
	clm.global = true
	clm.globalActHeight = now
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
		panic("courtv2: only a global DAO member may clear a global hide")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	clm := lookupClaimMod(cm, claimID)
	if clm == nil || !clm.global {
		panic("courtv2: no global hide on that claim")
	}
	clm.global = false
	clm.globalClearedAt = runtime.ChainHeight()
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
		panic("courtv2: only a global DAO member may clear bits (recovery)")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	clm := lookupClaimMod(cm, claimID)
	if clm == nil {
		panic("courtv2: nothing to clear on that claim")
	}
	now := runtime.ChainHeight()
	clm.court = false
	clm.meta = false
	clm.courtActByOthers = now
	clm.metaActByOthers = now
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
		panic("courtv2: only a global DAO member may clear a suspension (recovery)")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	if !cm.suspended {
		panic("courtv2: that court's set is not suspended")
	}
	cm.suspended = false
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
		panic("courtv2: only a global DAO member may purge")
	}
	if len(categoryCode) == 0 || len(categoryCode) > maxReasonLen {
		panic("courtv2: purge needs a statutory category code")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	clm := ensureClaimMod(c, cm, claimID)
	fire, code := approveAction(d.pending, "purge:"+c.id+":"+strconv.FormatUint(claimID, 10), who, categoryCode, d.purgeM)
	if !fire {
		return
	}
	clm.purged = true
	clm.tombstone = code
	clm.appendLog(who, "purge:"+code, "")
	emitPurge(c.id, claimID, code, who)
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
		panic("courtv2: only a global DAO member may purge")
	}
	if len(categoryCode) == 0 || len(categoryCode) > maxReasonLen {
		panic("courtv2: purge needs a statutory category code")
	}
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

// onTitleEdited is called by EditClaimTitle so the meta court can re-parse a
// `mod:` appeal's title while it is still editable (MODERATION.md §3.3). No-op
// for ordinary courts; the meta module (module 7) fills in the parse for the
// meta court's own claims.
func onTitleEdited(c *Court, cs *claimState) {
	// meta-parser re-run lands here in the meta module.
}

// ---- meta / suspension internal hooks (called by ExecuteMetaVerdict) ------
// These are unexported: only module 7's verdict executor reaches them, after
// the I8 guards. They write only the meta bit / suspension flag — never money.

func setMetaBit(c *Court, claimID uint64, by address) {
	cm := ensureMod(c)
	clm := ensureClaimMod(c, cm, claimID)
	clm.meta = true
	clm.executedAt = runtime.ChainHeight()
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

// clearCourtBitByMeta clears the courtMod bit via a meta unhide verdict. Marks
// the transition as by-a-third-party so the staleness guard (module 7) treats
// it correctly.
func clearCourtBitByMeta(c *Court, claimID uint64, by address) {
	cm := ensureMod(c)
	clm := lookupClaimMod(cm, claimID)
	if clm == nil || !clm.court {
		return
	}
	clm.court = false
	clm.courtActByOthers = runtime.ChainHeight()
	clm.executedAt = runtime.ChainHeight()
	clm.appendLog(by, "meta-unhide", "")
	emitModAct(c.id, claimID, "meta-unhide", by)
}

func suspendSet(c *Court, by address) {
	cm := ensureMod(c)
	cm.suspended = true
	cm.suspendedAt = runtime.ChainHeight()
	emitModAct(c.id, 0, "suspend", by)
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

// CourtSuspended reports whether a court's moderator set is suspended (masked).
func CourtSuspended(courtSlug string) bool {
	c := mustCourt(courtSlug)
	return c.mod != nil && c.mod.suspended
}

// IsCourtMod reports set membership (render shows the set; tests assert it).
func IsCourtMod(courtSlug string, who address) bool {
	c := mustCourt(courtSlug)
	return c.mod != nil && c.mod.members.Has(who.String())
}

// ModThreshold returns a court's m and n.
func ModThreshold(courtSlug string) (m, n int) {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return 0, 0
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
		"height", strconv.FormatInt(runtime.ChainHeight(), 10),
	)
}

func emitGlobalAct(slug string, claimID uint64, code string, actor address) {
	chain.Emit(globalActEvent,
		"court", slug,
		"claim", strconv.FormatUint(claimID, 10),
		"act", code,
		"by", actor.String(),
		"height", strconv.FormatInt(runtime.ChainHeight(), 10),
	)
}

func emitPurge(slug string, claimID uint64, categoryCode string, actor address) {
	chain.Emit(purgeEvent,
		"court", slug,
		"claim", strconv.FormatUint(claimID, 10),
		"code", categoryCode, // a statutory category enum, not user text
		"by", actor.String(),
		"height", strconv.FormatInt(runtime.ChainHeight(), 10),
	)
}
