//go:build gnochain

package chain

import (
	"strings"
	"testing"
)

// What governing costs, measured on a chain rather than remembered.
//
// DESIGN.md carries four figures for this — the first proposal, every proposal
// after it, the first vote, every vote after that — and they were measured by
// hand, once, and written down. Nothing kept them honest. The mint and transfer
// figures beside them are asserted by a test; these were the ones a change
// could move silently, which is awkward for numbers that exist to show the
// design's central claim: a new key costs far more than an update.
//
// Asserted as RATIOS, the way the mint test is. The byte counts drift whenever
// a string in the realm changes, and a test that fails on that gets deleted
// rather than read. What must not drift is the shape: starting costs much more
// than continuing, and every vote costs the same because the proposer bought
// the roll's first node along with the proposal.
//
// The equality is the assertion, not a tolerance. Left to itself a bptree buys
// its first node on the first key, so the first vote costs eleven times the
// second — a tax on voting early. Propose plants a sentinel to move that cost
// onto the proposer, and this fails if the pre-warming is ever dropped.
func TestIntegrationGovernWhatGoverningCosts(t *testing.T) {
	nodeUp(t)
	root, rootAddr := rawClient(t, 0)
	aliceCl, aliceAddr := rawClient(t, 1)
	bobCl, bobAddr := rawClient(t, 2)
	realmPath := deployGovern(t, root, rootAddr)

	// Alice and Bob get a tenth each and the rest goes somewhere that never
	// votes, so two votes clear the 20% quorum without deciding anything. A
	// vote that settles the proposal drops the voter set, which is a REFUND and
	// would make the second measurement meaningless.
	governCall(t, root, rootAddr, realmPath, "Mint", aliceAddr.String(), "100")
	governCall(t, root, rootAddr, realmPath, "Mint", bobAddr.String(), "100")
	governCall(t, root, rootAddr, realmPath, "Mint", rootAddr.String(), "800")
	fundFor(t, root, rootAddr, aliceAddr)
	fundFor(t, root, rootAddr, bobAddr)
	sealCurrentEpoch(t, root, rootAddr)

	// Two proposals. The first pays for the first node of the proposals tree
	// AND of the open index; the second pays for a proposal.
	_, firstProp := storageCost(t, root, rootAddr, realmPath, "Propose",
		"govern:minter", aliceAddr.String(), "one")
	_, laterProp := storageCost(t, root, rootAddr, realmPath, "Propose",
		"govern:minter", bobAddr.String(), "two")
	t.Logf("first proposal on the realm: %d bytes", firstProp)
	t.Logf("every proposal after that:   %d bytes", laterProp)

	// Both votes land on the SAME proposal, and the proposer has already bought
	// the voter set, so these should match.
	id := "1"
	_, firstVote := storageCost(t, aliceCl, aliceAddr, realmPath, "Vote", id, "yes")
	_, laterVote := storageCost(t, bobCl, bobAddr, realmPath, "Vote", id, "yes")
	t.Logf("first vote on a proposal:    %d bytes", firstVote)
	t.Logf("every vote after that:       %d bytes", laterVote)

	if got := qeval(t, root, realmPath, "State("+id+")"); !strings.Contains(got, "active") {
		t.Fatalf("the proposal is %s, not active — a settled one drops its voter "+
			"set, so the second vote measured a refund rather than a vote", got)
	}

	// Starting is not proposing. Measuring one proposal and calling it the
	// price was wrong by more than three times when this was first measured;
	// it is about double now, because a proposal grew by the voter roll's
	// first node while the two trees the FIRST proposal buys did not.
	//
	// Threshold at 1.5 rather than 2 for that reason. The measured ratio is
	// 2.02, which cleared a 2x assertion by 216 bytes out of 17,788 — a pass
	// by luck, and the next change to a struct in this realm would have
	// flipped it into a failure that said nothing about what broke.
	if firstProp < laterProp*3/2 {
		t.Errorf("the first proposal cost %d bytes and a later one %d: the "+
			"trees are no longer being paid for up front, so the figure a "+
			"reader would quote as 'what proposing costs' is now whichever "+
			"proposal they happened to measure", firstProp, laterProp)
	}
	// The claim the design turns on. Whoever asks a question pays for the set
	// of people who can answer it, so answering costs the same whenever you do
	// it. A quarter's tolerance rather than equality: both votes insert into a
	// node that is already there, but the keys are different addresses and the
	// encoded sizes need not agree to the byte.
	if firstVote > laterVote*5/4 || laterVote > firstVote*5/4 {
		t.Errorf("the first vote cost %d bytes and a later one %d: these are "+
			"supposed to be the same vote, because the proposer bought the "+
			"roll's first node. A large first vote means the pre-warming is "+
			"gone and being early is taxed again", firstVote, laterVote)
	}
	// And the cost went to the proposer rather than evaporating. A proposal now
	// carries the roll's first node, so it is much larger than a vote — if it
	// were not, nobody would have paid for the node and the figures above would
	// be equal because they are both first-inserts into an unbought tree.
	if laterProp <= 2*laterVote {
		t.Errorf("a proposal cost %d bytes against %d for a vote: the proposal "+
			"is no longer carrying the roll's first node, so the equal votes "+
			"above prove nothing", laterProp, laterVote)
	}
	// A reason costs the realm nothing, which is the claim that makes offering
	// one affordable at all. It rides on the event; the ledger carries none of
	// it. Measured against a plain vote on the same proposal rather than
	// asserted, because "emitted, not stored" is exactly the sort of thing that
	// is true until somebody adds a field to a struct.
	// Compared against laterVote, which is a plain vote in the SAME position —
	// not the first on its proposal. Measuring an opening vote on a fresh
	// proposal against a reasoned later one compares 4,955 with 441, which looks
	// like a resounding pass and is nothing of the sort: the gap is the
	// voter-set node, and the reason was never in it.
	//
	// So: alice opens the second proposal's voting unmeasured, and bob's
	// reasoned vote is measured against the plain later vote already taken
	// above. Both abstain, because two tenths of the supply reaches the quorum
	// without reaching a verdict and a proposal that settles mid-measurement
	// gives back the node instead of a number.
	const other = "2"
	governCall(t, aliceCl, aliceAddr, realmPath, "Vote", other, "abstain")
	_, withReason := storageCost(t, bobCl, bobAddr, realmPath, "VoteWithReason",
		other, "abstain", "a reason long enough that storing it would show up here, "+
			"several times over, if any of it were being kept by the realm")
	t.Logf("plain later vote: %d bytes, reasoned later vote: %d", laterVote, withReason)
	if withReason > laterVote {
		t.Errorf("a vote carrying a reason cost %d bytes against %d for a plain "+
			"one in the same position: the reason is supposed to be emitted and "+
			"not stored, and the difference is the realm keeping it",
			withReason, laterVote)
	}

	if firstProp <= 0 || firstVote <= 0 {
		t.Fatalf("a proposal cost %d bytes and a vote %d — no StorageDepositEvent "+
			"was found and none of these numbers mean anything",
			firstProp, firstVote)
	}
}
