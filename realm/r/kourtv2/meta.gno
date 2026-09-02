// The meta court: the appeals layer (MODERATION.md §3.3).
//
// It is not a special authority bolted onto moderation — it IS a court,
// deployed at realm init under the reserved slug "meta", and it decides appeals
// through the same bonded machinery every other claim uses: answer bond → 72h →
// optional dispute → sealed vote → verdict. What makes a claim an appeal is
// only its title: a reserved `mod:` schema naming a verb and a target. When
// such a claim reaches a final YES verdict, anyone may execute it, and the
// execution flips a render-layer bit (or replaces a moderator set).
//
// Everything here is bounded by the constitution: an execution can hide, unhide,
// suspend, or reseat — it can never move a coin. A captured meta court censors
// discovery and nothing else, and the global DAO can undo every one of its acts
// (ClearAnyBit, ClearCourtSuspension, ResetModSet).
//
// The guard set is the expensive part. Three independent adversarial vets shaped
// it, and every guard below exists because a specific attack got through
// without it — the comments name them.

package kourtv2

import (
	"chain"
	"strconv"
	"strings"

	unsafe "chain/runtime/unsafe"

	"math/overflow"

	bptree "gno.land/p/nt/bptree/v0"
)

// realmPath is this realm's own package path — the same one buy.gno derives its
// burn sink from. init cannot ask `cur` for the realm address, so the escrow
// address is derived from the path instead.
const metaRealmPath = "gno.land/r/kourt/kourtv2"

const (
	metaPrefix   = "mod:"
	metaCourtNm  = "Review Court"
	metaExecuted = "MetaExecuted"
)

// The verbs. Restorative verbs may execute from the undisputed (silence) route:
// silence may RESTORE visibility. Aggressive verbs may not — silence must never
// remove visibility, disarm a court, re-arm one, or reseat its moderators.
const (
	verbUnhide    = "unhide"    // restorative: clear the courtMod bit
	verbClear     = "clear"     // restorative: clear the meta bit
	verbHide      = "hide"      // aggressive: set the meta bit
	verbSuspend   = "suspend"   // aggressive: disarm a moderator set
	verbUnsuspend = "unsuspend" // aggressive: re-arm one (it re-applies masked hides)
	verbSetmods   = "setmods"   // aggressive: install a moderator set
)

func verbIsAggressive(v string) bool {
	return v == verbHide || v == verbSuspend || v == verbUnsuspend || v == verbSetmods
}

// modParse is a claim title parsed into a binding instruction. It is STORED
// STRUCTURED STATE, not re-derived at read time: a purged title is unrecoverable
// text, so a render-time re-parse would both blind the appeal's own electorate
// and orphan its latch.
type modParse struct {
	valid     bool
	verb      string
	court     string
	target    uint64 // claimID for item verbs, candidateID for setmods
	hasTarget bool
	poisoned  bool // purged before the binding was persisted: render-only
}

// metaState holds the meta court's per-claim parses, latches, and execution
// flags. Keyed by the meta court's own claim ids — it is deliberately NOT a
// field on the shared claimState, which every court's claims carry.
type metaState struct {
	parses   *bptree.BPTree // claimID -> *modParse (stored at open, rewritten on edit)
	bindings *bptree.BPTree // claimID -> *modParse (persisted at PostAnswer; the only thing execution reads)
	latches  *bptree.BPTree // latchKey -> claimID
	executed *bptree.BPTree // claimID -> true (exactly-once)
}

var meta = &metaState{
	parses:   bptree.NewBPTree32(),
	bindings: bptree.NewBPTree32(),
	latches:  bptree.NewBPTree32(),
	executed: bptree.NewBPTree32(),
}

// init deploys the meta court. init has no `cur` to ask, and MsgAddPackage sets
// OriginCaller to the deployer — the r/govern/token.gno pattern, and the only
// moment the deployer can be read without a caller influencing it. It calls
// startCourt directly rather than StartCourt, because the public path reserves
// this slug precisely so only init can take it.
func init() {
	startCourt(unsafe.OriginCaller(), chain.PackageAddress(metaRealmPath), metaSlug, metaCourtNm, 0)
}

// parseModTitle reads a reserved title. Anything that is not an exact match is
// simply an ordinary meta-court claim (render badges it "not a valid appeal", so
// a near-miss cannot masquerade as binding).
//
//	mod:unhide:<court>/<claimID>   mod:clear:<court>/<claimID>
//	mod:hide:<court>/<claimID>     mod:setmods:<court>/<candidateID>
//	mod:suspend:<court>            mod:unsuspend:<court>
func parseModTitle(title string) modParse {
	p := modParse{}
	if !strings.HasPrefix(title, metaPrefix) {
		return p
	}
	rest := title[len(metaPrefix):]
	slash := strings.Index(rest, ":")
	if slash < 0 {
		return p
	}
	verb := rest[:slash]
	arg := rest[slash+1:]
	switch verb {
	case verbUnhide, verbClear, verbHide, verbSetmods:
		cut := strings.Index(arg, "/")
		if cut <= 0 || cut == len(arg)-1 {
			return p
		}
		id, err := strconv.ParseUint(arg[cut+1:], 10, 64)
		if err != nil || id == 0 {
			return p
		}
		p.court, p.target, p.hasTarget = arg[:cut], id, true
	case verbSuspend, verbUnsuspend:
		if arg == "" || strings.Contains(arg, "/") {
			return p
		}
		p.court = arg
	default:
		return p
	}
	// The slug charset is [a-z0-9-], so a malformed target cannot hide in it.
	for i := 0; i < len(p.court); i++ {
		ch := p.court[i]
		if !((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-') {
			return modParse{}
		}
	}
	p.verb, p.valid = verb, true
	return p
}

// latchKey serialises appeals so one target cannot host a swarm of them.
// setmods is keyed per COURT, not per candidate: a per-candidate key would let
// an attacker bank unlimited parallel installs on one court and discharge them
// one after each local election.
func latchKey(p modParse) string {
	switch p.verb {
	case verbSetmods:
		return "set:" + p.court
	case verbSuspend, verbUnsuspend:
		return "sus:" + p.court
	default:
		return "item:" + p.court + ":" + strconv.FormatUint(p.target, 10)
	}
}

// ---- lifecycle hooks (called from the claim/answer paths) -----------------

// onClaimOpened stores the parse for a meta-court claim, and puts a valid
// unanswered appeal on the pending list so it is force-visible from birth (an
// appeal nobody can find is an appeal nobody can contest).
func onClaimOpened(c *Court, cs *claimState) {
	if c.id != metaSlug {
		return
	}
	p := parseModTitle(cs.title)
	meta.parses.Set(beClaimKey(cs.id), &p)
	if p.valid {
		pendingEnter(c, cs)
	}
}

// onTitleEdited re-parses a meta claim whose title changed inside the polish
// window. It deliberately performs NO latch work: edits are provably pre-answer
// (the window closes before a claim can mature enough to answer) and the latch
// binds at PostAnswer, so an edit-time acquire would reopen the camp it closed.
func onTitleEdited(c *Court, cs *claimState) {
	if c.id != metaSlug {
		return
	}
	p := parseModTitle(cs.title)
	// Carry the purge poison forward: re-parsing must not re-arm an appeal whose
	// title was purged during the polish window.
	if prev := meta.parses.Get(beClaimKey(cs.id)); prev != nil && prev.(*modParse).poisoned {
		p.poisoned = true
	}
	meta.parses.Set(beClaimKey(cs.id), &p)
	// A SEEDED claim stays on the pending list whatever its title says — the set
	// that seeds content must never be able to embargo it by editing the title
	// into a non-appeal string (M-A18).
	if p.valid || cs.seeded {
		pendingEnter(c, cs)
	} else {
		pendingExit(c, cs)
	}
}

// onClaimAnswered persists the BINDING parse and takes the target's latch.
// First-to-answer takes it, which forces anyone who wants to hold a target's
// appeal lane onto the bonded, disputable path rather than a 0.1-CC claim that
// is never answered.
func onClaimAnswered(c *Court, cs *claimState) {
	if c.id != metaSlug {
		return
	}
	v := meta.parses.Get(beClaimKey(cs.id))
	if v == nil {
		return
	}
	p := v.(*modParse)
	if !p.valid || p.poisoned {
		return // an ordinary claim, or a purged-before-binding one: never executable
	}
	k := latchKey(*p)
	if held := meta.latches.Get(k); held != nil {
		if held.(uint64) != cs.id {
			panic("kourtv2: another appeal already holds this target's review slot")
		}
	}
	meta.latches.Set(k, cs.id)
	bind := *p
	meta.bindings.Set(beClaimKey(cs.id), &bind)
}

// releaseMetaLatchIfMeta frees a meta appeal's target slot at any TERMINAL
// transition of the appeal claim. It exists because the latch used to be freed
// only on a SUCCESSFUL execution — so every appeal that was refused, expired, or
// simply voted down held its target's review slot FOREVER, permanently bricking
// that target's appeals lane and permanently reverting PostAnswer for it. That
// fires on the ordinary path, not just under attack: a hide appeal correctly
// refused on silence would have poisoned the item for good. Non-panicking, so
// it is safe on a money path.
func releaseMetaLatchIfMeta(c *Court, cs *claimState) {
	if c.id != metaSlug {
		return
	}
	releaseMetaLatch(cs)
}

// releaseMetaLatch frees a target's slot once its appeal can no longer execute.
func releaseMetaLatch(cs *claimState) {
	v := meta.bindings.Get(beClaimKey(cs.id))
	if v == nil {
		return
	}
	k := latchKey(*v.(*modParse))
	if held := meta.latches.Get(k); held != nil && held.(uint64) == cs.id {
		meta.latches.Remove(k)
	}
}

// poisonMetaParse marks a purged appeal's parse render-only. The parse still
// RENDERS (verb+target are realm-validated strings, the same speech class as a
// category code, so redacting them would blind the appeal's electorate for no
// legal-hold gain) but it can no longer bind an execution.
func poisonMetaParse(claimID uint64) {
	if v := meta.parses.Get(beClaimKey(claimID)); v != nil {
		v.(*modParse).poisoned = true
	}
}

// ---- execution ------------------------------------------------------------

// ExecuteMetaVerdict applies a decided appeal. Permissionless: the verdict is
// the authority, not the caller.
//
// The guard order is FIXED and validity comes before state, so a call that
// should do nothing can never leave a mark (an earlier ordering let a non-final
// call stamp the re-hide cooldown).
func ExecuteMetaVerdict(cur realm, metaClaimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	mc := mustCourt(metaSlug)
	cs := mustClaim(mc, metaClaimID)

	// 1. A binding parse must exist. Purged-before-binding executes nothing;
	//    a purge AFTER the binding never blocks execution, which is what stops
	//    purge from becoming a veto over the appeals layer.
	bv := meta.bindings.Get(beClaimKey(metaClaimID))
	if bv == nil {
		panic("kourtv2: this claim carries no binding appeal")
	}
	p := *bv.(*modParse)

	// 2. The target must exist and STRICTLY predate the appeal, so no appeal can
	//    be aimed at something created after voters judged it.
	if !Exists(p.court) {
		panic("kourtv2: the target court does not exist")
	}
	tc := mustCourt(p.court)
	if tc.createdAt >= cs.openedAt {
		panic("kourtv2: the target court does not predate this appeal")
	}
	var target *claimState
	if p.hasTarget && p.verb != verbSetmods {
		target = mustClaim(tc, p.target)
		if target.openedAt >= cs.openedAt {
			panic("kourtv2: the target claim does not predate this appeal")
		}
	}
	if p.verb == verbSetmods {
		// The candidate is the target here, and it must ALSO predate the appeal.
		// Registration is permissionless with a predictable per-court counter, so
		// without this an attacker opens setmods against an unallocated id, wins
		// the vote on a candidate nobody could inspect, and only then registers
		// their own puppet set at that id.
		if cand := ensureMod(tc).mustCandidate(p.target); cand.at >= cs.openedAt {
			panic("kourtv2: the candidate set does not predate this appeal")
		}
	}

	// 3. A final YES verdict — read from `provisional`, the field a dispute
	//    OVERTURNS, never from the posted answer.
	if cs.verdictAt == 0 || cs.provClose {
		panic("kourtv2: no final verdict")
	}
	if int(cs.provisional) != sideYES {
		panic("kourtv2: the verdict was not YES")
	}

	// 4. Aggressive verbs need a genuinely contested route. `route == "vote"`
	//    alone is forgeable: it is stamped for ANY once-disputed claim, including
	//    one whose only round FAILED QUORUM — so silence plus a self-dispute
	//    would seat a principal on someone else's court for ~10% of a
	//    self-chosen stake. decidedRounds proves a quorate round classified it.
	if verbIsAggressive(p.verb) {
		if cs.route != "vote" || cs.decidedRounds == 0 {
			panic("kourtv2: this verb needs a decided contested vote, not silence")
		}
		// credEligible (dispute.gno) means ≥ floor/4 of weight voted AGAINST the
		// claim — a real adversary showed up. Without it the surviving forge is
		// "hold 5% of meta supply and abstain-vote your own appeal": abstentions
		// clear the quorum, yes=0 falls to the uphold default, and decidedRounds
		// stamps. That buys a contested-looking verdict with ZERO opposing
		// weight, so the verbs that seize authority demand real opposition.
		//
		// hide is deliberately EXEMPT (3-agent panel, 2/3 with the carve-out
		// reasoned only by B): requiring an adversary would mean a correct but
		// UNCONTESTED hide could never execute, and hide is the one aggressive
		// verb that is low-harm and globally reversible — the global DAO clears
		// it, and it moves no money.
		if p.verb != verbHide && !cs.credEligible {
			panic("kourtv2: a manufactured contest cannot seize authority — this verb needs weight voted against it")
		}
	}

	// 5. Exactly-once. Without it, anyone could re-call a settled appeal every
	//    votingBlocks-1 and extend the respondent's cooldown forever — the
	//    livelock, mirrored onto the moderator side.
	if meta.executed.Has(beClaimKey(metaClaimID)) {
		panic("kourtv2: already executed")
	}

	// 6. Execution expiry: a verdict is not a sleeper round. Without this a
	//    party could bank K decided appeals and discharge one after each local
	//    election, inverting last-writer-wins into oldest-ammunition-wins.
	now := heightNow()
	if now > cs.verdictAt+mc.params.votingBlocks {
		panic("kourtv2: this verdict has expired; re-appeal")
	}

	// 7. Staleness, per verb. setmods anchors on verdictAt — NOT openedAt: the
	//    local electorate is always faster than a meta appeal, so an openedAt
	//    anchor would hand it a permanent free veto and meta's duty cycle would
	//    be zero. An install between the verdict and its execution refuses.
	cm := ensureMod(tc)
	switch p.verb {
	case verbSetmods:
		if cm.setActHeight > cs.verdictAt {
			panic("kourtv2: the moderator set changed after this verdict; re-appeal")
		}
		// The global DAO's term applies to THIS verb too (v0.55, 3-0). setmods
		// looks like a membership verb, so this arm was written against
		// setActHeight alone — but installModSet RE-ARMS a suspended court, the
		// same `cm.suspended = false` unsuspendSet performs, and GlobalSuspendSet
		// stamps suspendActByGlobal WITHOUT moving setActHeight. So a stale
		// verdict was invisible on this path: `setmods` was a cheaper `unsuspend`
		// than `unsuspend`, qualified only by its spelling, and a registered
		// candidate is free and permissionless.
		//
		// Anchored on openedAt, unlike the setActHeight term above. That term's
		// verdictAt anchor is about the LOCAL electorate, which moves on a cadence
		// fast enough to veto meta permanently; the global DAO's is m-of-n and
		// GlobalSuspendSet REFUSES while already suspended, so it cannot re-arm
		// the veto without first clearing the suspension the appellant wants gone.
		// The cost is one re-appeal per global act, exactly what the arm below
		// already prices in. An asymmetric anchor between two arms of one switch
		// is what produced this bug.
		//
		// Direction-scoping needs no second clause: installModSet can only ever
		// CLEAR the flag, so `cm.suspended` IS the opposite-direction test. A
		// global ClearCourtSuspension also stamps suspendActByGlobal but leaves
		// the flag false, so a legitimate install still proceeds.
		if cm.suspended && cm.suspendActByGlobal > cs.openedAt {
			panic("kourtv2: the global DAO changed this court's suspension under this appeal; re-appeal")
		}
	case verbSuspend, verbUnsuspend:
		if cm.lastElectionAt > cs.openedAt || cm.setActHeight > cs.verdictAt {
			panic("kourtv2: the moderator set changed under this appeal; re-appeal")
		}
		// The global DAO's own term. Its suspension verbs are the legal
		// backstop, so a meta verdict that predates a global decision must not
		// silently overturn it — a stale `suspend` could re-suspend a court the
		// global DAO just cleared, and a stale `unsuspend` could release one it
		// just suspended. Only OPPOSITE-direction acts refuse, which is the same
		// rule verbUnhide settled on: refusing on a same-direction act buys
		// nothing (the verdict's goal is already achieved) and costs a re-appeal.
		if cm.suspendActByGlobal > cs.openedAt &&
			cm.suspended == (p.verb == verbUnsuspend) {
			panic("kourtv2: the global DAO changed this court's suspension under this appeal; re-appeal")
		}
	case verbUnhide:
		// Only an ELECTION refuses an unhide. A third-party CLEAR is
		// same-direction as the verdict, and refusing on it once let a
		// moderator re-hide for free after a global clear.
		if cm.lastElectionAt > cs.openedAt {
			panic("kourtv2: the moderator set changed under this appeal; re-appeal")
		}
	}

	meta.executed.Set(beClaimKey(metaClaimID), true)
	applyMetaVerb(mc, tc, cm, p, cs, target)
	releaseMetaLatch(cs)
	chain.Emit(metaExecuted,
		"appeal", strconv.FormatUint(metaClaimID, 10),
		"verb", p.verb, "court", p.court,
		"target", strconv.FormatUint(p.target, 10),
	)
}

func applyMetaVerb(mc, tc *Court, cm *courtMod, p modParse, cs, target *claimState) {
	by := cs.answerer
	switch p.verb {
	case verbUnhide:
		// A no-op unhide (the bit is already clear) stamps NOTHING: otherwise a
		// chain of appeals against an always-visible item would hold a
		// moderator's hide power off pre-emptively.
		clm := lookupClaimMod(cm, p.target)
		if clm == nil || !clm.court {
			return
		}
		clearCourtBitByMeta(tc, p.target, by)
	case verbClear:
		clearMetaBit(tc, p.target, by)
	case verbHide:
		setMetaBit(tc, p.target, by)
	case verbSuspend:
		suspendSet(tc, by)
	case verbUnsuspend:
		unsuspendSet(tc, by)
	case verbSetmods:
		cand := cm.mustCandidate(p.target)
		installModSet(tc, cm, cand, heightNow(), false)
		chain.Emit("ModSetInstalled",
			"court", tc.id, "by", "meta",
			"candidate", strconv.FormatUint(cand.id, 10),
			"height", eventHeight(),
		)
	}
}

// ---- reads ----------------------------------------------------------------

// AppealParse exposes a meta claim's parsed instruction for render: the verb and
// target of a valid appeal, or "" when the title is not a reserved schema.
func AppealParse(claimID uint64) (verb, court string, target uint64, valid bool) {
	v := meta.parses.Get(beClaimKey(claimID))
	if v == nil {
		return "", "", 0, false
	}
	p := v.(*modParse)
	return p.verb, p.court, p.target, p.valid
}

// AppealExecuted reports whether an appeal has already been applied.
func AppealExecuted(claimID uint64) bool { return meta.executed.Has(beClaimKey(claimID)) }

// AppealLatchHolder is the claim currently holding a target's review slot.
func AppealLatchHolder(verb, court string, target uint64) uint64 {
	p := modParse{verb: verb, court: court, target: target}
	if v := meta.latches.Get(latchKey(p)); v != nil {
		return v.(uint64)
	}
	return 0
}

// ---- the meta franchise (MODERATION.md §13.8) -----------------------------
//
// The appeals layer's electorate should be the platform's paying participants,
// not whoever chose to buy the appeals coin. Selling meta-CC on its own curve
// makes the security parameter a CONSTANT — one actor's one-time purchase — so
// a 5% pivot costs ~0.108x the deployer's genesis spend forever, at any
// platform size. Deriving it from burned GNOT instead makes it ENDOGENOUS: it
// grows with adoption, and burned GNOT is the one signal nobody can fake.
//
// Three independent vets converged on the same shape, and every clause below
// exists because a specific attack needs it:
//
//   - accrue on `spent` µGNOT, NEVER on CC minted. A fresh curve sells CC
//     ~44,721x cheaper per GNOT and StartCourt is free, so a per-CC rule is an
//     unbounded sqrt(N) free-mint of the platform's governance token. Per-GNOT
//     makes the court you burn into irrelevant — and that is sound ONLY because
//     the GNOT is truly burned to a keyless sink with no redemption path
//     anywhere. TRIPWIRE: this breaks the instant a treasury or redemption is
//     reintroduced.
//   - CLAIM-ON-DEMAND, not an airdrop. Burning accrues an entitlement; meta-CC
//     exists only when its owner asks for it. This one choice does four jobs:
//     supply stays equal to the ENGAGED electorate (so the 5%-of-supply quorum
//     floor stays reachable — an auto-mint would inflate the bar ~158x while
//     turnout stayed flat, killing honest appeals while the zero-voter forge
//     kept working); the cheap-float capture route disappears (an attacker must
//     pay people to claim AND sell, which is visible vote-buying); the
//     unsolicited distribution becomes an opt-in membership act; and the
//     unclaimed overhang is a standing DEFENSIVE RESERVE — dormant burners can
//     claim and dilute a capture next cycle.
//   - route the mint through META'S OWN CURVE, advancing the same monotone
//     position its Buy uses. That keeps the quadratic escalator (capture gets
//     harder as the platform grows), closes the side door where a parked curve
//     would sell a capture bloc at genesis prices, and leaves court.gno's
//     supply-ceiling invariant true UNCHANGED — the curve's own cap still
//     bounds every unit of meta primary issuance.
//   - CLAMP, never panic. This mint is reached from Buy, the platform's only
//     GNOT on-ramp; a MaxSupply panic here would brick buying on every court.

// franchise: address -> unclaimed µGNOT burned across all courts.
var franchise = bptree.NewBPTree32()

// accrueFranchise records a burn toward the claimant's future meta weight.
// Called from Buy; never panics, never mints, never reads money state back.
// Buying META itself does not accrue — that GNOT already bought meta-CC
// directly through the same curve, and counting it twice would pay the same
// burn two ways.
func accrueFranchise(c *Court, who address, spent int64) {
	if c.id == metaSlug || spent <= 0 {
		return
	}
	k := who.String()
	prev := int64(0)
	if v := franchise.Get(k); v != nil {
		prev = v.(int64)
	}
	sum, ok := overflow.Add64(prev, spent)
	if !ok {
		return // unreachable at real volumes; never panic on the Buy path
	}
	franchise.Set(k, sum)
}

// ClaimMetaFranchise mints the caller's accrued appeals weight. Permissionless
// and idempotent — claiming twice with nothing accrued is a no-op returning 0.
func ClaimMetaFranchise(cur realm) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	k := who.String()
	v := franchise.Get(k)
	if v == nil {
		return 0
	}
	owed := v.(int64)
	if owed <= 0 {
		return 0
	}
	mc := mustCourt(metaSlug)
	touch(mc) // the mint changes meta's live supply; its accrual clock must be current
	delta, used := mc.crv.Minted(mc.minted, owed)
	if delta <= 0 {
		return 0 // the curve is at its cap: clamp silently, keep the entitlement
	}
	mc.minted += delta // ONE monotone position, shared with meta's own Buy
	recordPrice(mc)    // a franchise mint moves the curve too
	mc.coin.Mint(who, delta)
	if used >= owed {
		franchise.Remove(k)
	} else {
		franchise.Set(k, owed-used) // a partial fill leaves the rest claimable
	}
	chain.Emit("FranchiseClaimed",
		"who", who.String(),
		"burned", strconv.FormatInt(used, 10),
		"minted", strconv.FormatInt(delta, 10),
	)
	return delta
}

// FranchiseOf is the caller-visible unclaimed entitlement, in µGNOT burned.
func FranchiseOf(who address) int64 {
	if v := franchise.Get(who.String()); v != nil {
		return v.(int64)
	}
	return 0
}
