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
// THE OBLIGATION SET IS CLOSED, which is what makes the assertion possible at all. Four
// transfers put coin into the escrow — the deposit+fee at OpenClaim, the answer bond, the
// dispute bond, and a nomination bond in the election lane — and lock.gno
// refuses the escrow as a transfer endpoint in all three of its user-facing paths
// ("the court escrow is not a transfer endpoint"), so no other path can add or remove a
// coin. That refusal is what bounds this sum; without it the list would be open-ended.
//
// RE-DERIVED FROM SIX PER-CLAIM TERMS TO FOUR when the quality lane went. The two that
// left were flagBond and pendingSlash, and the count is re-derived rather than decremented:
// the sum is now deposit + fee + answerBond + disputeBond, and the argument that each of
// the four is REACHED by the fixture below has to hold for the shorter list on its own.
//
// pendingSlash needed its own paragraph here, because a reserve was carved OUT of the
// answer bond — `cs.answerBond == ab - slash` once reserved — so the escrow physically
// held both halves and a sum using only answerBond came up short by exactly the reserve.
// settleAnswerBond no longer carves anything, so answerBond alone is now the whole
// obligation and that subtlety is gone with it.
func escrowObligations(c *Court) int64 {
	total := int64(0)
	for id := uint64(1); id <= c.nextID; id++ {
		cs := mustClaim(c, id)
		total = mustAdd(total, cs.deposit)
		total = mustAdd(total, cs.fee)
		total = mustAdd(total, cs.answerBond)
		total = mustAdd(total, cs.disputeBond)
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

	// Finalize returns the answer bond in full — it used to retain a slash reserve,
	// which was the case that needed pendingSlash counted alongside answerBond.
	if now := heightNow(); now < cs.escrowUntil {
		testing.SkipHeights(cs.escrowUntil - now + 1)
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	Finalize(cross(cur), "esum", id)
	mustReconcile(t, c, "after Finalize settles the answer bond")

	// THE FLAG LANE STOOD HERE, and it was load-bearing for this test rather than
	// incidental: it existed because dropping the flagBond term left the test PASSING,
	// and a conclusive LOW was chosen over a mid for the same measured reason about
	// pendingSlash. Both terms are gone from the sum, so both halves of that fixture go
	// with them — but the lesson does not. Each of the four remaining terms should be
	// ablatable to a FAILURE by this fixture, and if one is not, the fixture is short a
	// state rather than the sum being short a term.

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

// THE OTHER TWO TERMINAL SHAPES. The fixture above walks one claim through a DISPUTED
// life (answer, dispute, finalize, flag, slash, draw). A claim can also end undisputed
// — SettleUndisputed returns most of the bond — or never be answered at all, in which
// case CloseDeadClaim refunds the deposit and BURNS the fee. Both move escrowed coin,
// and neither was reconciled anywhere: the tests that drive them assert per-operation
// deltas or drain-to-zero, which is the weaker statement this file exists to replace.
//
// Both claims live in ONE court but the dead one is opened FIRST, because closing it
// needs the clock 1.45M blocks forward and that would blow every window the settled
// claim depends on. Open early, settle the other, then skip.
//
// IT CATCHES NOTHING TODAY THAT SOMETHING ELSE DOES NOT, and saying so is the point —
// a reader should not mistake this for load-bearing. Measured: planting a fee-burn
// bookkeeping error on the dead path (burn the coin, leave cs.fee set) fails THREE
// tests, and two are older than this one; with this file withdrawn the suite still
// goes red. The reason is structural. CloseDeadClaim touches no bond field at all, so
// its only obligations are deposit and fee — and those are already pinned twice, by
// TestCourtDepositLedgerMatchesItsClaims and by the balance itself. SettleUndisputed's
// bond goes through settleAnswerBond, which the disputed fixture above already reaches
// via Finalize.
//
// KEPT ANYWAY, and the distinction from the disjointness walk cut out of
// queuetile_test.gno matters. That walk could never fire because a STRONGER assertion
// in the same test pinned exact values — subsumption by construction. This is
// subsumption by coincidence of today's field set: the moment an obligation field is
// added that a terminal path forgets to clear, these two paths are where it shows, and
// nothing else reconciles them. The set has grown before — stake moved OUT of the
// escrow at v0.34 — so the coincidence is not a law.
func TestTheEscrowHoldsExactlyWhatItOwesOnTheOtherTerminalPaths(cur realm, t *testing.T) {
	alice := testutils.TestAddress("esum3-alice")
	bob := testutils.TestAddress("esum3-bob")
	c := testCourt(cur, "esum3", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)

	// The claim that will die unanswered, opened before the clock moves.
	testing.SetRealm(testing.NewUserRealm(alice))
	dead := OpenClaim(cross(cur), "esum3", "A question nobody will answer")
	mustReconcile(t, c, "after the dead claim's deposit is escrowed")

	// THE UNDISPUTED PATH: answered, never disputed, settled at the delay.
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "esum3", "A question that settles quietly")
	matureOI(cur, "esum3", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "esum3", id, sideYES)
	mustReconcile(t, c, "after the settling claim's answer bond is escrowed")

	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "esum3", id)
	mustReconcile(t, c, "after SettleUndisputed returns the whole bond")

	// The bond is fully OUT, which is what the reconciliation above has to see: this
	// path used to exercise a PARTIAL return, and the assertion here was that the
	// retention was real or the checkpoint proved nothing about a reserve. There is
	// no reserve now, so the same checkpoint is testing the complementary thing —
	// that the term left the sum entirely rather than being half-counted.
	cs := mustClaim(c, id)
	if cs.answerBond != 0 {
		t.Fatalf("SettleUndisputed must zero the bond, got %d", cs.answerBond)
	}

	testing.SkipHeights(priorityWindowBlocks + 1)
	testing.SkipHeights(periodBlocks)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "esum3", id)
	mustReconcile(t, c, "after the undisputed claim crystallizes")

	// THE DEAD PATH: the deposit comes back, the fee burns. The escrow must lose both,
	// and the sum has to drop by exactly the pair.
	testing.SkipHeights(deadClaimTimeout + 1)
	dcs := mustClaim(c, dead)
	if dcs.deposit == 0 || dcs.fee == 0 {
		t.Fatalf("setup: the dead claim must still hold both, got dep=%d fee=%d",
			dcs.deposit, dcs.fee)
	}
	testing.SetRealm(testing.NewUserRealm(bob))
	CloseDeadClaim(cross(cur), "esum3", dead)
	mustReconcile(t, c, "after CloseDeadClaim refunds the deposit and burns the fee")
	if dcs.deposit != 0 || dcs.fee != 0 {
		t.Fatalf("a dead claim's obligations must both clear, got dep=%d fee=%d",
			dcs.deposit, dcs.fee)
	}
}
