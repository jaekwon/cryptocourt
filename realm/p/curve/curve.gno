// Package curve is a linear, one-way bonding curve for issuing a token against a
// reserve: price rises linearly with the position on the curve, and the cost of
// minting is the exact integral, computed in 128-bit so it never overflows and
// never issues a coin for less than its backing.
//
// # Why a reciprocal slope
//
// The marginal price is p(s) = s/D — a RECIPROCAL denominator D, not a numerator
// slope. That is not cosmetic. The cost of moving from s0 to s1 is the integral
// (s1²−s0²)/(2D). With a numerator slope k the product k·(s1²−s0²) can exceed
// 2^128 for a realistic k at a large supply, and the single 128-bit multiply
// overflows. As 1/D the numerator is only s1²−s0², at most cap² which for a cap
// near 9.2e14 is about 2^100 — always inside 128 bits — and D sits safely in the
// divisor. D is chosen from economics: larger D is a gentler curve.
//
// # No coin is ever minted below its backing
//
// Two rounding rules, and one belt-and-suspenders check, guarantee it:
//
//   - Cost rounds UP. The buyer pays at least the integral, so backing (the sum
//     of integrals) never exceeds treasury (the sum charged).
//   - Minted rounds DOWN. It floors the number of coins a payment buys — but it
//     does not trust the square root. It uses isqrt only for a CANDIDATE, then
//     corrects ±1 against the canonical Cost, so an off-by-one in the root can
//     never over-issue. This re-check is mandatory, not optional.
//
// # A value, not an object
//
// A Curve is immutable configuration (the slope denominator and the position
// cap); it holds no mutable state and is never a heap object. The CURVE POSITION
// — how far up the curve issuance has walked — lives in the consuming realm as a
// monotonic counter it passes in as `from`. Burning or redeeming the token must
// NOT move that counter back: the curve prices the next mint off total-ever-
// minted, and walking it backward would let the same region be bought twice.
package curve

import (
	"math/bits"
	"math/overflow"
)

const maxInt64 = int64(9223372036854775807)

// maxCap bounds the position cap so cap² ≤ 2^100 and every 128-bit operand here
// stays well inside 2^126 (where isqrt128's search bound is exact). 2^50 ≈ 1.1e15
// comfortably covers a token's ~9.2e14 supply ceiling.
const maxCap = int64(1) << 50

// Curve is a linear one-way bonding curve. Build it with New.
type Curve struct {
	d   int64 // reciprocal slope: marginal price p(s) = s/d
	cap int64 // the highest position issuance may reach
}

// New builds a curve with reciprocal slope d and position cap. A larger d is a
// gentler price rise. cap bounds the position so cap² stays inside 128 bits and
// the token's own supply ceiling is respected.
func New(d, cap int64) Curve {
	if d < 1 || d > maxInt64/2 {
		panic("curve: d must be in [1, MaxInt64/2] so 2d does not overflow")
	}
	if cap < 1 || cap > maxCap {
		panic("curve: cap must be in [1, 2^50]")
	}
	return Curve{d: d, cap: cap}
}

// D and Cap expose the construction parameters.
func (c Curve) D() int64   { return c.d }
func (c Curve) Cap() int64 { return c.cap }

// Cost is the coin a buyer must pay to move the position from `from` to
// `from+delta`, the integral of the price over that span, ROUNDED UP. ok is false
// when the move would pass the cap or the cost would not fit in an int64 (only at
// absurd positions). Minting zero costs zero.
func (c Curve) Cost(from, delta int64) (coin int64, ok bool) {
	if from < 0 || delta < 0 || from > c.cap {
		return 0, false
	}
	s1, add := overflow.Add64(from, delta)
	if !add || s1 > c.cap {
		return 0, false
	}
	// diff = s1² − s0², an exact 128-bit value (s1 ≥ s0 so it never borrows past 0).
	sh1, sl1 := bits.Mul64(uint64(s1), uint64(s1))
	sh0, sl0 := bits.Mul64(uint64(from), uint64(from))
	lo, borrow := bits.Sub64(sl1, sl0, 0)
	hi, _ := bits.Sub64(sh1, sh0, borrow)

	m := uint64(2 * c.d)
	// Ceil-divide the 128-bit diff by m: (diff + m − 1) / m.
	lo2, carry := bits.Add64(lo, m-1, 0)
	hi2 := hi + carry
	if hi2 >= m {
		// The quotient would not fit int64 (and bits.Div64 REQUIRES hi < m). This IS
		// reachable well below the position cap — for the court's d=1e9 it fires around
		// s1≈1.9e14, far under cap≈9.2e14 — but only at positions whose fill cost exceeds
		// MaxInt64 µGNOT, i.e. more GNOT than can exist, so no funded Buy reaches it.
		// Do NOT delete this as "dead": Minted relies on ok=false meaning "unaffordable",
		// and without the guard bits.Div64 would violate its hi<m precondition (over-issue).
		return 0, false
	}
	q, _ := bits.Div64(hi2, lo2, m)
	if q > uint64(maxInt64) {
		// Same story one step later: the cost is a valid 128-bit value but exceeds int64,
		// so it is unaffordable (MaxInt64 µGNOT is more than the whole supply's worth).
		return 0, false
	}
	return int64(q), true
}

// Minted is the largest whole number of coins `coin` can buy starting at position
// `from`, and the coin actually spent on them (≤ coin; the caller keeps or refunds
// the remainder). It floors: it finds a candidate with a 128-bit integer square
// root, then corrects ±1 against the canonical Cost, so issued coin is never worth
// more than what was paid, and it is zero when even one coin costs more than
// `coin`.
func (c Curve) Minted(from, coin int64) (delta, spent int64) {
	if from < 0 || from >= c.cap || coin <= 0 {
		return 0, 0
	}
	// Short-circuit a payment large enough to buy the whole remaining curve. This
	// bounds the isqrt operand below to at most cap² (so isqrt128's search bound is
	// exact) and handles the huge-coin case explicitly instead of relying on the
	// later cap clamp. When filling to the cap costs more than an int64 can hold
	// (a very steep curve), full is !ok and coin (≤ MaxInt64) is necessarily below
	// it, so we fall through — and then s1 < cap keeps the operand under cap² too.
	if full, ok := c.Cost(from, c.cap-from); ok && coin >= full {
		return c.cap - from, full
	}
	// operand = from² + 2·d·coin, a 128-bit value; s1 = floor(sqrt(operand)).
	fh, fl := bits.Mul64(uint64(from), uint64(from))
	ph, pl := bits.Mul64(uint64(2*c.d), uint64(coin))
	lo, carry := bits.Add64(fl, pl, 0)
	hi := fh + ph + carry
	r := isqrt128(hi, lo)

	// UNREACHABLE AND LOAD-BEARING, which is not a contradiction — the same standing
	// as the hi2 >= m guard above, and it is worth being explicit because no test can
	// pin it. Nothing reaches it while the domain check at the top of this function
	// stands: on fall-through coin < full, so the operand is at most cap²−1 and r is
	// at most cap−1. There is NO margin in that bound (r does reach exactly cap−1), and
	// the clamp is the second line, not a redundant one. Delete BOTH and, on a curve
	// New will happily build, Minted(1, -1) returns 9223372036854775807 units for a
	// spend of 0 — measured, not argued: uint64(-1) makes the operand exceed isqrt128's
	// exact range, r comes back as its search bound 2^63, int64(r) is MinInt64, and
	// s1 - from WRAPS to MaxInt64, which the delta <= 0 exit below then waves through
	// as a positive mint.
	var s1 int64
	if r > uint64(c.cap) {
		s1 = c.cap // clamp before the correction so Cost never sees an over-cap span
	} else {
		s1 = int64(r)
	}

	// Step DOWN while the rounded-up cost of reaching s1 exceeds the payment.
	for s1 > from {
		cst, ok := c.Cost(from, s1-from)
		if ok && cst <= coin {
			break
		}
		s1--
	}
	// Step UP while one more coin still fits (and stays under the cap).
	for s1 < c.cap {
		cst, ok := c.Cost(from, s1+1-from)
		if !ok || cst > coin {
			break
		}
		s1++
	}
	delta = s1 - from
	if delta <= 0 {
		return 0, 0
	}
	spent, _ = c.Cost(from, delta) // round-up cost of exactly what was minted
	return delta, spent
}

// Price is the marginal price at position s (coin per unit), floor(s/d). Backing
// is the reserve behind one unit at position s, exactly half the marginal price —
// the reason every buyer pays about twice the backing of the coin they buy.
func (c Curve) Price(s int64) int64   { return s / c.d }
func (c Curve) Backing(s int64) int64 { return s / (2 * c.d) }

// isqrt128 returns floor(sqrt(x)) for the 128-bit unsigned value x = hi:lo, by
// binary search on the ≤64-bit result — each step squares a candidate with a
// 128-bit multiply and compares. Division-free and deterministic.
func isqrt128(hi, lo uint64) uint64 {
	var ans, lo_ uint64
	hi_ := uint64(1) << 63 // search bound: covers every result up to sqrt(2^126)=2^63 (our operands stay < 2^100)
	for lo_ <= hi_ {
		mid := lo_ + (hi_-lo_)/2
		mh, ml := bits.Mul64(mid, mid)
		if mh < hi || (mh == hi && ml <= lo) { // mid² ≤ x
			ans = mid
			if mid == ^uint64(0) {
				break
			}
			lo_ = mid + 1
		} else {
			if mid == 0 {
				break
			}
			hi_ = mid - 1
		}
	}
	return ans
}
