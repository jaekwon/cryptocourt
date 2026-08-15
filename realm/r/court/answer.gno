package court

import (
	"chain/runtime"
)

// answerWindow is the trailing window (in blocks) the answerability X̄ and the
// pre-answer price are read over. A V1 value: it demands SOME trailing history so a
// fresh claim cannot be flash-answered, without waiting the tokenomics' full week
// (raise toward 7 days as the design hardens). 3 hourly buckets.
const answerWindow = 3 * epochBlocks

// PostAnswer posts THE answer to a claim — a proposed verdict (YES or NO) backed by
// a bond. One answer per claim, single-funded. The bond is min(50%·X, cap) in CC,
// escrowed; if the answer stands it is returned (and the disputer's forfeited bond
// paid to the answerer), and if it is overturned the answerer loses it.
//
// Answerability reads the MATURE trailing open interest X̄, not instant supply — an
// instant read is flash-crossable (§3.5a). It also snapshots the pre-answer price
// ONCE, at the first answer, kept across dispute rounds for a 3-round CloseAt.
func PostAnswer(cur realm, courtSlug string, claimID uint64, verdict int) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.answered {
		panic("court: this claim already has an answer")
	}
	if verdict != outcomeYES && verdict != outcomeNO {
		panic("court: an answer must be YES or NO")
	}

	// Answerability: the trailing X̄ (CC) must be mature and at or above the floor.
	// OI carry-forward is truthful (X moves only on mint/redeem), so no StaleBy gate.
	x, mature := cs.oi.Average(runtime.ChainHeight(), answerWindow)
	if !mature {
		panic("court: not enough open-interest history to answer yet")
	}
	if x < c.params.minAnswerX {
		panic("court: open interest is below the minimum to answer")
	}

	// Bond = min(50%·X, cap), never zero (an answer straight to the record still
	// needs skin — the tokenomics' "some amount").
	bond := x / 2
	if c.params.answerBondCapCC > 0 && bond > c.params.answerBondCapCC {
		bond = c.params.answerBondCapCC
	}
	if bond < 1 {
		bond = 1
	}
	c.coin.Transfer(who, c.escrow, bond)

	// Snapshot the pre-answer price ONCE, from the mature price twap (an immature or
	// never-traded market splits the two sides equally). Kept across rounds.
	if !cs.preAnswerSet {
		p, pm := cs.price.Average(runtime.ChainHeight(), answerWindow)
		if !pm {
			p = priceScale / 2 // no traded price yet → 50/50
		}
		cs.preAnswerPrice = p
		cs.preAnswerSet = true
	}

	cs.answered = true
	cs.answer = int8(verdict)
	cs.answerer = who
	cs.answerBond = bond
	cs.answerHeight = runtime.ChainHeight()
}

// ------------------------------------------------------------------ reads --

// HasAnswer, AnswerVerdict, AnswerBond, and PreAnswerPrice expose a claim's answer.
// AnswerVerdict is outcomeYES/outcomeNO; PreAnswerPrice is a grid price 0..100.
func HasAnswer(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).answered
}

func AnswerVerdict(courtSlug string, claimID uint64) int {
	return int(mustClaim(mustCourt(courtSlug), claimID).answer)
}

func AnswerBond(courtSlug string, claimID uint64) int64 {
	return mustClaim(mustCourt(courtSlug), claimID).answerBond
}

func PreAnswerPrice(courtSlug string, claimID uint64) int64 {
	return mustClaim(mustCourt(courtSlug), claimID).preAnswerPrice
}

// Answerer is who posted the claim's answer.
func Answerer(courtSlug string, claimID uint64) address {
	return mustClaim(mustCourt(courtSlug), claimID).answerer
}
