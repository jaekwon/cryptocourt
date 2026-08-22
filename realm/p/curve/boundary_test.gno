package curve

import "testing"

// THE CURVE IS THE ARITHMETIC EVERY GNOT↔CC CONVERSION GOES THROUGH, and it carried 5
// mutation rows against ~200 lines of exact 128-bit work. A sweep of its comparisons
// caught three (reaching exactly the cap, the round-UP price, charging for what was
// minted) and left five. These pin the three of those five that are reachable with
// legitimate curve parameters; the other two are recorded in KNOWN-GAPS with their
// derivations.

// COST'S RANGE ENDS AT THE CAP, INCLUSIVELY. The guard is `from > c.cap`, so a start
// position AT the cap is a legal question with an empty answer — the cost of nothing is
// nothing, and `ok` is true. Narrowing it to `>=` makes that question a REFUSAL instead,
// which a caller branching on ok reads as "this curve cannot be priced here".
//
// Nothing exercised it because the realm never asks: Minted returns early on `from >=
// cap`, so its own Cost calls always start below. This is a library boundary, and the
// library is where the contract has to hold.
func TestCostPricesAnEmptySpanAtTheCap(t *testing.T) {
	c := New(1000, 10_000)
	if got, ok := c.Cost(c.Cap(), 0); !ok || got != 0 {
		t.Fatalf("an empty span at the cap costs nothing and is legal: got %d, ok=%v",
			got, ok)
	}
	// One unit PAST the cap is where the refusal belongs.
	if _, ok := c.Cost(c.Cap(), 1); ok {
		t.Fatal("a span that ends past the cap must be refused")
	}
	// And a start beyond the cap is refused outright.
	if _, ok := c.Cost(c.Cap()+1, 0); ok {
		t.Fatal("a start position past the cap must be refused")
	}
}

// THE OVERFLOW GUARD REFUSES RATHER THAN PANICS. Cost divides a 128-bit numerator by
// m = 2d with bits.Div64, which PANICS when the high word is at least the divisor — so
// `hi2 >= m` is the difference between an honest (0, false) and an abort. Narrowing it to
// `>` leaves exactly the hi2 == m case falling into Div64.
//
// WHAT I GOT WRONG FIRST, because it says what this test can and cannot claim. I modelled
// the boundary in python, found hi2 == m at a 20,000-unit span for d = 1 and cap = 2^50,
// and wrote a "just inside" assertion at 16,384 expecting it to be PRICED. It is refused
// too — by the SECOND guard, `q > maxInt64`, which my model did not have. Working it
// through: hi2 >= m means the numerator is about m·2^64, so q is about 2^64 and the int64
// ceiling would refuse it anyway. The two guards overlap, and the hi2 one exists only to
// stop Div64 panicking BEFORE the q check can be reached. So this test cannot show a
// priced span next to a refused one at that boundary — it shows that the boundary span is
// REFUSED rather than dividing, with a small span on the same curve priced to prove the
// curve is not simply refusing everything.
func TestCostRefusesTheOverflowBoundaryRatherThanDividing(t *testing.T) {
	// `cap` is a builtin and gno refuses to shadow it, so the ceiling is spelled out.
	const top = int64(1) << 50
	c := New(1, top)

	// The curve prices ordinary spans, so a refusal below is about the span and not the
	// curve.
	if _, ok := c.Cost(0, 1); !ok {
		t.Fatal("setup: this curve must price a one-unit span at the origin")
	}
	// ON the boundary, hi2 == m: refused, not divided. With the guard narrowed to `>`
	// this call reaches bits.Div64 with hi >= y and aborts.
	if _, ok := c.Cost(top-20000, 20000); ok {
		t.Fatal("a numerator whose high word reaches 2d must be refused, not divided")
	}
	// Past it: still refused.
	if _, ok := c.Cost(top-32768, 32768); ok {
		t.Fatal("and past the boundary too")
	}
}

// MINTED GIVES THE MOST A PAYMENT CAN BUY, AND NEVER LESS. Both correction loops walk
// one unit at a time around isqrt's estimate and stop on a comparison against the
// payment; nudging either comparison by one makes the buyer receive one unit LESS than
// their money bought, and both nudges survived the whole suite.
//
// WHAT I GOT WRONG FIRST, again worth keeping: I asserted that paying the exact cost of N
// units mints exactly N. It does not, and should not — near the origin the price rounds
// to almost nothing, so on a d = 1,000 curve the cost of ONE unit also buys 44. Minted's
// contract is the MAXIMUM the payment reaches, not the span the caller had in mind, and a
// test asserting equality was asserting my own misreading.
//
// The three properties that are actually the contract, each of which an off-by-one in
// either loop breaks: the mint is at least what the payment priced, the charge never
// exceeds the payment, and the result is MAXIMAL — one more unit would have cost more
// than was paid. A range of starts, because which loop runs depends on where isqrt lands.
func TestMintedIsMaximalAndNeverShortChangesTheBuyer(t *testing.T) {
	c := New(1_000, 1_000_000)
	tried := 0
	for from := int64(0); from < 50_000; from += 1_000 {
		for _, want := range []int64{1, 2, 7, 37, 250} {
			cost, ok := c.Cost(from, want)
			if !ok || cost <= 0 {
				continue // not a priceable span on this curve; nothing to assert
			}
			tried++
			got, spent := c.Minted(from, cost)
			if got < want {
				t.Fatalf("paying the exact price of %d units from %d minted only %d",
					want, from, got)
			}
			if spent > cost {
				t.Fatalf("minting %d units from %d charged %d for a %d payment",
					got, from, spent, cost)
			}
			// MAXIMAL: one unit more than what was minted must cost more than was paid.
			// This is the assertion both loops exist to satisfy.
			if next, nok := c.Cost(from, got+1); nok && next <= cost {
				t.Fatalf("from %d a payment of %d minted %d, but %d units cost only %d",
					from, cost, got, got+1, next)
			}
		}
	}
	if tried < 100 {
		t.Fatalf("setup: the range must actually exercise the loops, %d spans priced",
			tried)
	}
}

// A COST OF EXACTLY MaxInt64 IS PRICED, NOT REFUSED — the case KNOWN-GAPS recorded as
// "NOT CONSTRUCTED, and recorded as that rather than as unreachable".
//
// `if q > uint64(maxInt64)` narrowed to `>=` differs only where the ceil-divided
// quotient lands on 2^63-1 exactly. The gap row searched for that case at d = 1, argued
// the numerator would have to be 2^64-2 whose factor pairs have opposite parity, and
// concluded no integer (from, s1) exists. THE ARGUMENT WAS INCOMPLETE: the window is
// ((q-1)m, qm], so at d = 1 the numerator may also be 2^64-3, which is odd and factors
// as 1 x (2^64-3) — same parity, so from and s1 are integral. That solution needs
// s1 = 2^63-1 and dies on the cap (New refuses cap > 2^50), which is the real
// obstruction and not parity.
//
// Searching under the cap instead: diff = k*Q with Q = 2^63-1 = 7^2 * 73 * 127 * 337 *
// 92737 * 649657 makes m = k exactly, so any even k whose k*Q factors into
// (s1-from)(s1+from) with s1 <= 2^50 lands the quotient ON the ceiling. 74 such
// solutions exist; this is the first, at d = 2.
//
// The three arms are the boundary and its two sides, because a ceiling that refuses one
// unit early and one that refuses one unit late are different defects with the same
// smell: the exact value is priced, one unit more is refused, one unit less is priced.
func TestCostPricesACostOfExactlyMaxInt64(t *testing.T) {
	const from = int64(994862694074946)
	const delta = int64(18542)
	c := New(2, 1<<50)

	got, ok := c.Cost(from, delta)
	if !ok {
		t.Fatal("a cost of exactly MaxInt64 fits an int64, so it must be priced " +
			"rather than refused as unaffordable")
	}
	if got != maxInt64 {
		t.Fatalf("this span was constructed to cost exactly MaxInt64; it cost %d "+
			"(the fixture no longer sits on the boundary and proves nothing)", got)
	}
	// ONE UNIT MORE overshoots the ceiling and must be refused.
	if _, ok := c.Cost(from, delta+1); ok {
		t.Fatal("one unit past a MaxInt64 cost cannot fit an int64 and must be refused")
	}
	// ...and one unit less is comfortably priced, so the refusal above is about the
	// ceiling and not about the span or the curve.
	if under, ok := c.Cost(from, delta-1); !ok || under >= maxInt64 {
		t.Fatalf("one unit short of the ceiling must be priced below it: %d ok=%v",
			under, ok)
	}
}
