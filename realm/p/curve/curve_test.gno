package curve

import "testing"

const maxSupply = int64(9223372036854775807) / 10000 // grc20votes ceiling

func TestCostIsTheIntegralRoundedUp(t *testing.T) {
	c := New(2, maxSupply) // p(s) = s/2, so Cost(0,delta) = ceil(delta²/4)
	cases := []struct {
		delta, want int64
	}{{0, 0}, {2, 1}, {3, 3}, {4, 4}, {5, 7}}
	for _, k := range cases {
		got, ok := c.Cost(0, k.delta)
		if !ok || got != k.want {
			t.Fatalf("Cost(0,%d) = %d,%v want %d", k.delta, got, ok, k.want)
		}
	}
}

// TestCostRefusedBelowCap exercises Cost's ok=false paths: a cost that overflows int64
// even though the position is well below the cap. Both branches (the 128-bit quotient
// not fitting, and the fitting quotient exceeding int64) were untested, and the code
// relies on them — Minted reads ok=false as "unaffordable", so they are not dead code.
func TestCostRefusedBelowCap(t *testing.T) {
	c := New(1_000_000_000, maxSupply) // the court's exact denom
	for _, delta := range []int64{140_000_000_000_000, 200_000_000_000_000} {
		if delta >= maxSupply {
			t.Fatalf("setup: delta %d must be below the cap %d to prove 'refused below the cap'", delta, maxSupply)
		}
		if got, ok := c.Cost(0, delta); ok {
			t.Fatalf("Cost(0,%d) below the cap should be refused (its cost exceeds int64), got %d,true", delta, got)
		}
	}
}

// TestMintedBackedAtExtremes checks the never-mint-below-backing invariant where the
// existing fuzz does not reach: coin near MaxInt64, a `from` inside the cost-overflow
// region, near the cap, and one-below-cost. Every minted delta's canonical cost must be
// ≤ what was paid, and one more coin must cost strictly more (delta is maximal).
func TestMintedBackedAtExtremes(t *testing.T) {
	c := New(1_000_000_000, maxSupply)
	check := func(from, coin int64) {
		delta, spent := c.Minted(from, coin)
		if delta < 0 || spent < 0 || spent > coin {
			t.Fatalf("Minted(%d,%d)=%d,%d: spent must be in [0,coin]", from, coin, delta, spent)
		}
		if delta == 0 {
			return
		}
		cost, ok := c.Cost(from, delta)
		if !ok || cost != spent || cost > coin {
			t.Fatalf("Minted(%d,%d) minted %d; its Cost is %d,%v (spent %d, coin %d) — must be ≤ coin (no over-issue)", from, coin, delta, cost, ok, spent, coin)
		}
		if cost1, ok1 := c.Cost(from, delta+1); ok1 && cost1 <= coin {
			t.Fatalf("Minted(%d,%d) minted %d but %d was still affordable (cost %d ≤ %d) — not maximal", from, coin, delta, delta+1, cost1, coin)
		}
	}
	check(0, maxInt64)                   // the whole budget from the origin
	check(0, maxInt64-1)                 // one below
	check(100_000_000_000_000, maxInt64) // a `from` inside the cost-overflow region
	check(maxSupply-1, maxInt64)         // one short of the cap (fills to cap, then stops)

	// Paying one below the exact cost of k coins buys strictly fewer than k.
	from, k := int64(50_000_000), int64(1000)
	cost, ok := c.Cost(from, k)
	if !ok {
		t.Fatal("setup: Cost(from,k) should be affordable")
	}
	if delta, _ := c.Minted(from, cost-1); delta >= k {
		t.Fatalf("paying one below Cost(%d,%d)=%d should buy < %d, got %d", from, k, cost, k, delta)
	}
}

func TestCostFromNonZero(t *testing.T) {
	c := New(2, maxSupply)
	// ceil((15²−10²)/4) = ceil(125/4) = 32.
	if got, ok := c.Cost(10, 5); !ok || got != 32 {
		t.Fatalf("Cost(10,5) = %d,%v want 32", got, ok)
	}
}

func TestCostMonotonic(t *testing.T) {
	c := New(7, maxSupply)
	var prev int64
	for d := int64(1); d <= 1000; d++ {
		got, ok := c.Cost(0, d)
		if !ok || got < prev {
			t.Fatalf("Cost not monotonic at delta=%d: %d after %d", d, got, prev)
		}
		prev = got
	}
	// Monotonic in `from` too: the same delta costs more further up the curve.
	a, _ := c.Cost(100, 10)
	b, _ := c.Cost(200, 10)
	if b <= a {
		t.Fatalf("same delta should cost more higher up: Cost(200,10)=%d <= Cost(100,10)=%d", b, a)
	}
}

func TestMintedRoundTripsExactPayment(t *testing.T) {
	c := New(2, maxSupply)
	// Paying exactly Cost(0,delta) buys AT LEAST delta and spends the whole
	// payment. It can buy MORE when the ceil flattens cost near zero
	// (Cost(0,1)==Cost(0,2)==1, so paying 1 buys the maximal 2 — still exactly
	// backed since Cost(0,2)=1). The invariant is: same cost, maximal units.
	for _, delta := range []int64{1, 2, 4, 5, 10, 100, 999} {
		coin, _ := c.Cost(0, delta)
		gotDelta, spent := c.Minted(0, coin)
		if gotDelta < delta {
			t.Fatalf("Minted(0, Cost(0,%d)=%d) bought %d < %d", delta, coin, gotDelta, delta)
		}
		if spent != coin {
			t.Fatalf("exact payment should be fully spent: spent %d of %d", spent, coin)
		}
		if got, _ := c.Cost(0, gotDelta); got != coin {
			t.Fatalf("the %d units bought for %d actually cost %d", gotDelta, coin, got)
		}
	}
}

func TestMintedFloorsAndNeverOverIssues(t *testing.T) {
	c := New(3, maxSupply)
	// The invariant that guarantees the curve never mints below backing:
	//   Cost(from, delta) == spent <= coin  AND  one more coin costs more than coin
	//   (or would pass the cap).
	from := int64(0)
	var lcg uint64 = 0x9e3779b97f4a7c15
	for i := 0; i < 4000; i++ {
		lcg = lcg*6364136223846793005 + 1442695040888963407
		coin := int64(lcg>>16) % 1_000_000_000 // up to ~1e9
		if coin < 0 {
			coin = -coin
		}
		from = int64(lcg>>8) % (maxSupply / 2)
		if from < 0 {
			from = -from
		}
		delta, spent := c.Minted(from, coin)
		if delta == 0 {
			// Then even one coin must cost more than the payment (or we're at cap).
			if from < c.cap {
				one, ok := c.Cost(from, 1)
				if ok && one <= coin {
					t.Fatalf("Minted returned 0 but one coin costs %d <= %d at from=%d", one, coin, from)
				}
			}
			continue
		}
		cst, ok := c.Cost(from, delta)
		if !ok || cst != spent || spent > coin {
			t.Fatalf("over-issue at from=%d coin=%d: delta=%d spent=%d Cost=%d", from, coin, delta, spent, cst)
		}
		// Maximality: one more coin must exceed the payment or the cap.
		if from+delta+1 <= c.cap {
			nxt, ok := c.Cost(from, delta+1)
			if ok && nxt <= coin {
				t.Fatalf("not maximal at from=%d coin=%d: delta+1 costs %d <= %d", from, coin, nxt, coin)
			}
		}
	}
}

func TestLargeValuesStayInside128Bits(t *testing.T) {
	// The reciprocal-slope point: near the supply cap, s² is ~2^100 and must not
	// overflow. A numerator slope would blow past 2^128 here.
	c := New(1_000_000_000, maxSupply)
	from := int64(100_000_000_000_000) // 1e14
	delta := int64(1_000_000_000_000)  // 1e12
	cost, ok := c.Cost(from, delta)
	if !ok || cost <= 0 {
		t.Fatalf("Cost near the cap failed: %d,%v", cost, ok)
	}
	// Round-trips.
	gotDelta, spent := c.Minted(from, cost)
	if gotDelta != delta || spent != cost {
		t.Fatalf("large round-trip: Minted(%d,%d) = %d,%d want %d,%d", from, cost, gotDelta, spent, delta, cost)
	}
}

func TestBackingIsHalfTheMarginalPrice(t *testing.T) {
	c := New(4, maxSupply)
	for _, s := range []int64{0, 8, 40, 4000, 1_000_000} {
		if c.Backing(s) != c.Price(s)/2 {
			t.Fatalf("backing at %d is %d, want half of marginal %d", s, c.Backing(s), c.Price(s))
		}
	}
}

func TestEdges(t *testing.T) {
	c := New(2, 1000)
	if d, s := c.Minted(0, 0); d != 0 || s != 0 {
		t.Fatal("paying 0 buys 0")
	}
	if d, s := c.Minted(1000, 999999); d != 0 || s != 0 {
		t.Fatal("at the cap nothing more can be minted")
	}
	if _, ok := c.Cost(0, 1001); ok {
		t.Fatal("a move past the cap must not be ok")
	}
	if _, ok := c.Cost(-1, 5); ok {
		t.Fatal("a negative position is refused")
	}
}

func TestMintedFillsToCap(t *testing.T) {
	c := New(2, 1000)
	// Paying at least the cost to fill from 0 to the cap buys exactly the cap and
	// spends only that cost (the short-circuit; the extra is the caller's to keep).
	full, _ := c.Cost(0, 1000)
	if delta, spent := c.Minted(0, full+999999); delta != 1000 || spent != full {
		t.Fatalf("overpaying should fill to cap: delta=%d spent=%d want 1000,%d", delta, spent, full)
	}
	// And from a non-zero position.
	full2, _ := c.Cost(400, 600)
	if d2, s2 := c.Minted(400, full2+50); d2 != 600 || s2 != full2 {
		t.Fatalf("fill-to-cap from 400: delta=%d spent=%d want 600,%d", d2, s2, full2)
	}
}

func TestNewValidates(t *testing.T) {
	shouldPanic(t, "d zero", func() { New(0, 100) })
	shouldPanic(t, "d too big", func() { New(maxInt64, 100) })
	shouldPanic(t, "cap zero", func() { New(1, 0) })
	shouldPanic(t, "cap too big", func() { New(1, maxCap+1) })
}

func TestIsqrt128(t *testing.T) {
	// Spot-check the 128-bit root against exact squares and boundaries.
	for _, x := range []uint64{0, 1, 3, 4, 8, 9, 15, 16, 100, 99, 1 << 40} {
		r := isqrt128(0, x)
		if r*r > x || (r+1)*(r+1) <= x {
			t.Fatalf("isqrt(%d) = %d is not the floor root", x, r)
		}
	}
	// A genuine 128-bit input: (2^63)² = 2^126.
	if r := isqrt128(uint64(1)<<62, 0); r != uint64(1)<<63 {
		t.Fatalf("isqrt(2^126) = %d want 2^63", r)
	}
}

func shouldPanic(t *testing.T, name string, fn func()) {
	t.Helper()
	defer func() {
		if recover() == nil {
			t.Fatalf("%s should have panicked", name)
		}
	}()
	fn()
}

// The DOMAIN contract of Cost and Minted, stated for the benefit of a SECOND consumer:
// this is a /p/ package, so the contract has to stand on its own rather than resting on
// kourtv2's call discipline (which only ever passes from >= 0 and coin > 0).
//
// Four guards here survived the harness, and the first reading of that — "defensive
// depth, every rejected input is rejected again downstream, all four are equivalent
// mutations" — was WRONG on the one that mattered, in the way this codebase warns
// about most often. Recorded because the wrong reasoning is the instructive part:
//
//	Cost's domain check  LOAD-BEARING. The argument said a negative span borrows,
//	                     so hi is all ones, so `hi2 >= m` re-rejects it. It does
//	                     not: bits.Add64(lo, m-1, 0) CARRIES, hi+carry wraps back
//	                     to zero, and the overflow guard sees nothing. Cost answers
//	                     (0, TRUE) — a valid quote for a span that runs backwards.
//	                     It survived only because the pairs first written into the
//	                     table below ({10,-1}) are too far from the origin to
//	                     diverge. It is caught now.
//	Minted's domain      Value-equivalent, and NOT a gas nit either: with it gone,
//	                     a negative `from` walks the correction loop s1-from times,
//	                     up to ~9.2e18 divisions. Same answer, no answer in
//	                     practice.
//	Minted's s1 clamp    Unreachable while the domain check stands, with no margin —
//	                     r reaches exactly cap-1. Unreachable is not dead: see the
//	                     note beside it in curve.gno.
//	Minted's zero-delta  Value-equivalent while the two above stand.
//
// So the four are not independently redundant, they are MUTUALLY PROTECTIVE, and only
// the first can be pinned by a test — the others' removal changes no return value on
// its own. That is why the arms below assert results and only the Cost table is
// adversarially chosen; it is also why none of the four should be removed as dead.
func TestCostAndMintedRefuseTheirDomain(t *testing.T) {
	c := New(2, 1_000_000)

	// Cost reports NOT-OK rather than a number for anything outside its domain, so a
	// caller that ignores `ok` cannot silently price a nonsense span.
	for _, k := range []struct{ from, delta int64 }{
		// Only the first three of these DISCRIMINATE — measured, with the guard
		// deleted, on this exact curve. The rest are contract documentation, and
		// saying which is which is the point: a table of pairs that are merely
		// obviously invalid proves nothing, because the invalid ones are refused
		// downstream anyway.
		//
		// {1,-1}, {2,-1} — a negative span, answered (0, TRUE). The 128-bit
		//   subtract borrows so hi is all ones, but bits.Add64(lo, m-1, 0) CARRIES
		//   and hi+carry WRAPS BACK TO ZERO, so the `hi2 >= m` overflow guard never
		//   fires. That is a free rewind of the curve position reported as a valid
		//   quote — the "walking it backward would let the same region be bought
		//   twice" failure this package's doc names. Needs from² − s1² ≤ 2d−1, so on
		//   this d=2 curve only a span ending near the origin exposes it.
		// {-631917,1} — the worse family: a FABRICATED PRICE. uint64() of a
		//   negative from injects a 2^65·|from| term, and both magnitude checks
		//   (`hi2 >= m`, and the quotient against MaxInt64) bound SIZE, not domain,
		//   so for |from| < d they pass and a price comes back. Deleting the guard
		//   quotes this span at 9223372036854459850 with ok=true.
		// {-1,10}, {-1,-1}, {cap+1,1} — refused either way. {-1,10} in particular
		//   only just misses: it exits on the quotient check by a margin of 21, so
		//   it is not protection, it is a coincidence of d=2. Do not let it stand in
		//   for the negative-from case; that is what {-631917,1} is for.
		{1, -1}, {2, -1}, {-631917, 1}, {-1, 10}, {10, -1}, {-1, -1}, {c.Cap() + 1, 1},
	} {
		if got, ok := c.Cost(k.from, k.delta); ok || got != 0 {
			t.Fatalf("Cost(%d,%d) must be refused: got %d,%v", k.from, k.delta, got, ok)
		}
	}
	// A span that ENDS past the cap is refused too — the curve is finite, and a
	// partially-fillable span must not be priced as if it fitted.
	if got, ok := c.Cost(c.Cap()-1, 5); ok || got != 0 {
		t.Fatalf("a span ending past the cap must be refused: got %d,%v", got, ok)
	}
	// The boundary itself is priced: ending exactly AT the cap is legal.
	if _, ok := c.Cost(c.Cap()-1, 1); !ok {
		t.Fatal("a span ending exactly at the cap must be priced")
	}

	// Minted returns (0,0) — never a mint, never a charge — outside its domain.
	for _, k := range []struct{ from, coin int64 }{
		{-1, 100}, {c.Cap(), 100}, {c.Cap() + 1, 100}, {0, 0}, {0, -1},
	} {
		if d, sp := c.Minted(k.from, k.coin); d != 0 || sp != 0 {
			t.Fatalf("Minted(%d,%d) must mint and charge nothing: got %d,%d",
				k.from, k.coin, d, sp)
		}
	}

	// A payment larger than the whole remaining curve mints exactly to the cap and
	// charges exactly that, never past it — this is the clamp the harness found
	// unpinned, and without it the correction loop sees an over-cap span.
	full, ok := c.Cost(0, c.Cap())
	if !ok {
		t.Fatal("setup: filling the whole curve must be priceable")
	}
	d, sp := c.Minted(0, full*2)
	if d != c.Cap() {
		t.Fatalf("an over-large payment mints exactly to the cap: got %d want %d", d, c.Cap())
	}
	if sp != full {
		t.Fatalf("and is charged only the cost of the cap: got %d want %d", sp, full)
	}
	// At the cap there is nothing left to mint, at any price.
	if d, sp := c.Minted(c.Cap(), full); d != 0 || sp != 0 {
		t.Fatalf("a filled curve mints nothing: got %d,%d", d, sp)
	}
}
