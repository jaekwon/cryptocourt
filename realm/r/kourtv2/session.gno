// The 72h settle (PLAN §3.1, P4): an answered, UNDISPUTED claim reaches
// VERDICT_FINAL a fixed delay after its answer — silence settles, safely,
// because staking froze at the answer and principal never depends on anything
// that follows. The answerer's bond returns exactly once (a settled claim can
// still be quality-flagged — quality ≠ verdict — but the verdict itself is
// final; V2 has no reopen of undisputed verdicts through this path: contesting
// happens by DISPUTING before the delay lapses).

package kourtv2

// SettleUndisputed records the answer as the final verdict once the 72h delay
// has passed with no dispute. Permissionless.
func SettleUndisputed(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.frozenAt == 0 {
		panic("kourtv2: there is no answer to settle")
	}
	if cs.disputeOpen || cs.round > 0 {
		panic("kourtv2: this claim was disputed; it settles by vote")
	}
	if cs.verdictAt != 0 {
		panic("kourtv2: already settled")
	}
	// The deadline is a date now (clock.gno); the height arithmetic remains the
	// fallback for claims answered before the stamps existed. One message
	// either way — the caller is told the same fact.
	if passed, known := pastDeadline(cs.answeredAtTime, settleSecs); (known && !passed) ||
		(!known && heightNow() < cs.answerHeight+settleDelay) {
		panic("kourtv2: the answer has not aged the 72h settlement minimum")
	}
	touch(c)

	cs.verdictAt = heightNow()
	cs.verdictAtTime = nowTime()
	cs.route = "undisputed"
	// The record froze with the pools; clip its hourly tail to the final week
	// now — no later stake op will ever ride a trim past this point.
	trimClaimHistory(c, cs, uint32(cs.frozenAt/epochBlocks)+1)
	cs.provisional = cs.answer
	// The bond returns WHOLE. Why it is whole rather than partly retained is
	// settleAnswerBond's own story (answerbond.gno) and is not repeated here.
	//
	// WHAT USED TO BE HERE, because deleting it outright would invite somebody to
	// reintroduce it: twenty-one lines sizing a slash-sized reserve to keep
	// collateralized past settle (audit M3-HIGH-1, v0.40, v0.44), because a
	// conclusive-low flag could still land while flags ran until open the rewards.
	// Every mechanism that paragraph reasoned about — the quality slot,
	// slotConsumed, OpenFlag, ResolveFlag, pendingSlash — went with the quality
	// lane, and none of them has a single non-comment line left in this realm.
	// It also cited TestSettleRetainsNothingAfterDustLowNoSlash as the fixture
	// isolating its load-bearing clause; that test is gone too, surviving only as
	// a mention in audit_m3_test.gno's own header.
	//
	// So it justified a retention this code no longer performs, through symbols a
	// reader cannot find, against a fixture that does not run. Two mutation rows
	// anchored on its `if !cs.tierFinal && !cs.slotConsumed {` and were retired in
	// 4cb3969 for the same reason.
	if cs.answerBond > 0 {
		settleAnswerBond(c, cs)
	}
	releasePriority(c, cs.answerer, claimID)
}

// WithdrawStake returns a staker's FULL principal on one side after the
// verdict is final. Both sides withdraw 1× — losers lose nothing — and this
// path is unpausable: no flag, no quality vote, nothing downstream may hold
// principal (P4/V2-6, split settlement). Conviction records survive the
// withdrawal for the reward draws.
func WithdrawStake(cur realm, courtSlug string, claimID uint64, side int) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	mustSide(side)
	// Withdrawable at VERDICT_FINAL (both sides), or EARLY for the side a
	// standing provisional verdict is against (econ F7: their outcome cannot
	// improve — principal is 1× regardless and conviction is already frozen —
	// and releasing them defuses the multi-round freeze-hostage, A12).
	if cs.verdictAt == 0 && !(cs.provisional >= 0 && side != int(cs.provisional)) {
		panic("kourtv2: no verdict yet — unstake freely before an answer, withdraw after the verdict")
	}
	touch(c)
	advancePools(c, cs)
	p := getPos(c, cs, who, side)
	if p.stake <= 0 {
		panic("kourtv2: nothing staked on that side")
	}
	accrue(c, cs, p, side) // settles to the freeze pin (a no-op if already settled)
	amount := p.stake
	p.stake = 0
	if side == sideYES {
		cs.yesStake -= amount
	} else {
		cs.noStake -= amount
	}
	releaseStake(c, who, amount)
	return amount
}

// ------------------------------------------------------------------ reads --

// Settled reports VERDICT_FINAL; Verdict is the final side; VerdictRoute is
// "undisputed" or "vote" — the provenance the record exists to carry.
func Settled(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).verdictAt != 0
}

func Verdict(courtSlug string, claimID uint64) int {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.verdictAt == 0 {
		panic("kourtv2: no verdict yet")
	}
	if cs.provClose {
		panic("kourtv2: closed without a decision (three failed dispute rounds)")
	}
	return int(cs.provisional)
}

func VerdictRoute(courtSlug string, claimID uint64) string {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.verdictAt == 0 {
		panic("kourtv2: no verdict yet")
	}
	return cs.route
}

// SettleDeadline is the block height at which an answered, undisputed claim
// becomes settleable (the answer height + the 72h delay); 0 if unanswered. A UI
// renders a wall-clock countdown from it, and it is also the first-round dispute
// window's close.
func SettleDeadline(courtSlug string, claimID uint64) int64 {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.frozenAt == 0 {
		return 0
	}
	return cs.answerHeight + settleDelay
}
