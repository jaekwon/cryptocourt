// The court's own board sanctions (docs/CLAIM_BOARDS.md §7.2, §7.7).
//
// FOUR ACTS AND THEIR TWO UNDOS. Hide a row, slash standing, freeze an address
// out of the board, freeze one claim's board; restore standing, unfreeze. Each
// sanction takes `speechM`-of-n; each undo takes `requireMod`, not
// `requireActiveMod`, so a SUSPENDED set can still de-escalate — the same rule
// UnhideItem follows and for the same reason.
//
// NO ELECTION-WINDOW REFUSAL HERE YET, deliberately. §7.3's carve-out rests on
// two open owner rulings (§7.7): whether "parties of the contest" is
// actor-scoped or target-scoped, and whether a live sanction should lapse at
// `OpenElection` at all, given that registering a candidate set costs ~0.4 CC
// net and would clear your own sanction. Shipping either reading now would bake
// in a capture path. What ships is the half that does not depend on the answer.

package kourtv2

import "strconv"

const (
	// The ceiling on one freeze, below the 1-day nomination window rather than
	// the 7-day vote: the election is the remedy for a capturing set, so a
	// freeze must never outlast the chance to nominate against it.
	freezeMaxBlocks = int64(17_280) / 2 // ~12h at 17_280 blocks/day

	// The gap a court must leave between freezing the same address twice. Without
	// it, `freezeMaxBlocks` bounds nothing: a set re-freezes in the next block
	// and the ceiling becomes a per-transaction formality.
	freezeGapBlocks = freezeMaxBlocks
)

// mustBoardModInvariants runs at init over constants only, so it is in no
// mutation batch and cannot be made vacuous by a test fixture.
func mustBoardModInvariants() {
	if freezeMaxBlocks >= 17_280 {
		panic("kourtv2: a board freeze must expire inside the nomination window")
	}
	if freezeGapBlocks < freezeMaxBlocks {
		panic("kourtv2: the gap between freezes must be at least one freeze long, " +
			"or the ceiling is a formality")
	}
}

func init() { mustBoardModInvariants() }

// speechM is the threshold every board sanction fires at.
//
//	speechM = min(n, max(2, m))
//
// Never below the set's own m — a court that chose unanimity does not get a
// looser rule for speech — and never above n, which is what makes it satisfiable
// at every configuration the realm permits. On a 1-of-1 court it is 1, and that
// hands a solo creator no power they lacked: HideItem already fires at cm.m = 1
// and removes the whole claim, board included.
//
// Computed at the act site rather than at deploy because it reads per-court m
// and n, which no init() over package constants can see.
func speechM(cm *courtMod) int {
	m := cm.m
	if m < 2 {
		m = 2
	}
	if m > cm.n {
		m = cm.n
	}
	return m
}

// SpeechThreshold is the render/client read of the above.
func SpeechThreshold(courtSlug string) int {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return 0
	}
	return speechM(c.mod)
}

// ---- the sanction epoch ---------------------------------------------------

// boardSanctionEpochOf is what makes a freeze clearable in O(1).
//
// A FREEZE CARRIES THE EPOCH IT WAS SET UNDER, and is live only while that
// number still matches the court's. So `GlobalClearBoardBits` and a mod-set
// reset each clear every freeze in the court by incrementing one integer,
// instead of walking a tree of unknown size on the remedy path — which §7.5
// refuses everywhere else in this design for the same reason.
//
// Slashes are NOT covered: a slash is a changed number, not a bit, so undoing it
// takes the per-address `RestoreStanding` / `GlobalRestoreStanding`.
func boardSanctionEpochOf(c *Court) int64 {
	if c.mod == nil {
		return 0
	}
	return c.mod.boardSanctionEpoch
}

// boardFreezeActive and boardFreezeGapOpen are the address freeze's two clocks.
//
// BOTH ARE STORED FUTURE MOMENTS, so both carry a seconds twin written at the
// same instant as the height — the kind that cannot be reconstructed later,
// because the `now` they were derived from is gone.
//
// THEY CONVERT TOGETHER because the gap only bounds the freeze if the two are
// measured the same way. freezeGapBlocks equals freezeMaxBlocks precisely so a
// set cannot hold an address frozen indefinitely in twelve-hour increments; let
// one run on the clock and the other on blocks, and on a drifting chain the gap
// expires while the freeze is still live, which is the stacking the ceiling
// exists to prevent.
//
// The freeze's own duration is CALLER-SUPPLIED in blocks (FreezeBoard takes
// `blocks`, bounded by freezeMaxBlocks), so it converts at the write site.
//
// secs is 0 in both: these stamps ARE the deadline, not an event to add a window
// to. And note the PRESENCE check stays on frozenUntil in boardFrozen — that
// zero is "there is no freeze", not "the freeze expired", which is what makes
// UnfreezeBoard's single assignment still lift it.
func boardFreezeActive(r *standingRow) bool {
	passed, known := pastDeadline(r.frozenUntilTime, 0)
	return (known && !passed) || (!known && heightNow() < r.frozenUntil)
}

func boardFreezeGapOpen(r *standingRow) bool {
	passed, known := pastDeadline(r.frozenGapUntilTime, 0)
	return (known && !passed) || (!known && heightNow() < r.frozenGapUntil)
}

// boardFrozen reports whether who is frozen out of this court's boards. Expiry
// is LAZY — nothing sweeps, exactly as every other clock in this realm.
func boardFrozen(c *Court, who address) bool {
	r := lookupStanding(c, who)
	if r == nil || r.frozenUntil == 0 {
		return false
	}
	if r.frozenEpoch != boardSanctionEpochOf(c) {
		return false // cleared wholesale; the stamp is stale
	}
	return boardFreezeActive(r)
}

// boardFrozenAt is WHEN an address freeze lifts — the date the gate reads, with
// its reference height beside it — or (0, 0). Same relationship to boardFrozen
// that claimBoardFrozenAt has to claimBoardFrozen.
//
// Both, not either: the date is what the realm gates on and what a person can
// plan around, and the height is the reference (clock.gno's pairing). A freeze
// set before the stamps has no date, so `at` is 0 and only the height is
// knowable — the caller shows the block and says so.
func boardFrozenAt(c *Court, who address) (at, atHeight int64) {
	if !boardFrozen(c, who) {
		return 0, 0
	}
	r := lookupStanding(c, who)
	return r.frozenUntilTime, r.frozenUntil
}

// BoardFrozenUntil is the exported read: the date a freeze lifts and the height
// beside it, or (0, 0).
func BoardFrozenUntil(courtSlug string, who address) (at, atHeight int64) {
	return boardFrozenAt(mustCourt(courtSlug), who)
}

// claimFreezeActive and claimFreezeGapOpen are the claim-board freeze's two
// clocks — the exact mirror of boardFreezeActive/boardFreezeGapOpen above, on a
// claimMod instead of a standingRow. Same reasoning throughout: both are stored
// future moments, so both carry a twin written at the same instant; and they
// convert TOGETHER because freezeGapBlocks equals freezeMaxBlocks so that a set
// cannot re-close a board indefinitely in twelve-hour steps, which is a claim
// about the two windows' relative lengths and fails if only one moves.
//
// Two near-identical pairs rather than one generic pair: the records have no
// common type, and giving them one purely to share four lines would put a shape
// in the type system to serve a comment. The mirror is stated instead.
func claimFreezeActive(clm *claimMod) bool {
	passed, known := pastDeadline(clm.boardFrozenUntilTime, 0)
	return (known && !passed) || (!known && heightNow() < clm.boardFrozenUntil)
}

func claimFreezeGapOpen(clm *claimMod) bool {
	passed, known := pastDeadline(clm.boardFrozenGapUntilTime, 0)
	return (known && !passed) || (!known && heightNow() < clm.boardFrozenGapUntil)
}

// claimBoardFrozen reports whether ONE claim's board is closed by a moderator
// act. Same lazy expiry, same epoch stamp.
func claimBoardFrozen(c *Court, claimID uint64) bool {
	if c.mod == nil {
		return false
	}
	clm := lookupClaimMod(c.mod, claimID)
	if clm == nil || clm.boardFrozenUntil == 0 {
		return false
	}
	if clm.boardFrozenEpoch != c.mod.boardSanctionEpoch {
		return false
	}
	return claimFreezeActive(clm)
}

// claimBoardFrozenAt is the height a claim-board freeze lifts, or 0 — the same
// question claimBoardFrozen answers as a bool, for callers that must PRINT the
// deadline. One expression, so the page and the gate cannot disagree about
// whether a freeze is live.
func claimBoardFrozenAt(c *Court, claimID uint64) (at, atHeight int64) {
	if !claimBoardFrozen(c, claimID) {
		return 0, 0
	}
	clm := lookupClaimMod(c.mod, claimID)
	return clm.boardFrozenUntilTime, clm.boardFrozenUntil
}

// ClaimBoardFrozenUntil is the exported read: the date, with its height beside it.
func ClaimBoardFrozenUntil(courtSlug string, claimID uint64) (at, atHeight int64) {
	return claimBoardFrozenAt(mustCourt(courtSlug), claimID)
}

// ---- hide a row ------------------------------------------------------------

// HideBoardRow is the court's discovery-only hide of one comment, at speechM.
//
// NOT 1-of-n: the realm's own precedent for the identical act on a claim,
// HideItem, is m-of-n, and a board row is lower-stakes than a claim, not higher.
// The deep link still serves — this is the same bit an author sets on their own
// row, so a row hidden here reads exactly as one withdrawn, which is why the
// LEGAL verbs in boardlegal.gno exist separately.
func HideBoardRow(cur realm, courtSlug string, claimID, rowID uint64, code string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireActiveMod(cm, who)
	mustBoardCode(code)
	cs := mustClaim(c, claimID)
	r := mustBoardRow(cs, rowID)
	if r.hiddenByMod {
		panic("kourtv2: that comment is already hidden")
	}
	fire, _ := approveAction(cm.pending,
		"boardhide:"+strconv.FormatUint(claimID, 10)+":"+strconv.FormatUint(rowID, 10),
		who, code, speechM(cm))
	if !fire {
		return
	}
	r.hiddenByMod = true
	scoreIndexDrop(cs, r)
	ensureClaimMod(c, cm, claimID).
		appendLog(who, boardActCode("board-hide", rowID, code), "")
	emitModAct(c.id, claimID, "board-hide", who)
}

// UnhideBoardRow clears it. requireMod, not requireActiveMod: de-escalation must
// outlive a suspension, or a suspended set's mistakes become permanent.
func UnhideBoardRow(cur realm, courtSlug string, claimID, rowID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireMod(cm, who)
	cs := mustClaim(c, claimID)
	r := mustBoardRow(cs, rowID)
	if !r.hiddenByMod {
		panic("kourtv2: that comment is not hidden")
	}
	fire, _ := approveAction(cm.pending,
		"boardunhide:"+strconv.FormatUint(claimID, 10)+":"+strconv.FormatUint(rowID, 10),
		who, "", speechM(cm))
	if !fire {
		return
	}
	// The MODERATOR's bit only. scoreIndexPut gates on boardMark, so a row whose
	// author has also withdrawn it stays out of the ranked index — an unhide must
	// not republish what its author withdrew.
	r.hiddenByMod = false
	scoreIndexPut(cs, r)
	ensureClaimMod(c, cm, claimID).
		appendLog(who, boardActCode("board-unhide", rowID, ""), "")
	emitModAct(c.id, claimID, "board-unhide", who)
}

// ---- slash standing --------------------------------------------------------

// SlashStanding ratchets one address down by WHOLE LEVELS.
//
// WHOLE LEVELS, NOT A PERCENTAGE. A percentage is a different sanction at every
// court size and at every point on the ladder — 20% of a top-rung score is
// several rungs on a small court and none on a large one. A level is the unit
// the whole design is denominated in: it is what the ladder gates, what the
// throttle prices, and what the person can see on their own page.
//
// It never touches `highWater`, which is what makes the act reversible: a
// successor set raises `score` back toward that number. The asymmetry is the
// entire safety argument, since there is no appeals lane for a board sanction.
func SlashStanding(cur realm, courtSlug string, who address, levels int64, code string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	actor := cur.Previous().Address()
	if levels < 1 || levels > 3 {
		panic("kourtv2: a slash is 1, 2 or 3 whole levels")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireActiveMod(cm, actor)
	mustBoardCode(code)
	if who == "" {
		panic("kourtv2: no such address")
	}
	fire, voted := approveAction(cm.pending,
		"slash:"+who.String()+":"+strconv.FormatInt(levels, 10),
		actor, code, speechM(cm))
	if !fire {
		return
	}
	r := getStanding(c, who)
	target := postLevel(c, who) - levels
	if target < 0 {
		target = 0
	}
	// The score that sits exactly AT the target rung, so the address lands on it
	// rather than somewhere inside it. At target 0 that is zero standing.
	if want := levelFloor(c, target); r.score > want {
		r.score = want
	}
	// A SLASH TO ZERO FORFEITS THE PASS, and without this line the whole sanction
	// is defeated for 0.1 CC. postLevel floors a pass-holder at level 1, so an
	// address that bought one could be slashed to zero standing and still post at
	// entry rate forever — leaving the freeze as the only remaining sanction, and
	// that is bounded at 12h with a 12h gap, i.e. a 50% duty cycle no court can
	// close. Forfeiture rather than refund is the realm's own rule for a
	// misused stake, and the burn already happened: nothing is returned here,
	// the entitlement is simply spent.
	//
	// Only at target ZERO. A slash from 3 to 2 leaves the pass alone, because a
	// partial sanction that silently destroyed a purchase would be a bigger act
	// than the one the moderators voted for.
	if target == 0 {
		r.passHeld = false
	}
	// THE VERB IN `code`, THE VOTED CATEGORY IN `reason` — the shape claimMod's
	// log already uses, and the reason PurgeCourtLogRow has anything to destroy.
	// Folding both into one string left the reason field permanently empty, which
	// made that verb's own "the reason leaves state" line dead code.
	cm.appendCourtLog(actor, "slash:"+strconv.FormatInt(levels, 10), voted)
	emitModAct(c.id, 0, "slash", actor)
}

// levelFloor is the score that just reaches level `lv`. Level 0's floor is 0.
//
// ONE READER OF THE LADDER THRESHOLDS BESIDES postLevel, and it must agree with
// it or a slash to level 1 can land at level 0 or 2. Expressed with the same
// `sup*bps/10_000` shape for that reason.
func levelFloor(c *Court, lv int64) int64 {
	if lv <= 0 {
		return 0
	}
	l := ladderFor(c)
	// boardSupply returns 0 for a court with no sealed epoch, and 0*bps/10_000 is
	// 0, so every rung is already 0 there. No second guard: it would be one this
	// corpus cannot catch, because it cannot change an answer.
	sup, _ := boardSupply(c)
	switch lv {
	case 1:
		return sup * l.t1Bps / 10_000
	case 2:
		return sup * l.t2Bps / 10_000
	}
	return sup * l.t3Bps / 10_000
}

// RestoreStanding raises a score back toward `highWater` and never past it.
//
// requireMod, so a suspended set can still repair. And CLAMPED rather than
// checked: a restore that panicked above the high water would make the caller
// guess the number, and the whole point of storing it is that nobody has to.
func RestoreStanding(cur realm, courtSlug string, who address) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	actor := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireMod(cm, actor)
	r := lookupStanding(c, who)
	if r == nil || r.score >= r.highWater {
		panic("kourtv2: that address has nothing to restore")
	}
	fire, _ := approveAction(cm.pending, "restore:"+who.String(), actor, "",
		speechM(cm))
	if !fire {
		return 0
	}
	r.score = r.highWater
	cm.appendCourtLog(actor, "restore", "")
	emitModAct(c.id, 0, "restore", actor)
	return r.score
}

// ---- freeze ----------------------------------------------------------------

// FreezeBoard bars one address from BOARD WRITES ONLY, for a bounded time.
//
// THE ALLOWLIST IS EVERYTHING ELSE, and it is explicit because the election is
// the remedy: a frozen address still stakes, votes, answers, disputes, flags,
// opens claims, withdraws, draws emission, and takes every election action. A
// freeze that reached any of those would let a set silence the vote that removes
// it, which is the one thing this power must never be able to do.
func FreezeBoard(cur realm, courtSlug string, who address, blocks int64, code string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	actor := cur.Previous().Address()
	if blocks < 1 || blocks > freezeMaxBlocks {
		panic("kourtv2: a board freeze is at most freezeMaxBlocks long")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireActiveMod(cm, actor)
	mustBoardCode(code)
	if who == "" {
		panic("kourtv2: no such address")
	}
	now := heightNow()
	// The GAP, read before the m-of-n so a refused proposal cannot be used to
	// probe it. A set that could re-freeze in the next block would make
	// freezeMaxBlocks a per-transaction formality rather than a ceiling.
	// Read from frozenGapUntil, NOT from frozenUntil and NOT gated on the epoch.
	// Both of those were wrong: the undo clears frozenUntil, and the recovery verb
	// bumps the epoch, so either one handed the set a fresh window. See the
	// field's own note in standing.gno.
	if r := lookupStanding(c, who); r != nil && boardFreezeGapOpen(r) {
		panic("kourtv2: this address was frozen too recently; the ceiling is not a formality")
	}
	fire, voted := approveAction(cm.pending, "freeze:"+who.String(), actor, code,
		speechM(cm))
	if !fire {
		return
	}
	r := getStanding(c, who)
	r.frozenUntil = now + blocks
	r.frozenUntilTime = nowTime() + blocksToSecs(blocks)
	r.frozenEpoch = boardSanctionEpochOf(c)
	// Stamped at the FULL ceiling, not at the requested length: a set that asks
	// for one block must not thereby earn a shorter cooldown than one that asks
	// for twelve hours, or the gap is bought off with short freezes.
	r.frozenGapUntil = now + freezeMaxBlocks + freezeGapBlocks
	r.frozenGapUntilTime = nowTime() + blocksToSecs(freezeMaxBlocks+freezeGapBlocks)
	cm.appendCourtLog(actor, "freeze:"+strconv.FormatInt(blocks, 10), voted)
	emitModAct(c.id, 0, "freeze", actor)
}

// UnfreezeBoard lifts it early. requireMod: de-escalation survives suspension.
func UnfreezeBoard(cur realm, courtSlug string, who address) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	actor := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireMod(cm, actor)
	if !boardFrozen(c, who) {
		panic("kourtv2: that address is not frozen")
	}
	fire, _ := approveAction(cm.pending, "unfreeze:"+who.String(), actor, "",
		speechM(cm))
	if !fire {
		return
	}
	lifted := lookupStanding(c, who)
	lifted.frozenUntil = 0
	lifted.frozenUntilTime = 0
	cm.appendCourtLog(actor, "unfreeze", "")
	emitModAct(c.id, 0, "unfreeze", actor)
}

// FreezeClaimBoard closes ONE claim's board, auto-expiring. The claim itself
// stays fully live: answers, stakes, votes and the verdict are untouched.
func FreezeClaimBoard(cur realm, courtSlug string, claimID uint64, blocks int64, code string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	actor := cur.Previous().Address()
	if blocks < 1 || blocks > freezeMaxBlocks {
		panic("kourtv2: a board freeze is at most freezeMaxBlocks long")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireActiveMod(cm, actor)
	mustBoardCode(code)
	_ = mustClaim(c, claimID)
	now := heightNow()
	// The gap, read before the m-of-n so a refused proposal cannot probe it —
	// and stamped at the full ceiling below, so a one-block freeze does not buy
	// a one-block cooldown.
	if prev := lookupClaimMod(cm, claimID); prev != nil && claimFreezeGapOpen(prev) {
		panic("kourtv2: this board was frozen too recently; the ceiling is not a formality")
	}
	fire, _ := approveAction(cm.pending,
		"freezeboard:"+strconv.FormatUint(claimID, 10), actor, code, speechM(cm))
	if !fire {
		return
	}
	clm := ensureClaimMod(c, cm, claimID)
	clm.boardFrozenUntil = now + blocks
	clm.boardFrozenUntilTime = nowTime() + blocksToSecs(blocks)
	clm.boardFrozenEpoch = cm.boardSanctionEpoch
	clm.boardFrozenGapUntil = now + freezeMaxBlocks + freezeGapBlocks
	clm.boardFrozenGapUntilTime = nowTime() + blocksToSecs(freezeMaxBlocks+freezeGapBlocks)
	clm.appendLog(actor, "freezeboard:"+strconv.FormatInt(blocks, 10)+":"+code, "")
	emitModAct(c.id, claimID, "freezeboard", actor)
}

// ThawClaimBoard reopens it early. requireMod.
func ThawClaimBoard(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	actor := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireMod(cm, actor)
	if !claimBoardFrozen(c, claimID) {
		panic("kourtv2: that board is not frozen")
	}
	fire, _ := approveAction(cm.pending,
		"thawboard:"+strconv.FormatUint(claimID, 10), actor, "", speechM(cm))
	if !fire {
		return
	}
	thawed := lookupClaimMod(cm, claimID)
	thawed.boardFrozenUntil = 0
	thawed.boardFrozenUntilTime = 0
	ensureClaimMod(c, cm, claimID).appendLog(actor, "thawboard", "")
	emitModAct(c.id, claimID, "thawboard", actor)
}

// ---- the global backstop ---------------------------------------------------

// GlobalClearBoardBits clears EVERY live board freeze in a court at once.
//
// THE PER-BATCH RECOVERY ClearAnyBit CANNOT REACH. ClearAnyBit is claim-keyed, so
// against a set that froze two hundred addresses it is two hundred transactions
// on the remedy path. One integer does it here, which is also why it is O(1)
// rather than a walk — see boardSanctionEpochOf.
//
// Slashes are untouched: those are numbers, not bits, and each takes
// GlobalRestoreStanding.
func GlobalClearBoardBits(cur realm, courtSlug string) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	if !isGlobalMod(who) {
		panic("kourtv2: only a global DAO member may clear board bits (recovery)")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	cm.boardSanctionEpoch++
	// THE COURT'S OWN LOG, not only an event. Every other global verb in this
	// lane writes one, and these two — the verbs that UNDO a court's sanctions —
	// did not. A reader of /mod saw the slash and the freeze recorded and no
	// trace that the platform reversed them: the accusation without the
	// acquittal. The log is how curation becomes visible after the fact, and an
	// intervention nobody can see is worth less than one nobody made.
	cm.appendCourtLog(who, "global-clear-board-bits", "")
	emitGlobalAct(c.id, 0, "clear-board-bits", who)
	return cm.boardSanctionEpoch
}

// GlobalRestoreStanding is the same repair as RestoreStanding, reachable when the
// court's own set is the problem. Clamped to highWater identically — the global
// DAO gets no power to MINT standing, only to put back what a slash took.
func GlobalRestoreStanding(cur realm, courtSlug string, who address) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	actor := cur.Previous().Address()
	if !isGlobalMod(actor) {
		panic("kourtv2: only a global DAO member may restore standing (recovery)")
	}
	c := mustCourt(courtSlug)
	r := lookupStanding(c, who)
	if r == nil || r.score >= r.highWater {
		panic("kourtv2: that address has nothing to restore")
	}
	r.score = r.highWater
	ensureMod(c).appendCourtLog(actor, "global-restore-standing", "")
	emitGlobalAct(c.id, 0, "restore-standing", actor)
	return r.score
}

// mustBoardWritable is the ONE place the two freezes are read, and every board
// write goes through it.
//
// A SINGLE CHOKEPOINT rather than a pair of checks at each entrypoint: two
// freezes times two write verbs is four call sites that have to stay in
// agreement, and the third write verb added later is the one that forgets. The
// address freeze and the claim-board freeze are separate powers with separate
// undos, so they are checked in one function rather than merged into one flag.
func mustBoardWritable(c *Court, cs *claimState, who address) {
	if claimBoardFrozen(c, cs.id) {
		panic("kourtv2: this claim's board is frozen by moderators")
	}
	if boardFrozen(c, who) {
		panic("kourtv2: you are frozen out of this court's boards")
	}
}

// PurgeCourtLogRow tombstones ONE court-level log row's reason.
//
// ITS OWN VERB, because the two logs have separate sequences: PurgeModLogRow
// takes a claim id and a row id, and a court row has no claim. Sharing one verb
// would mean a sentinel claim id, and a sentinel that means "not a claim" on a
// path that also accepts real claim ids is how the wrong row gets destroyed.
func PurgeCourtLogRow(cur realm, courtSlug string, rowID uint64, categoryCode string) {
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
	// Resolve the row BEFORE the vote, so an unreachable id is refused on the
	// first approval rather than after m-of-n has been spent on it.
	idx := -1
	for i := range cm.log {
		if cm.log[i].rowID == rowID {
			idx = i
			break
		}
	}
	if idx < 0 {
		panic("kourtv2: no such court log row")
	}
	if cm.log[idx].purged {
		return // already tombstoned; a second purge is a no-op, not an error
	}
	fire, code := approveAction(d.pending,
		"purgecourtrow:"+c.id+":"+strconv.FormatUint(rowID, 10),
		who, categoryCode, d.purgeM)
	if !fire {
		return
	}
	cm.log[idx].purged = true
	cm.log[idx].reason = "" // gone from state, not merely hidden at render
	cm.appendCourtLog(who, "purgecourtrow:"+code, "")
	emitPurge(c.id, 0, code, who)
}

// GlobalClearCourtParams drops BOTH per-court parameter overrides at once.
//
// THE BACKSTOP THAT DID NOT EXIST. Every other board power a set holds is
// reversible by the global DAO — freezes by GlobalClearBoardBits, slashes by
// GlobalRestoreStanding, hides by GlobalClearRow — which is what S10 requires.
// The two parameter overrides had no such verb, and their own Clear verbs were
// reachable only by the set that set them. So a captured set could throttle a
// whole court's board permanently and the platform's only answer was to suspend
// or reset the set, neither of which touched the numbers.
//
// One verb for both, because it is a recovery hammer rather than a tuning knob,
// and single-key like the other recovery reads: a redaction that must not be
// set alone is a different act from an override that must not be LEFT alone.
func GlobalClearCourtParams(cur realm, courtSlug string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	if !isGlobalMod(who) {
		panic("kourtv2: only a global DAO member may clear court parameters (recovery)")
	}
	c := mustCourt(courtSlug)
	if c.ladder == nil && c.creditRates == nil {
		panic("kourtv2: this court has no parameter overrides")
	}
	c.ladder, c.creditRates = nil, nil
	ensureMod(c).appendCourtLog(who, "global-clear-params", "")
	emitGlobalAct(c.id, 0, "clear-court-params", who)
}
