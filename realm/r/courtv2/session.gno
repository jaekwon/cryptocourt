// The 72h settle (PLAN §3.1, P4): an answered, UNDISPUTED claim reaches
// VERDICT_FINAL a fixed delay after its answer — silence settles, safely,
// because staking froze at the answer and principal never depends on anything
// that follows. The answerer's bond returns exactly once (a settled claim can
// still be quality-flagged — quality ≠ verdict — but the verdict itself is
// final; V2 has no reopen of undisputed verdicts through this path: contesting
// happens by DISPUTING before the delay lapses).
package courtv2

import "chain/runtime"

// SettleUndisputed records the answer as the final verdict once the 72h delay
// has passed with no dispute. Permissionless.
func SettleUndisputed(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.frozenAt == 0 {
		panic("courtv2: there is no answer to settle")
	}
	if cs.disputeOpen || cs.round > 0 {
		panic("courtv2: this claim was disputed; it settles by vote")
	}
	if cs.verdictAt != 0 {
		panic("courtv2: already settled")
	}
	if runtime.ChainHeight() < cs.answerHeight+settleDelay {
		panic("courtv2: the answer has not aged the 72h settlement minimum")
	}
	touch(c)

	cs.verdictAt = runtime.ChainHeight()
	cs.route = "undisputed"
	cs.tier = tierMidX // the undisputed default; the flag lane may re-vote it

	// The bond returns exactly once — and is zeroed so nothing later (a
	// quality flag, a slash path) can double-dispose it. The >0 guard also
	// avoids grc20votes' non-positive-transfer panic (the V1 lesson).
	if cs.answerBond > 0 {
		c.coin.Transfer(c.escrow, cs.answerer, cs.answerBond)
		cs.answerBond = 0
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
	if cs.verdictAt == 0 {
		panic("courtv2: no verdict yet — unstake freely before an answer, withdraw after the verdict")
	}
	touch(c)
	p := getPos(c, cs, who, side)
	if p.stake <= 0 {
		panic("courtv2: nothing staked on that side")
	}
	accrue(c, cs, p, side) // settles to the freeze pin (a no-op if already settled)
	amount := p.stake
	p.stake = 0
	if side == sideYES {
		cs.yesStake -= amount
	} else {
		cs.noStake -= amount
	}
	c.coin.Transfer(c.escrow, who, amount)
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
		panic("courtv2: no verdict yet")
	}
	return int(cs.answer)
}

func VerdictRoute(courtSlug string, claimID uint64) string {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.verdictAt == 0 {
		panic("courtv2: no verdict yet")
	}
	return cs.route
}
