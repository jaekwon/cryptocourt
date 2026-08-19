// The quality lane (PLAN §3.4, §10.2 Q1-Q5): was this claim low, mid, or high
// information? A court-local SEALED 3-bucket tally answers it — riding every
// decided dispute round for free, and available standalone through the one
// per-claim FLAG slot. The tally's electorate is pinned at the answer
// (qualityEpoch, Q1): capital staked by then is disenfranchised on its own
// payout multiplier, and the flagger cannot shop epochs.
//
// The flag slot: consumed only by a CONCLUSIVE vote. Inconclusive outcomes
// reopen it with a doubled bond (frozen at 4×b₀ after 3 cycles + a 7-day
// cooldown) — flaggability never ends, it only reprices (v0.24). Bond
// dispositions follow the two-tier-low table (v0.25-v0.29): conclusive low
// returns the bond and pays a burn-dominated bounty; conclusive mid/high
// burns it (flag risk cuts both ways); inconclusive-mid half-burns;
// inconclusive-low returns in full (T1 — the electorate's absenteeism is not
// the flagger's fault, and a bond return is not income).
//
// The slash (max(4.5%·X̄, 1.6× the forgone mid draw), from the answer bond)
// fires only at the supply-floored FULL bar with a ⅔-low supermajority, and even
// then it only RESERVES: the burn and its bounty escrow one counter-flag window
// in which the slashed answerer may force one re-vote (v0.31, Q5).
//
// It is NOT gated on the answer being undisputed (v0.28's extra clause, deleted
// in v0.47): that made immunity purchasable for ~4%·X̄ — below even the flat
// slash floor — with a sock dispute deliberately lost. Winning an argument about
// whether the ANSWER is right settles nothing about whether the CLAIM was worth
// answering. A round supersedes an adjudicated slash only by RE-ADJUDICATING
// quality: an overturn burns the bond slash-inclusive (A19), and an upheld
// round's ride is scored on ResolveCounter's own bar.
//
// A dispute arriving mid-flag VOIDS the flag (bond returned whole, slot
// unconsumed, no cycle counted): the dispute vote carries quality itself, and
// anything less would let a dust flag's 7-day vote blockade the 72h dispute
// window — the verdict lane always outranks the quality lane. A dispute does NOT
// void a RESERVED slash: opening a round is not adjudicating one.
package kourtv2

import (
	bptree "gno.land/p/nt/bptree/v0"
)

// Quality buckets. Ints in the API for gnokey ergonomics.
const (
	qualityLow  = 0
	qualityMid  = 1
	qualityHigh = 2
)

// flagCooldownBlocks is the 7-day per-flag cooldown once the bond is frozen.
const flagCooldownBlocks = int64(120_960)

// flagBondFor quotes the flag bond at the claim's current cycle count:
// b₀ = max(flagMin, 2%·X̄frozen), doubling per inconclusive cycle, frozen at
// flagFrozenMultX (= 4×b₀ = 8%·X̄) from cycle 3 on (v0.24).
func flagBondFor(cs *claimState) int64 {
	b0 := cs.xBarFrozen * flagBondXBps / 10000
	if b0 < flagMinCC {
		b0 = flagMinCC
	}
	exp := cs.flagCycles
	if exp > 2 {
		exp = 2 // 2^2 = the frozen 4× multiplier
	}
	return mustMul(b0, int64(1)<<uint(exp))
}

// OpenFlag posts the quality flag on an answered claim: was this claim LOW
// information? Allowed from the answer until crystallization; refused during
// a dispute (the dispute vote carries quality). The flag cannot be withdrawn.
func OpenFlag(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.frozenAt == 0 {
		panic("kourtv2: only an answered claim can be quality-flagged")
	}
	if cs.crystallized {
		panic("kourtv2: quality is settled; the draw has crystallized")
	}
	if cs.provClose || cs.closed {
		panic("kourtv2: this claim closed without a draw; there is no quality to vote")
	}
	if cs.disputeOpen {
		panic("kourtv2: a dispute is open; its vote already carries quality")
	}
	if cs.flagOpen {
		panic("kourtv2: a flag vote is already open")
	}
	if cs.slotConsumed {
		panic("kourtv2: the flag slot was consumed by a conclusive vote")
	}
	if cs.pendingSlash > 0 {
		panic("kourtv2: a slash is in its counter-flag window")
	}
	// The re-flag cooldown applies after ANY inconclusive cycle, not only past
	// the freeze (audit M3-MED-1): a dust-low flag chain (T1 full-return) could
	// otherwise re-open back-to-back and block Crystallize for free forever.
	// The 7-day cooldown exceeds the 24h Crystallize quiet window, so every
	// inconclusive cycle leaves a ~6-day window in which the draw can settle.
	if cs.flagCycles >= 1 && heightNow() < cs.lastFlagAt+flagCooldownBlocks {
		panic("kourtv2: the flag cooldown after an inconclusive vote has not passed")
	}
	touch(c)

	bond := flagBondFor(cs)
	mustSpendable(c, who, bond)
	c.coin.Transfer(who, c.escrow, bond)
	cs.flagOpen = true
	cs.flagger = who
	cs.flagBond = bond
	cs.flagVoteEnd = heightNow() + c.params.votingBlocks
	cs.lastFlagAt = heightNow()
	openQualityTally(cs)
}

// openQualityTally starts a fresh sealed tally (flag or dispute-ride).
func openQualityTally(cs *claimState) {
	cs.qVoteSeq++
	cs.qLowW, cs.qMidW, cs.qHighW = 0, 0, 0
}

// reaskQualityTally re-poses the quality question for the DISPUTE RIDE — the one
// lane a third party can open at will. Before anything has been adjudicated every
// round asks fresh; afterwards the ride re-asks EXACTLY ONCE and every later round
// votes the SAME accumulating tally. Accumulation is what makes a reopen chain cost
// weight instead of buying a fresh coin flip: qVoted keys on qVoteSeq|addr, so a
// frozen seq also freezes each address to one vote.
//
// The counter re-vote does NOT come through here — see CounterFlag. That freezing
// property is exactly why: it is correct against a sock buying round after round,
// and wrong against the answerer's single answerer-gated challenge, which the
// doctrine grants as an INDEPENDENT poll.
func reaskQualityTally(cs *claimState) {
	if !cs.slotConsumed {
		openQualityTally(cs) // nothing adjudicated yet: each round asks fresh
		return
	}
	if !cs.qualityReasked {
		cs.qualityReasked = true
		openQualityTally(cs)
	}
}

// voidFlag cancels an open flag because a dispute arrived: the bond returns
// whole, the slot is NOT consumed, no cycle is counted. The 24h stamp moves so
// crystallize cannot race the void.
func voidFlag(c *Court, cs *claimState) {
	if !cs.flagOpen {
		return
	}
	if cs.flagBond > 0 {
		c.coin.Transfer(c.escrow, cs.flagger, cs.flagBond)
		cs.flagBond = 0
	}
	cs.flagOpen = false
	cs.lastFlagEventAt = heightNow()
}

// VoteQuality casts a sealed quality vote — low 0, mid 1, high 2 — inside an
// open flag vote OR an open dispute round (P11: the ride is its own tx).
// Weight = the voter's checkpointed balance at the claim's qualityEpoch (Q1).
// The claim's participants are excluded (Q2): quality moves their payout
// multiplier, and nobody votes their own multiplier.
func VoteQuality(cur realm, courtSlug string, claimID uint64, bucket int) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if bucket != qualityLow && bucket != qualityMid && bucket != qualityHigh {
		panic("kourtv2: quality is 0 (low), 1 (mid) or 2 (high)")
	}
	if !cs.flagOpen && !cs.disputeOpen && !cs.counterOpen {
		panic("kourtv2: no quality vote is open on this claim")
	}
	if cs.flagOpen && heightNow() >= cs.flagVoteEnd {
		panic("kourtv2: the flag vote has closed; resolve it")
	}
	if cs.counterOpen && heightNow() >= cs.counterVoteEnd {
		panic("kourtv2: the counter re-vote has closed; resolve it")
	}
	// The ride's deadline is the governor's own, since disputeOpen stays true until
	// the permissionless ResolveDispute and nothing else bounds the window. Under a
	// per-round wipe a mempool-raced late vote died with its round; the tally now
	// ACCUMULATES, so an unbounded ride would let a vote landing after the roll
	// closed persist into every later round and window — transaction ordering, not
	// the electorate, deciding a reserve worth up to 30.8%·X̄.
	if cs.disputeOpen && c.gov.State(cs.proposalID) != "active" {
		panic("kourtv2: the dispute vote has closed; resolve the round")
	}
	if isParticipant(cs, who) {
		panic("kourtv2: the claim's participants cannot vote its quality (Q2)")
	}
	w := c.coin.PastVotes(who, cs.qualityEpoch)
	if w <= 0 {
		panic("kourtv2: no checkpointed weight at the claim's quality epoch")
	}
	if cs.qVoted == nil {
		cs.qVoted = bptree.NewBPTree32()
	}
	// One vote per address PER TALLY. Since v0.51 a ride does not reset the tally
	// after the first re-ask, so the voter-facing rule is stronger than it reads:
	// across an accumulating tally an address's FIRST quality vote is its ONLY one,
	// and it cannot be revised as later rounds bring information. That is deliberate
	// against a sock buying round after round — banked weight is what makes a reopen
	// cost weight instead of buying a coin flip — and it is why CounterFlag keeps an
	// unconditional fresh tally: the answerer's one challenge must be a poll every
	// holder can actually vote in, including one who already voted low on a ride.
	// Elector's consequence: on a ride, commit once and late.
	k := beClaimKey(cs.qVoteSeq) + string(who)
	if cs.qVoted.Has(k) {
		panic("kourtv2: already voted this quality tally")
	}
	cs.qVoted.Set(k, true)
	switch bucket {
	case qualityLow:
		cs.qLowW = mustAdd(cs.qLowW, w)
	case qualityMid:
		cs.qMidW = mustAdd(cs.qMidW, w)
	default:
		cs.qHighW = mustAdd(cs.qHighW, w)
	}
}

// qualityBars computes the two turnout bars at the claim's quality epoch:
// the demotion bar min(X̄, votable/3)/4 (no supply floor — v0.25) and the
// full bar max(5%·supply, min(X̄, votable/3)). Never zero.
func qualityBars(c *Court, cs *claimState) (demotionBar, fullBar int64) {
	supply := c.coin.PastTotal(cs.qualityEpoch)
	votable := supply - c.coin.PastVotes(c.escrow, cs.qualityEpoch)
	if votable < 0 {
		votable = 0
	}
	arm := cs.xBarFrozen
	if third := votable / 3; third < arm {
		arm = third
	}
	demotionBar = arm / 4
	if demotionBar < 1 {
		demotionBar = 1
	}
	fullBar = arm
	if fivePct := mulDiv128(supply, quorumSupplyBps, 10000); fivePct > fullBar {
		fullBar = fivePct
	}
	// The same clamp quorumFloor takes, for the same reason (v0.29): `arm` above
	// is already bounded by votable/3 and the 5% max() escapes that ceiling once
	// escrow passes 85%. Inert below it.
	//
	// The consequence here is sharper than on the verdict lane, because this bar
	// gates the SLASH and cs.qualityEpoch is pinned at PostAnswer — nobody can
	// buy fresh weight in afterwards. So a mill's own answered claims fill the
	// escrow that makes the mill permanently unslashable, per claim, for that
	// claim's whole life. Meanwhile demotionBar has no supply arm and gets EASIER
	// as escrow grows, so at high escrow the lane kept its one free destructive
	// action (a refunded demotion that burns the author's deposit) and lost the
	// priced one. That is not a conservative failure; it is positive feedback on
	// the single deterrent the draw-proportional slash exists to provide.
	if third := votable / 3; fullBar > third {
		fullBar = third
	}
	// The pair must keep its designed ordering: demotionBar is arm/4 and the tier
	// ladder in applyQualityTally reads them together, so a clamp that pushed the
	// full bar below the demotion bar would invert the ladder.
	if fullBar < demotionBar {
		fullBar = demotionBar
	}
	if fullBar < 1 {
		fullBar = 1
	}
	return demotionBar, fullBar
}

// applyQualityTally classifies a CLOSED tally against the bars and returns
// the outcome tier plus whether it was conclusive. Shared by the flag lane
// and the dispute ride. Pure — dispositions stay with the callers.
//
//	tier: qualityLow/Mid/High as decided (mid when nothing conclusive moved it)
func applyQualityTally(c *Court, cs *claimState) (tier int, conclusive bool, turnout int64) {
	turnout = cs.qLowW + cs.qMidW + cs.qHighW
	demotionBar, fullBar := qualityBars(c, cs)
	// Promotion first (the F3 ratchet): high needs ⅔ of turnout AND the bar.
	if turnout >= fullBar && cs.qHighW*3 >= turnout*2 {
		return qualityHigh, true, turnout
	}
	// The weighted median across low<mid<high.
	medianLow := cs.qLowW*2 >= turnout && turnout > 0
	if medianLow {
		if turnout < demotionBar {
			return qualityLow, false, turnout // inconclusive-low (T1)
		}
		return qualityLow, true, turnout
	}
	if turnout >= fullBar {
		return qualityMid, true, turnout
	}
	return qualityMid, false, turnout // inconclusive-mid
}

// ResolveFlag settles a closed flag vote: the outcome table of §10.2 Q4.
// Permissionless once the vote window has passed.
func ResolveFlag(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if !cs.flagOpen {
		panic("kourtv2: no flag vote to resolve")
	}
	now := heightNow()
	if now < cs.flagVoteEnd {
		panic("kourtv2: the flag vote is still open")
	}
	touch(c)

	tier, conclusive, turnout := applyQualityTally(c, cs)
	_, fullBar := qualityBars(c, cs)
	cs.flagOpen = false
	cs.lastFlagEventAt = now

	if !conclusive {
		// The slot REOPENS at a doubled bond. T1: an inconclusive-LOW returns
		// the bond in full (the flagger was directionally backed, the
		// electorate was absent); an inconclusive-MID half-burns (2A: full
		// return would make suppression chains free). The 7-day cooldown
		// anchor moves to the CLOSE (from-open would be a zero cooldown).
		cs.flagCycles++
		cs.lastFlagAt = now
		if tier == qualityLow {
			if cs.flagBond > 0 {
				c.coin.Transfer(c.escrow, cs.flagger, cs.flagBond)
				cs.flagBond = 0
			}
		} else {
			half := cs.flagBond / 2
			if half > 0 {
				c.coin.Transfer(c.escrow, cs.flagger, half)
			}
			if rest := cs.flagBond - half; rest > 0 {
				c.coin.Burn(c.escrow, rest)
			}
			cs.flagBond = 0
		}
		return
	}

	// Conclusive: the slot is consumed and the tier lands.
	cs.slotConsumed = true
	cs.conclusiveSeq = cs.qVoteSeq
	cs.conclusiveTurnout = turnout
	cs.tier = int64(tier) // tierLow/Mid/High share values 0/1/2 with the buckets

	if tier != qualityLow {
		// Mid or high: the flag was wrong — the bond burns whole (flag risk
		// cuts both ways; a bad flag pays for the delay it caused).
		if cs.flagBond > 0 {
			c.coin.Burn(c.escrow, cs.flagBond)
			cs.flagBond = 0
		}
		cs.tierFinal = true
		return
	}

	// Conclusive LOW. Two tiers (v0.28/v0.29, regated v0.47):
	//   T2 free-roll price: where a slash was POSSIBLE and the vote reached the
	//   full bar but missed the ⅔-low supermajority, the bond half-burns — the
	//   failed-slash-attempt price. Where no slash was ever in reach, a
	//   conclusive low just returns the bond.
	//
	// "In reach" is now asked directly — `answerBond > 0` — instead of via
	// `decidedRounds == 0`. That clause was v0.28's BELT on top of the
	// load-bearing supply-floored-bar + ⅔ braces, and it was purchasable: one
	// sock-wallet dispute deliberately lost costs ~3-4%·X̄ after comp (below even
	// the 4.5%·X̄ flat slash floor) and permanently retired a slash worth up to
	// 30.8%·X̄ — so buying it dominated at every hold time, capping the whole
	// v0.40 draw-proportional deterrent at a flat ~4%. It was also redundant for
	// every case it was written for: a CONCLUSIVE ride latches slotConsumed and
	// OpenFlag panics on that, so ResolveFlag is unreachable once a round has
	// judged quality; and an OVERTURN zeroes answerBond, which the clamp below
	// already turns into slash == 0. Its only live domain was an UPHELD round
	// whose ride adjudicated NOTHING — precisely where immunity is unearned.
	// Winning an argument about whether the ANSWER is right establishes nothing
	// about whether the CLAIM was worth answering (v0.25: the answerer is the
	// gatekeeper of the slot they occupy).
	slashGrade := turnout >= fullBar && cs.qLowW*3 >= turnout*2 && cs.answerBond > 0
	if turnout >= fullBar && cs.answerBond > 0 && !slashGrade {
		half := cs.flagBond / 2
		if half > 0 {
			c.coin.Transfer(c.escrow, cs.flagger, half)
		}
		if rest := cs.flagBond - half; rest > 0 {
			c.coin.Burn(c.escrow, rest)
		}
		cs.flagBond = 0
	} else if cs.flagBond > 0 {
		c.coin.Transfer(c.escrow, cs.flagger, cs.flagBond)
		cs.flagBond = 0
	}

	// The dust-low dispositions land NOW, exactly once: the deposit is
	// slashed and burned, the fee burns, and the bounty — burn-dominated,
	// min(bond, 80% × what actually burned) — senior-queues to the flagger.
	burns := burnConclusiveLowDust(c, cs)

	if slashGrade {
		// The slash RESERVES only (Q5): the draw-proportional size (v0.40) out
		// of what remains of the answer bond, escrowed one counter-flag window.
		// Its burn and the full bounty settle at the window's close.
		originateSlash(c, cs, now, cs.flagger)
		// The dust bounty pays now against the dust burns; the slash's share
		// of the bounty waits for the window (exactly-once, per component).
	} else {
		cs.tierFinal = true
	}
	if bounty := bountyFor(cs.flagBondPosted(), burns); bounty > 0 {
		enqueueSenior(c, cs.flagger, bounty, "bounty")
	}
}

// burnConclusiveLowDust burns the deposit and fee — the dispositions EVERY
// conclusive low carries (§3.1.7), whichever lane asked the question and whether
// or not a slash was in reach. Returns the CC burned (the bounty base).
// Exactly-once: both fields zero here, so a second call burns nothing.
func burnConclusiveLowDust(c *Court, cs *claimState) int64 {
	burns := int64(0)
	if cs.deposit > 0 {
		c.coin.Burn(c.escrow, cs.deposit)
		c.deposit -= cs.deposit
		burns += cs.deposit
		cs.deposit = 0
	}
	if cs.fee > 0 {
		c.coin.Burn(c.escrow, cs.fee)
		c.deposit -= cs.fee
		burns += cs.fee
		cs.fee = 0
	}
	// Record what ACTUALLY burned, so settleSlash sizes its top-up against
	// reality rather than re-deriving a params deposit+fee that a waived-deposit
	// (moderator-seeded) claim never paid. Recorded HERE, at the one site that
	// burns, because both lanes reach it — the ride calls this too, and a
	// caller-side record would leave the ride's top-up sized against zero.
	// Accumulates, though the fields can only burn once (they zero above).
	cs.dustBurns += burns
	return burns
}

// originateSlash is the ONE origination site for pendingSlash — the flag lane and
// the dispute ride share it, so the two can never drift apart the way the sizer
// and the bond floor did before slashSizeAt (v0.46). It reserves out of what
// remains of the answer bond and escrows one counter-flag window.
//
// `flagger` is the bounty beneficiary: the flag's poster, or "" on a RIDE, where
// nobody posted a bond and so no policing pay is owed (riders are paid by the
// carrot). Recording it per-slash rather than reading cs.flagger later is
// load-bearing — see slashFlagger's comment in claim.gno.
//
// slashLevied makes origination exactly-once per claim ACROSS BOTH LANES. The
// flag lane was bounded by slotConsumed; the ride is not, so a reopen chain could
// otherwise levy a fresh slashSizeFor out of the remaining bond every round.
func originateSlash(c *Court, cs *claimState, now int64, flagger address) {
	if cs.slashLevied || cs.pendingSlash > 0 || cs.answerBond <= 0 {
		return
	}
	slash := slashSizeFor(cs)
	// UNREACHABLE behind PostAnswer's collateralization floor, and kept anyway. The
	// mutation harness reports this clamp as a SURVIVOR — deleting it fails no test —
	// because the floor sizes the bond to cover slashSizeFor, and slashLevied bounds
	// origination to the single carve where that guarantee holds. So there is no
	// fixture that can reach it without first breaking the floor, and writing one
	// would pin a state the design forbids. It stays because the cost of the floor
	// ever drifting is `answerBond` going NEGATIVE here, which is a conservation
	// break rather than a wrong number. Do not "clean this up" on the strength of the
	// survivor report; the report is the reason the comment exists.
	if slash > cs.answerBond {
		slash = cs.answerBond
	}
	if slash <= 0 {
		return
	}
	cs.answerBond -= slash
	cs.pendingSlash = slash
	cs.pendingSlashUntil = now + c.params.votingBlocks
	cs.slashFlagger = flagger
	cs.slashLevied = true
}

// flagBondPosted recomputes the bond this cycle posted (the live field is
// already disposed when the bounty is sized).
func (cs *claimState) flagBondPosted() int64 { return flagBondFor(cs) }

// sideConv is one side's pool conviction accumulator (u128). The winning side's
// mid-weight gross draw is convToCC of this, keyed on cs.answer — the
// counterfactual take at the default mid tier, i.e. exactly crystallize's
// midGross for the answer side. It is read from accumulators that freeze at the
// answer (advancePools settles them in PostAnswer; stake/unstake refuse after),
// so the value is identical at PostAnswer, settle, ResolveFlag and crystallize —
// which is what lets the bond floor and the slash share one sizer.
func (cs *claimState) sideConv(side int) (hi, lo uint64) {
	if side == sideYES {
		return cs.yesConvHi, cs.yesConvLo
	}
	return cs.noConvHi, cs.noConvLo
}

// slashSizeFor is the draw-proportional slash (v0.40): max(4.5%·X̄ floor,
// 1.6× the mill's would-be mid draw). On a conclusive-low the actual draw is
// zero (tier→0), so the deterrent must scale with the FORGONE mid draw, not
// the realized one — otherwise a patient mill (draw grows with hold-time)
// outpaces a flat X̄-scaled slash. The caller clamps to the posted bond; the
// deploy invariant (court.gno) guarantees the draw arm fits under the bond at
// the hot-rate 12-week max, so the clamp only bites answers whose winning pool
// was inflated past the answerer's own bond by honest co-stakers.
// slashSizeAt is the sizer parameterized on the base and the answered side's
// conviction, so PostAnswer can price the EXACT slash a later ResolveFlag will
// draw — BEFORE the freeze pins land. One function, two callers: "the bond
// collateralizes the slash" is then enforced by SHARED CODE rather than by two
// parallel arithmetic paths that a drained pool can pull apart (audit round 2).
func slashSizeAt(xbar int64, convHi, convLo uint64) int64 {
	flat := xbar * slashXBps / 10000
	if draw := mulDiv128(convToCC(convHi, convLo), slashDrawBps, 10000); draw > flat {
		return draw
	}
	return flat
}

func slashSizeFor(cs *claimState) int64 {
	hi, lo := cs.sideConv(int(cs.answer))
	return slashSizeAt(cs.xBarFrozen, hi, lo)
}

// bountyFor is the A19-shaped bounty: min(the flagger's own bond, 80% × the
// CC that actually burned on the outcome). Floors; never negative.
func bountyFor(bond, burned int64) int64 {
	b := burned * compOfBurnBps / 10000
	if bond < b {
		b = bond
	}
	if b < 0 {
		b = 0
	}
	return b
}

// bucketW is the sealed tally's weight for one bucket. Only the authority ratchet
// reads it; no exported read exposes the buckets (§10.2 Q3).
func bucketW(cs *claimState, bucket int) int64 {
	switch bucket {
	case qualityLow:
		return cs.qLowW
	case qualityMid:
		return cs.qMidW
	default:
		return cs.qHighW
	}
}

// resolveQualityRide applies a dispute round's quality tally at a DECIDED
// resolve: the same bars, no bond mechanics (the ride is free), the slot
// untouched. Below-bar rides leave the tier standing (default mid).
func resolveQualityRide(c *Court, cs *claimState) {
	tier, conclusive, turnout := applyQualityTally(c, cs)
	if !conclusive {
		return // below-bar rides leave the tier standing (default mid)
	}
	// AUTHORITY RATCHET, promotion-only (v0.54). A PROMOTION out of an already
	// adjudicated tier must carry a ⅔ MANDATE in its own bucket — the same F3 shape
	// applyQualityTally already imposes on HIGH, and ResolveCounter on the rescue.
	// Without it, MID is reachable as a bare RESIDUAL: applyQualityTally returns
	// conclusive MID whenever the full bar is met and low misses the weighted median,
	// so `qLowW=49, qMidW=0, qHighW=51` classifies MID on ZERO mid weight. A
	// bare-plurality mid then overturned a conclusive ⅔-low and restored cs.tier, and
	// with it the WHOLE draw, since tierLowX = 0 makes a low zero D outright. Priced at
	// ~4%·X̄ net (a 20%·X̄ bond burns on UPHOLD while comp mints 16%·X̄ back to the
	// answerer) against a draw bounded by maxMidGrossBps = 1927, i.e. 19.27%·X̄. Note
	// the reserve, at max(4.5%·X̄, 1.6·midGross), is the LARGER prize of the two — the
	// draw is not, and an earlier version of this comment had that backwards.
	//
	// PROMOTION-only, deliberately: gating demotions would break two honest paths — an
	// ordinary demotion at the supply-floorless demotionBar, which §3.4's F3 asymmetry
	// makes cheap on purpose, and `tier = LOW` on an OVERTURN ride, where skipping it
	// would restore the winning pool's draw on a claim the crowd called junk.
	//
	// A MANDATE test, not a turnout comparison. `turnout <= cs.conclusiveTurnout` was
	// tried and is wrong three ways: cs.conclusiveTurnout is REWRITTEN unconditionally
	// below on any non-gated conclusive ride, so a throwaway dust-LOW round resets the
	// mark downward and the promotion lands on the next round for one extra bond; the
	// mark is sealed and unreadable, so an honest promoter must burn a 20%·X̄ bond to
	// discover the bar; and it makes the bar depend on the OPPOSITION's participation,
	// so opposition that stays home RAISES it. The mandate form is unresettable,
	// turnout-independent, and needs no new state.
	//
	// What it does NOT do — stated so the next reader does not overrate it: it cannot
	// see weight the ride's one wipe already erased. Where the honest low bloc was
	// wiped rather than out-voted, the surviving tally genuinely does show a ⅔ mid
	// mandate and the promotion is allowed. Closing that needs a change upstream of any
	// authority test (no post-adjudication ride wipe, or a monotone authority mark) and
	// is an OWNER DECISION — see PLAN §13 v0.54.
	//
	// Rescues: the SLASH rescue is unaffected on every branch — no reserve path reads
	// cs.tier (ResolveCounter never calls this function, and disposeSlashOnRide is a
	// separate call scoring the buckets with hadSlash captured before the ride —
	// see disposeSlashOnRide and ResolveCounter in dispute.gno). The TIER rescue is
	// a different question, and the
	// mandate form is what keeps it open: a mid-only counter poll has qMidW == turnout,
	// so it clears ⅔ trivially. The turnout form refused exactly that, which is why
	// v0.52's objection was MIS-SCOPED rather than false, and why calling it simply
	// "false" over-corrected.
	if cs.slotConsumed && tier > int(cs.tier) && bucketW(cs, tier)*3 < turnout*2 {
		return // a promotion out of an adjudicated tier needs a ⅔ mandate (§3.4 F3)
	}
	now := heightNow()
	_, fullBar := qualityBars(c, cs)
	cs.tier = int64(tier)
	cs.conclusiveSeq = cs.qVoteSeq
	cs.conclusiveTurnout = turnout
	cs.slotConsumed = true

	// A conclusive LOW carries the flag lane's dust dispositions wherever it is
	// delivered. Skipping them REFUNDED the junk author their deposit and fee at
	// crystallize on exactly the claims the crowd demoted, while an identical
	// flag-lane low burned both (v0.50). Already-zero fields make this a no-op if
	// a flag burned them first.
	if tier == qualityLow {
		burnConclusiveLowDust(c, cs)
	}

	// v0.50 — THE RIDE ORIGINATES THE SLASH. `pendingSlash` had exactly one
	// origination site (ResolveFlag), while `OpenFlag` panics forever on the
	// one-way slotConsumed latch this function sets. So a full-bar ⅔-low verdict
	// delivered on the RIDE foreclosed the only path that could levy the slash it
	// had just voted for: a sock dispute filed in the block after the answer
	// (votingBlocks 7d > settleDelay 72h, so no flag can have resolved, and
	// OpenFlag refuses while disputeOpen) bought immunity for the same ~4%·X̄ that
	// v0.47 closed on the flag lane's door. Winning an argument about whether the
	// ANSWER is right settles nothing about whether the CLAIM was worth answering —
	// and neither does which lane ASKED the quality question.
	//
	// The predicate is ResolveFlag's slashGrade, never merely "conclusive":
	// applyQualityTally goes conclusive-LOW at the supply-floorless demotionBar, and
	// a dust ride must not levy what a dust ride cannot lift (the same asymmetry
	// disposeSlashOnRide is scored on). `answerBond > 0`, inside originateSlash,
	// suppresses this on the OVERTURN branch, where the bond already burned.
	if tier == qualityLow && turnout >= fullBar && cs.qLowW*3 >= turnout*2 {
		originateSlash(c, cs, now, "") // "" — a ride posts no bond, so no bounty
	}
	// tierFinal stays FALSE while a reserve this ride levied stands, so the answerer
	// keeps the one v0.31/Q5 counter re-vote exactly as the flag lane leaves it.
	// Both terminal paths' tier-clobber guards read `!tierFinal && !slotConsumed`
	// and slotConsumed is already true, so nothing can reset the LOW meanwhile.
	cs.tierFinal = cs.pendingSlash == 0
}

// ------------------------------------------------------------------ reads --

// FlagState renders the slot: "open" (flaggable), "voting", "consumed",
// "cooldown", or "settled". The tally itself is SEALED — no read exposes it.
func FlagState(courtSlug string, claimID uint64) string {
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	switch {
	case cs.crystallized:
		return "settled"
	case cs.flagOpen:
		return "voting"
	case cs.pendingSlash > 0:
		return "counter-window"
	case cs.slotConsumed:
		return "consumed"
	case cs.flagCycles >= 1 &&
		heightNow() < cs.lastFlagAt+flagCooldownBlocks:
		return "cooldown"
	default:
		return "open"
	}
}

// FlagBondNext quotes the bond the next flag posts (0 before an answer).
func FlagBondNext(courtSlug string, claimID uint64) int64 {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.frozenAt == 0 {
		return 0
	}
	return flagBondFor(cs)
}

// QualityTier reads the standing tier and whether it is final. Rendered as
// text upstream; numeric here for clients.
func QualityTier(courtSlug string, claimID uint64) (tier int, final bool) {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return int(cs.tier), cs.tierFinal
}

// FlagCycles is the inconclusive-reopen count (the bond-doubling exponent).
func FlagCycles(courtSlug string, claimID uint64) int64 {
	return mustClaim(mustCourt(courtSlug), claimID).flagCycles
}

// QualityBars quotes the two turnout bars a voter is judged against: the demotion
// bar (a LOW below it is inconclusive) and the full bar (nothing but LOW can go
// conclusive below it, and since v0.55 nothing below it is PAID).
//
// Exported because the asymmetry was one-sided and it was mine to create. Both bars
// read a SEALED past epoch (cs.qualityEpoch), so a sophisticated party has always
// been able to reconstruct them from the checkpoint archive, while an ordinary
// elector could not — and v0.55 then made clearing the full bar the condition for
// being paid at all. Quoting them is what lets an elector decide to over-shoot the
// bar rather than land in the unpaid band. Neither bar is the TALLY: the three
// buckets stay sealed (see FlagState), so this still says nothing about how much
// weight has already arrived or which way it voted.
func QualityBars(courtSlug string, claimID uint64) (demotionBar, fullBar int64) {
	c := mustCourt(courtSlug)
	return qualityBars(c, mustClaim(c, claimID))
}

// ------------------------------------------------- the counter-flag window --

// CounterFlag is the slashed answerer's ONE forced re-vote (v0.31, Q5): the
// slash and its bounty wait one challenge window; during it the answerer may
// re-pose the quality question at the supply-floored bar. No bond — the
// reserved slash IS the stake. Exactly-once per claim.
func CounterFlag(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.pendingSlash <= 0 {
		panic("kourtv2: no slash is pending on this claim")
	}
	if who != cs.answerer {
		panic("kourtv2: only the slashed answerer may counter-flag")
	}
	if cs.counterUsed {
		panic("kourtv2: the one counter re-vote was already used")
	}
	if cs.disputeOpen {
		panic("kourtv2: a dispute is open; its quality ride decides the slash first")
	}
	if heightNow() >= cs.pendingSlashUntil {
		panic("kourtv2: the counter-flag window has lapsed")
	}
	touch(c)
	cs.counterUsed = true
	cs.counterOpen = true
	cs.counterVoteEnd = heightNow() + c.params.votingBlocks
	// UNCONDITIONAL, unlike the ride (v0.51 follow-up). The v0.31/Q5 grant is an
	// INDEPENDENT second poll — "a capture-whale must win ⅔ TWICE, the second
	// against maximal mobilization (p² ≈ 0)" — and inheriting the ride's tally
	// collapses p² to p: qVoted keys on qVoteSeq|addr, so a frozen seq LOCKS OUT
	// every address that already voted. An honest voter who changes their mind
	// cannot, and their earlier low still counts against the answerer.
	//
	// It also LATCHES, which is what keeps the budget order-independent. Wiping here
	// without latching would let the answerer take TWO rolls by choosing the order:
	// counter-flag first (roll one), watch the crowd re-confirm low, then sock-dispute
	// to spend the ride's still-unspent wipe (roll two), erasing that low and voting
	// mid alone over the bar — refunding the reserve for ~4%·X̄, the same purchase
	// v0.47, v0.50 and v0.51 each closed at a different door. Latching costs the
	// answerer nothing they are owed: their wipe is unconditional either way, and
	// counterUsed already bounds them to one challenge.
	//
	// Net budget, whichever lane moves first: unlimited before anything is
	// adjudicated, then AT MOST ONE fresh tally per lane and never two for one party.
	// A sock that disputes first spends the ride's wipe and the answerer still gets
	// their own poll; an answerer that counters first spends both and every later
	// round votes their accumulating tally.
	cs.qualityReasked = true
	openQualityTally(cs)
}

// ResolveCounter settles the re-vote. The slash STANDS unless the re-vote
// reaches the full bar and the low bucket misses ⅔ of turnout — an
// inconclusive re-vote does not rescue (the answerer facing 4.5%·X̄ is the
// most mobilized party the electorate will ever have; if even they cannot
// raise a bar of turnout, the original supermajority stands). The tier stays
// LOW either way: the window challenges the SLASH, not the ¼-bar dust low.
func ResolveCounter(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.disputeOpen {
		panic("kourtv2: a dispute is open; its quality ride decides the slash first")
	}
	if !cs.counterOpen {
		panic("kourtv2: no counter re-vote to resolve")
	}
	now := heightNow()
	if now < cs.counterVoteEnd {
		panic("kourtv2: the counter re-vote is still open")
	}
	touch(c)
	cs.counterOpen = false
	cs.lastFlagEventAt = now
	turnout := cs.qLowW + cs.qMidW + cs.qHighW
	_, fullBar := qualityBars(c, cs)
	if turnout >= fullBar && cs.qLowW*3 < turnout*2 {
		refundSlash(c, cs) // the whale failed the second ⅔
		return
	}
	settleSlash(c, cs)
}

// ResolveSlashWindow closes an UNCHALLENGED window: permissionless once it
// lapses with no counter re-vote running. A dispute open at the lapse holds
// the close — a decided round refunds the slash itself (never slashable once
// disputed); a failed round falls back here.
func ResolveSlashWindow(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.pendingSlash <= 0 {
		panic("kourtv2: no slash is pending")
	}
	if cs.counterOpen {
		panic("kourtv2: the counter re-vote is running; resolve it instead")
	}
	if cs.disputeOpen {
		panic("kourtv2: a dispute is open; its quality ride decides the slash first")
	}
	if heightNow() < cs.pendingSlashUntil {
		panic("kourtv2: the counter-flag window is still open")
	}
	touch(c)
	cs.lastFlagEventAt = heightNow()
	settleSlash(c, cs)
}

// settleSlash burns the reserved slash and tops up the flagger's bounty to
// the full per-event bound min(bond, 80% × (deposit+fee+slash)), minus the
// dust share already paid. Exactly-once: pendingSlash zeroes here.
func settleSlash(c *Court, cs *claimState) {
	// UNREACHABLE TODAY, and deliberately kept: no caller can arrive here with the
	// lane open (ResolveCounter clears it first, ResolveSlashWindow panics on it,
	// and disposeSlashOnRide runs inside a round whose OpenDispute already closed
	// it), so no mutation of this line fails a test. It stays because the cost of
	// the invariant breaking is unbounded: Crystallize panics on counterOpen, so a
	// lane outliving its reserve would strand the claim's whole draw forever.
	cs.counterOpen = false
	slash := cs.pendingSlash
	if slash <= 0 {
		return
	}
	cs.pendingSlash = 0
	c.coin.Burn(c.escrow, slash)
	// Two independent corrections, both needed.
	//
	// WHO: pay the beneficiary RECORDED AT ORIGINATION, never cs.flagger. On a
	// ride-levied slash that field is the zero address (an unpayable entitlement
	// that would strand accrual in the monotone reservedTail forever) or a stale
	// flagger from an earlier inconclusive cycle whose bond already came back
	// whole under T1, who would mint a bounty for a slash the RIDE levied.
	//
	// AGAINST WHAT: size the top-up on cs.dustBurns, what the deposit and fee
	// ACTUALLY burned. Re-deriving params.minClaimDepositCC + its fee assumes
	// every claim paid one, which a moderator-seeded claim never does — the
	// phantom base silently under-paid the flagger whenever the bond clamped.
	if cs.slashFlagger != "" {
		bond := flagBondFor(cs)
		if topUp := bountyFor(bond, cs.dustBurns+slash) - bountyFor(bond, cs.dustBurns); topUp > 0 {
			enqueueSenior(c, cs.slashFlagger, topUp, "bounty")
		}
	}
	cs.slashFlagger = ""
	cs.tierFinal = true
}

// refundSlash returns the reserved slash untouched — the re-vote overturned the
// supermajority. No bounty top-up; the tier stays low and is final.
//
// Normally the reserve rejoins the bond and rides its existing exit (settle or
// Finalize retains it, crystallize pays out whatever stands). A provClosed claim
// has NEITHER: provCloseClaim already returned the bond, and Crystallize panics
// on provClose — so there the reserve must be paid straight back or it strands in
// escrow forever. Newly reachable in v0.47, where a slash survives the failed
// rounds that provClose counts.
func refundSlash(c *Court, cs *claimState) {
	cs.counterOpen = false // as settleSlash: unreachable today, same strand if it broke
	slash := cs.pendingSlash
	cs.pendingSlash = 0
	cs.tierFinal = true
	if slash <= 0 {
		return
	}
	cs.slashFlagger = ""
	if cs.provClose {
		c.coin.Transfer(c.escrow, cs.answerer, slash)
		return
	}
	cs.answerBond = mustAdd(cs.answerBond, slash)
}

// unslash folds a pending reserve back into the answer bond so a round can
// dispose the bond WHOLE. Since v0.47 its ONLY caller is ResolveDispute's
// OVERTURN branch, where the whole bond burns and the burn must stay
// slash-inclusive (A19). Opening a round no longer calls it: opening a dispute is
// not adjudicating one.
func unslash(c *Court, cs *claimState) {
	if cs.pendingSlash <= 0 {
		return
	}
	cs.answerBond = mustAdd(cs.answerBond, cs.pendingSlash)
	cs.pendingSlash = 0
	cs.slashFlagger = ""
	cs.counterOpen = false
}

// rearmSlashWindow gives a SURVIVING reserve a fresh window after a round that
// adjudicated nothing about quality (or one that reached the slash's bar before the
// answerer had been offered their challenge). The round consumed the window it
// interrupted, since its own vote runs a full votingBlocks.
//
// A re-armed reserve always has exactly one permissionless closer, but WHICH one
// depends on the branch below, and it is not always ResolveSlashWindow:
//   - counterUsed false: the lane stays shut, so ResolveSlashWindow closes it once
//     pendingSlashUntil lapses — and CounterFlag is still open to the answerer until
//     then, which is the whole point of re-arming rather than settling.
//   - counterUsed true: the lane REOPENS, and ResolveSlashWindow then PANICS on
//     counterOpen. ResolveCounter is the closer on that path.
//
// Either way Crystallize cannot strand: it panics on pendingSlash > 0, and one of
// the two closers is always callable.
//
// A challenge already SPENT gets its lane back, not the right to open a second one:
// counterUsed stays true (still exactly one per claim) while counterOpen reopens,
// because CounterFlag would refuse to re-enter and the answerer would otherwise
// forfeit their one v0.31/Q5 challenge to a stranger's failed round. What comes back
// there is the WINDOW, not a fresh ballot: counterUsed implies qualityReasked, so the
// tally is frozen and VoteQuality refuses every address already recorded at that seq
// — including the answerer's own bloc. Only weight that has not yet voted can move it.
//
// counterVoteEnd is set EQUAL to pendingSlashUntil. A shorter lane would also be
// safe — with counterOpen true, ResolveCounter is the only closer and an earlier
// counterVoteEnd merely closes sooner. (An earlier version of this comment claimed a
// shorter lane opened an unclosable gap; that is backwards. The gap it describes
// needs counterVoteEnd > pendingSlashUntil, which is what CounterFlag itself does —
// now + votingBlocks while now < pendingSlashUntil — and is safe for the same reason.)
func rearmSlashWindow(c *Court, cs *claimState) {
	if cs.pendingSlash <= 0 {
		return
	}
	now := heightNow()
	cs.pendingSlashUntil = now + c.params.votingBlocks
	cs.lastFlagEventAt = now
	if cs.counterUsed {
		cs.counterOpen = true
		cs.counterVoteEnd = cs.pendingSlashUntil
	}
}

// disposeSlashOnRide settles a slash that survived an UPHELD round against that
// round's own quality ride, scored on ResolveCounter's EXACT test: the ride asks
// the slash's question at the same bars before a strictly larger electorate, so
// it IS the counter re-vote and must be scored as one. It can therefore dispose
// the slash only on terms at least as good for the answerer as the window it
// replaced. A ride that never reached the slash's bar adjudicated nothing — the
// reserve stands on a fresh window.
//
// Never merely "conclusive": applyQualityTally returns conclusive-LOW at the
// demotionBar, which has NO supply floor, so a dust ride would otherwise be able
// to settle (or lift) a slash imposed at the full supply-floored bar.
func disposeSlashOnRide(c *Court, cs *claimState) {
	if cs.pendingSlash <= 0 {
		return
	}
	turnout := cs.qLowW + cs.qMidW + cs.qHighW
	_, fullBar := qualityBars(c, cs)
	switch {
	case turnout < fullBar:
		rearmSlashWindow(c, cs) // adjudicated nothing about quality
	case cs.qLowW*3 < turnout*2:
		refundSlash(c, cs) // the electorate failed the second ⅔ (ResolveCounter's rescue)
	case !cs.counterUsed:
		// A ride may CONFIRM a slash only once the answerer has actually been offered
		// their v0.31/Q5 challenge. Settling here while counterUsed is false
		// ANNIHILATES that grant with no block in which they could have used it, and
		// it is race-free for the attacker: ResolveFlag is permissionless, so a sock
		// OpenDispute lands in the same block the reserve is carved in, CounterFlag
		// panics on disputeOpen throughout the round, and after settleSlash it panics
		// on pendingSlash <= 0 forever. Half a dispute bond (~10%·X̄ burned, no comp on
		// a quorum-less round) would destroy up to 30.8%·X̄ plus the poll.
		//
		// Re-arming instead costs the mechanism nothing: the reserve is not forgiven,
		// ResolveSlashWindow still settles it unconditionally once the window lapses
		// with no lane open, and the RESCUE arm above is untouched — the electorate can
		// still lift a slash on a ride, we just do not let a ride burn one behind the
		// answerer's back. Bounded by escrowUntil and maxFailedRounds → provClose.
		rearmSlashWindow(c, cs)
	default:
		settleSlash(c, cs) // a full-bar ⅔-low ride re-confirms the flag
	}
}
