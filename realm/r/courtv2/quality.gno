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
// The slash (4.5%·X̄, from the answer bond) fires only at the supply-floored
// FULL bar with a ⅔-low supermajority on an UNDISPUTED answer (v0.28), and
// even then it only RESERVES: the burn and its bounty escrow one counter-flag
// window in which the slashed answerer may force one re-vote (v0.31, Q5).
//
// A dispute arriving mid-flag VOIDS the flag (bond returned whole, slot
// unconsumed, no cycle counted): the dispute vote carries quality itself, and
// anything less would let a dust flag's 7-day vote blockade the 72h dispute
// window — the verdict lane always outranks the quality lane.
package courtv2

import (
	"chain/runtime"

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
		panic("courtv2: only an answered claim can be quality-flagged")
	}
	if cs.crystallized {
		panic("courtv2: quality is settled; the draw has crystallized")
	}
	if cs.provClose || cs.closed {
		panic("courtv2: this claim closed without a draw; there is no quality to vote")
	}
	if cs.disputeOpen {
		panic("courtv2: a dispute is open; its vote already carries quality")
	}
	if cs.flagOpen {
		panic("courtv2: a flag vote is already open")
	}
	if cs.slotConsumed {
		panic("courtv2: the flag slot was consumed by a conclusive vote")
	}
	if cs.pendingSlash > 0 {
		panic("courtv2: a slash is in its counter-flag window")
	}
	// The re-flag cooldown applies after ANY inconclusive cycle, not only past
	// the freeze (audit M3-MED-1): a dust-low flag chain (T1 full-return) could
	// otherwise re-open back-to-back and block Crystallize for free forever.
	// The 7-day cooldown exceeds the 24h Crystallize quiet window, so every
	// inconclusive cycle leaves a ~6-day window in which the draw can settle.
	if cs.flagCycles >= 1 && runtime.ChainHeight() < cs.lastFlagAt+flagCooldownBlocks {
		panic("courtv2: the flag cooldown after an inconclusive vote has not passed")
	}
	touch(c)

	bond := flagBondFor(cs)
	c.coin.Transfer(who, c.escrow, bond)
	cs.flagOpen = true
	cs.flagger = who
	cs.flagBond = bond
	cs.flagVoteEnd = runtime.ChainHeight() + c.params.votingBlocks
	cs.lastFlagAt = runtime.ChainHeight()
	openQualityTally(cs)
}

// openQualityTally starts a fresh sealed tally (flag or dispute-ride).
func openQualityTally(cs *claimState) {
	cs.qVoteSeq++
	cs.qLowW, cs.qMidW, cs.qHighW = 0, 0, 0
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
	cs.lastFlagEventAt = runtime.ChainHeight()
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
		panic("courtv2: quality is 0 (low), 1 (mid) or 2 (high)")
	}
	if !cs.flagOpen && !cs.disputeOpen && !cs.counterOpen {
		panic("courtv2: no quality vote is open on this claim")
	}
	if cs.flagOpen && runtime.ChainHeight() >= cs.flagVoteEnd {
		panic("courtv2: the flag vote has closed; resolve it")
	}
	if cs.counterOpen && runtime.ChainHeight() >= cs.counterVoteEnd {
		panic("courtv2: the counter re-vote has closed; resolve it")
	}
	if isParticipant(cs, who) {
		panic("courtv2: the claim's participants cannot vote its quality (Q2)")
	}
	w := c.coin.PastVotes(who, cs.qualityEpoch)
	if w <= 0 {
		panic("courtv2: no checkpointed weight at the claim's quality epoch")
	}
	if cs.qVoted == nil {
		cs.qVoted = bptree.NewBPTree32()
	}
	k := beClaimKey(cs.qVoteSeq) + string(who)
	if cs.qVoted.Has(k) {
		panic("courtv2: already voted this quality tally")
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
		panic("courtv2: no flag vote to resolve")
	}
	now := runtime.ChainHeight()
	if now < cs.flagVoteEnd {
		panic("courtv2: the flag vote is still open")
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

	// Conclusive LOW. Two tiers (v0.28/v0.29):
	//   T2 free-roll price: where a slash was POSSIBLE (undisputed answer) and
	//   the vote reached the full bar but missed the ⅔-low supermajority, the
	//   bond half-burns — the failed-slash-attempt price. Where no slash was
	//   ever in reach (a decided-dispute claim), a conclusive low just
	//   returns the bond.
	slashGrade := turnout >= fullBar && cs.qLowW*3 >= turnout*2 && cs.decidedRounds == 0
	if turnout >= fullBar && cs.decidedRounds == 0 && !slashGrade {
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

	if slashGrade {
		// The slash RESERVES only (Q5): the draw-proportional size (v0.40) out
		// of what remains of the answer bond, escrowed one counter-flag window.
		// Its burn and the full bounty settle at the window's close.
		slash := slashSizeFor(cs)
		if slash > cs.answerBond {
			slash = cs.answerBond
		}
		if slash > 0 {
			cs.answerBond -= slash
			cs.pendingSlash = slash
			cs.pendingSlashUntil = now + c.params.votingBlocks
		}
		// The dust bounty pays now against the dust burns; the slash's share
		// of the bounty waits for the window (exactly-once, per component).
	} else {
		cs.tierFinal = true
	}
	// Record what ACTUALLY burned, so settleSlash can size its top-up against
	// reality instead of re-deriving a params figure that a waived-deposit
	// (seeded) claim never paid. Accumulates, though the deposit/fee can only
	// burn once (they zero on disposition).
	cs.dustBurns += burns
	if bounty := bountyFor(cs.flagBondPosted(), burns); bounty > 0 {
		enqueueSenior(c, cs.flagger, bounty, "bounty")
	}
}

// flagBondPosted recomputes the bond this cycle posted (the live field is
// already disposed when the bounty is sized).
func (cs *claimState) flagBondPosted() int64 { return flagBondFor(cs) }

// winMidGross is the winning-side pool's mid-weight gross draw in CC — the
// counterfactual take the mill would have received at the default mid tier,
// i.e. exactly crystallize's midGross for the answer side. Keyed on cs.answer
// (undisputed: the winning side IS the answer; slashGrade gates decidedRounds
// == 0), and read from the pool conviction accumulators, which freeze at the
// answer (advancePools settles them in PostAnswer; stake/unstake refuse after)
// — so it is identical at settle, ResolveFlag, and crystallize.
func winMidGross(cs *claimState) int64 {
	if int(cs.answer) == sideYES {
		return convToCC(cs.yesConvHi, cs.yesConvLo)
	}
	return convToCC(cs.noConvHi, cs.noConvLo)
}

// slashSizeFor is the draw-proportional slash (v0.40): max(4.5%·X̄ floor,
// 1.6× the mill's would-be mid draw). On a conclusive-low the actual draw is
// zero (tier→0), so the deterrent must scale with the FORGONE mid draw, not
// the realized one — otherwise a patient mill (draw grows with hold-time)
// outpaces a flat X̄-scaled slash. The caller clamps to the posted bond; the
// deploy invariant (court.gno) guarantees the draw arm fits under the bond at
// the hot-rate 12-week max, so the clamp only bites answers whose winning pool
// was inflated past the answerer's own bond by honest co-stakers.
func slashSizeFor(cs *claimState) int64 {
	flat := cs.xBarFrozen * slashXBps / 10000
	if draw := mulDiv128(winMidGross(cs), slashDrawBps, 10000); draw > flat {
		return draw
	}
	return flat
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

// resolveQualityRide applies a dispute round's quality tally at a DECIDED
// resolve: the same bars, no bond mechanics (the ride is free), the slot
// untouched. Below-bar rides leave the tier standing (default mid).
func resolveQualityRide(c *Court, cs *claimState) {
	tier, conclusive, turnout := applyQualityTally(c, cs)
	if !conclusive {
		return
	}
	cs.tier = int64(tier)
	cs.conclusiveSeq = cs.qVoteSeq
	cs.conclusiveTurnout = turnout
	// A decided ride settles quality with the verdict — but never a slash:
	// a disputed answer is not slashable (v0.28: undisputed-only).
	cs.tierFinal = true
	cs.slotConsumed = true
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
		runtime.ChainHeight() < cs.lastFlagAt+flagCooldownBlocks:
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
		panic("courtv2: no slash is pending on this claim")
	}
	if who != cs.answerer {
		panic("courtv2: only the slashed answerer may counter-flag")
	}
	if cs.counterUsed {
		panic("courtv2: the one counter re-vote was already used")
	}
	if cs.disputeOpen {
		panic("courtv2: a dispute is open; its decision supersedes the slash")
	}
	if runtime.ChainHeight() >= cs.pendingSlashUntil {
		panic("courtv2: the counter-flag window has lapsed")
	}
	touch(c)
	cs.counterUsed = true
	cs.counterOpen = true
	cs.counterVoteEnd = runtime.ChainHeight() + c.params.votingBlocks
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
		panic("courtv2: a dispute supersedes the slash; it decides the outcome")
	}
	if !cs.counterOpen {
		panic("courtv2: no counter re-vote to resolve")
	}
	now := runtime.ChainHeight()
	if now < cs.counterVoteEnd {
		panic("courtv2: the counter re-vote is still open")
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
		panic("courtv2: no slash is pending")
	}
	if cs.counterOpen {
		panic("courtv2: the counter re-vote is running; resolve it instead")
	}
	if cs.disputeOpen {
		panic("courtv2: a dispute is open; it decides the slash")
	}
	if runtime.ChainHeight() < cs.pendingSlashUntil {
		panic("courtv2: the counter-flag window is still open")
	}
	touch(c)
	cs.lastFlagEventAt = runtime.ChainHeight()
	settleSlash(c, cs)
}

// settleSlash burns the reserved slash and tops up the flagger's bounty to
// the full per-event bound min(bond, 80% × (deposit+fee+slash)), minus the
// dust share already paid. Exactly-once: pendingSlash zeroes here.
func settleSlash(c *Court, cs *claimState) {
	slash := cs.pendingSlash
	if slash <= 0 {
		return
	}
	cs.pendingSlash = 0
	c.coin.Burn(c.escrow, slash)
	// The top-up is the bounty on the slash ON TOP OF the dust bounty already
	// paid at ResolveFlag — so it must subtract what that bounty was actually
	// sized against. Reading the PARAMS deposit+fee here (the pre-moderation
	// code) assumes every claim paid one, which a moderator-seeded claim never
	// does: the phantom base silently under-paid the flagger whenever the bond
	// clamped. cs.dustBurns is what really burned.
	bond := flagBondFor(cs)
	if topUp := bountyFor(bond, cs.dustBurns+slash) - bountyFor(bond, cs.dustBurns); topUp > 0 {
		enqueueSenior(c, cs.flagger, topUp, "bounty")
	}
	cs.tierFinal = true
}

// refundSlash returns the reserved slash to the answer bond untouched — the
// re-vote overturned the supermajority. No bounty top-up; the tier stays low
// and is final.
func refundSlash(c *Court, cs *claimState) {
	cs.answerBond = mustAdd(cs.answerBond, cs.pendingSlash)
	cs.pendingSlash = 0
	cs.tierFinal = true
}

// unslash is the dispute machine's pre-disposition hook: a DECIDED round
// supersedes any pending slash (a disputed answer is never slashable). The
// reserve rejoins the bond BEFORE the round disposes it, so an overturn burns
// slash-inclusive and an uphold escrows it back whole. Closes any running
// counter re-vote; tier finality is then the ride's to decide.
func unslash(c *Court, cs *claimState) {
	if cs.pendingSlash <= 0 {
		return
	}
	cs.answerBond = mustAdd(cs.answerBond, cs.pendingSlash)
	cs.pendingSlash = 0
	cs.counterOpen = false
}
