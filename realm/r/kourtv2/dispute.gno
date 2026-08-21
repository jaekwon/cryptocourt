// The dispute machine — V1's audited round structure (doubling bonds, sealed
// 7-day tallies, tally-based classification, escrow windows, reopens, 3-round
// close) with the V2 dispositions (PLAN §3.6, v0.11–v0.25):
//
//	FORFEITURES BURN; COMPENSATION MINTS. No value ever moves between
//	adversaries on any outcome — punishment is deflation, reward is issuance,
//	senior-queued: comp = min(2 × the prevailing party's own bond,
//	floor(80% × the loser's burned bond)), reserved at the round's decision.
//
//	Failed (quorum-less) rounds burn HALF the disputer's bond and return half
//	(turnout is not the disputer's conduct); the answerer is NOT comped on a
//	failed round — their bond simply survives, escrowed until the verdict is
//	final. Three failed rounds close the claim without a decision: everyone
//	1×, deposit AND fee refund, no draw.
//
//	Every %·X̄ quantity reads the ONE X̄frozen snapshot taken at the answer
//	(P6): bond base = min(20%·X̄frozen, 40% × the actual answer bond),
//	doubling per failed round, claim-scoped (sybil-proof).
//
// Rounds are framed against the ORIGINAL answer (V1): overturn sets the
// provisional verdict to its opposite, uphold to the answer itself; a reopen
// vote can flip it back. Bonds are disposed at each round's decision (the
// per-event burn must accompany its comp reservation — A19's invariant); the
// answer bond is burned only by the round that decides against it and returned
// only at VERDICT_FINAL. Answer records move ONCE, at Finalize, from the final
// verdict (P13) — intermediate rounds never churn the record.
package kourtv2

import (
	"strconv"

	governor "gno.land/p/kourt/governor/v0"
	grc20votes "gno.land/p/kourt/grc20votes/v0"
	bptree "gno.land/p/nt/bptree/v0"
)

const disputeKindName = "dispute"

// quorumSupplyBps is the absolute turnout floor's supply arm: 5%.
const quorumSupplyBps = int64(500)

// finalizeGraceBlocks is the week Finalize stays participant-only after the
// escrow window lapses (v0.11 A13: a stranger must not pick the settle block).
const finalizeGraceBlocks = int64(120_960)

type disputeKind struct{}

func (disputeKind) Name() string { return disputeKindName }
func (disputeKind) Describe(payload string) string {
	return "resolve a disputed claim by a token vote (see the court page for the claim)"
}
func (disputeKind) Check(payload string) error { return nil } // the court validates

// Do is unused: the court resolves by reading the tally, never by
// governor.Execute. It exists only to satisfy the Kind seam.
func (disputeKind) Do(_ int, rlm realm, payload string) error { return nil }

// disputeRules mirror V1: ThresholdBps is the overturn bar; the escrow window,
// not the governor timelock, is the reaction period.
func disputeRules(p Params) governor.Rules {
	return governor.NewRules(5000, p.disputeThresholdBps, p.votingBlocks, 1, p.graceBlocks, 0)
}

// OpenDispute contests a claim's answer. The caller posts the round's bond and
// the court opens a sealed governor vote ("OVERTURN the answer?") with an
// absolute quorum floor. The first round must open inside the 72h settle
// delay; reopens must open inside the escrow window of a standing provisional
// verdict. Returns the governor proposal id.
func OpenDispute(cur realm, courtSlug string, claimID uint64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.frozenAt == 0 {
		panic("kourtv2: there is no answer to dispute")
	}
	if who == cs.answerer {
		// Hygiene only (a sybil wallet trivially evades it): the REAL
		// credential defense is the credEligible weight bar below (M2-1).
		panic("kourtv2: the answerer cannot dispute their own answer")
	}
	if cs.disputeOpen {
		panic("kourtv2: a dispute is already open on this claim")
	}
	if cs.verdictAt != 0 {
		panic("kourtv2: the verdict is final")
	}
	now := heightNow()
	if cs.provisional < 0 {
		// First round: the 72h settle delay IS the dispute window — after it,
		// only SettleUndisputed. The two guards partition every height, so no
		// settle/dispute race exists.
		if passed, known := pastDeadline(cs.answeredAtTime, settleSecs); (known && passed) ||
			(!known && now >= cs.answerHeight+settleDelay) {
			panic("kourtv2: the dispute window has passed; the answer settles undisputed")
		}
	} else if (cs.escrowUntilAt != 0 && nowTime() >= cs.escrowUntilAt) ||
		(cs.escrowUntilAt == 0 && now >= cs.escrowUntil) {
		panic("kourtv2: the escrow window has passed; Finalize the verdict")
	}
	touch(c)
	// A dispute outranks the quality lane (audit M3-LOW-1): an open flag VOIDS
	// (bond returned, slot unconsumed — the dispute's own tally carries quality).
	//
	// A pending slash does NOT (v0.47). Opening a round is not adjudicating one:
	// this used to unslash unconditionally, right here, before a single vote — so
	// a zero-weight FAILED-QUORUM dispute permanently destroyed an already
	// adjudicated full-bar ⅔-low slash, and slotConsumed was already latched so no
	// replacement flag could ever re-arm it. Only a round's OUTCOME disposes the
	// reserve now: an overturn burns it with the bond (A19), an upheld round is
	// scored on its own ride, and a round that decided nothing re-arms it.
	//
	// A LIVE counter re-vote still closes here — the round's own ride replaces it —
	// but it is no longer un-SPENT (v0.51). Clearing counterUsed re-minted the
	// one-shot Q5 challenge on demand: an answerer facing a settle could counter,
	// self-dispute to cancel it, and counter again, indefinitely inside the escrow
	// window. What the answerer is owed is the TIME, which rearmSlashWindow returns
	// by reopening the lane itself on any round that adjudicated nothing.
	voidFlag(c, cs)
	cs.counterOpen = false
	reaskQualityTally(cs)

	// Bond: min(20%·X̄frozen, 40% × the actual answer bond) — the v0.25 arm
	// keeps round 1 at q > 1/3 on every claim including bond-capped courts —
	// doubled per failed round, claim-scoped (a fresh disputer address cannot
	// reset the multiplier). provClose bounds failedRounds ≤ 2 here; the
	// clamp guards the shift regardless.
	base := cs.xBarFrozen * disputeBondXBps / 10000
	if arm := cs.answerBond0 * disputeBondOfAnswerBps / 10000; arm < base {
		base = arm
	}
	if base < 1 {
		base = 1
	}
	shift := cs.failedRounds
	if shift > maxFailedRounds-1 {
		shift = maxFailedRounds - 1
	}
	bond := mustMul(base, int64(1)<<uint(shift))
	mustSpendable(c, who, bond)
	c.coin.Transfer(who, c.escrow, bond)

	floor := quorumFloor(c, cs.xBarFrozen)
	cs.round++
	payload := strconv.FormatUint(claimID, 10) + "|" + strconv.FormatInt(cs.round, 10)
	pid := c.gov.ProposeWithQuorum(c.escrow, disputeKindName, payload, "dispute", floor)

	cs.proposalID = pid
	cs.disputeOpen = true
	cs.disputeBond = bond
	cs.disputer = who
	return pid
}

// VoteDispute casts a vote on a claim's open dispute — "yes" to overturn the
// answer, "no" to uphold it, "abstain" for turnout without a side. The
// governor is the sole roll authority and refuses a second vote.
func VoteDispute(cur realm, courtSlug string, claimID uint64, choice string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if !cs.disputeOpen {
		panic("kourtv2: no open dispute on this claim")
	}
	// Nobody votes on their own claim's verdict — the same rule VoteQuality has
	// applied since V2, for the same reason: a participant's stake, bond or
	// authorship is a direct interest in the outcome, and quality already refuses
	// to let anyone vote their own payout multiplier.
	//
	// THIS IS HYGIENE, NOT A SECURITY GUARD, and the distinction matters because
	// it would be easy to bank on. isParticipant is ADDRESS-KEYED, and this
	// design's root principle — earned over four audit rounds and stated at the
	// top of MODERATION.md — is that address-keyed defenses fall to sybils; only
	// capital-keyed, deadline-keyed or residency-keyed ones hold. An attacker
	// wanting to uphold their own answer simply votes from an address that never
	// staked, which costs nothing. So this closes the naive case and the
	// conflict of interest; it does NOT close the manufactured contest.
	//
	// What closes that is capital-keyed and already shipped: credEligible
	// requires weight >= floor/4 voted AGAINST the claim before an aggressive
	// meta verb will execute, so a contest with no real adversary buys nothing
	// however many addresses staged it.
	if isParticipant(cs, who) {
		panic("kourtv2: a participant may not vote on their own claim's verdict")
	}
	// The cap is what the voter still holds. The governor keeps deriving the
	// snapshot itself and takes the lesser, so this can only ever LOWER — which is
	// why the dispute lane goes through VoteWithCap instead of clamping here. The
	// tally is the governor's, and `rest := p.total - cast` is its invariant to
	// keep; an earlier attempt handed it a finished weight instead of a ceiling and
	// that dropped `no` out of the early-decide test entirely.
	//
	// Refused here rather than in the governor so the message is this court's. See
	// quality.gno for the derivation, and VOTEFLOOR.md for why the snapshot alone
	// was rentable: this is the lane the end-to-end rental was demonstrated on.
	held := voteCap(c, who)
	if held <= 0 {
		panic("kourtv2: you no longer hold the coin you would vote with")
	}
	c.gov.VoteWithCap(who, cs.proposalID, choice, held)
	// Court-side record of the choice AND THE WEIGHT: the governor's roll is
	// reclaimable after resolution (ReleaseRoll is permissionless), so the carrot
	// must not depend on it.
	//
	// The weight used to be recomputed later from PastVotes at the proposal's
	// epoch, which was exactly equal and needed no storage. It is stored because
	// equal-by-coincidence is a bad thing for a payout to rest on — and THAT
	// COINCIDENCE IS NOW GONE: the line above caps the tally at the voter's live
	// balance, so a recomputed PastVotes numerator would exceed what actually
	// counted toward the denominator and the carrot would over-pay every voter who
	// was capped. What was defensive when written is load-bearing now. Read back
	// from the governor here, where the roll is certainly intact because this line
	// just voted.
	if cs.qVoted == nil {
		cs.qVoted = bptree.NewBPTree32()
	}
	cs.qVoted.Set("d"+beClaimKey(uint64(cs.proposalID))+string(who), choice)
	_, dw, ok := c.gov.VoteOf(cs.proposalID, who)
	if !ok {
		panic("kourtv2: the governor did not record the vote it just accepted")
	}
	cs.qVoted.Set("dw"+beClaimKey(uint64(cs.proposalID))+string(who), dw)
	// AND THE COIN IS COMMITTED UNTIL THIS ROUND RESOLVES. The floor above stops a
	// renter voting weight they have already handed back; this stops them handing
	// it back the moment after. Measured on the floor alone: the rental survived as
	// vote-then-sell at 599x the quorum floor. Locked at the weight the governor
	// tallied, not at the balance — a voter capped down should be committed to what
	// their ballot was worth and no more. See votelock.gno.
	lockVote(c, who, voteLockDispute, int64(claimID), cs.proposalID, dw)
}

// ResolveDispute reads the FROZEN tally of a closed dispute vote and
// classifies it — failed-quorum, overturn, or uphold — disposing this round's
// bonds under the burn/mint doctrine and recording the provisional verdict.
// Permissionless; only once the vote has closed. The verdict is derived from
// the tally, never the drifting State label (V1's classifier).
func ResolveDispute(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if !cs.disputeOpen {
		panic("kourtv2: no dispute to resolve")
	}
	if c.gov.State(cs.proposalID) == "active" {
		panic("kourtv2: the dispute vote is still open")
	}
	touch(c)

	yes, no, abstain, _ := c.gov.Tally(cs.proposalID)
	cast := yes + no + abstain
	floor := c.gov.QuorumFloor(cs.proposalID)
	firstResolution := cs.provisional < 0 // capture BEFORE the switch mutates it

	switch {
	case cast < floor:
		// FAILED-QUORUM: apathy must not resolve a claim — and it is not the
		// disputer's conduct (v0.25): HALF the bond returns, half burns
		// (floor favors the burn; dust deflates). No comp mints — the
		// answerer's bond simply survives, still escrowed.
		half := cs.disputeBond / 2
		if half > 0 {
			c.coin.Transfer(c.escrow, cs.disputer, half)
		}
		if rest := cs.disputeBond - half; rest > 0 {
			c.coin.Burn(c.escrow, rest)
		}
		cs.disputeBond = 0
		// The VERDICT question failed quorum, but the RESERVE's question has its own,
		// higher bar and can be answered on a round the governor's floor rejected
		// (v0.51). Scoring the ride here rather than re-arming blindly is what stops
		// a full-bar rescue tally from being discarded and then burned by the
		// unconditional ResolveSlashWindow — a below-bar ride still re-arms, which is
		// the v0.47 behavior verbatim.
		//
		// Scores the RESERVE only, deliberately not the TIER: this branch does not
		// call resolveQualityRide, so an identical full-bar non-⅔-low ride refunds
		// here while leaving cs.tier LOW, where a DECIDED round would promote it to
		// MID. That asymmetry errs conservative in both directions it can err (it
		// cannot promote a tier on a round nobody carried, and it cannot burn a
		// reserve the electorate just rescued), and widening it moves draw money, so
		// it stays until it has its own econ vet.
		//
		// Runs BEFORE provCloseClaim so a refund rejoins answerBond and leaves on the
		// ordinary bond exit. Note the reverse order would ALSO be safe — refundSlash
		// has a provClose arm that pays the answerer directly — so this ordering is a
		// preference for the common path, not a strand guard. (An earlier version of
		// this comment claimed it was a strand guard; it is not.)
		disposeSlashOnRide(c, cs)
		// Only the FIRST failed round defaults the verdict to the answer; a
		// failed reopen leaves a standing decided verdict untouched.
		if firstResolution {
			cs.provisional = cs.answer
		}
		cs.failedRounds++
		if cs.failedRounds >= maxFailedRounds {
			provCloseClaim(c, cs)
		}
	case yes > 0 && yes*grc20votes.Bps >= (yes+no)*c.params.disputeThresholdBps:
		// OVERTURN: the answer was wrong. The answer bond BURNS in full (the
		// forfeiture); the disputer's own bond returns; comp mints
		// senior-queued, capped by both arms (v0.20). A reopen after a prior
		// overturn finds answerBond already zero — comp's 80% arm is then 0
		// and nothing mints (no burn happened this round to anchor it).
		// A pending slash refunds INTO the bond first (a decided round
		// supersedes it — never slashable once disputed) so the forfeiture
		// burns the whole posted bond, slash reserve included.
		unslash(c, cs)
		posted := cs.disputeBond // the disputer's own risk, captured pre-zeroing
		burned := cs.answerBond
		if burned > 0 {
			c.coin.Burn(c.escrow, burned)
			cs.answerBond = 0
		}
		if posted > 0 {
			c.coin.Transfer(c.escrow, cs.disputer, posted)
			cs.disputeBond = 0
		}
		if comp := compAmount(posted, burned); comp > 0 {
			enqueueSenior(c, cs.disputer, comp, "comp")
		}
		cs.provisional = int8(oppositeSide(int(cs.answer)))
		cs.failedRounds = 0
		cs.decidedRounds++
		cs.decidedPID, cs.carrotChoice, cs.carrotDenom = cs.proposalID, "yes", yes
		resolveQualityRide(c, cs)
	default:
		// UPHOLD (tie, all-abstain, or a sub-threshold split, quorum met):
		// the disputer's bond BURNS in full; the answerer is comped against
		// their posted bond magnitude (answerBond0 — the live field may
		// already be spent by an earlier overturn round). Their bond stays
		// escrowed until VERDICT_FINAL: still at stake for reopens. A pending
		// slash is left carved here — comp reads answerBond0, so the reserve
		// changes no arithmetic in this branch — and is disposed below by this
		// round's own ride (v0.47).
		burned := cs.disputeBond
		if burned > 0 {
			c.coin.Burn(c.escrow, burned)
			cs.disputeBond = 0
		}
		if comp := compAmount(cs.answerBond0, burned); comp > 0 {
			enqueueSenior(c, cs.answerer, comp, "comp")
		}
		// The credential bar (audit M2-1): this uphold counts toward the
		// difficulty record only if the OVERTURN side carried real weight —
		// >= 1/4 of the (supply-floored) quorum floor. A manufactured contest
		// has no adversarial weight unless the farmer HOLDS and votes ~1.25%
		// of court supply against their own claim (the v0.28 pricing:
		// supply-absolute prizes demand supply-absolute weight).
		//
		// "HOLDS" IS ENFORCED NOW, and it was aspirational when written: before
		// the vote floor the farmer could rent the weight, vote it against their
		// own claim, and return it the same hour. `yes` here is c.gov.Tally, and
		// the governor's tally is the CAPPED sum — VoteDispute hands it a ceiling
		// of the voter's live balance, so weight that has been given back
		// contributes nothing to this bar. Both sides read the proposal's own
		// epoch, so the comparison is coherent.
		//
		// The direction is also the safe one. Capping can only LOWER `yes`, so it
		// makes this bar harder to clear, and clearing it is what unlocks an
		// aggressive meta verb (meta.gno) and the difficulty earning below. A
		// floor that made the bar EASIER would be the dangerous rounding; this
		// one withholds.
		//
		// It must stay a read of the TALLY and never a re-derivation from
		// PastVotes. crystallize.gno's carrot had exactly that bug — re-deriving
		// a numerator the tally had capped — and over-paid every capped voter
		// until it was made to read the recorded figure instead. A mutation row
		// pins this one, caught by TestMetaLifecycleGuards.
		if yes >= credWeightFloor(c, cs.proposalID)/4 {
			cs.credEligible = true
		}
		cs.provisional = cs.answer
		cs.failedRounds = 0
		cs.decidedRounds++
		cs.decidedPID, cs.carrotChoice, cs.carrotDenom = cs.proposalID, "no", no
		// Captured BEFORE the ride, which may now ORIGINATE a reserve (v0.50).
		// disposeSlashOnRide scores a reserve this round INHERITED; one this round's
		// own ride just levied gets its counter-flag window instead. Running both on
		// the SAME tally would settle the slash in the very call that levied it —
		// burned with no window and no Q5 challenge for the answerer.
		hadSlash := cs.pendingSlash > 0
		resolveQualityRide(c, cs)
		// The VERDICT question is not the QUALITY question: winning the dispute
		// does not lift an adjudicated slash. Only this round's ride can, and only
		// on ResolveCounter's own terms — it asks the slash's question at the same
		// bars before the same electorate, so it is scored as one (v0.47).
		if hadSlash {
			disposeSlashOnRide(c, cs)
		}
	}

	// The escrow clock is set ONCE, at the first resolution, and never
	// recomputed — a reopen does not reset it (V1 §3.6).
	if firstResolution && !cs.provClose {
		w := escrowWindow(c, cs)
		// S2 — A QUORUM-LESS VERDICT MUST NOT FINALIZE BY APATHY.
		//
		// votingBlocks and escrowMinBlocks are the same number, and escrowWindow
		// returns the floor whenever extraDays rounds to zero — so round 3 could not
		// open, failedRounds capped at 2 against a maxFailedRounds of 3, and
		// provCloseClaim was unreachable on any court without a curve price. Meanwhile
		// the FIRST failed round has already written provisional = answer. So apathy
		// resolved the claim in the liar's favour: the outcome the failed-quorum
		// branch's own comment forbids. Three shipped fixtures widen this window
		// in-test to reach provClose, one of them naming the bug.
		//
		// Floored ONLY when the standing verdict is a quorum-less DEFAULT. A decided
		// first round keeps today's window bit-identically — raising escrowMinBlocks
		// globally instead would tax an honest DISPUTED claim from 14 to 21 days of
		// frozen winning-side principal, which is the objection used to reject a
		// longer settle window, and it would double the reopen grind chain.
		//
		// BOTH ARMS. The gates read escrowUntilAt whenever the stamp exists, so
		// flooring only the height arm leaves the bug fully live. Computing w once is
		// also what stops the two stamps drifting apart.
		//
		// KNOWN AND NOT CLOSED: an abstain-only round with quorum met is not a FAILED
		// round — it upholds — so one free abstain from a non-participant keeps
		// failedRounds at zero and denies this floor for the claim's whole life. That
		// costs the abstainer nothing. So this defeats APATHY, not an active adversary,
		// and it is strictly better than today either way.
		if cs.failedRounds > 0 {
			if lw := ladderWindow(c.params); lw > w {
				w = lw
			}
		}
		cs.escrowUntil = heightNow() + w
		cs.escrowUntilAt = nowTime() + blocksToSecs(w)
	}
	cs.disputeOpen = false
}

// disputeBond0 quotes the bond the NEXT round posts at the claim's current
// failed-round count — OpenDispute's formula, factored for DisputeBondNext.
func (cs *claimState) disputeBond0() int64 {
	base := cs.xBarFrozen * disputeBondXBps / 10000
	if arm := cs.answerBond0 * disputeBondOfAnswerBps / 10000; arm < base {
		base = arm
	}
	if base < 1 {
		base = 1
	}
	shift := cs.failedRounds
	if shift > maxFailedRounds-1 {
		shift = maxFailedRounds - 1
	}
	return mustMul(base, int64(1)<<uint(shift))
}

// compAmount is the doctrine's cap pair: min(2 × own bond, floor(80% × the
// loser's burn)) — tier-invariant, never negative (v0.20/v0.25).
func compAmount(ownBond, burned int64) int64 {
	comp := mustMul(compOwnX, ownBond)
	if arm := burned * compOfBurnBps / 10000; arm < comp {
		comp = arm
	}
	if comp < 0 {
		comp = 0
	}
	return comp
}

// provCloseClaim closes a claim without a decision after three failed rounds:
// everyone 1× (withdrawals open), no draw ever, the answer bond returns, the
// deposit AND fee refund (provClose is not a conclusive low — §3.1.7).
func provCloseClaim(c *Court, cs *claimState) {
	cs.provClose = true
	cs.verdictAt = heightNow()
	cs.verdictAtTime = nowTime()
	cs.route = "closed"
	// S3 — A CLAIM THAT ENDS UNDECIDED STILL PAYS.
	//
	// This used to set tierLowX and latch tierFinal, which contradicted the line
	// immediately below: the deposit and fee are refunded precisely BECAUSE a
	// provClose is not a conclusive low. Three failed quorums mean the electorate
	// never ruled on the claim's worth — nobody was found at fault — so treating it
	// as junk for the draw while treating it as sound for the deposit was incoherent
	// in the same function. Measured, it turned a claim that pays 19,584 into one
	// that pays 0.
	//
	// tierFinal MUST NOT be latched here, and this is the subtle part: latching it
	// before the guard makes the guard SELF-BLOCKING, and the claim then pays 0
	// forever — the very defect this replaces, reintroduced by the replacement.
	//
	// The guard is the same one the other two terminal paths use, so an adjudicated
	// low is never clobbered. Both clauses are needed: a slash-grade low whose
	// counter window is still open leaves slotConsumed set while tierFinal is not,
	// and that is the only state where they differ. (Dropping !tierFinal alone
	// SURVIVES mutation, because tierFinal implies slotConsumed at every
	// pre-terminal writer — kept for symmetry with the other terminal paths, and
	// recorded as unmutatable rather than papered over.)
	if !cs.tierFinal && !cs.slotConsumed {
		cs.tier = tierMidX
	}
	if cs.answerBond > 0 {
		c.coin.Transfer(c.escrow, cs.answerer, cs.answerBond)
		cs.answerBond = 0
	}
	if cs.deposit > 0 {
		c.coin.Transfer(c.escrow, cs.author, cs.deposit)
		c.deposit -= cs.deposit
		cs.deposit = 0
	}
	if cs.fee > 0 {
		c.coin.Transfer(c.escrow, cs.author, cs.fee)
		c.deposit -= cs.fee
		cs.fee = 0
	}
	releasePriority(c, cs.answerer, cs.id)
	// A provClosed claim is terminal — unflaggable and undisputable — so it is
	// no longer policeable and must leave the strips, or its row would linger
	// forever (§5.3 membership exit).
	stripExit(c, cs)
	releaseMetaLatchIfMeta(c, cs)
}

// Finalize makes a disputed claim's standing provisional verdict FINAL once
// the escrow window has passed with no active dispute: withdrawals open for
// both sides, the answer bond is disposed (returned if the answer stands — it
// burned already if not, LESS a slash-sized reserve while the claim is still
// slash-eligible, mirroring SettleUndisputed's M3-HIGH-1 retention), and the
// answer record moves once, from the final verdict (P13). Participant-only for
// the first week of eligibility (A13), permissionless after. Deposit, fee, and
// any retained reserve wait for QUALITY_FINAL (crystallize).
func Finalize(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.verdictAt != 0 {
		panic("kourtv2: already final")
	}
	if cs.disputeOpen {
		panic("kourtv2: a dispute is active; cannot finalize")
	}
	if cs.provisional < 0 {
		panic("kourtv2: no provisional verdict to finalize")
	}
	now := heightNow()
	if (cs.escrowUntilAt != 0 && nowTime() < cs.escrowUntilAt) ||
		(cs.escrowUntilAt == 0 && now < cs.escrowUntil) {
		panic("kourtv2: the escrow window has not passed")
	}
	if now < cs.escrowUntil+finalizeGraceBlocks && !isParticipant(cs, who) {
		panic("kourtv2: Finalize is participant-only for its first week")
	}
	touch(c)

	cs.verdictAt = now
	cs.verdictAtTime = nowTime()
	cs.route = "vote"
	// Clip the frozen record's hourly tail to its final week (stakeseries.gno);
	// no later stake op will ride a trim past this point.
	trimClaimHistory(c, cs, uint32(cs.frozenAt/epochBlocks)+1)
	// The default mid tier — UNLESS a conclusive tally already set it. A
	// slash-grade conclusive-low flag leaves slotConsumed=true but tierFinal=false
	// for its counter-flag window (quality.gno slashGrade branch), and a failed
	// dispute round keeps verdictAt=0/decidedRounds=0 so Finalize is reachable
	// in that window. Without the slotConsumed guard this clobbers LOW→MID and a
	// junk claim draws full mid emission — the exact twin of the v0.40
	// SettleUndisputed fix (session.gno), which this mirrors.
	if !cs.tierFinal && !cs.slotConsumed {
		cs.tier = tierMidX
	}
	if cs.answerBond > 0 {
		// The answer stood (an overturned bond was burned at its round). But if
		// the claim is still slash-eligible — no DECIDED round ran, so a
		// conclusive-low flag can still slashGrade (quality.gno gates it on
		// decidedRounds==0), and no slash is yet reserved — retain a slash-sized
		// reserve exactly as SettleUndisputed does (M3-HIGH-1). votingBlocks
		// exceeds the dispute/escrow windows, so the flag typically resolves AFTER
		// this Finalize; returning the whole bond here would let that later slash
		// clamp to zero (zero deterrent). The reserve disposes exactly once later —
		// burned by the slash, or returned at crystallize if none lands. A slash
		// already pending (a flag that resolved first) is separate: return the rest.
		// slotConsumed is a one-way latch and OpenFlag panics on it, so a consumed
		// slot means no future flag and therefore no future slash — retaining then
		// would withhold the answerer's coin until crystallize for nothing.
		// v0.47 LOCKSTEP with slashGrade: a decided round no longer confers
		// immunity, so it must no longer suppress the reserve either — otherwise
		// the whole bond returns here and the later slash clamps to zero, which is
		// exactly the M3-HIGH-1 shape, re-created on the path a mill now targets.
		// Dropping the clause also makes this gate character-identical to
		// SettleUndisputed's (session.gno): the two terminal paths finally share
		// ONE predicate, which is the v0.44 symmetry goal. v0.43's proof that an
		// overturn cannot retain now rests on one lock instead of two — the
		// enclosing `answerBond > 0` (decidedRounds++ was the second).
		reserve := int64(0)
		if cs.pendingSlash == 0 && !cs.slotConsumed {
			reserve = slashSizeFor(cs)
			if reserve > cs.answerBond {
				reserve = cs.answerBond
			}
		}
		if refund := cs.answerBond - reserve; refund > 0 {
			c.coin.Transfer(c.escrow, cs.answerer, refund)
		}
		cs.answerBond = reserve
	}
	// The record moves once, from the final verdict (P13) — and "upheld"
	// means a DECIDED vote upheld it AGAINST real opposition: quorum-less
	// defaults earn nothing, and so do weightless contests (credEligible,
	// audit M2-1) — else ~20% of a dispute bond buys a difficulty point on
	// any trivially-true claim.
	if cs.provisional != cs.answer {
		resetOverturned(c, cs.answerer)
	} else if cs.decidedRounds > 0 && cs.credEligible {
		creditUpheld(c, cs.answerer) // contested-and-upheld: the hard point
	}
	releasePriority(c, cs.answerer, claimID)
}

// VotableSupply reports a court's raw supply, its escrowed weight, and the
// difference — the weight that can actually vote — at the last sealed epoch.
//
// This exists because the ratio it exposes is the one number that says whether
// a court's dispute lane is alive, and it was previously unobservable: escrow's
// ADDRESS is readable but its share never was. The failure it makes visible
// reads from outside as apathy rather than as a bug — every claim settling
// undisputed, no slash ever firing, no claim ever reaching HIGH — so a court
// that cannot watch this ratio cannot tell consensus from paralysis.
//
// Non-allocating, and it answers 0,0,0 before the first epoch seals rather than
// panicking, matching what the bars themselves do at that point.
func VotableSupply(courtSlug string) (raw, escrowed, votable int64) {
	c := mustCourt(courtSlug)
	at := c.coin.Epoch()
	if at <= 1 {
		return 0, 0, 0
	}
	at--
	raw = c.coin.PastTotal(at)
	escrowed = c.coin.PastVotes(c.escrow, at)
	votable = raw - escrowed
	if votable < 0 {
		votable = 0
	}
	return raw, escrowed, votable
}

// QuorumFloorOf quotes the turnout a dispute on this claim must reach.
// ElectionFloorOf has existed since the election lane shipped; the verdict and
// quality lanes had no equivalent, so their bars could go underwater unseen.
//
// WHILE A DISPUTE IS OPEN THIS RETURNS THE PINNED BAR, not a fresh computation,
// and the distinction is not cosmetic. quorumFloor reads the live sealed epoch
// for its votable/3 arm, while ResolveDispute enforces c.gov.QuorumFloor(pid) —
// the value frozen into the proposal at OpenDispute. Measured on a court where
// the third arm binds, the two were 7.5x apart (66,666,666 quoted against
// 500,000,000 enforced), and web/index.html renders this figure during an open
// dispute.
//
// The direction of harm is the one that matters: an UNDER-quoted bar sends a
// coalition to mobilise short of quorum, the round fails for turnout, and
// dispute.gno's own failed-quorum branch then leaves provisional = answer. So a
// wrong quote hands the claim to the answerer by apathy — the exact S1 failure
// mode, arriving through the read surface rather than through the bar.
func QuorumFloorOf(courtSlug string, claimID uint64) int64 {
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.disputeOpen {
		return c.gov.QuorumFloor(cs.proposalID)
	}
	return quorumFloor(c, cs.xBarFrozen)
}

// QualityBarsOf quotes the demotion and full bars this claim is judged against.
func QualityBarsOf(courtSlug string, claimID uint64) (demotionBar, fullBar int64) {
	c := mustCourt(courtSlug)
	return qualityBars(c, mustClaim(c, claimID))
}

// isParticipant: the claim's author, answerer, or any address with a staker
// record (records persist across withdrawal — conviction holders count).
func isParticipant(cs *claimState, who address) bool {
	if who == cs.author || who == cs.answerer {
		return true
	}
	return cs.stakers.Get(posKey(who, sideYES)) != nil ||
		cs.stakers.Get(posKey(who, sideNO)) != nil
}

// quorumFloor is the court's absolute turnout bar: max(5%·supply,
// min(X̄frozen, votable/3)), at the last sealed epoch; votable nets out the
// escrow so staked capital cannot inflate the denominator. Never zero.
func quorumFloor(c *Court, xbar int64) int64 {
	at := c.coin.Epoch() - 1
	supply := c.coin.PastTotal(at)
	votable := supply - c.coin.PastVotes(c.escrow, at)
	if votable < 0 {
		votable = 0
	}
	floor := xbar
	if third := votable / 3; third < floor {
		floor = third
	}
	// THE SUPPLY ARM AND ITS CLAMP ARE GONE (S1). Both were identities under the
	// only condition worth keeping, and together they handed small claims to the
	// party the bar exists to police.
	//
	// The bar was max()ed against 5% of court SUPPLY while the prize a claim pays is
	// denominated in that claim's own STAKE. Below X̄ = 5%·supply no turnout
	// proportional to the claim could clear it — 6.6x short at 1% of supply — and an
	// unreachable quorum does not mean "no verdict": the failed-quorum branch leaves
	// provisional = answer, burns half the disputer's bond, and returns the answer
	// bond whole. So non-satisfaction was a WIN for the answerer, and raising the bar
	// could not make that safer.
	//
	// Deleted rather than gated: under the gate that keeps them honest
	// (xbar >= fivePct) both blocks are provable identities — the arm can only bite
	// when 5%·supply exceeds votable/3, and the clamp then restores votable/3, which
	// min(X̄, votable/3) already equalled. Verified analytically and measured over
	// 3.9M rows including an exhaustive sweep of [0,120]^3: zero divergences. Gating
	// them would have left two unreachable blocks and a page of prose describing
	// behaviour that no longer runs.
	//
	// WHAT THIS DOES NOT DO, because the honest framing matters: it does not let the
	// robbed pool defend itself. VoteDispute refuses any address with a staker row on
	// either side, there is no stakers.Remove anywhere in this realm, and a staker who
	// withdraws in full before the answer still carries the row — measured, a pool
	// holding 5x the floor was refused at the door. This lowers a bar only
	// NON-PARTICIPANTS can clear. What it buys is that a verdict becomes reachable at
	// all, by third parties, instead of defaulting to the answer.
	//
	// And it is symmetric: it drops the price of deciding an arbitrary small claim's
	// verdict from 5% of supply to the answerability floor's 0.10%, so the same
	// relaxation makes a malicious overturn reachable by those same third parties —
	// measured at −4.80 CC to +19.20 CC, and SIMULTANEOUS across every concurrently
	// open claim, since voting consumes no weight. That trade is accepted because the
	// snipe it fixes is currently FREE while a false overturn costs a bond.
	//
	// THE 5% ANCHOR IS KEPT ELSEWHERE, and the three places do NOT share a
	// denominator. This list used to say they did, which matters because a base
	// mismatch is the exact bug class that has already bitten twice here: the
	// election bond was quoted on supply against a floor on votable, and ccwrap's
	// vault sat inside votable while no key could vote it. Read off the code:
	//
	//   election floor      5% of VOTABLE (modvote.gno electionFloor)
	//   quality full bar    5% of SUPPLY, then clamped down to votable/3 — the
	//                       clamp is what keeps it reachable, not the base
	//   credWeightFloor     5% of ENGAGED, and EngagedTotal == PastTotal, so RAW
	//                       SUPPLY with no votable clamp at all
	//
	// credWeightFloor is the outlier and it is deliberate. It gates a POWER —
	// credEligible needs weight >= floor/4 voted AGAINST before an aggressive meta
	// verb executes — so a larger floor WITHHOLDS the verb. Measured at two fifths
	// escrowed: 5.00e9 on supply against 3.00e9 on votable, so the supply base is
	// 1.67x stricter, and it grows stricter as escrow grows. Re-basing it on
	// votable "for consistency" would make an aggressive override that much cheaper
	// to unlock, which is what TestCredWeightFloorIsQuotedOnSupplyNotVotable stops.
	//
	// Note check-demo-physics reads quorumSupplyBps out of this file BY NAME.
	// LAST, deliberately: governor.ProposeWithQuorum refuses a non-positive
	// floor, and a fully-escrowed court has votable == 0.
	if floor < 1 {
		floor = 1
	}
	return floor
}

func oppositeSide(side int) int {
	if side == sideYES {
		return sideNO
	}
	return sideYES
}

// escrowWindow is how long a provisional verdict stays reopenable before
// Finalize can land: clamp(1 week + 1 day per 500 GNOT-equivalent of X̄frozen,
// escrowMin, escrowMax) — V1's rule with X̄frozen as V2's size proxy (the
// collateral is gone). X̄frozen is immutable after the answer, so the window
// cannot be shortened by manipulation; the 1-week floor bounds it regardless.
func escrowWindow(c *Court, cs *claimState) int64 {
	extraDays := mulDiv128(cs.xBarFrozen, c.crv.Price(c.minted), 500_000_000)
	room := (c.params.escrowMaxBlocks - c.params.escrowMinBlocks) / oneDayBlocks
	if extraDays >= room {
		return c.params.escrowMaxBlocks
	}
	return c.params.escrowMinBlocks + extraDays*oneDayBlocks
}

// oneDayBlocks is a day at the five-second cadence, the escrow window's unit.
const oneDayBlocks = int64(24) * epochBlocks

// ------------------------------------------------------------------ reads --

func DisputeOpen(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).disputeOpen
}

func DisputeProposal(courtSlug string, claimID uint64) int64 {
	return mustClaim(mustCourt(courtSlug), claimID).proposalID
}

// Provisional is the standing (reopenable) verdict: sideYES/sideNO, -1 none.
func Provisional(courtSlug string, claimID uint64) int {
	return int(mustClaim(mustCourt(courtSlug), claimID).provisional)
}

func FailedRounds(courtSlug string, claimID uint64) int64 {
	return mustClaim(mustCourt(courtSlug), claimID).failedRounds
}

func ProvClose(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).provClose
}

func EscrowUntil(courtSlug string, claimID uint64) int64 {
	return mustClaim(mustCourt(courtSlug), claimID).escrowUntil
}

// DisputeBondNext quotes what the NEXT dispute round costs right now — the
// page's bond quote (0-guard: quotable even before an answer exists).
func DisputeBondNext(courtSlug string, claimID uint64) int64 {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.frozenAt == 0 {
		return 0
	}
	return cs.disputeBond0()
}

// Reopenable reports whether the standing provisional verdict can still be
// disputed again. A client gates the "reopen" txlink on this.
func Reopenable(courtSlug string, claimID uint64) bool {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return cs.provisional >= 0 && cs.verdictAt == 0 && !cs.disputeOpen &&
		heightNow() < cs.escrowUntil
}

// ladderWindow is the window a DEFAULTED verdict needs so the failed-round ladder
// can actually be walked: one votingBlocks per round after the first, plus a
// resolution-latency allowance per round, plus one block.
//
// THE GRACE TERM IS A LATENCY BUDGET, NOT CONSERVATISM — do not "simplify" it away.
// ResolveDispute is permissionless and escrowUntil is stamped once, so every block
// between a vote closing and somebody cranking it is spent out of this window.
// Measured: a round-2 resolution 34,559 blocks late still reaches provClose, and
// 34,560 does not. At the bare arithmetic minimum that budget is ZERO — the ladder
// would require a resolver in the closing block of every single round.
func ladderWindow(p Params) int64 {
	return (maxFailedRounds-2)*p.votingBlocks + (maxFailedRounds-1)*p.graceBlocks + 1
}

// credWeightFloor is the CREDENTIAL bar's own anchor: 5% of the court supply that
// was actually engaged by this tally.
//
// It keeps the 5%-of-supply price the quorum floor is giving up, because the
// credential prices a CAREER and must not become forgeable just because one claim's
// bar fell. Without it the bar would follow the claim (X̄/4), a cut of 5% divided by
// the claim's share of supply — 50x at the answerability floor — and two socks
// totalling 1.125% of supply would mint a record.
//
// THE EPOCH IS THE PROPOSAL'S, and that is the whole point of routing through
// Snapshot. The numerator `yes` was weighed at the proposal's snapshot epoch; reading
// supply at resolve instead reads it ~168 epochs later, so the bar would move under a
// frozen tally and anyone could mint inside the voting window to strip an honest
// contested uphold of its credit — measured 2.43x skew. It cuts both ways: burns
// during the window would LOWER the bar, and ResolveDispute is permissionless, so a
// farmer would pick the block.
func credWeightFloor(c *Court, pid int64) int64 {
	engaged, _ := c.gov.Snapshot(pid)
	return mulDiv128(engaged, quorumSupplyBps, grc20votes.Bps)
}

// credWeightFloorAt is credWeightFloor's expression against an explicit epoch,
// for asking what a FRESH round would be judged against. Split out so the test
// that pins the denominator reads the shipped formula instead of a paraphrase of
// it — a paraphrased bar cannot notice the shipped one being re-based.
func credWeightFloorAt(c *Court, at uint32) int64 {
	return mulDiv128(c.coin.EngagedTotal(at), quorumSupplyBps, grc20votes.Bps)
}
