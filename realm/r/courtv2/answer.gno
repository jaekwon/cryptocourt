// Answers: one per claim, bonded, freezing (PLAN §3.1, pins P6/P13). The
// answerability gate reads the trailing average of TOTAL STAKE (X̄) — open
// interest moves only on real stake flows, so a short window is safe (V1's
// audited argument, unchanged). The answer freezes staking, pins the era
// integral (H1), and snapshots X̄frozen — the single base every later
// %-of-X̄ quantity (bonds, slash, flag bond) reads (P6).
package courtv2

import "chain/runtime"

// answerWindow: the trailing window answerability reads. V1's audited 3-hour
// value — enough history to block a flash-answer without walling off fresh
// claims (the price-manipulation concern that forced V1's week-long window is
// gone: no price exists in V2).
const answerWindow = 3 * epochBlocks

// PostAnswer posts THE answer (one per claim, first-come within the rules),
// escrowing bond = 50%·X̄frozen (min 1, capped by court params if set).
func PostAnswer(cur realm, courtSlug string, claimID uint64, verdict int) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	mustSide(verdict)
	if cs.closed {
		panic("courtv2: this claim is closed")
	}
	if cs.frozenAt != 0 {
		panic("courtv2: this claim already has an answer")
	}

	now := runtime.ChainHeight()
	// Answerability ENDS at the dead-claim timeout. CloseDeadClaim is
	// permissionless but OPTIONAL, so without this a claim stays answerable at any
	// age — and every X̄-derived bound in the system (court.gno's maxTcWeeks term,
	// the conviction magnitudes, the escrow window) is derived for a ≤12-week
	// life. Conviction keeps accruing on an un-closed claim, so past ~19.5 weeks
	// (hot) the draw arm crosses the 50%·X̄ bond even on a perfectly CONSTANT
	// pool: the calibration below would be falsified with no drain at all.
	if now >= cs.openedAt+deadClaimTimeout {
		panic("courtv2: this claim is past the dead-claim timeout; it closes, it is not answered")
	}
	// Answerability: mature trailing X̄ at or above the floor.
	xbar, mature := cs.oi.Average(now, answerWindow)
	if !mature {
		panic("courtv2: not enough stake history to answer yet")
	}
	if xbar < effMinAnswerX(c) {
		panic("courtv2: trailing stake is below the minimum to answer")
	}

	// The priority window (P13, implementation pin): keyed on claim AGE — the
	// first priorityWindowBlocks after the earliest the claim could have been
	// answerable (openedAt + answerWindow). Deterministic; needs no crossing
	// detection; priority is a perk, not a guarantee (a claim that matures
	// late may have no priority phase left). Binds only once the court's
	// cold-start gate is armed.
	// Re-anchored for the polish window (MODERATION.md §9): the earliest
	// answerable moment moves by stakeOpenDelayBlocks, because the ring cannot
	// mature until staking opens. Without this the priority phase silently
	// shrinks — and at the 24h maximum delay it would vanish entirely, since
	// the delay cap equals priorityWindowBlocks. Default delay 0 → unchanged.
	inPriority := false
	if priorityGateActive(c) && now < cs.openedAt+c.params.stakeOpenDelayBlocks+answerWindow+priorityWindowBlocks {
		if !mayAnswerInPriority(c, who) {
			panic("courtv2: the priority window is open — a qualified answerer may act first (wait ~24h)")
		}
		inPriority = true
	}

	// Settle the pool integrals to this height FIRST: the bond is sized against
	// the answered side's conviction, which must therefore be current. (These ran
	// just below before; nothing between here and the freeze pin touches pools,
	// and a Transfer moves no supply, so the walk is unchanged.)
	touch(c)
	advancePools(c, cs)

	// P6 BASE: max(3h trailing average, LIFETIME time-averaged total stake).
	// The 3h window is the right ANSWERABILITY gate — a liveness question, checked
	// above against minAnswerX and deliberately left reading the raw trailing value,
	// or a fully drained claim would become unanswerable on history alone. It is the
	// WRONG base for SIZING. Every consumer of X̄frozen prices a prize or a
	// punishment — this bond, the slash flat arm, the flag bond, the P2 carrot
	// clamp, both quality bars, the dispute bond, the quorum floor, the escrow
	// window — and each of those guards a quantity set by CONVICTION, a lifetime
	// integral. Unstake is free and KEEPS conviction (F9), so a pool that banked 11
	// weeks at 100k CC and drained to 100 CC two hours before the answer still
	// carries a 100k-CC prize while the 3h arm reads 100 CC, mis-pricing every
	// consumer by the whole drain factor: a 25 CC demotion bar that lets 25 CC of
	// weight force a conclusive LOW and zero a 7_012 CC draw at a PROFIT (the flag
	// bond returns whole below the full bar), a 20 CC dispute bond, and a ~1 CC
	// carrot clamp against a 5%-of-supply mobilisation. Worse, the drain also
	// un-escrows the attacker's weight — escrowed stake is netted out of `votable`
	// and barred from the quality lane by isParticipant — so the same act that
	// lowers the bars hands the attacker the weight to clear them.
	//
	// This is also what makes court.gno's deploy check TRUE rather than merely
	// calibrated: its identity midGross/X̄ = rateBpsFP·T_c/1e10 is only valid when
	// X̄ is the claim's time-averaged stake, since midGross is a lifetime integral.
	// Feeding it a 3-hour average was a units mismatch; the drain was its extremal
	// exploit. max(), never replace: on any claim whose total stake never decreased
	// the trailing arm wins, so this is a provable no-op off the drain path.
	if life := lifeAvgStake(cs, now); life > xbar {
		xbar = life
	}

	// Bond = 50%·X̄, never zero; the court's cap applies if set (0 = uncapped).
	bond := xbar * answerBondBps / 10000
	if c.params.answerBondCapCC > 0 && bond > c.params.answerBondCapCC {
		bond = c.params.answerBondCapCC
	}
	// COLLATERALIZATION FLOOR (audit round 2). The bond must cover the slash it
	// may later owe, or the clamp at ResolveFlag silently voids the deterrent.
	// The slash's draw arm is 1.6× the answered side's FROZEN CONVICTION, while
	// the bond is sized off the 3-HOUR trailing X̄ — and Unstake keeps conviction
	// by design (F9, no-loss). So a mill could bank conviction with a large stake,
	// drain to minAnswerX two hours before answering, and post a bond 224× smaller
	// than the slash it had earned: caught in full, it paid ~51 CC against a
	// 11_220 CC exposure. For a roughly constant pool the two arms both scale with
	// X̄ and this floor is a no-op (the deploy invariant bounds the draw arm at
	// 30.8%·X̄ < 50%·X̄ over the full 12-week life), so it binds ONLY on a pool
	// that was drained or is otherwise mispriced by X̄. It is applied after the
	// court cap deliberately: an uncollateralized slash is worse than an
	// over-large bond, and the cap must not re-open the hole.
	// Floors on the WHOLE sizer, not just the draw arm: the flat arm (4.5%·X̄)
	// is covered today only because answerBondCapCC is 0 everywhere, so a
	// draw-arm-only floor is a trap armed the day that knob is wired.
	convHi, convLo := cs.sideConv(verdict)
	if floor := slashSizeAt(xbar, convHi, convLo); floor > bond {
		bond = floor
	}
	if bond < 1 {
		bond = 1
	}
	c.coin.Transfer(who, c.escrow, bond)

	// FREEZE: conviction is pinned here — immutable by construction (audit H1).
	cs.frozenAt = now
	cs.rateAccAtFreeze = c.rateAccFP
	cs.xBarFrozen = xbar // P6: the one base for every later %-of-X̄ quantity

	cs.answer = int8(verdict)
	cs.answerer = who
	cs.answerBond = bond
	cs.answerBond0 = bond
	cs.qualityEpoch = c.coin.Epoch() - 1
	cs.answerHeight = now
	if inPriority {
		holdPriority(c, who, claimID)
	}
	// Policing surfaces (§5.3): an answered claim becomes policeable, so it
	// enters both strips regardless of any hide bit; a seeded/appeal row that
	// was waiting on the pending list moves over. Non-panicking by contract.
	pendingExit(c, cs)
	stripEnter(c, cs)
	// On the meta court: persist the BINDING appeal parse and take the target's
	// review slot. Refuses if another appeal already holds it (meta.gno) — the
	// one moderation read that gates a money entrypoint, and it reads only the
	// latch, never a hide bit (MODERATION.md §2 read gate #4).
	onClaimAnswered(c, cs)
}

// ------------------------------------------------------------------ reads --

func HasAnswer(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).frozenAt != 0
}

func AnswerVerdict(courtSlug string, claimID uint64) int {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.frozenAt == 0 {
		panic("courtv2: no answer yet")
	}
	return int(cs.answer)
}

func AnswerBond(courtSlug string, claimID uint64) int64 {
	return mustClaim(mustCourt(courtSlug), claimID).answerBond
}

func Answerer(courtSlug string, claimID uint64) address {
	return mustClaim(mustCourt(courtSlug), claimID).answerer
}

// XBarFrozen is the P6 snapshot every bond/slash/flag quantity reads.
func XBarFrozen(courtSlug string, claimID uint64) int64 {
	return mustClaim(mustCourt(courtSlug), claimID).xBarFrozen
}
