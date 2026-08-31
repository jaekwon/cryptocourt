package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// VOTE-THEN-SELL, which is what the floor alone did NOT stop. Probed on the floor
// before this lock existed: borrow, seal, open the dispute, vote while still
// holding, repay in the next call — 599x the quorum floor with a final balance of
// zero, against the 600x the original characterization measured. The floor moved
// the attack one step to the right. This is the step that prices it.
func TestVotedCoinCannotLeaveUntilTheRoundResolves(cur realm, t *testing.T) {
	whale := testutils.TestAddress("vl1-whale")
	author := testutils.TestAddress("vl1-author")
	renter := testutils.TestAddress("vl1-renter")
	c := testCourt(cur, "vlk1", author, 100_000_000_000)
	c.coin.Mint(whale, 400_000_000_000)

	id := stakeAnswerDispute(cur, "vlk1", author, whale)

	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "vlk1", renter, 300_000_000_000)
	testing.SkipHeights(epochBlocks * 2)
	touch(c)

	testing.SetRealm(testing.NewUserRealm(renter))
	OpenDispute(cross(cur), "vlk1", id)
	cs := mustClaim(c, id)

	// Vote WHILE HOLDING — the reorder the floor permits, and it still lands.
	testing.SetRealm(testing.NewUserRealm(renter))
	VoteDispute(cross(cur), "vlk1", id, "yes")
	_, w, ok := c.gov.VoteOf(cs.proposalID, renter)
	uassert.True(t, ok)
	if w <= 0 {
		t.Fatal("fixture is vacuous: nothing was voted, so nothing is being locked")
	}

	// The ballot's weight is now committed, exactly and no more.
	uassert.Equal(t, w, VoteLockedOf("vlk1", renter))

	// And repaying the lender is refused.
	testing.SetRealm(testing.NewUserRealm(renter))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferCC(cross(cur), "vlk1", whale, w)
	})

	// PAIRED with what must still work. The lock is amount-keyed, not
	// address-keyed: coin above the ballot's weight is untouched. The reverted
	// first attempt froze a voter's whole future inventory off one dust abstain.
	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "vlk1", renter, 5_000_000_000)
	testing.SetRealm(testing.NewUserRealm(renter))
	TransferCC(cross(cur), "vlk1", whale, 5_000_000_000)
	uassert.Equal(t, w, VoteLockedOf("vlk1", renter))

	// AND STAKING STILL WORKS, which is the other half of the rule: staking moves
	// nothing out of the balance, so a pending vote is no reason to refuse it. This
	// is the arm that catches folding the vote lock into spendable(). A SECOND
	// claim, because staking is frozen on one that already has an answer.
	testing.SetRealm(testing.NewUserRealm(author))
	other := OpenClaim(cross(cur), "vlk1", "an unanswered claim to stake on")
	testing.SetRealm(testing.NewUserRealm(renter))
	Stake(cross(cur), "vlk1", other, sideYES, 1_000_000_000)

	// RELEASED at resolution, not at the ballot close — the correction that
	// mattered, since the reverted version let a voter sell before the verdict
	// they caused was applied.
	testing.SkipHeights(c.params.votingBlocks + 1)
	if VoteLockedOf("vlk1", renter) != w {
		t.Fatal("the ballot closed but the round has not resolved — the coin must " +
			"still be committed, or a voter sells before their verdict applies")
	}
	testing.SetRealm(testing.NewUserRealm(whale))
	ResolveDispute(cross(cur), "vlk1", id)
	uassert.Equal(t, int64(0), VoteLockedOf("vlk1", renter))

	// Free to move again.
	testing.SetRealm(testing.NewUserRealm(renter))
	TransferCC(cross(cur), "vlk1", whale, 1_000_000_000)
}

// The election lane: one voter is one commitment, however many lines they approve.
func TestApprovingManyLinesLocksOneCommitment(cur realm, t *testing.T) {
	creator := testutils.TestAddress("vl2-creator")
	voter := testutils.TestAddress("vl2-voter")
	helper := testutils.TestAddress("vl2-helper")
	modA := testutils.TestAddress("vl2-moda")
	modB := testutils.TestAddress("vl2-modb")
	c := electionCourt(cur, "vlk2", creator,
		[]address{voter, helper}, []int64{200_000_000_000, 200_000_000_000})
	c.coin.Mint(voter, 50_000_000)
	c.coin.Mint(helper, 50_000_000)

	testing.SetRealm(testing.NewUserRealm(voter))
	candA := RegisterModCandidate(cross(cur), "vlk2", 1, modA)
	testing.SetRealm(testing.NewUserRealm(helper))
	candB := RegisterModCandidate(cross(cur), "vlk2", 1, modB)

	testing.SetRealm(testing.NewUserRealm(voter))
	OpenElection(cross(cur), "vlk2", candA)
	testing.SkipHeights(10)
	testing.SetRealm(testing.NewUserRealm(helper))
	NominateCandidate(cross(cur), "vlk2", candB)
	testing.SkipHeights(nominationWindow)

	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "vlk2", candA)
	one := VoteLockedOf("vlk2", voter)
	if one <= 0 {
		t.Fatal("fixture is vacuous: the first approval locked nothing")
	}

	// A second line, and a third (retain) — the commitment does not grow.
	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "vlk2", candB)
	uassert.Equal(t, one, VoteLockedOf("vlk2", voter))
	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveRetain(cross(cur), "vlk2")
	uassert.Equal(t, one, VoteLockedOf("vlk2", voter))

	// Committed, and refused.
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferCC(cross(cur), "vlk2", helper, one)
	})

	// Released when the election resolves.
	testing.SkipHeights(c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(helper))
	ResolveElection(cross(cur), "vlk2")
	uassert.Equal(t, int64(0), VoteLockedOf("vlk2", voter))
	testing.SetRealm(testing.NewUserRealm(voter))
	TransferCC(cross(cur), "vlk2", helper, one)
}

// A staker who votes holds ONE pile answering to TWO claims, and the rule is MAX
// not SUM. Summing them would refuse a transfer the holder can honestly make.
//
// The fixture is built so the two readings give DIFFERENT answers, which took
// arranging: the voter's live balance must exceed their snapshot (so the vote lock
// is smaller than the balance and something is free at all), and the stake lock
// must be smaller than the vote lock (so max picks the vote lock). Under SUM the
// final transfer is refused; under MAX it goes through.
//
// The court is kept small on purpose: effMinAnswerX is 10 bps of SUPPLY, and a
// larger court pushes the answerability floor above stakeAnswerDispute's X-bar so
// PostAnswer aborts before the test begins. That is how the first version failed.
func TestStakeAndVoteLocksOverlapRatherThanStack(cur realm, t *testing.T) {
	whale := testutils.TestAddress("vl3-whale")
	author := testutils.TestAddress("vl3-author")
	voter := testutils.TestAddress("vl3-voter")
	c := testCourt(cur, "vlk3", author, 40_000_000_000)
	c.coin.Mint(whale, 10_000_000_000)
	c.coin.Mint(voter, 10_000_000_000)

	id := stakeAnswerDispute(cur, "vlk3", author, whale)
	// A second, unanswered claim to stake on — staking is frozen once a claim has
	// an answer, and the answered one is the one being disputed below.
	testing.SetRealm(testing.NewUserRealm(author))
	other := OpenClaim(cross(cur), "vlk3", "an unanswered claim to stake on")
	testing.SkipHeights(epochBlocks * 2)
	touch(c)
	// AFTER the seal, so the ceiling stays at 10B while the balance rises. That gap
	// is what leaves anything free once the vote lock bites.
	c.coin.Mint(voter, 5_000_000_000)

	// Stake first, so a stake lock exists before the vote lock does.
	testing.SetRealm(testing.NewUserRealm(voter))
	Stake(cross(cur), "vlk3", other, sideYES, 2_000_000_000)
	bal := c.coin.BalanceOf(voter)
	sl := bal - SpendableOf("vlk3", voter)
	if sl != 2_000_000_000 {
		t.Fatalf("fixture is vacuous: expected a 2B stake lock, saw %d", sl)
	}

	testing.SetRealm(testing.NewUserRealm(whale))
	OpenDispute(cross(cur), "vlk3", id)
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteDispute(cross(cur), "vlk3", id, "no")
	vl := VoteLockedOf("vlk3", voter)
	if vl <= sl {
		t.Fatalf("fixture is vacuous: the vote lock (%d) must EXCEED the stake "+
			"lock (%d) for max-vs-sum to be distinguishable", vl, sl)
	}

	// Under MAX the free amount is balance - vote lock. Under SUM it would be
	// balance - vote - stake, i.e. 2B less, and this transfer would be refused.
	free := bal - vl
	if free <= 0 || free <= sl {
		t.Fatalf("fixture is vacuous: free=%d must be positive and larger than "+
			"the stake lock=%d, or SUM and MAX agree", free, sl)
	}
	testing.SetRealm(testing.NewUserRealm(voter))
	TransferCC(cross(cur), "vlk3", whale, free)
	uassert.Equal(t, vl, c.coin.BalanceOf(voter))

	// And one unit more is refused: max is a real bound, not an unenforced one.
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferCC(cross(cur), "vlk3", whale, 1)
	})
}

// TestASupersededQualityVoteReleasesItsCoin went with the quality lane: a superseded quality tally cannot exist

// TestAFrozenQualityTallyHoldsCoinUntilTheClaimEnds went with the quality lane: there is no quality tally to freeze

// TestTwoQuestionsCommitOnePileOnce went with the quality lane: there is only one question now, so one pile cannot be committed to two

// THE LOCK CAN NEVER TRAP ANYONE, and that is a liveness property distinct from
// everything else here: a voter may commit their ENTIRE balance, which leaves them
// with nothing to pay a fee with, so if freeing the coin cost anything they would
// be stranded by their own vote.
//
// It does not, because every release trigger is free AND permissionless —
// ResolveDispute, ResolveElection, ResolveFlag, ResolveCounter, SettleUndisputed
// and Finalize between them charge the caller nothing (Finalize is
// participant-gated only for its grace window). So the locked party can always
// reach the release themselves. That is a claim about six functions not growing a
// fee, which is exactly the kind of claim that rots silently, so it is asserted
// here rather than trusted.
func TestAFullyCommittedVoterCanAlwaysFreeTheirOwnCoin(cur realm, t *testing.T) {
	alice := testutils.TestAddress("vl6-alice")
	bob := testutils.TestAddress("vl6-bob")
	voter := testutils.TestAddress("vl6-voter")
	c := testCourt(cur, "vlk6", alice, 40_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	c.coin.Mint(voter, 10_000_000_000)
	id := stakeAnswerDispute(cur, "vlk6", alice, bob)
	cs := mustClaim(c, id)

	testing.SetRealm(testing.NewUserRealm(bob))
	OpenDispute(cross(cur), "vlk6", id)

	// Commit EVERYTHING. The voter never paid a bond, so their whole balance is
	// their weight, and after voting their whole balance is committed.
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteDispute(cross(cur), "vlk6", id, "no")
	locked := VoteLockedOf("vlk6", voter)
	if locked != c.coin.BalanceOf(voter) {
		t.Fatalf("fixture is vacuous: this test is about a voter with NOTHING "+
			"spare, but %d of %d is committed", locked, c.coin.BalanceOf(voter))
	}

	// Nothing at all can leave, not even one unit — so nothing could be paid.
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferCC(cross(cur), "vlk6", bob, 1)
	})

	// And yet the voter frees themselves, unaided and for free, by resolving the
	// very question that locked them. Permissionless, no fee, no participant gate.
	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(voter))
	ResolveDispute(cross(cur), "vlk6", id)
	uassert.Equal(t, int64(0), VoteLockedOf("vlk6", voter))
	testing.SetRealm(testing.NewUserRealm(voter))
	TransferCC(cross(cur), "vlk6", bob, 1)
	_ = cs
}

// The same property in the election lane, where the whole ballot is one commitment
// and ResolveElection is the release.
func TestAFullyCommittedApproverCanAlwaysFreeTheirOwnCoin(cur realm, t *testing.T) {
	creator := testutils.TestAddress("vl7-creator")
	voter := testutils.TestAddress("vl7-voter")
	other := testutils.TestAddress("vl7-other")
	mod := testutils.TestAddress("vl7-mod")
	c := electionCourt(cur, "vlk7", creator, []address{voter, other},
		[]int64{100_000_000_000, 100_000_000_000})
	// Bond money POST-seal so the snapshot stays at the full pre-seal balance and
	// the bond does not leave the voter with convenient spare change.
	c.coin.Mint(voter, 50_000_000)

	testing.SetRealm(testing.NewUserRealm(voter))
	cand := RegisterModCandidate(cross(cur), "vlk7", 1, mod)
	testing.SetRealm(testing.NewUserRealm(voter))
	OpenElection(cross(cur), "vlk7", cand)
	testing.SkipHeights(nominationWindow)
	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "vlk7", cand)

	locked := VoteLockedOf("vlk7", voter)
	if locked <= 0 || locked > c.coin.BalanceOf(voter) {
		t.Fatalf("fixture is vacuous: locked=%d against a balance of %d",
			locked, c.coin.BalanceOf(voter))
	}
	// Spend the spare change down so the commitment really is everything.
	if spare := c.coin.BalanceOf(voter) - locked; spare > 0 {
		testing.SetRealm(testing.NewUserRealm(voter))
		TransferCC(cross(cur), "vlk7", other, spare)
	}
	uassert.Equal(t, locked, c.coin.BalanceOf(voter))
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferCC(cross(cur), "vlk7", other, 1)
	})

	testing.SkipHeights(c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(voter))
	ResolveElection(cross(cur), "vlk7")
	uassert.Equal(t, int64(0), VoteLockedOf("vlk7", voter))
	testing.SetRealm(testing.NewUserRealm(voter))
	TransferCC(cross(cur), "vlk7", other, 1)
}

// PRUNING DROPS DEAD ROWS AND MOVES NOTHING ELSE.
//
// lockVote prunes, so an address that keeps voting never accumulates. One that
// votes in several simultaneously-open questions and then STOPS carries a row per
// question forever — measured at six open disputes voted, all six resolved, six
// rows still present with ZERO coin committed, and every mustSpendable on that
// address walking all six. Each is persistent state paying a storage deposit for
// nothing, and the count is bounded only by how many questions were open at once.
//
// The safety argument for leaving the entrypoint permissionless is an EQUALITY, not
// a judgement: prune removes exactly the rows voteLockedOf already skips, because
// both ask voteLockOpen. So the committed figure is identical either side of a
// prune. That is asserted here, together with the pair that matters more — a LIVE
// row must survive, or "prune" would be a way to walk out of a commitment.
func TestPruningDropsDeadRowsWithoutMovingTheCommitment(cur realm, t *testing.T) {
	alice := testutils.TestAddress("vl8-alice")
	whale := testutils.TestAddress("vl8-whale")
	voter := testutils.TestAddress("vl8-voter")
	c := testCourt(cur, "vlk8", alice, 40_000_000_000)
	c.coin.Mint(whale, 60_000_000_000)
	c.coin.Mint(voter, 10_000_000_000)

	// Three questions, all voted, all resolved: three dead rows.
	dead := make([]uint64, 0, 3)
	for i := 0; i < 3; i++ {
		id := stakeAnswerDispute(cur, "vlk8", alice, whale)
		testing.SetRealm(testing.NewUserRealm(whale))
		OpenDispute(cross(cur), "vlk8", id)
		testing.SetRealm(testing.NewUserRealm(voter))
		VoteDispute(cross(cur), "vlk8", id, "no")
		dead = append(dead, id)
	}
	testing.SkipHeights(c.params.votingBlocks + 1)
	for _, id := range dead {
		testing.SetRealm(testing.NewUserRealm(whale))
		ResolveDispute(cross(cur), "vlk8", id)
	}

	// A fourth question, voted and left OPEN, so there is a live row to protect.
	live := stakeAnswerDispute(cur, "vlk8", alice, whale)
	testing.SetRealm(testing.NewUserRealm(whale))
	OpenDispute(cross(cur), "vlk8", live)
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteDispute(cross(cur), "vlk8", live, "no")

	// lockVote pruned on that fourth vote, so re-dirty the state: resolve the
	// fourth's PREDECESSORS are already gone, so instead add two more dead rows
	// after the live one exists.
	extra := make([]uint64, 0, 2)
	for i := 0; i < 2; i++ {
		id := stakeAnswerDispute(cur, "vlk8", alice, whale)
		testing.SetRealm(testing.NewUserRealm(whale))
		OpenDispute(cross(cur), "vlk8", id)
		testing.SetRealm(testing.NewUserRealm(voter))
		VoteDispute(cross(cur), "vlk8", id, "no")
		extra = append(extra, id)
	}
	testing.SkipHeights(c.params.votingBlocks + 1)
	for _, id := range extra {
		testing.SetRealm(testing.NewUserRealm(whale))
		ResolveDispute(cross(cur), "vlk8", id)
	}

	before := VoteLockedOf("vlk8", voter)
	rows := voteLockRows(c, voter)
	if rows < 2 || before <= 0 {
		t.Fatalf("fixture is vacuous: need dead rows AND a live commitment, got "+
			"rows=%d committed=%d", rows, before)
	}

	// Anyone may prune, so a bystander does it.
	testing.SetRealm(testing.NewUserRealm(alice))
	dropped := PruneVoteLocks(cross(cur), "vlk8", voter)
	if dropped <= 0 {
		t.Fatal("nothing was pruned, so this says nothing about pruning")
	}
	// THE EQUALITY: the commitment is untouched.
	uassert.Equal(t, before, VoteLockedOf("vlk8", voter))
	// And the live row survived — pruning is not an exit from a commitment.
	uassert.Equal(t, rows-dropped, voteLockRows(c, voter))
	if voteLockRows(c, voter) < 1 {
		t.Fatal("the LIVE row was pruned: prune must never be a way to walk out " +
			"of a commitment")
	}
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferCC(cross(cur), "vlk8", whale, before)
	})

	// Idempotent: a second prune finds nothing, so it is not a repeatable state
	// churn a griefer could bill to the court.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.Equal(t, 0, PruneVoteLocks(cross(cur), "vlk8", voter))

	// And once the live question resolves, the last row goes too.
	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(whale))
	ResolveDispute(cross(cur), "vlk8", live)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.True(t, PruneVoteLocks(cross(cur), "vlk8", voter) > 0)
	uassert.Equal(t, 0, voteLockRows(c, voter))
	uassert.Equal(t, int64(0), VoteLockedOf("vlk8", voter))
}

// voteLockRows counts an address's lock rows, live and dead. Test-only: the realm
// has no reason to know, and a reader would be one more surface to keep honest.
func voteLockRows(c *Court, who address) int {
	if c.voteLocks == nil {
		return 0
	}
	n := 0
	pre := string(who)
	c.voteLocks.Iterate(pre, pre+"\xff", func(_ string, _ any) bool { n++; return false })
	return n
}

// THE COMMON CASE CLEANS ITSELF, which is the whole reason PruneVoteLocks is for
// the pathological case only. An address that votes, sees the question resolve, and
// votes again carries ONE row — not one per vote it has ever cast.
//
// FOUND BY ABLATION, not by design: deleting lockVote's prune call left every other
// test in the suite green. Three tests catch a prune that removes too much and one
// catches a prune that removes nothing, but nothing at all noticed the routine
// prune simply not happening — the failure mode with no symptom except a bill.
func TestRepeatedVotingDoesNotAccumulateRows(cur realm, t *testing.T) {
	alice := testutils.TestAddress("vl9-alice")
	whale := testutils.TestAddress("vl9-whale")
	voter := testutils.TestAddress("vl9-voter")
	c := testCourt(cur, "vlk9", alice, 40_000_000_000)
	c.coin.Mint(whale, 60_000_000_000)
	c.coin.Mint(voter, 10_000_000_000)

	for round := 1; round <= 3; round++ {
		id := stakeAnswerDispute(cur, "vlk9", alice, whale)
		testing.SetRealm(testing.NewUserRealm(whale))
		OpenDispute(cross(cur), "vlk9", id)
		testing.SetRealm(testing.NewUserRealm(voter))
		VoteDispute(cross(cur), "vlk9", id, "no")

		// One row: this question. The previous rounds' rows were pruned by this
		// very vote, because their questions had resolved.
		if got := voteLockRows(c, voter); got != 1 {
			t.Fatalf("round %d: expected exactly 1 lock row after voting a single "+
				"open question, found %d — lockVote's prune is not running, so "+
				"rows accumulate one per vote for the address's whole life",
				round, got)
		}
		if VoteLockedOf("vlk9", voter) <= 0 {
			t.Fatalf("round %d: fixture is vacuous, nothing was committed", round)
		}

		testing.SkipHeights(c.params.votingBlocks + 1)
		testing.SetRealm(testing.NewUserRealm(whale))
		ResolveDispute(cross(cur), "vlk9", id)
		// Still one row, now dead — the prune happens on the NEXT vote, not on
		// resolution, because resolution is permissionless and must not be made to
		// pay for an unbounded sweep of everyone who voted.
		uassert.Equal(t, 1, voteLockRows(c, voter))
		uassert.Equal(t, int64(0), VoteLockedOf("vlk9", voter))
	}
}

// THE TWO EXPORTED FIGURES ANSWER DIFFERENT GATES, AND DisposableOf IS THE BINDING
// ONE.
//
// SpendableOf is stake-only — its name predates the vote lock — and every client had
// it while nothing exposed the figure the realm actually enforces on a bond, a
// deposit, a transfer or a wrap. This pins that they differ exactly when a holder has
// voted, that DisposableOf is what a transfer really allows to the unit, and that
// SpendableOf still answers its own question correctly for a stake.
func TestDisposableOfIsTheBindingFigureAndSpendableOfIsNot(cur realm, t *testing.T) {
	alice := testutils.TestAddress("vla-alice")
	whale := testutils.TestAddress("vla-whale")
	voter := testutils.TestAddress("vla-voter")
	c := testCourt(cur, "vlka", alice, 40_000_000_000)
	c.coin.Mint(whale, 60_000_000_000)
	c.coin.Mint(voter, 10_000_000_000)

	// Before voting the two agree, which is the bystander half: this change must not
	// move the figure for a holder who has not voted.
	uassert.Equal(t, SpendableOf("vlka", voter), DisposableOf("vlka", voter))

	id := stakeAnswerDispute(cur, "vlka", alice, whale)
	testing.SetRealm(testing.NewUserRealm(whale))
	OpenDispute(cross(cur), "vlka", id)
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteDispute(cross(cur), "vlka", id, "no")

	// Top up so a disposable remainder exists and the two figures are both positive
	// but unequal — otherwise this passes against a DisposableOf that returned zero.
	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "vlka", voter, 4_000_000_000)

	sp := SpendableOf("vlka", voter)
	dp := DisposableOf("vlka", voter)
	locked := VoteLockedOf("vlka", voter)
	if locked <= 0 || dp <= 0 || dp >= sp {
		t.Fatalf("fixture is vacuous: need a live vote lock and 0 < disposable < "+
			"spendable, got locked=%d disposable=%d spendable=%d", locked, dp, sp)
	}
	// SpendableOf still answers ITS question: the balance less the stake lock, which
	// is the whole balance here because nothing is staked.
	uassert.Equal(t, c.coin.BalanceOf(voter), sp)
	// And DisposableOf is the balance less the vote commitment.
	uassert.Equal(t, c.coin.BalanceOf(voter)-locked, dp)

	// DisposableOf is what a transfer actually allows, to the unit.
	testing.SetRealm(testing.NewUserRealm(voter))
	TransferCC(cross(cur), "vlka", whale, dp)
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferCC(cross(cur), "vlka", whale, 1)
	})
	// Whereas SpendableOf would have over-promised by exactly the commitment.
	uassert.Equal(t, locked, sp-dp)
}

// TestQualityLockReleasesWhenItsVoteCanNoLongerDecideAnything went with the quality lane: the quality lock is gone

// TestQualityLockHoldsWhenTheTallyCarriesIntoLaterRounds went with the quality lane: no tally carries between rounds

// NO LANE MAY STRAND A VOTER'S COIN BEHIND SOMEBODY ELSE'S ACTION.
//
// The vote lock is only defensible if the voter can always get their own coin back
// without depending on a counterparty who may have no reason to act. Resolution is
// permissionless in both of these lanes today, which is what makes that true — and it
// is exactly the kind of property a later "only the disputer may resolve" tidy-up would
// remove while every existing test stayed green, because every existing test resolves
// from a participant.
//
// The third lane is the exception and it is bounded rather than absent: a quality vote
// releases the moment it can no longer decide anything (see the release test above),
// but in the frozen-accumulating case it holds until the claim is terminal, and the
// route there — Finalize — is participant-only for finalizeGraceBlocks. Measured at
// roughly sixteen days. That asymmetry is deliberate: there the vote really is still
// deciding rounds.
//
// Each test pairs the refusal with the release, because a lane that refused everything
// would pass a release-only assertion trivially.
func TestAnElectionVoterCanFreeItsOwnCoin(cur realm, t *testing.T) {
	creator := testutils.TestAddress("vlsr-creator")
	opener := testutils.TestAddress("vlsr-opener")
	voter := testutils.TestAddress("vlsr-voter")
	newMod := testutils.TestAddress("vlsr-newmod")
	c := electionCourt(cur, "vlsr", creator,
		[]address{opener, voter}, []int64{600_000_000, 400_000_000})
	c.coin.Mint(opener, 50_000_000)

	testing.SetRealm(testing.NewUserRealm(opener))
	cand := RegisterModCandidate(cross(cur), "vlsr", 1, newMod)
	testing.SetRealm(testing.NewUserRealm(opener))
	OpenElection(cross(cur), "vlsr", cand)
	testing.SkipHeights(nominationWindow)

	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "vlsr", cand)
	held := c.coin.BalanceOf(voter)
	locked := VoteLockedOf("vlsr", voter)
	if locked <= 0 {
		t.Fatal("fixture is vacuous: approving committed nothing")
	}
	uassert.Equal(t, int64(0), disposable(c, voter))

	// THE BYSTANDER HALF: while the ballot is open the lock binds and resolution is
	// refused, so the release below is not the lane simply never holding anything.
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "voting window has not closed", func() {
		ResolveElection(cross(cur), "vlsr")
	})
	uassert.Equal(t, locked, VoteLockedOf("vlsr", voter))

	// And the voter resolves it THEMSELVES. No opener, no mod, no participant.
	testing.SkipHeights(c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(voter))
	ResolveElection(cross(cur), "vlsr")
	uassert.Equal(t, int64(0), VoteLockedOf("vlsr", voter))
	uassert.Equal(t, held, disposable(c, voter))
}
// TestADisputeVoterCanFreeItsOwnCoin went with the quality lane: its fixture was the counter lane; the dispute release rule is pinned by the tests above

// TestTheCounterLaneHoldsCoinAndItsRedundancyIsTheReasonWhy went with the quality lane: the counter lane is gone, and with it the redundant hold term it justified

// TestAnOrdinaryFlagVoteReleasesWhenTheFlagResolves went with the quality lane: there is no flag vote

// A RESOLVED ELECTION'S COMMITMENT MUST NOT SURVIVE INTO THE NEXT ONE.
//
// c.mod.election is a single pointer, so the lock row from election N is matched against
// whichever election is current. `e.seq == id` is what keeps a stale row from being read
// against a live ballot, and the term-by-term ablation found it unpinned: dropping it
// leaves `!e.resolved`, which the NEXT election satisfies, so a voter who voted once
// would be re-committed by every later election they took no part in.
func TestAResolvedElectionsCommitmentDoesNotSurviveIntoTheNext(cur realm, t *testing.T) {
	creator := testutils.TestAddress("vlq5-creator")
	opener := testutils.TestAddress("vlq5-opener")
	voter := testutils.TestAddress("vlq5-voter")
	modA := testutils.TestAddress("vlq5-moda")
	modB := testutils.TestAddress("vlq5-modb")
	c := electionCourt(cur, "vlq5", creator,
		[]address{opener, voter}, []int64{600_000_000, 400_000_000})
	c.coin.Mint(opener, 200_000_000)

	// Election one: the voter approves, and it resolves.
	testing.SetRealm(testing.NewUserRealm(opener))
	candA := RegisterModCandidate(cross(cur), "vlq5", 1, modA)
	testing.SetRealm(testing.NewUserRealm(opener))
	seqA := OpenElection(cross(cur), "vlq5", candA)
	testing.SkipHeights(nominationWindow)
	testing.SetRealm(testing.NewUserRealm(voter))
	ApproveCandidate(cross(cur), "vlq5", candA)
	if VoteLockedOf("vlq5", voter) <= 0 {
		t.Fatal("fixture is vacuous: approving committed nothing")
	}
	testing.SkipHeights(c.params.votingBlocks)
	testing.SetRealm(testing.NewUserRealm(voter))
	ResolveElection(cross(cur), "vlq5")
	uassert.Equal(t, int64(0), VoteLockedOf("vlq5", voter))

	// Election two opens, with the voter taking no part in it at all.
	// Only skip if a cooldown is actually pending. Measured the hard way: this
	// election leaves electionCooldownUntil at 0, so an unguarded
	// `cooldownUntil - heightNow()` is a large NEGATIVE SkipHeights, which walks the
	// chain backwards to epoch 1 and fails in grc20votes with "that epoch has not
	// been sealed yet" — a confusing error a long way from its cause.
	if d := c.mod.electionCooldownUntil - heightNow() + 1; d > 0 {
		testing.SkipHeights(d)
		touch(c)
	}
	testing.SetRealm(testing.NewUserRealm(opener))
	candB := RegisterModCandidate(cross(cur), "vlq5", 1, modB)
	testing.SetRealm(testing.NewUserRealm(opener))
	seqB := OpenElection(cross(cur), "vlq5", candB)
	if seqB == seqA {
		t.Fatal("fixture: the second election reused the sequence number, so a " +
			"stale row would match by seq and this test proves nothing")
	}
	if c.mod.election.resolved {
		t.Fatal("fixture: the second election is already resolved, so `!e.resolved` " +
			"is false and the seq term is not what is being tested")
	}

	// The stale row from election one must not be read against the live ballot.
	uassert.Equal(t, int64(0), VoteLockedOf("vlq5", voter))
	uassert.Equal(t, c.coin.BalanceOf(voter), disposable(c, voter))
}

// TestTheCommitmentIsTheLargestOpenRowNotTheLastOne went with the quality lane: its fixture needed TWO lanes open on one claim, and only the verdict lane remains — see the note below

// TestCommitmentsOfIsOneReadAndItsTotalIsAMaxNotASum went with the quality lane: same fixture, same reason
//
// A GAP THIS LEAVES, NAMED. Both tests pinned how voteLock AGGREGATES across
// several open rows: the commitment is the MAX of them, not the last one written
// and not their sum. That rule is still in the code and is still load-bearing —
// under-committing is the vote-then-sell rental the lock exists to price — but
// the only fixture that could open two rows on one claim used the verdict lane
// and the quality lane together.
//
// The verdict and ELECTION lanes can still both be open for one holder, so the
// property remains reachable; it needs a fixture that is not simply this one with
// the calls swapped, because an election needs a court shaped by electionCourt
// (sealed holders, no claims) and escrowsum_test.gno's header records that
// cramming both shapes into one fixture leaves each half contorted. Written up
// rather than quietly dropped so the next reader knows the rule is unpinned and
// not merely untested-because-trivial.

// A STRANGER COULD DESTROY A VOTER'S COMMITMENT WITH ONE PERMISSIONLESS CALL, and this
// is the regression.
//
// `address` is a bare string type with no length invariant, and nothing validated the
// `who` handed to PruneVoteLocks. So a caller passing "g1" prefix-matched EVERY holder's
// rows, voteLockParts rejected each one on length, voteLockOpen therefore returned false,
// and pruneVoteLocks removed all of them as stale. Probed on the shipped code before the
// fix: one call by a stranger dropped a voter's 10,000,000,000 commitment, and the voter
// then moved all of it after voting with it — the vote-then-sell rental this lock exists
// to price, reduced to a single call anyone could make.
//
// TWO HALVES, because either alone would have stopped it and neither should be the only
// thing standing there: PruneVoteLocks rejects a non-address, and the prune itself will
// not delete a row it cannot positively parse as this holder's — tested by calling the
// internal prune directly, past the guard.
//
// ONLY THE WRITE PATH WAS EVER EXPOSED, which is worth recording because the first read
// of this bug assumed otherwise and added guards to the reads too. Measured with no guard
// anywhere: a short or empty address returns VoteLockedOf 0, DisposableOf 0 and
// CommitmentsOf "stake:0;vote:0;free:0" while the real voter is committed 10,000,000,000.
// The reads were already safe for the SAME reason the prune was not — voteLockParts
// rejects a foreign row on length, so a reader skips it and the max stays zero, while the
// prune read that same rejection as "stale, delete". One check, opposite consequences.
// The read guards were removed again as redundant; the assertions below stay, because the
// property is worth pinning even though no guard is what holds it.
func TestAStrangerCannotPruneAwayACommitment(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sec-alice")
	whale := testutils.TestAddress("sec-whale")
	voter := testutils.TestAddress("sec-voter")
	attacker := testutils.TestAddress("sec-attacker")
	c := testCourt(cur, "sec", alice, 40_000_000_000)
	c.coin.Mint(whale, 60_000_000_000)
	c.coin.Mint(voter, 10_000_000_000)

	id := stakeAnswerDispute(cur, "sec", alice, whale)
	testing.SetRealm(testing.NewUserRealm(whale))
	OpenDispute(cross(cur), "sec", id)
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteDispute(cross(cur), "sec", id, "no")
	committed := VoteLockedOf("sec", voter)
	if committed <= 0 {
		t.Fatal("fixture is vacuous: nothing was committed to destroy")
	}

	// THE ATTACK, refused at the door.
	for _, bad := range []string{"g1", "", "g"} {
		testing.SetRealm(testing.NewUserRealm(attacker))
		uassert.AbortsContains(t, cur, "not a valid address", func() {
			PruneVoteLocks(cross(cur), "sec", address(bad))
		})
	}
	// THE SECOND HALF, past the guard: the prune itself refuses to delete a row it
	// cannot parse as this holder's.
	if n := pruneVoteLocks(c, address("g1")); n != 0 {
		t.Fatalf("the internal prune removed %d row(s) for a non-address; the "+
			"entry-point guard is then the only thing standing between a stranger "+
			"and every commitment in the court", n)
	}
	uassert.Equal(t, committed, VoteLockedOf("sec", voter))
	uassert.Equal(t, int64(0), disposable(c, voter))

	// And the coin still cannot move, which is the property the attack defeated.
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferCC(cross(cur), "sec", whale, committed)
	})

	// THE BYSTANDER: a real address still prunes, so the fix is a check and not a
	// wall. The voter's own row is live, so nothing is dropped; a resolved one is.
	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.Equal(t, 0, PruneVoteLocks(cross(cur), "sec", voter))
	testing.SkipHeights(c.params.votingBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(whale))
	ResolveDispute(cross(cur), "sec", id)
	testing.SetRealm(testing.NewUserRealm(attacker))
	uassert.Equal(t, 1, PruneVoteLocks(cross(cur), "sec", voter))

	// And a non-address gets nothing from the reads — zero, and a commitment line
	// with three zeros in it, never another holder's figures. No guard does this;
	// voteLockParts' length check does, by skipping every row it cannot parse.
	uassert.Equal(t, int64(0), VoteLockedOf("sec", address("g1")))
	uassert.Equal(t, int64(0), DisposableOf("sec", address("g1")))
	uassert.Equal(t, "stake:0;vote:0;free:0", CommitmentsOf("sec", address("g1")))
}
