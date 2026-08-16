// The dispute machine — V1's audited round structure (doubling bonds, sealed
// 7-day tallies, tally-based classification, escrow windows, reopens, 3-round
// close) with the V2 dispositions (PLAN §3.6, v0.11–v0.25):
//
//   FORFEITURES BURN; COMPENSATION MINTS. No value ever moves between
//   adversaries on any outcome — punishment is deflation, reward is issuance,
//   senior-queued: comp = min(2 × the prevailing party's own bond,
//   floor(80% × the loser's burned bond)), reserved at the round's decision.
//
//   Failed (quorum-less) rounds burn HALF the disputer's bond and return half
//   (turnout is not the disputer's conduct); the answerer is NOT comped on a
//   failed round — their bond simply survives, escrowed until the verdict is
//   final. Three failed rounds close the claim without a decision: everyone
//   1×, deposit AND fee refund, no draw.
//
//   Every %·X̄ quantity reads the ONE X̄frozen snapshot taken at the answer
//   (P6): bond base = min(20%·X̄frozen, 40% × the actual answer bond),
//   doubling per failed round, claim-scoped (sybil-proof).
//
// Rounds are framed against the ORIGINAL answer (V1): overturn sets the
// provisional verdict to its opposite, uphold to the answer itself; a reopen
// vote can flip it back. Bonds are disposed at each round's decision (the
// per-event burn must accompany its comp reservation — A19's invariant); the
// answer bond is burned only by the round that decides against it and returned
// only at VERDICT_FINAL. Answer records move ONCE, at Finalize, from the final
// verdict (P13) — intermediate rounds never churn the record.
package courtv2

import (
	"chain/runtime"
	"strconv"

	governor "gno.land/p/cryptocourt/governor/v0"
	grc20votes "gno.land/p/cryptocourt/grc20votes/v0"
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
		panic("courtv2: there is no answer to dispute")
	}
	if who == cs.answerer {
		// Hygiene only (a sybil wallet trivially evades it): the REAL
		// credential defense is the credEligible weight bar below (M2-1).
		panic("courtv2: the answerer cannot dispute their own answer")
	}
	if cs.disputeOpen {
		panic("courtv2: a dispute is already open on this claim")
	}
	if cs.verdictAt != 0 {
		panic("courtv2: the verdict is final")
	}
	now := runtime.ChainHeight()
	if cs.provisional < 0 {
		// First round: the 72h settle delay IS the dispute window — after it,
		// only SettleUndisputed. The two guards partition every height, so no
		// settle/dispute race exists.
		if now >= cs.answerHeight+settleDelay {
			panic("courtv2: the dispute window has passed; the answer settles undisputed")
		}
	} else if now >= cs.escrowUntil {
		panic("courtv2: the escrow window has passed; Finalize the verdict")
	}
	touch(c)
	// A dispute outranks the quality lane: an open flag VOIDS (bond returned,
	// slot unconsumed — the dispute's own tally carries quality), and a fresh
	// ride tally opens with the round.
	voidFlag(c, cs)
	openQualityTally(cs)

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
		panic("courtv2: no open dispute on this claim")
	}
	c.gov.Vote(who, cs.proposalID, choice)
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
		panic("courtv2: no dispute to resolve")
	}
	if c.gov.State(cs.proposalID) == "active" {
		panic("courtv2: the dispute vote is still open")
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
		resolveQualityRide(c, cs)
	default:
		// UPHOLD (tie, all-abstain, or a sub-threshold split, quorum met):
		// the disputer's bond BURNS in full; the answerer is comped against
		// their posted bond magnitude (answerBond0 — the live field may
		// already be spent by an earlier overturn round). Their bond stays
		// escrowed until VERDICT_FINAL: still at stake for reopens.
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
		resolveQualityRide(c, cs)
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
}

// Finalize makes a disputed claim's standing provisional verdict FINAL once
// the escrow window has passed with no active dispute: withdrawals open for
// both sides, the answer bond is disposed (returned if the answer stands —
// it burned already if not), and the answer record moves once, from the final
// verdict (P13). Participant-only for the first week of eligibility (A13),
// permissionless after. Deposit and fee wait for QUALITY_FINAL (crystallize).
func Finalize(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.verdictAt != 0 {
		panic("courtv2: already final")
	}
	if cs.disputeOpen {
		panic("courtv2: a dispute is active; cannot finalize")
	}
	if cs.provisional < 0 {
		panic("courtv2: no provisional verdict to finalize")
	}
	now := runtime.ChainHeight()
	if now < cs.escrowUntil {
		panic("courtv2: the escrow window has not passed")
	}
	if now < cs.escrowUntil+finalizeGraceBlocks && !isParticipant(cs, who) {
		panic("courtv2: Finalize is participant-only for its first week")
	}
	touch(c)

	cs.verdictAt = now
	cs.route = "vote"
	cs.tier = tierMidX // default pending the quality machinery (quality.gno)
	if cs.answerBond > 0 {
		// The answer stood (an overturned bond was burned at its round).
		c.coin.Transfer(c.escrow, cs.answerer, cs.answerBond)
		cs.answerBond = 0
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
