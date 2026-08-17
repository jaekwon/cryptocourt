package kourtv1

import (
	"chain/runtime"
)

// settleDelay is the 72-hour minimum an answer must age before it can settle
// undisputed (§10). A V1 rolling delay; fixed weekly session boundaries are a
// refinement that only changes WHEN a due answer settles, not the accounting.
const settleDelay = int64(51840) // 72h at gno's 5-second blocks

// SettleUndisputed records the answer as the provisional verdict for a claim that
// was answered and left UNDISPUTED past the settlement minimum, and starts the
// escrow window so Finalize can resolve it. This is the path a claim takes when
// nobody contests the answer — the answerer keeps their bond. Permissionless.
//
// The answerer keeps their bond. A settled claim CAN still be reopened and overturned
// during its escrow window (see the reopen machine in dispute.gno), so the bond is made
// safe by DISPOSING IT EXACTLY ONCE — returned and zeroed below — not by any refusal to
// reopen. The zeroing is load-bearing; do not remove it as "redundant".
func SettleUndisputed(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if !cs.answered {
		panic("court: there is no answer to settle")
	}
	if cs.disputeOpen || cs.round > 0 {
		panic("court: this claim was disputed; it settles by vote, not by session")
	}
	if cs.provisional >= 0 || cs.finalized {
		panic("court: already settled")
	}
	if runtime.ChainHeight() < cs.answerHeight+settleDelay {
		panic("court: the answer has not aged the 72h settlement minimum")
	}

	// The answer stands undisputed; the answerer keeps their bond. Settle it exactly
	// once and zero it, so a later reopen-and-resolve cannot double-return it (the
	// guard also avoids grc20votes' non-positive-transfer panic).
	if cs.answerBond > 0 {
		c.coin.Transfer(c.escrow, cs.answerer, cs.answerBond)
		cs.answerBond = 0
	}
	cs.provisional = cs.answer
	// The market freezes now (provisional is set), so record the settlement fee from
	// the frozen winning-share supply — pulled later by the answerer (ClaimSettleFee).
	chargeSettleFee(c, cs, claimID)
	// The escrow clock is set once; a reopen never resets it.
	if cs.escrowUntil == 0 {
		cs.escrowUntil = runtime.ChainHeight() + escrowWindow(c, cs)
	}
}

// SettleableAt is the height a claim's undisputed answer becomes settleable (0 if
// it has no answer). A page uses it to show the countdown.
func SettleableAt(courtSlug string, claimID uint64) int64 {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if !cs.answered {
		return 0
	}
	return cs.answerHeight + settleDelay
}
