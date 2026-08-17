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
	"chain/runtime"
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
	now := runtime.ChainHeight()
	if cs.provisional < 0 {
		// First round: the 72h settle delay IS the dispute window — after it,
		// only SettleUndisputed. The two guards partition every height, so no
		// settle/dispute race exists.
		if now >= cs.answerHeight+settleDelay {
			panic("kourtv2: the dispute window has passed; the answer settles undisputed")
		}
	} else if now >= cs.escrowUntil {
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
	c.gov.Vote(who, cs.proposalID, choice)
	// Court-side choice record: the governor's roll is reclaimable after
	// resolution (ReleaseRoll is permissionless), so the carrot must not
	// depend on it. Weight is recomputed later from PastVotes at the
	// proposal's epoch; only the choice needs remembering.
	if cs.qVoted == nil {
		cs.qVoted = bptree.NewBPTree32()
	}
	cs.qVoted.Set("d"+beClaimKey(uint64(cs.proposalID))+string(who), choice)
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
		if yes >= floor/4 {
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
		cs.escrowUntil = runtime.ChainHeight() + escrowWindow(c, cs)
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
	cs.verdictAt = runtime.ChainHeight()
	cs.route = "closed"
	cs.tier = tierLowX
	cs.tierFinal = true
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
	now := runtime.ChainHeight()
	if now < cs.escrowUntil {
		panic("kourtv2: the escrow window has not passed")
	}
	if now < cs.escrowUntil+finalizeGraceBlocks && !isParticipant(cs, who) {
		panic("kourtv2: Finalize is participant-only for its first week")
	}
	touch(c)

	cs.verdictAt = now
	cs.route = "vote"
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
func QuorumFloorOf(courtSlug string, claimID uint64) int64 {
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
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
	if fivePct := mulDiv128(supply, quorumSupplyBps, grc20votes.Bps); fivePct > floor {
		floor = fivePct
	}
	// THE CLAMP THIS FUNCTION ALREADY IMPLIED AND THEN THREW AWAY (v0.29, three
	// reviewers, 2/3 preferring this over netting and the third naming it as its
	// own fallback).
	//
	// The X̄ arm above is clamped to votable/3 — this function's own statement of
	// how high a turnout bar may go and still be decidable. The 5% arm then
	// max()es past that ceiling. And 5%·supply exceeds votable/3 exactly when
	// escrow passes 85% of supply, so the supply arm breaks the reachability rule
	// in precisely, and only, the regime where the lane is already dying. Above
	// 95% the bar exceeds ALL votable weight and no set of votes can clear it.
	//
	// Totalling the clamp is BIT-IDENTICAL for every court under 85% escrow, so
	// it weakens nothing in the normal range; above it, "a third of the float"
	// replaces "impossible". Netting the 5% arm instead would have divided the bar
	// by (1−E) at EVERY level — 20× at 95% escrow — buying nothing at 50% where
	// the bar was already fine.
	//
	// Why this matters more than it looks: an unreachable quorum does NOT mean
	// "no verdict". The failed-quorum branch leaves cs.provisional = cs.answer,
	// burns half the disputer's bond, and returns the answer bond whole. So the
	// bar hands the decision to the party it exists to police, and challenging
	// costs ~70%·X̄ across three doubling rounds to deny a draw worth ≤31%. A bar
	// whose non-satisfaction means the policed party wins cannot be made safer by
	// raising it.
	if third := votable / 3; floor > third {
		floor = third
	}
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
		runtime.ChainHeight() < cs.escrowUntil
}
