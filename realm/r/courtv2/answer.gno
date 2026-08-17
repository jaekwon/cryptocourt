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
	// Answerability: mature trailing X̄ at or above the floor.
	xbar, mature := cs.oi.Average(now, answerWindow)
	if !mature {
		panic("courtv2: not enough stake history to answer yet")
	}
	if xbar < c.params.minAnswerX {
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

	// Bond = 50%·X̄, never zero; the court's cap applies if set (0 = uncapped).
	bond := xbar * answerBondBps / 10000
	if c.params.answerBondCapCC > 0 && bond > c.params.answerBondCapCC {
		bond = c.params.answerBondCapCC
	}
	if bond < 1 {
		bond = 1
	}
	c.coin.Transfer(who, c.escrow, bond)

	// FREEZE: the era integral is walked to this exact height, then pinned —
	// frozen conviction is immutable by construction (audit H1).
	touch(c)
	advancePools(c, cs)
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
