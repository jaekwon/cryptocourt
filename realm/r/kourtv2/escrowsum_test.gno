package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// THE ESCROW'S BALANCE, RECONCILED AGAINST WHAT IT OWES — the physical half of a
// conservation check whose accounting half is already pinned.
//
// claim_test.gno's TestCourtDepositLedgerMatchesItsClaims asserts the LEDGER identity,
// `c.deposit == Σ over live claims of (cs.deposit + cs.fee)`, and its header records why
// that mattered: the field was documented "for the conservation checks" and read nowhere.
// This is the other identity, and nothing asserted it. Every one of the suite's escrow
// balance assertions is either drain-to-zero at the end of one claim's life or a
// per-operation delta (`escrow0 - dep - fee`); none of them says the escrow holds exactly
// the sum of what is recorded against it.
//
// THE OBLIGATION SET IS CLOSED, which is what makes the assertion possible at all. Five
// transfers put coin into the escrow — the deposit+fee at OpenClaim, the answer bond, the
// dispute bond, the flag bond, and a nomination bond in the election lane — and lock.gno
// refuses the escrow as a transfer endpoint in all three of its user-facing paths
// ("the court escrow is not a transfer endpoint"), so no other path can add or remove a
// coin. That refusal is what bounds this sum; without it the list would be open-ended.
//
// pendingSlash IS ADDED ALONGSIDE answerBond, not folded into it: a slash reserve is
// carved OUT of the bond (`cs.answerBond == ab - slash` once reserved), so the escrow
// physically holds both halves and a sum that used only answerBond would come up short by
// exactly the reserve.
func escrowObligations(c *Court) int64 {
	total := int64(0)
	for id := uint64(1); id <= c.nextID; id++ {
		cs := mustClaim(c, id)
		total = mustAdd(total, cs.deposit)
		total = mustAdd(total, cs.fee)
		total = mustAdd(total, cs.answerBond)
		total = mustAdd(total, cs.disputeBond)
		total = mustAdd(total, cs.flagBond)
		total = mustAdd(total, cs.pendingSlash)
	}
	// The election lane's per-candidate bonds. A court holds at most one open ballot,
	// and each line records the bond its poster put up.
	if c.mod != nil && c.mod.election != nil {
		c.mod.election.lines.Iterate("", "", func(_ string, v any) bool {
			if l, ok := v.(*ballotLine); ok {
				total = mustAdd(total, l.bond)
			}
			return false
		})
	}
	return total
}

func mustReconcile(t *testing.T, c *Court, when string) {
	t.Helper()
	held := c.coin.BalanceOf(c.escrow)
	owed := escrowObligations(c)
	if held != owed {
		t.Fatalf("%s: the escrow holds %d and owes %d (off by %d) — either a disposal "+
			"path moved coin without clearing its field, or a field was cleared "+
			"without moving the coin", when, held, owed, held-owed)
	}
}

// Asserted at every step of one claim's life rather than once at the end, because the
// interesting failure is a single path that moves coin and its field out of step — and a
// check only at the end cannot say which path did it. The ORDERING is the subject: each
// call below both creates and discharges obligations, and the sum has to track every one.
func TestTheEscrowHoldsExactlyWhatItOwes(cur realm, t *testing.T) {
	alice := testutils.TestAddress("esum-alice")
	bob := testutils.TestAddress("esum-bob")
	carol := testutils.TestAddress("esum-carol")
	c := testCourt(cur, "esum", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(carol, 20_000_000_000)

	// A FRESH COURT OWES NOTHING, and the fixture would be vacuous if it also HELD
	// nothing for the whole test — so this arm is the baseline, not the assertion.
	mustReconcile(t, c, "a fresh court")

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "esum", "Does the escrow hold what it owes?")
	mustReconcile(t, c, "after OpenClaim escrows a deposit and fee")
	if c.coin.BalanceOf(c.escrow) == 0 {
		t.Fatal("setup: OpenClaim must have escrowed something, or every assertion " +
			"below compares zero against zero")
	}

	matureOI(cur, "esum", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "esum", id, sideYES)
	mustReconcile(t, c, "after PostAnswer escrows the answer bond")

	// A dispute bond on top, so three obligations are live against one claim at once.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "esum", id)
	mustReconcile(t, c, "after OpenDispute escrows the dispute bond")
	cs := mustClaim(c, id)
	if cs.deposit == 0 || cs.answerBond == 0 || cs.disputeBond == 0 {
		t.Fatalf("setup: three obligations must be live at once, got dep=%d bond=%d "+
			"disp=%d", cs.deposit, cs.answerBond, cs.disputeBond)
	}

	// Resolve the round: the dispute bond is disposed (refunded, burned or split) and
	// the answer bond survives or does not. Either way the sum must follow.
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "esum", id, "no")
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveDispute(cross(cur), "esum", id)
	mustReconcile(t, c, "after ResolveDispute disposes the dispute bond")

	// Finalize returns most of the answer bond and may retain a slash reserve, which is
	// the case that needs pendingSlash counted alongside answerBond.
	if now := heightNow(); now < cs.escrowUntil {
		testing.SkipHeights(cs.escrowUntil - now + 1)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "esum", id)
	mustReconcile(t, c, "after Finalize settles the answer bond")

	// THE FLAG LANE, because without it the flagBond term of the sum is decorative:
	// measured by dropping that term, the test still passed. A quality flag escrows a
	// fifth kind of obligation, and crystallize refuses while one is open, so it opens
	// and resolves here — before the draw.
	testing.SetRealm(testing.NewUserRealm(bob))
	OpenFlag(cross(cur), "esum", id)
	if cs.flagBond == 0 {
		t.Fatal("setup: OpenFlag must escrow a bond, or the flagBond term is untested")
	}
	mustReconcile(t, c, "after OpenFlag escrows the flag bond")

	// A CONCLUSIVE LOW, not a mid, and that is the whole point of choosing it: a low
	// reserves a slash, and pendingSlash is the one term whose placement in the sum
	// needed an argument rather than a reading — it is carved OUT of answerBond, so the
	// escrow holds both halves. Measured with a mid vote first, dropping the
	// pendingSlash term left the test PASSING, which made that argument untested.
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteQuality(cross(cur), "esum", id, qualityLow)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "esum", id)
	if cs.pendingSlash == 0 {
		t.Fatal("setup: a conclusive low must reserve a slash, or the pendingSlash " +
			"term is untested")
	}
	mustReconcile(t, c, "after ResolveFlag reserves a slash out of the bond")

	// The counter window closes and the reserve burns: the escrow loses coin and the
	// field clears together.
	testing.SkipHeights(cs.pendingSlashUntil - heightNow() + 1)
	ResolveSlashWindow(cross(cur), "esum", id)
	mustReconcile(t, c, "after ResolveSlashWindow burns the reserve")

	// And the whole way out: crystallize releases the deposit and fee, and the escrow
	// must end owing exactly what it holds — which for this claim is nothing.
	testing.SkipHeights(periodBlocks)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "esum", id)
	mustReconcile(t, c, "after Crystallize releases the deposit and fee")
}

// THE ELECTION LANE GETS ITS OWN FIXTURE, because the claim lifecycle above cannot
// reach it: an election needs a court shaped by electionCourt (holders with sealed
// weights, no claims), and cramming both into one fixture would leave each half
// contorted. Measured why it is needed at all — with only the claim fixture, dropping
// the `l.bond` term from escrowObligations left the test PASSING, so that term was
// decorative.
//
// A court with no claims makes this maximally discriminating: the claim loop
// contributes nothing, so the election bonds are the ENTIRE obligation and any error
// in that term shows up undiluted.
func TestTheEscrowHoldsExactlyWhatItOwesInTheElectionLane(cur realm, t *testing.T) {
	creator := testutils.TestAddress("esum2-creator")
	alice := testutils.TestAddress("esum2-alice")
	bob := testutils.TestAddress("esum2-bob")
	c := electionCourt(cur, "esum2", creator,
		[]address{alice, bob}, []int64{690_000_000, 310_000_000})
	c.coin.Mint(alice, 50_000_000) // bond money
	c.coin.Mint(bob, 50_000_000)

	mustReconcile(t, c, "a fresh election court")

	testing.SetRealm(testing.NewUserRealm(alice))
	cand := RegisterModCandidate(cross(cur), "esum2", 1,
		testutils.TestAddress("esum2-mod1"))
	testing.SetRealm(testing.NewUserRealm(alice))
	OpenElection(cross(cur), "esum2", cand)
	if c.coin.BalanceOf(c.escrow) == 0 {
		t.Fatal("setup: OpenElection must escrow a nomination bond, or the election " +
			"term of the sum is untested")
	}
	mustReconcile(t, c, "after OpenElection escrows the first nomination bond")

	// A second line from a second poster: two bonds live at once, so an error that
	// counts one line and stops is caught as well as one that counts none.
	testing.SetRealm(testing.NewUserRealm(bob))
	cand2 := RegisterModCandidate(cross(cur), "esum2", 1,
		testutils.TestAddress("esum2-mod2"))
	testing.SetRealm(testing.NewUserRealm(bob))
	NominateCandidate(cross(cur), "esum2", cand2)
	mustReconcile(t, c, "after a second nomination escrows a second bond")

	// And out: the lane returns or burns each bond by its own rules, and the sum has
	// to follow whichever it does.
	testing.SkipHeights(nominationWindow)
	testing.SetRealm(testing.NewUserRealm(alice))
	ApproveCandidate(cross(cur), "esum2", cand)
	testing.SkipHeights(c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(alice))
	ResolveElection(cross(cur), "esum2")
	mustReconcile(t, c, "after ResolveElection disposes the nomination bonds")
}
