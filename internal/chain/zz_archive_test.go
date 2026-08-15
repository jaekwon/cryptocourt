//go:build gnochain

package chain

import (
	"os"
	"testing"
)

// The two-slot checkpoint design, priced across six epochs.
//
// An account carries two checkpoints inline and rolls the older one into a
// paged archive when a third arrives. DESIGN.md records the curve that comes out
// of that, and every figure in it proved correct to the byte when re-measured —
// which is worth saying, because three other hand-measured numbers in this
// realm did not.
//
// Correct and unasserted are different things, and these are the claims the
// design is chosen for:
//
//   - a second write inside one epoch is FREE, not merely cheap. The record is
//     rewritten at the same encoded size, so there is no delta to charge for.
//     That is the entire argument for quantising the clock into epochs instead
//     of checkpointing per block.
//   - an account's FIRST move into a new epoch is free too, the first time,
//     because the second inline slot was still empty and nothing had to be
//     archived. This is what the two slots buy and it is invisible anywhere
//     else.
//   - the archive is bought in a lump — its first page pays for the tree's
//     first node — and every page after it is an append into the node already
//     bought.
//
// Behind an environment variable because it costs six sealed epochs, and an
// epoch is 720 blocks that gnodev will only produce one transaction at a time:
// about seventy seconds each. The rest of the chain suite runs in five minutes
// and this alone would double it.
//
//	SLOW_ARCHIVE=1 go test -tags gnochain -run ArchiveRollsInLumps ./internal/chain/
func TestIntegrationGovernArchiveRollsInLumps(t *testing.T) {
	if os.Getenv("SLOW_ARCHIVE") == "" {
		t.Skip("SLOW_ARCHIVE unset: this seals six epochs, about seven minutes")
	}
	nodeUp(t)
	root, rootAddr := rawClient(t, 0)
	realmPath := deployGovern(t, root, rootAddr)
	_, dst := rawClient(t, 3)

	governCall(t, root, rootAddr, realmPath, "Mint", rootAddr.String(), "1000")

	const epochs = 6
	first := make([]int64, epochs+1)
	second := make([]int64, epochs+1)
	for e := 1; e <= epochs; e++ {
		_, first[e] = storageCost(t, root, rootAddr, realmPath, "Transfer", dst.String(), "1")
		_, second[e] = storageCost(t, root, rootAddr, realmPath, "Transfer", dst.String(), "1")
		t.Logf("epoch %d: first move %6d bytes, second move %6d", e, first[e], second[e])
		sealCurrentEpoch(t, root, rootAddr)
	}

	// The first epoch is the only one that pays for the account records
	// themselves, so it is the proof that these measurements see anything at
	// all. storageCost reports a missing event as zero, quite correctly, so
	// without a non-zero somewhere the zeroes below would all be satisfied by a
	// helper that had stopped reading events.
	if first[1] <= 0 {
		t.Fatalf("the first transfer of all charged %d bytes: no deposit event "+
			"was read, and every zero below is meaningless", first[1])
	}

	// From the second epoch on, a repeated transfer inside one epoch is free.
	//
	// Not from the FIRST epoch, and the difference is worth understanding
	// rather than asserting around. Coalescing means no new checkpoint is
	// written; it does not mean the record cannot change size. In epoch one the
	// balances are still small and growing a digit at a time, and a deposit is
	// charged on the delta of the encoded size — so the second transfer there
	// costs about 24 bytes, the same figure a second mint to an existing
	// address costs. Once the numbers have settled into their encoding the
	// delta really is nothing.
	for e := 2; e <= epochs; e++ {
		if second[e] != 0 {
			t.Errorf("a repeated transfer inside epoch %d charged %d bytes, want "+
				"0 — same-epoch coalescing has stopped working, and every "+
				"transfer is paying for a checkpoint nobody asked for",
				e, second[e])
		}
	}
	if second[1] > 200 {
		t.Errorf("the second transfer of the first epoch charged %d bytes: that "+
			"one is allowed to be non-zero because the balances are still "+
			"growing their encoding, but not by this much — a checkpoint is "+
			"being written", second[1])
	}

	// The free roll. Two inline slots, one of them still empty, so the second
	// epoch an account is touched in costs nothing at all.
	if first[2] != 0 {
		t.Errorf("the first move in the second epoch charged %d bytes, want 0 — "+
			"the second inline slot is not being used, so the two-slot design "+
			"is paying for an archive it did not need yet", first[2])
	}

	// The third epoch is where a checkpoint finally rolls out, and it buys the
	// archive tree its first node. A lump, not a page.
	if first[3] < 10*first[5] {
		t.Errorf("the first archived epoch charged %d bytes against %d for a "+
			"later one: the archive is no longer being bought a node at a time, "+
			"which is the shape every storage figure in this realm is reasoned "+
			"from", first[3], first[5])
	}
	// And afterwards it is an append into the node already paid for.
	if first[5] <= 0 || first[5] >= first[3]/10 {
		t.Errorf("a later archived epoch charged %d bytes against %d for the "+
			"first: appending to an existing page should be small and non-zero",
			first[5], first[3])
	}
	if first[6] != first[5] {
		t.Logf("note: epochs 5 and 6 charged %d and %d — appends have stopped "+
			"being uniform, which is not wrong but is worth knowing",
			first[5], first[6])
	}
}
