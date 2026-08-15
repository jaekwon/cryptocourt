package court

import (
	"chain/runtime"
	"strconv"

	governor "gno.land/p/cryptocourt/governor/v0"
	grc20votes "gno.land/p/cryptocourt/grc20votes/v0"
)

// The dispute machine. An answer, once posted, can be contested: a disputer posts a
// bond and the court opens a governor vote framed as "OVERTURN the answer?". When
// the vote closes, a permissionless Resolve reclassifies the outcome PURELY from the
// frozen tally (never the drifting State string) into one of three, records a
// PROVISIONAL verdict, and starts an escrow window; a permissionless Finalize past
// the window performs the one irreversible step (cshares.Resolve or CloseAt).
//
// This is the design three review rounds converged on. Its load-bearing choices:
// ThresholdBps=5001 (so a lone floor-sized voter cannot capture the verdict), the
// tally-based classifier (Succeeded→Expired drift cannot strand a verdict), and the
// provisional→Finalize deferral (a reopen can overturn before shares lock). V1
// implements a single dispute round; reopen/doubling/3-round-close reuse the same
// classifier and are the next increment (the fields are already here).

const disputeKindName = "dispute" // NON-reserved (a govern: name caps at 8 gov-lanes)

// maxFailedRounds is the realm constant: after this many failed-quorum dispute rounds a
// claim is closed without a decision at the pre-answer price (§3.7). Three, so a griefer
// pays base+2·base+4·base = 7·base to force it.
const maxFailedRounds = 3

type disputeKind struct{}

func (disputeKind) Name() string { return disputeKindName }
func (disputeKind) Describe(payload string) string {
	return "resolve a disputed claim by a token vote (see the court page for the claim)"
}
func (disputeKind) Check(payload string) error { return nil } // the court validates
// Do is unused for a V1 verdict: the court resolves by reading the tally, not by
// governor.Execute, so this never runs. It exists only to satisfy the Kind seam.
func (disputeKind) Do(_ int, rlm realm, payload string) error { return nil }

// disputeRules are the per-court dispute Kind's terms. ThresholdBps=5001 is the
// overturn bar; QuorumBps is a dead fallback (ProposeWithQuorum's absolute floor is
// used instead); DelayBlocks≈0 because escrow, not the governor timelock, is the
// reaction window; GraceBlocks is modest so a decided-but-unexecuted proposal frees
// its slot via Sweep.
func disputeRules(p Params) governor.Rules {
	return governor.NewRules(5000, p.disputeThresholdBps, p.votingBlocks, 1, p.graceBlocks, 0)
}

// OpenDispute contests a claim's answer. The caller posts the dispute bond
// (max(gov-min, 20%·X̄) CC) and the court opens a governor vote with an absolute
// quorum floor and a per-round-unique payload. Returns the governor proposal id.
func OpenDispute(cur realm, courtSlug string, claimID uint64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if !cs.answered {
		panic("court: there is no answer to dispute")
	}
	if cs.disputeOpen {
		panic("court: a dispute is already open on this claim")
	}
	if cs.finalized {
		panic("court: this claim is already finalized")
	}
	if cs.provClose {
		panic("court: this claim is closing without a decision")
	}
	// A standing provisional verdict is REOPENABLE — but only during its escrow window
	// (§3.6): a reopen goes straight to a fresh vote, does not reset the escrow clock,
	// and pays no new fee. Before the first resolution (provisional < 0) there is no
	// escrow window yet, so the very first dispute is unrestricted.
	if cs.provisional >= 0 && runtime.ChainHeight() >= cs.escrowUntil {
		panic("court: the escrow window has passed; the verdict is final")
	}

	xbar, mature := cs.oi.Average(runtime.ChainHeight(), answerWindow)
	if !mature {
		panic("court: not enough open-interest history to dispute")
	}

	base := xbar / 5 // 20% of X̄
	if base < c.params.disputeBondMinCC {
		base = c.params.disputeBondMinCC
	}
	// The bond escalates by 2^failedRounds — this round's `base` shifted left by the
	// claim's failed-round count. failedRounds is read BEFORE this round's own increment
	// (in ResolveDispute) and is claim-scoped, so a fresh disputer address cannot reset
	// the multiplier: sybil-proof. `base` is recomputed each round from the trailing OI,
	// which is frozen once a verdict stands, so across reopens it is stable and the series
	// is base·{1,2,4}; while the min-floor dominates (small claims) it is exactly
	// disputeBondMinCC·{1,2,4}. Either way a griefer forcing three rounds pays ≥ 7·floor.
	// provClose bounds failedRounds ≤ 2 at any allowed OpenDispute; the clamp guards the
	// shift regardless.
	shift := cs.failedRounds
	if shift > maxFailedRounds-1 {
		shift = maxFailedRounds - 1
	}
	bond := base << uint(shift)
	c.coin.Transfer(who, c.escrow, bond)

	floor := quorumFloor(c, xbar)
	cs.round++
	payload := strconv.FormatUint(claimID, 10) + "|" + strconv.FormatInt(cs.round, 10)
	pid := c.gov.ProposeWithQuorum(c.escrow, disputeKindName, payload, "dispute", floor)

	cs.proposalID = pid
	cs.disputeOpen = true
	cs.disputeBond = bond
	cs.disputer = who
	return pid
}

// VoteDispute casts a vote on a claim's open dispute — "yes" to overturn the answer,
// "no" to uphold it, "abstain" for turnout without a side. It is court-intermediated
// so the court can (later) attribute the fee; the governor is the sole roll
// authority and refuses a second vote.
func VoteDispute(cur realm, courtSlug string, claimID uint64, choice string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if !cs.disputeOpen {
		panic("court: no open dispute on this claim")
	}
	c.gov.Vote(who, cs.proposalID, choice)
}

// ResolveDispute reads the FROZEN tally of a closed dispute vote and classifies it —
// failed-quorum, overturn, or uphold — disposing the bonds and recording a
// PROVISIONAL verdict plus the escrow window. Permissionless; only once the vote has
// closed. The verdict is derived from the tally, never the State label.
func ResolveDispute(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if !cs.disputeOpen {
		panic("court: no dispute to resolve")
	}
	if c.gov.State(cs.proposalID) == "active" {
		panic("court: the dispute vote is still open")
	}

	yes, no, abstain, _ := c.gov.Tally(cs.proposalID)
	cast := yes + no + abstain
	floor := c.gov.QuorumFloor(cs.proposalID)
	firstResolution := cs.provisional < 0 // capture BEFORE the switch mutates provisional

	switch {
	case cast < floor:
		// FAILED-QUORUM: apathy must NOT resolve a claim. The disputer forfeits their
		// (escalating) bond — half compensates the answerer, half burns (never to the
		// voters: that would be a self-pay faucet); the answer bond is returned. Only the
		// FIRST failed round defaults the verdict to the answer; a failed REOPEN leaves a
		// standing decided verdict untouched. Every zero transfer is guarded because
		// grc20votes rejects a non-positive move — a reopen legitimately reaches these with
		// a spent answer bond, and an unguarded Transfer(…,0) would brick the resolution.
		db := cs.disputeBond
		half := db / 2
		if half > 0 {
			c.coin.Transfer(c.escrow, cs.answerer, half)
		}
		if rest := db - half; rest > 0 {
			c.coin.Burn(c.escrow, rest)
		}
		if cs.answerBond > 0 {
			c.coin.Transfer(c.escrow, cs.answerer, cs.answerBond)
			cs.answerBond = 0
		}
		if firstResolution {
			cs.provisional = cs.answer
		}
		cs.failedRounds++
		if cs.failedRounds >= maxFailedRounds {
			// Three failed rounds: closed without a decision, at the pre-answer price. A
			// close pays NO fee, so any earmark (a prior undisputed settlement) is VOIDED —
			// leaving it live would let voters claim it on top of a full CloseAt redemption
			// and break solvency.
			cs.provClose = true
			cs.feeKind, cs.feePool, cs.winShares, cs.feeProposalID = feeNone, 0, 0, 0
		}
	case yes > 0 && yes*grc20votes.Bps >= (yes+no)*int64(c.params.disputeThresholdBps):
		// OVERTURN: the disputer was right. Their bond returns, and the answer bond is
		// theirs (first round only — 0 and skipped on a reopen). The verdict flips; a
		// decision clears the failed-round streak and charges the adjudication fee once.
		if cs.disputeBond > 0 {
			c.coin.Transfer(c.escrow, cs.disputer, cs.disputeBond)
		}
		if cs.answerBond > 0 {
			c.coin.Transfer(c.escrow, cs.disputer, cs.answerBond)
			cs.answerBond = 0
		}
		cs.provisional = int8(oppositeOf(int(cs.answer)))
		cs.failedRounds = 0
		chargeAdjFee(c, cs, claimID)
	default:
		// UPHOLD (tie, all-abstain, or a sub-5001 split, all with quorum met): the answer
		// stands, the disputer forfeits their bond to the answerer. A decision clears the
		// streak and charges the fee once.
		if cs.disputeBond > 0 {
			c.coin.Transfer(c.escrow, cs.answerer, cs.disputeBond)
		}
		if cs.answerBond > 0 {
			c.coin.Transfer(c.escrow, cs.answerer, cs.answerBond)
			cs.answerBond = 0
		}
		cs.provisional = cs.answer
		cs.failedRounds = 0
		chargeAdjFee(c, cs, claimID)
	}

	// The escrow clock is set ONCE, at the first resolution, and never recomputed — a
	// reopen does not reset it (§3.6).
	if firstResolution {
		cs.escrowUntil = runtime.ChainHeight() + escrowWindow(c, cs)
	}
	cs.disputeOpen = false
}

// Finalize performs the one irreversible step for a claim that has a provisional
// verdict (from a dispute Resolve OR an undisputed session settlement), once the
// escrow window has passed and no dispute is active: it resolves (or fractionally
// closes) the claim's shares, after which winners can redeem. Deferring this past
// escrow is what lets a reopen overturn a wrong provisional verdict first (the
// reopen path is the next increment; the gate is already here).
func Finalize(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.finalized {
		panic("court: already finalized")
	}
	if cs.disputeOpen {
		panic("court: a dispute is active; cannot finalize")
	}
	if cs.provisional < 0 && !cs.provClose {
		panic("court: no provisional verdict to finalize")
	}
	if runtime.ChainHeight() < cs.escrowUntil {
		panic("court: the escrow window has not passed")
	}

	// The claim is settling. Release its open interest BEFORE locking the shares: the
	// collateral is about to be owed to winners, so it is no longer an active position.
	// Without this the court-wide OI counter only ever ratchets up (RedeemSet drops it,
	// but resolution never did) and the OI ceiling eventually bricks minting on every
	// claim. Refund the opener's deposit too — it is an anti-spam bond, not a fee, and
	// a resolved claim has served its purpose. Both come out of escrow, where the
	// collateral and the deposit have sat untouched since mint/open, so both are solvent.
	if x := claimX(c, claimID); x > 0 {
		if c.oi -= x; c.oi < 0 {
			c.oi = 0
		}
	}
	if cs.deposit > 0 {
		c.coin.Transfer(c.escrow, cs.depositor, cs.deposit)
		cs.deposit = 0
	}

	if cs.provClose {
		c.shares.CloseAt(claimID, int64(cs.preAnswerPrice), priceScale) // 3-round close
	} else {
		c.shares.Resolve(claimID, int(cs.provisional))
	}
	cs.finalized = true
}

// RedeemWinning pays a holder for a RESOLVED claim: priceScale CC per winning share,
// out of escrow. RedeemClosed pays a fractionally-closed claim. Both authenticate the
// actor (cshares trusts the address) and clear the position.
func RedeemWinning(cur realm, courtSlug string, claimID uint64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	won := c.shares.RedeemWinning(claimID, who)
	if won == 0 {
		return 0
	}
	cs := mustClaim(c, claimID)
	var pay int64
	if cs.feePool == 0 {
		pay = won * priceScale // no fee charged (failed-quorum, or no dispute path): full backing
	} else {
		// A fee was skimmed from the winning collateral, so a winning share pays a
		// pro-rata slice of what's left: floor(won · (S·priceScale − feePool) / S). The
		// floor keeps the rounding dust in escrow; winShares is the S frozen at resolution.
		pay = mulDivFloor(won, cs.winShares*priceScale-cs.feePool, cs.winShares)
	}
	if pay > 0 {
		c.coin.Transfer(c.escrow, who, pay)
	}
	return pay
}

func RedeemClosed(cur realm, courtSlug string, claimID uint64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	owed := c.shares.RedeemClosed(claimID, who) // in cshares units (already priced)
	pay := owed * priceScale
	if pay > 0 {
		c.coin.Transfer(c.escrow, who, pay)
	}
	return pay
}

// ----------------------------------------------------------------- innards --

// quorumFloor is the court's absolute turnout bar: max(5%·supply, min(X̄, votable/3)),
// all in CC, at the epoch the governor snapshots. votable nets out the escrow so
// escrowed collateral cannot inflate the denominator. Never zero (ProposeWithQuorum
// requires a positive floor).
func quorumFloor(c *Court, xbar int64) int64 {
	at := c.coin.Epoch() - 1
	supply := c.coin.PastTotal(at)
	votable := supply - c.coin.PastVotes(c.escrow, at)
	if votable < 0 {
		votable = 0
	}
	floor := xbar
	if third := votable / 3; third < floor {
		floor = third
	}
	if fivePct := supply * c.params.floorSupplyBps / grc20votes.Bps; fivePct > floor {
		floor = fivePct
	}
	if floor < 1 {
		floor = 1
	}
	return floor
}

func oppositeOf(outcome int) int {
	if outcome == outcomeYES {
		return outcomeNO
	}
	return outcomeYES
}

// oneDayBlocks is a day at gno's five-second cadence — the unit the escrow window grows in.
const oneDayBlocks = int64(24) * epochBlocks // 24 hourly epochs

// escrowWindow is how long a claim's collateral waits after its provisional verdict
// before Finalize can lock it: clamp(1 week + 1 day per 500 GNOT-equivalent of the
// claim's open interest, 1 week, 3 weeks). A larger claim earns more time to be
// disputed before its money is irreversible. X (the claim's collateral, frozen the
// moment the verdict became provisional) converts to GNOT at the curve's MARGINAL
// price — the same conversion the fee cap uses (§9). Because the market is frozen at
// resolution, X and the price cannot be moved to shorten the window, and the 1-week
// floor bounds any attempt regardless; so an instantaneous read is safe. The division
// is 128-bit (X·price reaches ~1.6e20), and the day count is clamped before it scales
// to blocks, so nothing overflows.
func escrowWindow(c *Court, cs *claimState) int64 {
	x := claimX(c, cs.id) // frozen collateral in CC
	extraDays := mulDivFloor(x, c.crv.Price(c.minted), 500_000_000)
	room := (c.params.escrowMaxBlocks - c.params.escrowMinBlocks) / oneDayBlocks
	if extraDays >= room {
		return c.params.escrowMaxBlocks
	}
	return c.params.escrowMinBlocks + extraDays*oneDayBlocks
}

// ------------------------------------------------------------------ reads --

// DisputeOpen reports whether a claim has an active dispute vote; DisputeProposal is
// its governor proposal id (0 if none). Provisional is the post-resolve verdict
// (outcomeYES/outcomeNO, or -1), and Finalized whether the irreversible step has run.
func DisputeOpen(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).disputeOpen
}

func DisputeProposal(courtSlug string, claimID uint64) int64 {
	return mustClaim(mustCourt(courtSlug), claimID).proposalID
}

func Provisional(courtSlug string, claimID uint64) int {
	return int(mustClaim(mustCourt(courtSlug), claimID).provisional)
}

func Finalized(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).finalized
}

func EscrowUntil(courtSlug string, claimID uint64) int64 {
	return mustClaim(mustCourt(courtSlug), claimID).escrowUntil
}

// FailedRounds is how many dispute rounds have failed quorum on a claim (0..3);
// ProvClose reports whether it is closing without a decision (three failed rounds).
// A page uses these to show the reopen count and the close path.
func FailedRounds(courtSlug string, claimID uint64) int {
	return mustClaim(mustCourt(courtSlug), claimID).failedRounds
}

func ProvClose(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).provClose
}

// DisputeBond is the current (doubled) bond the open or last dispute round posted.
func DisputeBond(courtSlug string, claimID uint64) int64 {
	return mustClaim(mustCourt(courtSlug), claimID).disputeBond
}

// Reopenable reports whether a claim's standing provisional verdict can still be
// disputed again — it has a verdict, is not finalized or closing, and its escrow
// window has not passed. A client gates the "reopen" txlink on this.
func Reopenable(courtSlug string, claimID uint64) bool {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return cs.provisional >= 0 && !cs.finalized && !cs.provClose &&
		runtime.ChainHeight() < cs.escrowUntil
}
