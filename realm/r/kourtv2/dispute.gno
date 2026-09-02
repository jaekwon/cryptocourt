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

	// Bond: min(20%·X̄frozen, 40% × the actual answer bond) — the v0.25 arm
	// keeps round 1 at q > 1/3 on every claim including bond-capped courts —
	// doubled per failed round, claim-scoped (a fresh disputer address cannot
	// reset the multiplier). provClose bounds failedRounds ≤ 2 here; the
	// clamp guards the shift regardless.
	bond := cs.disputeBond0()
	mustSpendable(c, who, bond)
	c.coin.Transfer(who, c.escrow, bond)

	floor := quorumFloor(c, cs.xBarFrozen)
	cs.round++
	payload := strconv.FormatUint(claimID, 10) + "|" + strconv.FormatInt(cs.round, 10)
	pid := c.gov.ProposeWithQuorum(c.escrow, disputeKindName, payload, "dispute", floor)

	cs.proposalID = pid
	cs.disputeOpen = true
	cs.disputeOpenedTime = nowTime()
	cs.disputeBond = bond
	cs.disputer = who
	return pid
}

// VoteDispute casts a vote on a claim's open dispute — "yes" to overturn the
// answer, "no" to uphold it, "spam" to say the claim was not worth judging.
//
// SPAM REPLACED ABSTAIN, and it is the same bucket underneath. Abstain was
// strictly dominated: it locked the same coin and added the same turnout as a
// side vote, while the carrot pays only voters who matched the verdict, so it
// had every cost and no upside and no payoff-maximiser ever pressed it. The
// bucket's MECHANICS are exactly what a spam flag wants, though — the governor
// counts it toward quorum (turnout = yes+no+abstain) and excludes it from the
// verdict bar (forAndAgainst = yes+no) — so the slot is repurposed rather than
// a fourth one added.
//
// What it now DOES is elsewhere: past half the weight cast, the claim is
// discarded; below that it discounts the claim's reward in proportion.
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
	// that let `yes` exceed anything the electorate held while the early arms'
	// denominator stayed snapshotted at (total - abstain) — a proposal passing on
	// support that did not exist. (An earlier comment here said it "dropped `no`
	// out of the early-decide test"; that reduction holds identically either way,
	// so it was never the symptom. governor.gno has the algebra.)
	//
	// Refused here rather than in the governor so the message is this court's. See
	// quality.gno for the derivation, and VOTEFLOOR.md for why the snapshot alone
	// was rentable: this is the lane the end-to-end rental was demonstrated on.
	held := voteCap(c, who)
	if held <= 0 {
		// "NO LONGER" WOULD BE A GUESS HERE, and for most people a wrong one.
		// voteCap is the balance NOW, and this guard has no snapshot check in
		// front of it — unlike quality.gno and modvote.gno, which refuse on
		// `snapshot <= 0` first and so have earned that word by the time they
		// reach it. Here a holder who sold and a stranger who never held a unit
		// arrive at the same line, and the second is the common case: it is the
		// message anyone who finds the court and tries to vote will read.
		panic("kourtv2: you hold none of this court's coin, and voting weight is " +
			"the lesser of what you held when the round opened and what you hold now")
	}
	// TWO VOCABULARIES, ONE TRANSLATION POINT. The court says "spam"; the
	// governor says "abstain", which is its own word for the bucket that counts
	// toward quorum and not toward a side. The p/ layer's vocabulary is not ours
	// to rename, so the mapping happens here and nowhere else.
	//
	// The literal "abstain" is REFUSED rather than accepted as a synonym. Two
	// names for one bucket is how a client and a realm come to disagree about
	// what was cast — and a caller still sending "abstain" is a caller written
	// against the old meaning, which no longer describes what the vote does.
	govChoice := choice
	switch choice {
	case voteYes, voteNo:
	case voteSpam:
		govChoice = govAbstain
	default:
		panic("kourtv2: a dispute vote is \"yes\" to overturn, \"no\" to uphold, " +
			"or \"spam\" to say the claim was not worth judging")
	}
	c.gov.VoteWithCap(who, cs.proposalID, govChoice, held)
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
	if cs.voted == nil {
		cs.voted = bptree.NewBPTree32()
	}
	// THE COURT'S WORD, not the governor's: this record is what PullCarrot
	// compares against cs.carrotChoice, and that is set in this realm's
	// vocabulary. Storing govChoice here would make a spam voter's record read
	// "abstain" and never match the "spam" the discard path records.
	cs.voted.Set("d"+beClaimKey(uint64(cs.proposalID))+string(who), choice)
	_, dw, ok := c.gov.VoteOf(cs.proposalID, who)
	if !ok {
		panic("kourtv2: the governor did not record the vote it just accepted")
	}
	cs.voted.Set("dw"+beClaimKey(uint64(cs.proposalID))+string(who), dw)
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

	// spamW, not "abstain": the governor's third bucket is the court's spam flag
	// (VoteDispute translates at the boundary), and calling it by the p/ layer's
	// name here is how the two meanings drift apart again.
	yes, no, spamW, _ := c.gov.Tally(cs.proposalID)
	cast := yes + no + spamW
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
		// Only the FIRST failed round defaults the verdict to the answer; a
		// failed reopen leaves a standing decided verdict untouched.
		if firstResolution {
			cs.provisional = cs.answer
		}
		cs.failedRounds++
		if cs.failedRounds >= maxFailedRounds {
			provCloseClaim(c, cs)
		}
	// DISCARDED, and its position in this switch is the protection. It sits
	// AFTER the failed-quorum arm, so a discard is a fraction of a turnout that
	// already cleared min(X̄, votable/3) — three voters cannot delete a claim.
	// And BEFORE the verdict arms, because a claim the court threw out has no
	// verdict to reach: whether the answer was right is not a question worth
	// settling once the electorate has said the claim should not have been asked.
	case spamDiscards(spamW, cast):
		spamDiscardClaim(c, cs, spamW, cast)
	case yes > 0 && yes*grc20votes.Bps >= (yes+no)*c.params.disputeThresholdBps:
		// OVERTURN: the answer was wrong. The answer bond BURNS in full (the
		// forfeiture); the disputer's own bond returns; comp mints
		// senior-queued, capped by both arms (v0.20). A reopen after a prior
		// overturn finds answerBond already zero — comp's 80% arm is then 0
		// and nothing mints (no burn happened this round to anchor it).
		posted := cs.disputeBond // the disputer's own risk, captured pre-zeroing
		burned := cs.answerBond
		if burned > 0 {
			c.coin.Burn(c.escrow, burned)
			cs.answerBond = 0
			// STAMP THE WINNER HERE, INSIDE THE FORFEITURE, and not below with
			// the rest of the round bookkeeping. The credit is for causing a
			// forfeiture, so it belongs to the round that caused one — and only
			// the first overturn ever does: it zeroes answerBond, so a second
			// overturn burns nothing, returns its own bond whole, mints no comp,
			// and would otherwise re-stamp this field at zero net cost and take
			// the credit from the address that actually won. Both halves are
			// captured together because they answer one question: who won, and
			// with how much of their own capital.
			cs.overturnBy = cs.disputer
			cs.overturnBond = posted
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
		// The spam share of THIS round, frozen with the rest of the deciding
		// round's record. cast is yes+no+spam — the same denominator the quorum
		// bar was measured against, so the discount is a fraction of the turnout
		// that actually decided the claim.
		cs.spamW, cs.spamTotalW = spamW, cast
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
		// The spam share of THIS round, frozen with the rest of the deciding
		// round's record. cast is yes+no+spam — the same denominator the quorum
		// bar was measured against, so the discount is a fraction of the turnout
		// that actually decided the claim.
		cs.spamW, cs.spamTotalW = spamW, cast
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

// disputeBond0 is the dispute bond at the claim's current failed-round count: the
// ONE definition, quoted by DisputeBondNext and the claim page and CHARGED by
// OpenDispute.
//
// It said "OpenDispute's formula, factored for DisputeBondNext" while OpenDispute
// went on computing the same eleven lines itself, byte for byte. That is a quote
// that can drift from the charge — the shape check-epoch-coherence's one-weight arm
// exists to prevent for vote weight, unguarded here for money. What drift would look
// like: render.gno tells the user "N CC units (doubles per failed round)" and
// DisputeBondNext returns N, and then OpenDispute takes something else.
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

// spamDiscardClaim ends a claim the electorate threw out: more than half the
// weight cast called it spam.
//
// ONLY REACHABLE WITH QUORUM MET, because it is a case in ResolveDispute's
// switch AFTER the failed-quorum arm. That ordering is the whole protection
// against a three-voter deletion — the discard is a fraction of a turnout that
// already had to clear min(X̄, votable/3).
//
// THE AUTHOR IS THE ONLY PARTY WHO LOSES, which is where the spam came from:
//
//	stakes, both sides   returned 1x   (provClose opens the same withdrawals)
//	answerer's bond      returned      they did the work; the junk is not theirs
//	disputer's bond      returned      they opened the round that FOUND it —
//	                                   burning it would discourage the only path
//	                                   that surfaces spam at all
//	the fee              always burns  it is the anti-spam price and this is the
//	                                   case it was priced for
//	the deposit          burns at 2/3  a supermajority, not a bare majority: the
//	                                   deposit is the harshest money consequence
//	                                   in this system reachable by somebody who
//	                                   posted no bond, so it wants a wider margin
//	                                   than the discard itself
//
// It carries provClose as well as spamClosed. That is not sloppiness: provClose
// is what every withdrawal path already reads to mean "everyone takes their
// principal back", and reusing it is how the stake half of this needs no new
// code. spamClosed is the REASON, so a page can tell a claim nobody turned up
// for from one the court looked at and threw out.
//
// No draw is written and none is possible: the claim's own spam share is past
// half, so spamNetBps is zero and crystallize multiplies the draw to nothing.
// Belt and braces, in opposite directions — the money is refused here and the
// arithmetic refuses it again there.
// spamDiscards and spamBurnsDeposit are the two thresholds, as predicates.
//
// EXTRACTED so they can be tested without a claim. They are integer comparisons
// with no division — a fraction here would round, and rounding at a threshold is
// how "exactly half" ends up on the wrong side of a line the owner drew.
//
// The pair is deliberately asymmetric: the discard is a bare majority, and the
// deposit burn wants a supermajority. Burning an author's deposit is the harshest
// money consequence in this system reachable by somebody who posted no bond, so
// it does not ride on the same margin that merely deletes the claim.
func spamDiscards(spamW, cast int64) bool { return spamW*2 > cast }

func spamBurnsDeposit(spamW, cast int64) bool { return spamW*3 >= cast*2 }

func spamDiscardClaim(c *Court, cs *claimState, spamW, cast int64) {
	cs.spamClosed = true
	cs.provClose = true
	cs.verdictAt = heightNow()
	cs.verdictAtTime = nowTime()
	cs.route = "spam"
	cs.spamW, cs.spamTotalW = spamW, cast
	// THE CARROT PAYS THE SIDE THAT WON, and here that side is spam.
	//
	// Without this the spam button is dominated exactly as abstain was — same
	// coin locked, same turnout added, no upside — and no payoff-maximiser ever
	// presses it. A flag nobody rationally raises is not a signal, so this line
	// is what makes the button real rather than decorative.
	//
	// It needs no new record. VoteDispute already writes each voter's choice in
	// the COURT's vocabulary under "d"+pid+addr, and PullCarrot compares that
	// against carrotChoice — so writing voteSpam here is the whole wiring. That
	// is the one-character seam step 1 was careful about.
	//
	// decidedPID is set for the same reason the verdict arms set it: PullCarrot
	// reads the DECIDING round's record, and cs.proposalID is overwritten by any
	// later round. A discarded claim has no later round, but the read is shared
	// and must not depend on that.
	cs.decidedPID, cs.carrotChoice, cs.carrotDenom = cs.proposalID, voteSpam, spamW

	if cs.answerBond > 0 {
		settleAnswerBond(c, cs)
	}
	if cs.disputeBond > 0 {
		c.coin.Transfer(c.escrow, cs.disputer, cs.disputeBond)
		cs.disputeBond = 0
	}
	// THE SUPERMAJORITY ARM, in integers and on the same numbers the discard
	// used: two thirds of the weight cast, not two thirds of the spam.
	burnDeposit := spamBurnsDeposit(spamW, cast)
	if cs.deposit > 0 {
		if burnDeposit {
			c.coin.Burn(c.escrow, cs.deposit)
		} else {
			c.coin.Transfer(c.escrow, cs.author, cs.deposit)
		}
		c.deposit -= cs.deposit
		cs.deposit = 0
	}
	if cs.fee > 0 {
		c.coin.Burn(c.escrow, cs.fee)
		c.deposit -= cs.fee
		cs.fee = 0
	}
	releasePriority(c, cs.answerer, cs.id)
	stripExit(c, cs)
	releaseMetaLatchIfMeta(c, cs)
}

// provCloseClaim closes a claim without a decision after three failed rounds:
// everyone 1× (withdrawals open), no draw ever, the answer bond returns, the
// deposit AND fee refund (provClose is not a conclusive low — §3.1.7).
func provCloseClaim(c *Court, cs *claimState) {
	cs.provClose = true
	cs.verdictAt = heightNow()
	cs.verdictAtTime = nowTime()
	cs.route = "closed"
	if cs.answerBond > 0 {
		settleAnswerBond(c, cs)
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
	if cs.answerBond > 0 {
		// The answer stood — an overturned bond was burned at its round, so
		// reaching here with a bond means it was never forfeited. It returns
		// WHOLE; why whole rather than partly retained is settleAnswerBond's
		// story (answerbond.gno), not repeated here.
		//
		// ONE PREDICATE, SHARED, and this part is live: the gate is
		// character-identical to SettleUndisputed's, which is the v0.44 symmetry
		// goal and the reason settleAnswerBond exists at all rather than the same
		// two lines appearing on both terminal paths. v0.43's proof that an
		// overturn cannot retain rests on the enclosing `answerBond > 0` alone.
		//
		// WHAT USED TO BE HERE, kept as a record because a bare deletion invites
		// its return: twenty-four lines sizing a slash-sized reserve to hold past
		// Finalize (M3-HIGH-1, v0.47), on the reasoning that votingBlocks exceeds
		// the dispute and escrow windows so a conclusive-low flag would resolve
		// after this point and find a bond already returned. It reasoned through
		// quality.gno's gate, slotConsumed, OpenFlag and a pending slash — the
		// lane those belong to is gone, and none of those symbols has a
		// non-comment line left in this realm. It also claimed to "retain a
		// slash-sized reserve exactly as SettleUndisputed does", which stopped
		// being true when that path stopped retaining; its twin note was corrected
		// in 76b2941. decidedRounds, which the old text also named, IS still live
		// — it is the gate that went, not the counter.
		settleAnswerBond(c, cs)
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
	// Standing rides the SAME predicate one ledger over (standing.gno), and
	// deliberately so — an uphold earns only when it was credEligible, because
	// otherwise ~20% of a dispute bond buys standing on any trivially-true claim,
	// which is the M2-1 finding this branch already encodes for the record.
	// The two ledgers stay separate: this one is slashable, the record is not.
	creditDisputeResolved(c, cs)
	releasePriority(c, cs.answerer, claimID)
}

// VotableSupply reports a court's coin supply at the last sealed epoch, split
// three ways: raw is the whole supply, escrowed is the weight sitting in the
// court escrow, and votable is raw minus escrowed — the base every percentage
// bar in this court is quoted against.
//
// VOTABLE IS AN UPPER BOUND ON WHAT CAN ACTUALLY VOTE, not the figure itself.
// It nets out the court escrow and nothing else. Coin parked at a wrapper's
// address is inside `votable` while no key can vote it, so the castable total is
// `votable` minus whatever the wrapper holds. A client that knows the wrapper
// can subtract CoinBalanceOf(courtSlug, wrapperAddress) itself; this court does
// not, deliberately, so that no safety bar here depends on that package being
// correct. r/kourt/ccwrap caps its vault at 35% of votable, so the overstatement
// is bounded at 35% while that cap holds.
//
// Read it as the health of a court's dispute lane: a court where escrowed is
// most of raw has little weight left to vote on the claims that weight is staked
// against, and that reads from outside as apathy rather than as a fault.
//
// Answers 0, 0, 0 before the first epoch seals rather than refusing. Refused
// only on a court that does not exist.
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

// QuorumFloorOf quotes the turnout a dispute on this claim must reach for the
// vote to decide anything, in CC base units.
//
// WHILE A DISPUTE IS OPEN THIS IS THE BAR THAT WILL ACTUALLY BE ENFORCED — the
// figure frozen into that round when it opened, not a fresh computation. With no
// dispute open it quotes what a dispute opened now would face, which moves with
// supply and can be several times smaller. Mobilise against the number this
// returns while the round is live.
//
// The bar exists to stop a thin round deciding a claim, and missing it is not
// neutral: a dispute that fails for turnout leaves the provisional verdict equal
// to the ANSWER, so falling short hands the claim to the answerer.
//
// Refused when the court or the claim does not exist.
func QuorumFloorOf(courtSlug string, claimID uint64) int64 {
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.disputeOpen {
		return c.gov.QuorumFloor(cs.proposalID)
	}
	return quorumFloor(c, cs.xBarFrozen)
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
	// THE VOTE LOCK DID NOT CLOSE THIS, and saying so matters more than the lock's
	// good news. The lock commits the coin voted with, but voteLockedOf takes the MAX
	// across a holder's open questions, not the sum — one pile of coin still votes in
	// every concurrently open claim, and it must, because the two locks a holder can
	// carry overlap rather than stack. Measured, in
	// TestTwoQuestionsCommitOnePileOnce: two questions, one commitment.
	//
	// So the simultaneity survives exactly as written. What the lock adds is a CARRY
	// cost rather than a per-claim cost: the attacker holds that one pile through the
	// longest round it voted in, roughly a week, instead of voting everywhere and
	// selling in the next block. The return still scales with the number of open
	// claims; it is now earned against a week of price risk on the whole position.
	// A reader arriving from VOTEFLOOR.md should not infer more than that.
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

// The dispute ballot's three choices, in the COURT's vocabulary.
//
// voteSpam is the governor's abstain bucket under a name that says what it does
// here. Quoted as constants because the same three strings are compared in
// VoteDispute, recorded in voted and matched by PullCarrot, and a typo in any
// one of them is a vote that silently never earns its carrot.
const (
	voteYes  = "yes"
	voteNo   = "no"
	voteSpam = "spam"

	// govAbstain is the p/ layer's word for the same bucket. Named so the one
	// translation point in VoteDispute reads as a translation rather than as a
	// magic string, and so nothing else in this realm reaches for it by accident.
	govAbstain = "abstain"
)

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

// DisputeVoteCloses is the height this claim's open dispute round stops taking
// votes, or 0 when no round is open.
//
// The governor has always known it — Timings(id) returns (opened, closes,
// ready, expires) and closes is a HEIGHT, set at propose() as
// `now + rules.VotingBlocks` off the same realmClock every deadline here uses.
// What was missing is a way to ask kourtv2 for it, so a client showing "voting
// closes in four days" had nothing to compute from: the overlay carried the
// close by hand for its sample data and said, in live mode, that no read
// published one. This is that read.
//
// A HEIGHT, NOT A TIME, because that is what the governor gates on: Vote
// refuses once heightNow() >= closes. Projecting it into a date is the
// consumer's job and its projection is an estimate — the chain's cadence is
// not a promise — so this returns the number the court will actually check.
//
// 0 rather than a panic on a claim with no open round: a client asks this on
// every claim page it draws, and "no round is open" is an answer, not an error.
func DisputeVoteCloses(courtSlug string, claimID uint64) int64 {
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if !cs.disputeOpen || cs.proposalID == 0 {
		return 0
	}
	_, closes, _, _ := c.gov.Timings(cs.proposalID)
	return closes
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
