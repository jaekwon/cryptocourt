// The answerer's bond, after the quality lane.
//
// This file is what survived quality.gno. settleAnswerBond was never about
// quality — it is the answer bond's terminal disposition, shared by Finalize
// (dispute.gno) and SettleUndisputed (session.gno) — but it lived in that file
// because the reserve it carved was the flag lane's slash.
package kourtv2

// settleAnswerBond returns the answer bond to the answerer at a terminal path.
//
// IT USED TO CARVE A SLASH RESERVE FIRST. The flag lane could levy against this
// bond after settlement, so the bond was split — reserve retained, remainder
// refunded — and cs.answerBond was left holding the reserve rather than zeroed.
// With the lane gone there is no later levy to reserve against, and the whole
// bond is simply the answerer's again. The reserve arithmetic is not kept "just
// in case": a reserve that is provably always zero is dead state that reads
// like a live risk.
//
// ONE COPY BECAUSE THE CODE ASKED FOR ONE. The two terminal paths ran these
// lines character-identically before this function existed, and the corpus was
// paying for the copy in the open — M3-HIGH-1 stood as TWO rows with
// byte-identical find and replace, one aimed at each path.
//
// The caller keeps its own `if cs.answerBond > 0` guard: each terminal path has
// its own reason to be standing there and its own note about it, and what is
// shared is only what happens once it is.
func settleAnswerBond(c *Court, cs *claimState) {
	c.coin.Transfer(c.escrow, cs.answerer, cs.answerBond)
	cs.answerBond = 0
}

// sideConv is one side's pool conviction accumulator (u128). It is read from
// accumulators that freeze at the answer (advancePools settles them in
// PostAnswer; stake and unstake refuse after), so the value is identical at
// PostAnswer, at settle and at crystallize — which is what lets the bond floor
// and the draw share one reading of the same quantity.
func (cs *claimState) sideConv(side int) (hi, lo uint64) {
	if side == sideYES {
		return cs.yesConvHi, cs.yesConvLo
	}
	return cs.noConvHi, cs.noConvLo
}

// bondFloorAt sizes the answer bond's conviction floor: max(4.5%·X̄, 1.6× the
// mid draw a side's conviction would take). Parameterized on the base and one
// side's conviction so PostAnswer can price it before the freeze pins land.
//
// THIS WAS slashSizeAt AND IT SIZED A PENALTY. The conclusive-low slash was
// max(4.5%·X̄, 1.6× the mill's would-be mid draw), and the answer bond was
// floored at it so a levy could never clamp from under its own collateral —
// one function with two callers, so "the bond collateralizes the slash" held by
// SHARED CODE rather than by two arithmetic paths a drained pool could pull
// apart. The slash is gone with the quality lane. The floor is not, and
// answer.gno says at the call site what it is still for.
func bondFloorAt(xbar int64, convHi, convLo uint64) int64 {
	flat := xbar * bondFloorFlatBps / 10000
	if draw := mulDiv128(convToCC(convHi, convLo), bondFloorConvBps, 10000); draw > flat {
		return draw
	}
	return flat
}

// bondFloorFor is the floor keyed to the ANSWERED side, which is what PostAnswer
// prices before it takes the max over both sides. Kept as a named function
// because the tests that pin the bond compute the same quantity, and two
// arithmetic paths for one number is how they drift apart.
func bondFloorFor(cs *claimState) int64 {
	hi, lo := cs.sideConv(int(cs.answer))
	return bondFloorAt(cs.xBarFrozen, hi, lo)
}
