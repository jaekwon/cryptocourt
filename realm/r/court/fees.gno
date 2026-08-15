package court

import (
	"math/bits"

	grc20votes "gno.land/p/cryptocourt/grc20votes/v0"
)

// The two fees that pay for a verdict, wired onto the resolution flow — the realm's
// economic engine. A DISPUTED claim that reaches a decision pays an ADJUDICATION fee
// to the voters who had to sit; an UNDISPUTED claim pays a smaller SETTLEMENT fee to
// the answerer who produced a verdict nobody had to vote on. A claim pays exactly ONE
// of them, or none: a claim closed without a decision, or a dispute that failed
// quorum, pays nothing. Both are skimmed from the WINNING side's collateral — the
// losing side gets nothing either way — so a winning share pays slightly less than
// the full priceScale. The skim stays in the same escrow as the collateral and is
// PULLED by its claimants, never pushed, so resolution never iterates a holder set.
//
// Design converged across three independent passes (see docs/AUDIT.md). The
// load-bearing choices:
//   - Compute the fee ONCE at the resolution step, from the winning-share supply S
//     frozen there. market.gno freezes mint/redeem the moment a verdict is
//     provisional, so S — and thus the collateral the fee is a fraction of — cannot
//     drift before Finalize, and a matched-set holder cannot redeem out at par to
//     dodge the fee on their winning leg.
//   - FLOOR every value that leaves escrow, so rounding dust only ever stays in the
//     pool; escrow can never be short.
//   - Derive each voter's weight from governor.VoteOf, whose stored weight is exactly
//     what the tally summed. That equality is what makes Σ floor(pool·w/W) ≤ pool
//     airtight rather than approximate — the whole conservation proof rests on it.

const (
	feeNone   uint8 = 0
	feeAdj    uint8 = 1    // adjudication: a dispute that reached a decision
	feeSettle uint8 = 2    // settlement: an undisputed answer
	partBps   int64 = 6000 // 60% of the adjudication fee for turning up; the rest for being right
)

// adjFee is min(adjFeeBps·collateral, the flat GNOT cap converted to CC). The cap
// converts at the curve's MARGINAL price (COURTS_TOKENOMICS §9 — "flat GNOT-equivalent
// figures convert to CC at the curve's marginal price"): CoinPrice is µGNOT per CC
// base unit, so adjFeeCapGNOT (µGNOT) / price is CC directly. Both legs floor (a
// smaller fee only lightens escrow — always safe). A young court (minted < the curve
// denom) has price 0 and no cap, which is correct: when a coin is near-free, 200 GNOT
// is an unbounded amount of it, and 3% of a tiny collateral is negligible anyway. The
// cap is what stops the fee being a standing skim — price rises monotonically along
// the one-way curve, so the cap only ever shrinks, while the coin an attacker must
// hold to sole-vote grows with the court and the capped prize does not.
func adjFee(c *Court, collateral int64) int64 {
	f := collateral * c.params.adjFeeBps / grc20votes.Bps
	if price := c.crv.Price(c.minted); price > 0 {
		if capCC := c.params.adjFeeCapGNOT / price; f > capCC {
			f = capCC
		}
	}
	return f
}

// chargeAdjFee records the adjudication fee on a DECIDED dispute — the winning-share
// supply frozen here as the payout denominator, plus the fee skimmed from the
// collateral. Called from ResolveDispute's overturn and uphold branches only (a
// failed-quorum round charges nothing, leaving feeKind = feeNone). The provisional
// verdict is already set when this runs, so the market is frozen and Supply is the S
// that both the fee and every winner payout are a fraction of.
func chargeAdjFee(c *Court, cs *claimState, claimID uint64) {
	if cs.feeKind != feeAdj {
		// The FIRST decided resolution sizes the fee (from feeNone, or REPLACING a prior
		// feeSettle earmark — a claim pays one fee, never both). A later reopen that
		// re-decides finds feeKind==feeAdj and keeps the pool: charged exactly once.
		cs.winShares = c.shares.Supply(claimID)
		cs.feePool = adjFee(c, ccMul(cs.winShares, priceScale))
		cs.feeKind = feeAdj
	}
	// (Re)attribute the fee to THIS deciding round's electorate: a reopen clobbers
	// proposalID, so ClaimAdjFee must read feeProposalID, which always points at the
	// last decided round — the one whose verdict `provisional` now reflects.
	cs.feeProposalID = cs.proposalID
}

// chargeSettleFee records the settlement fee on an UNDISPUTED claim — the answerer's
// half of settleFeeBps of the resolved collateral (the roll's half is not charged in
// V1, so winners keep it). Called from SettleUndisputed after the provisional verdict
// is set, so the market is frozen and Supply is the frozen S.
func chargeSettleFee(c *Court, cs *claimState, claimID uint64) {
	cs.winShares = c.shares.Supply(claimID)
	cs.feeKind = feeSettle
	collateral := ccMul(cs.winShares, priceScale)
	cs.feePool = collateral * c.params.settleFeeBps / grc20votes.Bps / 2 // the answerer's half
}

// ClaimAdjFee pays the caller their share of a resolved dispute's adjudication fee:
// a pro-rata cut of 60% of the fee for having voted at all, plus a pro-rata cut of
// the other 40% if they voted WITH the verdict. Pull-based and once per voter (a
// per-(claim,voter) row guards a second claim). Only after Finalize, only on a claim
// that took the dispute path to a decision.
func ClaimAdjFee(cur realm, courtSlug string, claimID uint64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if !cs.finalized {
		panic("court: the claim is not finalized; fees are claimable after settlement")
	}
	if cs.feeKind != feeAdj || cs.feePool == 0 {
		panic("court: no adjudication fee on this claim")
	}
	key := be8(claimID) + string(who)
	if c.feeClaims.Has(key) {
		panic("court: you already claimed this fee")
	}

	choice, weight, ok := c.gov.VoteOf(cs.feeProposalID, who)
	if !ok || weight <= 0 {
		panic("court: you did not vote on the deciding round of this dispute")
	}
	yes, no, abstain, _ := c.gov.Tally(cs.feeProposalID)
	total := yes + no + abstain // the cast weight — every voter's weight, summed

	overturned := cs.provisional != cs.answer // within feeAdj, a flipped verdict ⟺ overturn
	vw := no                                  // uphold: the "no" (uphold) weight prevailed
	if overturned {
		vw = yes // overturn: the "yes" (overturn) weight prevailed
	}

	// The 60/40 participation/verdict split — UNLESS no weight actually voted WITH the
	// verdict (a dispute carried to quorum entirely by abstentions: yes = no = 0, an
	// uphold). Then the 40% has no possible claimant, so folding it into participation
	// distributes the whole fee to those who turned up, instead of stranding it in
	// escrow after the winners were already charged the full amount.
	partPool := cs.feePool * partBps / grc20votes.Bps
	verdPool := cs.feePool - partPool
	if vw == 0 {
		partPool = cs.feePool
		verdPool = 0
	}

	pay := mulDivFloor(partPool, weight, total) // participation slice: everyone who voted
	onVerdict := (overturned && choice == "yes") || (!overturned && choice == "no")
	if onVerdict && vw > 0 {
		pay += mulDivFloor(verdPool, weight, vw) // verdict slice: the weight that was right
	}

	c.feeClaims.Set(key, true)
	if pay > 0 {
		c.coin.Transfer(c.escrow, who, pay)
	}
	return pay
}

// ClaimSettleFee pays the answerer the settlement fee of an undisputed, finalized
// claim — the reward for producing a verdict nobody had to vote on. Only the
// answerer, only once, pull-based and gated on Finalize like every other payout.
func ClaimSettleFee(cur realm, courtSlug string, claimID uint64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if !cs.finalized {
		panic("court: the claim is not finalized")
	}
	if cs.feeKind != feeSettle {
		panic("court: no settlement fee on this claim")
	}
	if who != cs.answerer {
		panic("court: only the answerer may claim the settlement fee")
	}
	if cs.settleFeePaid {
		panic("court: the settlement fee is already claimed")
	}
	cs.settleFeePaid = true
	pay := cs.feePool
	if pay > 0 {
		c.coin.Transfer(c.escrow, who, pay)
	}
	return pay
}

// mulDivFloor returns floor(a·b/denom) via a 128-bit intermediate, so the products
// this file forms (won·collateral, pool·weight) never overflow int64. Its precondition
// — denom > 0 and the product's high word < denom, which bits.Div64 requires — holds
// at every call: for won·collateral/S the high word is < S because collateral =
// S·priceScale and priceScale·S < 2^64; for pool·weight/W it is < W because pool ≤
// collateral < 2^64. (This is NOT cshares' mulDivFloor, whose b ≤ denom precondition
// these calls do not meet — the high-word bound is the one that matters.)
func mulDivFloor(a, b, denom int64) int64 {
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	q, _ := bits.Div64(hi, lo, uint64(denom))
	return int64(q)
}

// ------------------------------------------------------------------ reads --

// FeePool is the CC skimmed as this claim's fee (0 if none due). FeeKind is
// "adjudication", "settlement", or "none" — which fee, if any, the claim pays.
func FeePool(courtSlug string, claimID uint64) int64 {
	return mustClaim(mustCourt(courtSlug), claimID).feePool
}

func FeeKind(courtSlug string, claimID uint64) string {
	switch mustClaim(mustCourt(courtSlug), claimID).feeKind {
	case feeAdj:
		return "adjudication"
	case feeSettle:
		return "settlement"
	default:
		return "none"
	}
}
