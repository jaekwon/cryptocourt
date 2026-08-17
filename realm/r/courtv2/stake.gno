// No-loss conviction staking (PLAN §3.1/§3.2). Stake CC on YES or NO; unstake
// freely until an answer freezes the claim; principal always returns 1×. The
// reward weight is CONVICTION: the exact integral ∫ rate(t)·stake·dt, held per
// (staker, side) in 128 bits — rate-weighted (V2-8), so no rate snapshot exists
// anywhere and step-downs cannot be raced; capital-conserving (unstake stops
// accrual, history is kept, restake resumes, nothing resets — F9).
package courtv2

import (
	"chain/runtime"
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
	bonusPaid    bool // the winner draw is one-shot (crystallize.gno)
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
// moment (crystallize's denominator) with no dependence on when individual
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
	h := runtime.ChainHeight()
	if cs.frozenAt != 0 && cs.frozenAt < h {
		h = cs.frozenAt
	}
	return h
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
		panic("courtv2: stake must be positive")
	}
	if cs.closed {
		panic("courtv2: this claim is closed")
	}
	if cs.frozenAt != 0 {
		panic("courtv2: staking is frozen — this claim has an answer")
	}
	// Polish window (§9): staking is closed for stakeOpenDelayBlocks after
	// OpenClaim so the author/moderators can fix wording before anyone bets.
	// Default 0 → no window, behaviour unchanged for courts that don't opt in.
	if runtime.ChainHeight() < cs.openedAt+c.params.stakeOpenDelayBlocks {
		panic("courtv2: the polish window is open; staking has not started yet")
	}
	touch(c)

	c.coin.Transfer(who, c.escrow, amount)
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
}

// Unstake withdraws principal from a live claim. Accrued conviction is kept —
// capital conservation makes the integral game-proof (F9) — but the removed
// portion stops earning.
func Unstake(cur realm, courtSlug string, claimID uint64, side int, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	mustSide(side)
	if amount <= 0 {
		panic("courtv2: unstake must be positive")
	}
	if cs.frozenAt != 0 {
		panic("courtv2: stakes are frozen — withdraw at settlement (principal is never withheld)")
	}
	touch(c)

	advancePools(c, cs)
	p := getPos(c, cs, who, side)
	if p.stake < amount {
		panic("courtv2: unstaking more than is staked")
	}
	accrue(c, cs, p, side)
	p.stake -= amount
	if side == sideYES {
		cs.yesStake -= amount
	} else {
		cs.noStake -= amount
	}
	c.coin.Transfer(c.escrow, who, amount)
	observePools(cs)
}

// observePools records both rings at the current height (§3.9).
func observePools(cs *claimState) {
	h := runtime.ChainHeight()
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
	p := v.(*stakePos)
	// A transient copy settled against a PREVIEW of the era integral: the
	// stored integral plus the un-walked tail at the current rate (reads must
	// not mutate; the tail approximation resolves exactly at the next touch).
	acc := c.rateAccFP
	if tail := runtime.ChainHeight() - c.lastAccrual; tail > 0 {
		acc = mustAdd(acc, mustMul(rateBpsFP(c), tail))
	}
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
		panic("courtv2: conviction exceeds payable range") // unreachable at bounded magnitudes
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
		panic("courtv2: side is 0 (YES) or 1 (NO)")
	}
}

// mustMul is the checked multiply (gno wraps silently — audit C1's class).
func mustMul(a, b int64) int64 {
	m, ok := overflow.Mul64(a, b)
	if !ok {
		panic("courtv2: multiply overflow")
	}
	return m
}

// mulDiv128 computes a×b/den with a 128-bit intermediate (audit C1: the naive
// uint64 product wraps at real-court magnitudes). Floors; panics if the
// quotient exceeds int64 (unreachable at our bounded inputs).
func mulDiv128(a, b, den int64) int64 {
	if a < 0 || b < 0 || den <= 0 {
		panic("courtv2: mulDiv128 domain")
	}
	hi, lo := bits.Mul64(uint64(a), uint64(b))
	if hi >= uint64(den) {
		panic("courtv2: mulDiv128 quotient overflow")
	}
	q, _ := bits.Div64(hi, lo, uint64(den))
	// Honor the contract (math-audit NOTE-6): the hi<den guard only bounds q to
	// uint64; a quotient in (MaxInt64, 2^64) would silently wrap through
	// int64(q). Fail loud instead — unreachable at bounded inputs, but the
	// discipline is fail-loud, never silent-wrong.
	if q > 9223372036854775807 {
		panic("courtv2: mulDiv128 quotient exceeds int64")
	}
	return int64(q)
}

// mustAdd is the checked add every pool total goes through (gno wraps silently).
func mustAdd(a, b int64) int64 {
	s, ok := overflow.Add64(a, b)
	if !ok {
		panic("courtv2: amount overflow")
	}
	return s
}

// add128 adds two u128s, panicking on 128-bit overflow (unreachable at our
// bounded magnitudes; checked anyway — the V1 discipline).
func add128(aHi, aLo, bHi, bLo uint64) (hi, lo uint64) {
	lo = aLo + bLo
	carry := uint64(0)
	if lo < aLo {
		carry = 1
	}
	hi = aHi + bHi + carry
	if hi < aHi || (hi == aHi && carry == 1 && bHi == ^uint64(0)) {
		panic("courtv2: 128-bit conviction overflow")
	}
	return hi, lo
}

// runtimeHeight exposes the chain height to in-package tests.
func runtimeHeight() int64 { return runtime.ChainHeight() }
