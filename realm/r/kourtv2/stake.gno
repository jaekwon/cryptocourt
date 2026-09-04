// No-loss conviction staking (PLAN §3.1/§3.2). Stake CC on YES or NO; unstake
// freely until an answer freezes the claim; principal always returns 1×. The
// reward weight is CONVICTION: the exact integral ∫ rate(t)·stake·dt, held per
// (staker, side) in 128 bits — rate-weighted (V2-8), so no rate snapshot exists
// anywhere and step-downs cannot be raced. Unstaking FORFEITS the credit the
// withdrawn coin earned, in proportion — you must still be holding when the
// claim is judged to be paid for it. That reverses F9's capital conservation and
// the reason is in Unstake. Principal is untouched: no-loss is a promise about
// principal, and it still holds exactly.

package kourtv2

import (
	"math/bits"
	"math/overflow"
)

// r0WeeklyBps is the frozen external-opportunity estimate (ECONOMICS.md):
// ~13%/yr ≈ 25 bps/week. Part of the published rate rule, never a lever.
const r0WeeklyBps = int64(25)

// stepDownNum/Den approximate 2^(−1/104) ≈ 0.9933575: the per-period budget
// factor of the amortized step-down (no cliff exists to race — 2A-T3).
const (
	stepDownNum = int64(9_933_575)
	stepDownDen = int64(10_000_000)
)

// budgetBpsFPStart is the weekly budget in bps × 1e6 fixed point (38 bps).
const budgetBpsFPStart = budgetWeeklyBps * 1_000_000

// stakePos is one staker's position on one side of one claim.
type stakePos struct {
	stake       int64  // live staked amount
	convHi      uint64 // rate-weighted conviction, u128: Σ stake × ΔrateAcc
	convLo      uint64
	lastRateAcc int64 // the court's era integral at the last settle (audit H1)
	// The RAW integral ∫stake·dt (stake × blocks, u128), freeze-capped — the
	// F9 flash-proof cap base: time-averaged stake = raw / claim-open-blocks.
	// Kept separate from conviction because the cap must not scale with the
	// rate (Q7).
	rawHi, rawLo uint64
	lastRawAt    int64
	bonusPaid    bool // the winner draw is one-shot (openrewards.gno)
}

// rateBpsFP is the current published rate in bps × 1e6 per week:
// rate = 0.85 × y*, y* = 2(r₀ + d_eff)·T_L/T_c with T_L/T_c = 1.5 → 2.55(r₀ + d_eff).
func rateBpsFP(c *Court) int64 {
	return 255 * (r0WeeklyBps*1_000_000 + c.dEffBpsFP) / 100
}

// effectiveRateAcc is the era integral a claim's positions settle against:
// the court's cumulative Σ rate×blocks, capped at the claim's freeze snapshot
// so frozen conviction can never be repriced by later d_eff moves (audit H1).
// Callers must touch(c) first so the integral is current.
func effectiveRateAcc(c *Court, cs *claimState) int64 {
	acc := c.rateAccFP
	if cs.frozenAt != 0 && cs.rateAccAtFreeze < acc {
		acc = cs.rateAccAtFreeze
	}
	return acc
}

// accrue settles a position against the era integral: conv += stake × Δacc,
// where Δacc = Σ rate(t)·dt over exactly the blocks the stake was live — the
// rate-weighted integral by construction (V2-8; no rate snapshot, no
// retroactive repricing). Also feeds the per-side pool conviction (§3.9) and
// the raw ∫stake·dt integral (the Q7 cap base), both freeze-capped.
func accrue(c *Court, cs *claimState, p *stakePos, side int) {
	acc := effectiveRateAcc(c, cs)
	delta := acc - p.lastRateAcc
	p.lastRateAcc = acc
	if delta > 0 && p.stake > 0 {
		// stake < 2^50, Δacc < 2^57 over a century: one 64×64 multiply covers it.
		hi, lo := bits.Mul64(uint64(p.stake), uint64(delta))
		p.convHi, p.convLo = add128(p.convHi, p.convLo, hi, lo)
	}
	rh := rawHeight(cs)
	rawDelta := rh - p.lastRawAt
	p.lastRawAt = rh
	if rawDelta > 0 && p.stake > 0 {
		hi, lo := bits.Mul64(uint64(p.stake), uint64(rawDelta))
		p.rawHi, p.rawLo = add128(p.rawHi, p.rawLo, hi, lo)
	}
	_ = side
}

// advancePools settles the per-side POOL integrals analytically from the side
// totals — sideStake × Δ over exactly the interval since the last mutation,
// during which the total was constant. This makes the pool EXACT at any
// moment (open the rewards's denominator) with no dependence on when individual
// positions settle: Σ position integrals == the side integral by construction.
// MUST run before any yesStake/noStake mutation.
func advancePools(c *Court, cs *claimState) {
	acc := effectiveRateAcc(c, cs)
	rh := rawHeight(cs)
	if d := acc - cs.yesLastAcc; d > 0 && cs.yesStake > 0 {
		hi, lo := bits.Mul64(uint64(cs.yesStake), uint64(d))
		cs.yesConvHi, cs.yesConvLo = add128(cs.yesConvHi, cs.yesConvLo, hi, lo)
	}
	if d := acc - cs.noLastAcc; d > 0 && cs.noStake > 0 {
		hi, lo := bits.Mul64(uint64(cs.noStake), uint64(d))
		cs.noConvHi, cs.noConvLo = add128(cs.noConvHi, cs.noConvLo, hi, lo)
	}
	if d := rh - cs.yesLastRawAt; d > 0 && cs.yesStake > 0 {
		hi, lo := bits.Mul64(uint64(cs.yesStake), uint64(d))
		cs.yesRawHi, cs.yesRawLo = add128(cs.yesRawHi, cs.yesRawLo, hi, lo)
	}
	if d := rh - cs.noLastRawAt; d > 0 && cs.noStake > 0 {
		hi, lo := bits.Mul64(uint64(cs.noStake), uint64(d))
		cs.noRawHi, cs.noRawLo = add128(cs.noRawHi, cs.noRawLo, hi, lo)
	}
	cs.yesLastAcc, cs.noLastAcc = acc, acc
	cs.yesLastRawAt, cs.noLastRawAt = rh, rh
}

// rawHeight is the height the raw integral runs to: now, capped at the freeze
// (stake stopped counting toward the cap base when the answer landed).
func rawHeight(cs *claimState) int64 {
	h := heightNow()
	if cs.frozenAt != 0 && cs.frozenAt < h {
		h = cs.frozenAt
	}
	return h
}

// lifeAvgStake is the claim's LIFETIME time-averaged TOTAL stake:
// (∫yesStake·dt + ∫noStake·dt) / (now − openedAt), read from the raw integrals
// advancePools already keeps — the same integral, over the same denominator,
// that open the rewards's capBonus uses for the F9 flash-proof base. Callers must
// have settled the pools to `now` first. The denominator runs from the claim's
// OPEN, not its first stake, so an idle head only ever lowers it: conservative
// by construction. Unlike the trailing ring, no withdrawal can lower this —
// moving it costs capital × TIME, and past capital-time is immutable.
func lifeAvgStake(cs *claimState, now int64) int64 {
	hi, lo := add128(cs.yesRawHi, cs.yesRawLo, cs.noRawHi, cs.noRawLo)
	den := now - cs.openedAt
	if den < 1 {
		den = 1
	}
	return div128(hi, lo, den)
}

// Stake backs one side of a claim with CC. Free to reverse until the answer.
func Stake(cur realm, courtSlug string, claimID uint64, side int, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	mustSide(side)
	if amount <= 0 {
		panic("kourtv2: stake must be positive")
	}
	if cs.closed {
		panic("kourtv2: this claim is closed")
	}
	if cs.frozenAt != 0 {
		panic("kourtv2: staking is frozen — this claim has an answer")
	}
	// Polish window (§9): staking is closed for stakeOpenDelayBlocks after
	// OpenClaim so the author/moderators can fix wording before anyone bets.
	// Default 0 → no window, behaviour unchanged for courts that don't opt in.
	//
	// THE SAME WINDOW EditClaimTitle READS (claim.gno), converted the same way
	// and deliberately character-identical apart from the polarity: that gate
	// asks whether the window has CLOSED, this one whether it is still OPEN. They
	// must agree on the instant, because it is one window seen from two sides —
	// the title freezes exactly when staking opens. blocksToSecs is what makes
	// them agree, the window being a court parameter denominated in blocks.
	if passed, known := pastDeadline(cs.openedAtTime, blocksToSecs(c.params.stakeOpenDelayBlocks)); (known && !passed) ||
		(!known && heightNow() < cs.openedAt+c.params.stakeOpenDelayBlocks) {
		panic("kourtv2: the polish window is open; staking has not started yet")
	}
	touch(c)

	// A LOCK, not a transfer (lock.gno): the coins stay here and keep voting. So
	// this is the ONE mustSpendable caller that uses the stake-only check — nothing
	// leaves the balance, and a pending vote is no reason to refuse a stake.
	mustStakable(c, who, amount)
	lockStake(c, who, amount)
	advancePools(c, cs)
	p := getPos(c, cs, who, side)
	accrue(c, cs, p, side)
	p.stake = mustAdd(p.stake, amount)
	if side == sideYES {
		cs.yesStake = mustAdd(cs.yesStake, amount)
	} else {
		cs.noStake = mustAdd(cs.noStake, amount)
	}
	observePools(cs)
	recordPools(c, cs)
}

// Unstake withdraws principal from a live claim, and the withdrawn coin gives
// back the conviction it earned. See the block below for the attack that forced
// this and for why the RAW integral is deliberately not touched.
func Unstake(cur realm, courtSlug string, claimID uint64, side int, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	mustSide(side)
	if amount <= 0 {
		panic("kourtv2: unstake must be positive")
	}
	if cs.frozenAt != 0 {
		panic("kourtv2: stakes are frozen — withdraw at settlement (principal is never withheld)")
	}
	touch(c)

	advancePools(c, cs)
	p := getPos(c, cs, who, side)
	if p.stake < amount {
		panic("kourtv2: unstaking more than is staked")
	}
	accrue(c, cs, p, side)
	// WITHDRAWING GIVES BACK THE CREDIT THE WITHDRAWN COIN EARNED.
	//
	// This reverses F9's "unstake keeps conviction", and the reason is an attack
	// answer.gno measured and priced: conviction is stake x time and used to
	// survive a withdrawal, while the answer bond is sized off a THREE-HOUR
	// trailing average of what is staked now. So a mill could bank conviction
	// with a large stake, drain to the floor two hours before answering, and post
	// a bond 224x smaller than the penalty it had earned — ~51 CC against 11,220
	// CC of exposure. What made that unprofitable was the quality lane's slash,
	// which is being removed.
	//
	// Rather than re-pricing the bond, the mismatch is closed at its source: the
	// reward is priced on history and the bond on the present, so history stops
	// counting coin that is no longer present. You must be holding when the claim
	// is judged to earn anything, and holding longer is worth more — which is
	// also the rule a reader would guess.
	//
	// PROPORTIONAL, not all-or-nothing, and that is not politeness. A flag for
	// "did you ever exit" would be a fake fix: stake 1000, unstake 999, keep 1,
	// and an exit flag never fires while the position keeps every unit of credit
	// the 1000 earned. The credit has to follow the coin.
	//
	// NO-LOSS IS UNTOUCHED. Principal comes back 1x exactly as before; what is
	// forfeited is the REWARD the withdrawn coin was accruing. No-loss has always
	// been a promise about principal.
	//
	// CONVICTION ONLY — NOT THE RAW INTEGRAL, and the asymmetry is the design.
	// A pre-existing test names it: X̄frozen is "the drain-resistant lifetime
	// base". The raw integral prices every %-of-X̄ bar in the system — the answer
	// bond, the dispute bond, the quorum floor, the tier reference — and if
	// withdrawing shrank it, draining would make a claim CHEAPER to answer and
	// cheaper to dispute. That is the attack pointing the other way. Scaling it
	// here broke that test on the first pass, which is what the test is for.
	//
	//	conviction  = what the coin EARNED, and it follows the coin
	//	raw integral = what the claim WAS, and history cannot be withdrawn
	//
	// THE SIDE POOL TOO. Position conviction and the side pool advance
	// independently — the pool from cs.yesStake, the position from p.stake — so
	// "the side equals the sum of its positions" only survives if the forfeit
	// comes out of both. Left in the side, the pot would be sized on conviction
	// no position can claim and every honest staker's share diluted by a ghost.
	if amount > 0 && p.stake > 0 {
		keep := p.stake - amount
		// Per-unit first, then rebuild: conviction is stake x (accumulator
		// delta), so dividing by the stake leaves the delta — an int64 quantity
		// well inside div128's guard. Scaling the 128-bit product directly would
		// need a 192-bit intermediate.
		convPer := div128(p.convHi, p.convLo, p.stake)
		nCHi, nCLo := bits.Mul64(uint64(convPer), uint64(keep))
		// The floor of the per-unit divide stays with the POSITION and is never
		// handed to the pool: rounding must not be able to leave the side short.
		dCHi, dCLo := sub128(p.convHi, p.convLo, nCHi, nCLo)
		p.convHi, p.convLo = nCHi, nCLo
		if side == sideYES {
			cs.yesConvHi, cs.yesConvLo = sub128(cs.yesConvHi, cs.yesConvLo, dCHi, dCLo)
		} else {
			cs.noConvHi, cs.noConvLo = sub128(cs.noConvHi, cs.noConvLo, dCHi, dCLo)
		}
	}
	p.stake -= amount
	releaseStake(c, who, amount)
	if side == sideYES {
		cs.yesStake -= amount
	} else {
		cs.noStake -= amount
	}
	observePools(cs)
	recordPools(c, cs)
}

// observePools records both rings at the current height (§3.9).
func observePools(cs *claimState) {
	h := heightNow()
	cs.oi = cs.oi.Observe(h, mustAdd(cs.yesStake, cs.noStake))
	cs.yes = cs.yes.Observe(h, cs.yesStake)
}

// ------------------------------------------------------------------ reads --

// StakeOf is a staker's live principal on one side.
func StakeOf(courtSlug string, claimID uint64, side int, who address) int64 {
	mustSide(side)
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if v := cs.stakers.Get(posKey(who, side)); v != nil {
		return v.(*stakePos).stake
	}
	return 0
}

// ConvictionOf is a staker's accrued rate-weighted conviction on one side,
// settled to now, returned as the CC-unit draw base (conv / (periodBlocks×1e10)
// — the same divisor emission.gno pays with), so clients can preview rewards.
func ConvictionOf(courtSlug string, claimID uint64, side int, who address) int64 {
	mustSide(side)
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	v := cs.stakers.Get(posKey(who, side))
	if v == nil {
		return 0
	}
	return convPreviewCC(cs, v.(*stakePos), ratePreview(c))
}

// ratePreview is the era integral as a READ may see it: the stored value plus the
// un-walked tail at the current rate. Reads must not mutate, so the tail is an
// approximation that resolves exactly at the next touch.
//
// SPLIT OUT so a reader that answers for MANY positions computes it once. It is
// court-level and identical for every position in a walk, and StakedPage hoists it
// out of its loop for exactly that reason.
func ratePreview(c *Court) int64 {
	acc := c.rateAccFP
	if tail := heightNow() - c.lastAccrual; tail > 0 {
		acc = mustAdd(acc, mustMul(rateBpsFP(c), tail))
	}
	return acc
}

// convPreviewCC settles ONE position against that preview and returns the CC-unit draw
// base — the same figure ConvictionOf has always answered, now in one place because two
// readers need it. Duplicating these six lines is the shape openrewards.gno records
// getting caught for: the mutation harness reported four rows as matching TWICE because
// PullSenior and SeniorEntitlement each carried their own copy of one formula.
func convPreviewCC(cs *claimState, p *stakePos, acc int64) int64 {
	if cs.frozenAt != 0 && cs.rateAccAtFreeze < acc {
		acc = cs.rateAccAtFreeze
	}
	hi, lo := p.convHi, p.convLo
	if delta := acc - p.lastRateAcc; delta > 0 && p.stake > 0 {
		mh, ml := bits.Mul64(uint64(p.stake), uint64(delta))
		hi, lo = add128(hi, lo, mh, ml)
	}
	return convToCC(hi, lo)
}

// convToCC converts a conviction accumulator to CC base units:
// conv / (periodBlocks × 10000 × 1e6). Floor division via 128/64.
func convToCC(hi, lo uint64) int64 {
	den := uint64(periodBlocks) * 10_000 * 1_000_000
	if hi >= den {
		panic("kourtv2: conviction exceeds payable range") // unreachable at bounded magnitudes
	}
	q, _ := bits.Div64(hi, lo, den)
	return int64(q)
}

// ----------------------------------------------------------------- innards --

func getPos(c *Court, cs *claimState, who address, side int) *stakePos {
	k := posKey(who, side)
	if v := cs.stakers.Get(k); v != nil {
		return v.(*stakePos)
	}
	p := &stakePos{lastRateAcc: c.rateAccFP, lastRawAt: rawHeight(cs)}
	cs.stakers.Set(k, p)
	// The address-first index, maintained at the one place a position is created.
	// getPos is reached before the guards in Unstake and WithdrawStake, so a
	// non-staker can arrive here — the whole message reverts in that case, which is
	// what keeps the index and cs.stakers in step. See stakeindex.gno.
	indexPosition(c, cs.id, who, side)
	return p
}

func posKey(who address, side int) string {
	if side == sideYES {
		return string(who) + "|y"
	}
	return string(who) + "|n"
}

func mustSide(side int) {
	if side != sideYES && side != sideNO {
		panic("kourtv2: side is 0 (YES) or 1 (NO)")
	}
}

// mustMul is the checked multiply (gno wraps silently — audit C1's class).
func mustMul(a, b int64) int64 {
	m, ok := overflow.Mul64(a, b)
	if !ok {
		panic("kourtv2: multiply overflow")
	}
	return m
}

// mulDiv128 computes a×b/den with a 128-bit intermediate (audit C1: the naive
// uint64 product wraps at real-court magnitudes). Floors; panics if the
// quotient exceeds int64 (unreachable at our bounded inputs).
func mulDiv128(a, b, den int64) int64 {
	if a < 0 || b < 0 || den <= 0 {
		panic("kourtv2: mulDiv128 domain")
	}
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	if hi >= uint64(den) {
		panic("kourtv2: mulDiv128 quotient overflow")
	}
	q, _ := bits.Div64(hi, lo, uint64(den))
	// Honor the contract (math-audit NOTE-6): the hi<den guard only bounds q to
	// uint64; a quotient in (MaxInt64, 2^64) would silently wrap through
	// int64(q). Fail loud instead — unreachable at bounded inputs, but the
	// discipline is fail-loud, never silent-wrong.
	if q > 9223372036854775807 {
		panic("kourtv2: mulDiv128 quotient exceeds int64")
	}
	return int64(q)
}

// mustAdd is the checked add every pool total goes through (gno wraps silently).
func mustAdd(a, b int64) int64 {
	s, ok := overflow.Add64(a, b)
	if !ok {
		panic("kourtv2: amount overflow")
	}
	return s
}

// add128 adds two u128s, panicking on 128-bit overflow (unreachable at our
// bounded magnitudes; checked anyway — the V1 discipline).
// sub128 removes b from a. Underflow is a bug, not a clamp: every caller is
// taking back conviction it can prove was added, so a borrow out of the top word
// means the side accumulator and its positions have already disagreed.
func sub128(aHi, aLo, bHi, bLo uint64) (hi, lo uint64) {
	if aHi < bHi || (aHi == bHi && aLo < bLo) {
		panic("kourtv2: 128-bit conviction underflow")
	}
	lo = aLo - bLo
	hi = aHi - bHi
	if aLo < bLo {
		hi--
	}
	return hi, lo
}

func add128(aHi, aLo, bHi, bLo uint64) (hi, lo uint64) {
	lo = aLo + bLo
	carry := uint64(0)
	if lo < aLo {
		carry = 1
	}
	hi = aHi + bHi + carry
	if hi < aHi || (hi == aHi && carry == 1 && bHi == ^uint64(0)) {
		panic("kourtv2: 128-bit conviction overflow")
	}
	return hi, lo
}

// runtimeHeight exposes the chain height to in-package tests.
