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
