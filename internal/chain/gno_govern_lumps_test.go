//go:build gnochain

package chain

import (
	"sort"
	"testing"
)

// The premise, checked: storage does not arrive per key, it arrives in lumps.
//
// This is the claim the whole design is built on. "A new key costs far more
// than an update" is the version everybody quotes, and it is true, but the
// useful half is the shape underneath it — a bptree node is bought whole, so
// thirty-two holders share one lump and the thirty-third buys the next.
// Epochs, the two inline checkpoint slots, coalescing within an epoch and the
// choice not to checkpoint per block all follow from that and not from the
// slogan.
//
// Asserted here rather than kept as a hand-measured table in DESIGN.md. Such a
// table drifts in a particular way — not by going stale, but by one number
// being right about a split, then quoted about a first node, and later about a
// different tree entirely. Numbers travel.
//
// The shape, not the bytes. Byte counts move whenever a string in the realm
// moves and a test that fails on that gets deleted rather than read; what must
// not move is that the curve is flat with a spike in it, and where the spike
// is.
func TestIntegrationGovernStorageArrivesInLumps(t *testing.T) {
	nodeUp(t)
	root, rootAddr := rawClient(t, 0)
	realmPath := deployGovern(t, root, rootAddr)

	// One unit to each of forty fresh addresses. They never sign anything, so
	// they need no funding — only to be valid, which is what deriving them from
	// the test mnemonic buys.
	const holders = 40
	cost := make([]int64, holders+1)
	for i := 1; i <= holders; i++ {
		_, a := rawClient(t, uint32(1000+i))
		_, cost[i] = storageCost(t, root, rootAddr, realmPath, "Mint", a.String(), "1")
		if cost[i] <= 0 {
			t.Fatalf("holder %d cost %d bytes — no StorageDepositEvent, so none "+
				"of this means anything", i, cost[i])
		}
	}

	// The flat stretch, taken from the middle so neither end can contaminate it.
	var flat []int64
	for i := 5; i <= 32; i++ {
		flat = append(flat, cost[i])
	}
	sort.Slice(flat, func(a, b int) bool { return flat[a] < flat[b] })
	lo, hi, mid := flat[0], flat[len(flat)-1], flat[len(flat)/2]
	t.Logf("holder 1: %d | steady %d..%d (median %d) | holder 33: %d | holder 34: %d",
		cost[1], lo, hi, mid, cost[33], cost[34])

	if hi > lo*5/4 {
		t.Errorf("holders 5..32 cost between %d and %d bytes, which is not flat "+
			"— an update inside an already-bought node is supposed to cost about "+
			"the same every time", lo, hi)
	}

	// The lump, where the node fills and splits. This is the assertion that
	// makes "far more than an update" mean something.
	if cost[33] < 4*mid {
		t.Errorf("the thirty-third holder cost %d bytes against a steady %d: the "+
			"node is no longer being bought whole, so the amortised figure this "+
			"realm quotes (steady + split/32) is measuring something else",
			cost[33], mid)
	}
	if cost[34] > mid*5/4 {
		t.Errorf("the thirty-fourth holder cost %d bytes against a steady %d — "+
			"the curve did not come back down after the split, so the lump is "+
			"not a lump", cost[34], mid)
	}

	// And the first node, which is a different event from a split and was
	// recorded as the same number for a long time. Bigger than a steady holder,
	// smaller than a split: one leaf against a leaf and a root.
	if cost[1] <= mid*2 {
		t.Errorf("the first holder cost %d bytes against a steady %d — the tree's "+
			"first node is not being paid for", cost[1], mid)
	}
	if cost[1] >= cost[33] {
		t.Errorf("the first holder cost %d and the split %d: a first node and a "+
			"split are different events and the split allocates the extra root, "+
			"so collapsing them into one figure is how this drifted before",
			cost[1], cost[33])
	}
}
