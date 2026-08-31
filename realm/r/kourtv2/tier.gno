// The claim's draw multiplier, derived from its size against the court's own
// typical claim.
//
// WHAT THIS REPLACES. A sealed three-bucket vote — low, mid, high — riding a
// dispute or a flag, with a bond, a bounty, a slash and a counter-flag window
// behind it. It answered "was this claim worth answering?" and multiplied the
// whole claim draw by 0, 1 or 2. It cost a second ballot on every disputed
// claim, which is the thing this removes.
//
// THE SUBSTITUTE IS THE MONEY ITSELF. A claim capital showed up for is worth
// more than one nobody staked, and the court already measures that: xBarFrozen
// is the claim's time-averaged TOTAL stake, yes and no together, snapshotted at
// the answer and already the base every bond and slash is priced off. So the
// multiplier reads it instead of asking.
//
// WHY IT REACHES A STAKER AT ALL, which is the point of the change. A winner's
// slice is
//
//	gross = drawWinners × myConv / winPoolConv
//	      = (tier × midGross × 80/93) × myConv / midGross
//	      = tier × myConv × 0.86
//
// because midGross IS winPoolConv — the pool cancels. Without a multiplier the
// same 10 CC earns the same on a 100 CC claim and a 1000 CC claim. `tier` is the
// only free term in that expression, so it is the only place a claim's size can
// reach a staker's rate.
//
// CONTINUOUS, NOT BANDED. A step function has a bar, and crossing a bar
// re-prices the crosser's WHOLE pre-existing position in one jump — the last
// unit of stake before the line buys a windfall on every unit already there. A
// continuous multiplier has no such jump.
//
// WHAT IS ACCEPTED, said once and plainly. This is buyable at the margin: a
// holder who stakes their own claim raises its multiplier, including on their
// own position, and PostAnswer has no no-position gate so they may answer it
// themselves. The bound is the token's distribution — the multiplier cannot be
// lifted without locking a real fraction of supply on the claim, on a side, for
// its life. The owner has ruled that bound sufficient. It is the same bound the
// vote had, where a holder could carry a tally with weight they merely HELD.
package kourtv2

// tierBpsFor is the claim's draw multiplier in bps: tierParBps is 1×.
//
// Reads only frozen state, so the answer is fixed the moment the claim is
// answered and no later caller can move it. That is not a nicety: Crystallize
// is permissionless once the participants' week has passed, so a multiplier
// derived from anything live would let whoever calls it choose the moment, and
// therefore the number.
//
// The clamps are not decoration:
//
//   - the FLOOR exists because a claim that reaches this function already
//     cleared effMinAnswerX, which is the court certifying it was worth
//     resolving. Paying zero on a claim the same measure just admitted would be
//     two thresholds on one quantity contradicting each other — and it would
//     leave the answerer, who posted a bond and carries the risk, drawing
//     nothing on a claim they were allowed to answer.
//
//   - the CEILING is the old high band exactly. tierHighX was 2, so a 2×
//     ceiling keeps the maximum draw per claim, and with it the emission
//     ceiling every deploy invariant is fitted to, where it already is. This
//     re-keys which claims reach the top; it does not raise the top.
func tierBpsFor(cs *claimState) int64 {
	if cs.tierRef <= 0 {
		return tierParBps // pre-answer, or a claim frozen before this shipped
	}
	v := mulDiv128(cs.xBarFrozen, tierParBps, cs.tierRef)
	if v < tierFloorBps {
		return tierFloorBps
	}
	if v > tierCeilBps {
		return tierCeilBps
	}
	return v
}

// tierRefAt is the claim size that earns exactly 1×, resolved at the answer and
// then frozen onto the claim.
//
// THE COURT'S OWN TYPICAL CLAIM, so "big" means big HERE. A fixed supply
// fraction cannot do that: it would call every claim in a small-claims court
// low and every claim in a large one high, and the number itself would be a
// guess. Against the court's own average, a claim of average size earns par by
// construction, in every court, with nothing to pick by hand.
//
// FLOORED ON A SUPPLY FRACTION, and the floor does two jobs at once:
//
//  1. IT IS THE BOOTSTRAP. A new court's accumulator is empty, so the floor is
//     the reference until real claims have accumulated. There is no "wait for N
//     claims" special case and no divide-by-zero — the court simply behaves like
//     a fixed-reference one at first and re-centres as it fills.
//
//  2. IT IS THE ANTI-GAMING BOUND, and this is the load-bearing half. A LOW
//     reference raises everybody's multiplier, so the cheap attack is to drag
//     the average DOWN with a run of dust claims rather than to grow one claim.
//     Answering costs a bond each, but the floor removes the question: the
//     reference cannot be pushed below it, so the cheapest route to the ceiling
//     is always real capital on the claim itself.
func tierRefAt(c *Court) int64 {
	ref := c.xBarAcc / tierEMAN
	if floor := supplyFloor(c, tierRefFloorBps, tierRefDustCC); ref < floor {
		ref = floor
	}
	return ref
}

// observeClaimSize folds one answered claim's size into the court's running
// average. Called once, at the freeze, AFTER the answering claim has taken its
// own reference — a claim does not move the average it is measured against.
//
// AN ACCUMULATOR, NOT A MEAN, because the obvious integer EMA stalls. Written
// `ema += (x - ema) / N`, every update where |x - ema| < N truncates to zero and
// the average sticks forever a few units from the truth — on a court whose
// claims are all within N base units of each other, that is every update.
// Holding N×ema and dividing only on read keeps the residue.
//
// O(1), which is the other requirement: the alternative is walking the docket at
// every answer, and that grows without bound.
func observeClaimSize(c *Court, xbar int64) {
	c.xBarAcc = mustAdd(c.xBarAcc, xbar-c.xBarAcc/tierEMAN)
}

// ClaimTierBps quotes the multiplier a claim's draw is scaled by, in bps of 1×.
//
// Quoted because it is the one term that decides what a staker's conviction is
// worth on this claim rather than another, and it is not derivable from
// anything else a page can read: it needs the court's average at the moment
// this claim was answered, which is frozen on the claim and nowhere else.
func ClaimTierBps(courtSlug string, claimID uint64) int64 {
	return tierBpsFor(mustClaim(mustCourt(courtSlug), claimID))
}

// ClaimTierRef quotes the claim size that would have earned 1× on this claim —
// the court's typical claim as of this claim's answer.
//
// The companion to ClaimTierBps: a multiplier without its reference cannot be
// checked against anything, and the reference moves per claim.
func ClaimTierRef(courtSlug string, claimID uint64) int64 {
	return mustClaim(mustCourt(courtSlug), claimID).tierRef
}
