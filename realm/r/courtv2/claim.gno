// Claims: an immutable statement of fact, a refundable deposit, a conditionally
// refundable fee, and two stake pools. No shares exist — see stake.gno.
package courtv2

import (
	"chain/runtime"

	bptree "gno.land/p/nt/bptree/v0"
	twap "gno.land/p/cryptocourt/twap/v0"
)

// Sides of a claim. A side is an int in the API for gnokey ergonomics.
const (
	sideYES = 0
	sideNO  = 1
)

const twapBuckets = 168 // a week of hourly buckets, as V1

// claimState is one claim. Fields group by lifecycle; answer/dispute/quality
// fields are added by their modules as they land (fresh code, no live state).
type claimState struct {
	id     uint64
	title  string
	author address

	deposit int64 // refundable anti-spam deposit (escrowed)
	fee     int64 // 10% of deposit: burned on dead/conclusive-low, else refunded
	openedAt int64
	closed   bool // dead-claim close (unanswered past the timeout)

	// The two stake pools and their staker records (stake.gno).
	yesStake, noStake int64
	stakers           *bptree.BPTree // addr|side -> *stakePos
	// Per-side lifetime conviction (rate-weighted, u128) — the reward
	// denominators and the manipulation-resistant lifetime ratio (§3.9).
	yesConvHi, yesConvLo uint64
	noConvHi, noConvLo   uint64

	// The trailing rings (§3.9): total staked (answerability X̄) and the YES
	// pool (the ratio series). Observed on every stake/unstake.
	oi  twap.Ring // total stake, hourly, one week
	yes twap.Ring // YES pool, hourly, one week

	// Answer-freeze markers (answer.gno sets them; stake/unstake refuse after).
	// rateAccAtFreeze pins the era integral at the freeze height so frozen
	// conviction can never be repriced by later d_eff moves (audit H1).
	frozenAt        int64 // 0 = live
	rateAccAtFreeze int64
	xBarFrozen      int64 // P6: the trailing-X̄ snapshot at the answer

	// The answer (answer.gno). answerBond is the LIVE escrowed remainder
	// (zeroed as disposed, exactly once); answerBond0 is the posted magnitude —
	// the anchor the dispute-bond and comp formulas read across rounds.
	answer       int8 // sideYES/sideNO once frozenAt != 0
	answerer     address
	answerBond   int64
	answerBond0  int64
	answerHeight int64

	// VERDICT_FINAL (P4): set by SettleUndisputed, Finalize, or provClose.
	verdictAt int64  // 0 = no verdict yet
	route     string // "undisputed" | "vote" | "closed"
	// Quality (quality.gno finalizes; mid is the undisputed default).
	tier      int64
	tierFinal bool
	// The dispute machine (dispute.gno). provisional is the standing verdict
	// between a decided round and Finalize (-1 = none); escrowUntil is the
	// reopen window's end, set once at the first resolution.
	disputeOpen   bool
	round         int64
	failedRounds  int64
	decidedRounds int64
	disputer     address
	disputeBond  int64
	proposalID   int64
	provisional  int8
	escrowUntil  int64
	provClose    bool
}

// OpenClaim posts a claim. The opener escrows deposit + fee; the fee's
// disposition is decided at resolution (refund unless dead or conclusive low).
func OpenClaim(cur realm, courtSlug, title string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	if len(title) == 0 || len(title) > 200 {
		panic("courtv2: a claim title is 1..200 characters")
	}
	dep := c.params.minClaimDepositCC
	fee := dep * depositFeeBps / 10000
	c.coin.Transfer(who, c.escrow, dep+fee)
	c.deposit += dep + fee

	c.nextID++
	id := c.nextID
	cs := &claimState{
		id:          id,
		title:       title,
		author:      who,
		deposit:     dep,
		fee:         fee,
		openedAt:    runtime.ChainHeight(),
		stakers:     bptree.NewBPTree32(),
		oi:          twap.New(epochBlocks, twapBuckets, 8),
		yes:         twap.New(epochBlocks, twapBuckets, 8),
		provisional: -1, // int8 zero is sideYES — the sentinel must be explicit
	}
	c.claims.Set(beClaimKey(id), cs)
	return id
}

// CloseDeadClaim closes a claim that never got an answer within the timeout:
// the deposit refunds to the author, the fee burns (the dead-claim spam price),
// and new stakes are refused. Existing stakes were never locked (no freeze
// happened) and remain withdrawable through Unstake. Permissionless.
func CloseDeadClaim(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.closed {
		panic("courtv2: already closed")
	}
	if cs.frozenAt != 0 {
		panic("courtv2: this claim has an answer; it settles, it does not die")
	}
	if runtime.ChainHeight() < cs.openedAt+deadClaimTimeout {
		panic("courtv2: the dead-claim timeout has not passed")
	}
	cs.closed = true
	// Exactly-once dispositions: refund the deposit, burn the fee.
	if cs.deposit > 0 {
		c.coin.Transfer(c.escrow, cs.author, cs.deposit)
		c.deposit -= cs.deposit
		cs.deposit = 0
	}
	if cs.fee > 0 {
		c.coin.Burn(c.escrow, cs.fee)
		c.deposit -= cs.fee
		cs.fee = 0
	}
}

// ------------------------------------------------------------------ reads --

func ClaimCount(courtSlug string) uint64 { return mustCourt(courtSlug).nextID }
func ClaimTitle(courtSlug string, claimID uint64) string {
	return mustClaim(mustCourt(courtSlug), claimID).title
}
func ClaimAuthor(courtSlug string, claimID uint64) address {
	return mustClaim(mustCourt(courtSlug), claimID).author
}
func ClaimClosed(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).closed
}

// StakePools returns the two live pool totals — the instantaneous ratio's
// numerator and denominator.
func StakePools(courtSlug string, claimID uint64) (yes, no int64) {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return cs.yesStake, cs.noStake
}

// TrailingOI is the flash-resistant trailing average of total stake (X̄).
func TrailingOI(courtSlug string, claimID uint64, window int64) (avg int64, mature bool) {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return cs.oi.Average(runtime.ChainHeight(), window)
}

func mustClaim(c *Court, id uint64) *claimState {
	v := c.claims.Get(beClaimKey(id))
	if v == nil {
		panic("courtv2: no such claim")
	}
	return v.(*claimState)
}

// beClaimKey is big-endian so claim ids iterate in order.
func beClaimKey(id uint64) string {
	b := [8]byte{
		byte(id >> 56), byte(id >> 48), byte(id >> 40), byte(id >> 32),
		byte(id >> 24), byte(id >> 16), byte(id >> 8), byte(id),
	}
	return string(b[:])
}
