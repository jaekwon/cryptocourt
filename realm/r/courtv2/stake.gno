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
	stake      int64  // live staked amount
	convHi     uint64 // rate-weighted conviction, u128:
	convLo     uint64 //   Σ stake × Δblocks × rateBpsFP  (bps × 1e6)
	lastUpdate int64  // height of the last accrual
}

// rateBpsFP is the current published rate in bps × 1e6 per week:
// rate = 0.85 × y*, y* = 2(r₀ + d_eff)·T_L/T_c with T_L/T_c = 1.5 → 2.55(r₀ + d_eff).
func rateBpsFP(c *Court) int64 {
	return 255 * (r0WeeklyBps*1_000_000 + c.dEffBpsFP) / 100
}

// accrue settles a position's conviction up to now at the current rate:
// conv += stake × Δblocks × rateBpsFP, in u128. Also feeds the per-side pool
// conviction so lifetime ratios and reward denominators exist for free (§3.9).
func accrue(c *Court, cs *claimState, p *stakePos, side int) {
	now := runtime.ChainHeight()
	if cs.frozenAt != 0 && now > cs.frozenAt {
		now = cs.frozenAt // accrual stops at the freeze, exactly
	}
	dt := now - p.lastUpdate
	p.lastUpdate = now
	if dt <= 0 || p.stake == 0 {
		return
	}
	// stake × dt fits u128 via one 64×64 multiply; × rateFP via a second.
	hi1, lo1 := bits.Mul64(uint64(p.stake), uint64(dt))
	// (hi1:lo1) × rateFP — rateFP < 2^38, hi1 < 2^17 at our magnitudes, so the
	// high product fits; checked anyway.
	r := uint64(rateBpsFP(c))
	hiA, loA := bits.Mul64(lo1, r)
	hiB, loB := bits.Mul64(hi1, r)
	if hiB != 0 {
		panic("courtv2: conviction accrual overflowed 128 bits")
	}
	hiA += loB
	if hiA < loB {
		panic("courtv2: conviction accrual overflowed 128 bits")
	}
	p.convHi, p.convLo = add128(p.convHi, p.convLo, hiA, loA)
	if side == sideYES {
		cs.yesConvHi, cs.yesConvLo = add128(cs.yesConvHi, cs.yesConvLo, hiA, loA)
	} else {
		cs.noConvHi, cs.noConvLo = add128(cs.noConvHi, cs.noConvLo, hiA, loA)
	}
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
	touch(c)

	c.coin.Transfer(who, c.escrow, amount)
	p := getPos(cs, who, side)
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

	p := getPos(cs, who, side)
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
	// A transient copy: settle without writing (reads must not mutate).
	tmp := *p
	accrueRead(c, cs, &tmp)
	return convToCC(tmp.convHi, tmp.convLo)
}

// accrueRead mirrors accrue without touching pool totals or storage.
func accrueRead(c *Court, cs *claimState, p *stakePos) {
	now := runtime.ChainHeight()
	if cs.frozenAt != 0 && now > cs.frozenAt {
		now = cs.frozenAt
	}
	dt := now - p.lastUpdate
	if dt <= 0 || p.stake == 0 {
		return
	}
	hi1, lo1 := bits.Mul64(uint64(p.stake), uint64(dt))
	r := uint64(rateBpsFP(c))
	hiA, loA := bits.Mul64(lo1, r)
	_, loB := bits.Mul64(hi1, r)
	hiA += loB
	p.convHi, p.convLo = add128(p.convHi, p.convLo, hiA, loA)
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

func getPos(cs *claimState, who address, side int) *stakePos {
	k := posKey(who, side)
	if v := cs.stakers.Get(k); v != nil {
		return v.(*stakePos)
	}
	p := &stakePos{lastUpdate: runtime.ChainHeight()}
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
