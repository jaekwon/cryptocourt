package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// The transferable-coin surface: TransferCC, ApproveCC, TransferFromCC.
//
// Court coins were soulbound from V1 until 2026-08-20 and the whole design rested
// on it in places, so what these tests pin is not that a transfer works — that is
// three lines — but the four things that had to stay true for the change to be
// safe at all:
//
//  1. Committed capital cannot leave. spendable() is BalanceOf minus lockedOf,
//     and every one of the three entrypoints is gated on it (the allowance one on
//     the OWNER, not the spender). Without this a staker sells the coins backing
//     a live position and keeps both the proceeds and the position.
//  2. Conviction does not travel. It accrues on a claim position keyed
//     (address, side), so a buyer gets the future ability to earn it and none of
//     the seller's accrued integral. The whitepaper says accrued conviction is
//     not for sale; this is what makes that true rather than aspirational.
//  3. Voting power DOES travel, because it is a property of the balance. That is
//     the half of the change with teeth for governance and it is pinned here so
//     nobody has to infer it from grc20votes.
//  4. The escrow is not an endpoint. Bonds and deposits live there and are
//     disposed only by the lanes that own them.

// A transfer moves coin between holders and creates none.
func TestTransferMovesCoinAndConservesSupply(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tx-alice")
	bob := testutils.TestAddress("tx-bob")
	c := testCourt(cur, "tx1", alice, 10_000_000)

	supply := c.coin.TotalSupply()

	testing.SetRealm(testing.NewUserRealm(alice))
	TransferCC(cross(cur), "tx1", bob, 4_000_000)

	uassert.Equal(t, int64(6_000_000), c.coin.BalanceOf(alice))
	uassert.Equal(t, int64(4_000_000), c.coin.BalanceOf(bob))
	uassert.Equal(t, supply, c.coin.TotalSupply())
}

// THE LOAD-BEARING TEST. Staked coin stays put. Paired, as it must be, with the
// unstaked remainder that must still move — otherwise a TransferCC that refused
// everything would satisfy the first half.
func TestStakedCoinCannotBeTransferred(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tx-alice2")
	bob := testutils.TestAddress("tx-bob2")
	testCourt(cur, "tx2", alice, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "tx2", "Can staked coin be sold?")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "tx2", id, sideYES, 6_000_000_000)

	locked := LockedOf("tx2", alice)
	uassert.Equal(t, int64(6_000_000_000), locked)
	spend := SpendableOf("tx2", alice)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "not enough unstaked CC", func() {
		TransferCC(cross(cur), "tx2", bob, spend+1)
	})
	// Nothing moved on the refusal.
	uassert.Equal(t, int64(0), CoinBalanceOf("tx2", bob))

	// And the half that must succeed. Exactly spendable, so this also pins that
	// the boundary is inclusive: a holder can move everything not committed.
	testing.SetRealm(testing.NewUserRealm(alice))
	TransferCC(cross(cur), "tx2", bob, spend)
	uassert.Equal(t, spend, CoinBalanceOf("tx2", bob))
	uassert.Equal(t, locked, CoinBalanceOf("tx2", alice))
	uassert.Equal(t, int64(0), SpendableOf("tx2", alice))
}

// Conviction is not carried by the coin. Alice earns an integral, exits the
// position, and sells the coins; Bob holds the coins and none of the history.
//
// This is the property that keeps a market in court coin from being a market in
// settled reputation, and it holds for a structural reason rather than a checked
// one: conviction lives on stakePos, keyed (address, side), and a coin transfer
// touches only balances. Pinned anyway, because "structural" is exactly the kind
// of claim that quietly stops being true.
func TestConvictionDoesNotTravelWithTheCoin(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tx-alice3")
	bob := testutils.TestAddress("tx-bob3")
	testCourt(cur, "tx3", alice, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "tx3", "Does conviction follow the coin?")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "tx3", id, sideYES, 5_000_000_000)

	// Let the integral accumulate, then leave the position. Unstake is free and
	// KEEPS conviction — that is F9, and it is about the integral rather than
	// about principal — so alice's accrued conviction is real and still hers.
	testing.SkipHeights(1_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Unstake(cross(cur), "tx3", id, sideYES, 5_000_000_000)

	accrued := ConvictionOf("tx3", id, sideYES, alice)
	if accrued <= 0 {
		t.Fatal("fixture is vacuous: no conviction accrued, so nothing is " +
			"being shown not to travel")
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	TransferCC(cross(cur), "tx3", bob, 5_000_000_000)

	// Bob has the coins and none of the history, on either side.
	uassert.Equal(t, int64(5_000_000_000), CoinBalanceOf("tx3", bob))
	uassert.Equal(t, int64(0), ConvictionOf("tx3", id, sideYES, bob))
	uassert.Equal(t, int64(0), ConvictionOf("tx3", id, sideNO, bob))
	// And alice did not lose hers by selling.
	uassert.Equal(t, accrued, ConvictionOf("tx3", id, sideYES, alice))
}

// Voting power travels with the coin, because it is a property of the balance
// and not of the holder. Stated as a test rather than left to grc20votes, since
// this is the half of transferability that reaches governance: the quorum floor,
// both quality bars, the credential bar and the election floor are all counted
// against holdings, so coin changing hands changes who can clear them.
func TestVotingPowerTravelsWithTheCoin(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tx-alice4")
	bob := testutils.TestAddress("tx-bob4")
	c := testCourt(cur, "tx4", alice, 8_000_000)

	uassert.Equal(t, int64(8_000_000), c.coin.VotesOf(alice))
	uassert.Equal(t, int64(0), c.coin.VotesOf(bob))

	testing.SetRealm(testing.NewUserRealm(alice))
	TransferCC(cross(cur), "tx4", bob, 3_000_000)

	uassert.Equal(t, int64(5_000_000), c.coin.VotesOf(alice))
	uassert.Equal(t, int64(3_000_000), c.coin.VotesOf(bob))
}

// The escrow is not an endpoint, in either direction, on either entrypoint. It
// holds bonds and deposits that only the lanes owning them may dispose of, so a
// transfer naming it would either strand coin there or draw on somebody's bond.
func TestTheEscrowIsNotATransferEndpoint(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tx-alice5")
	c := testCourt(cur, "tx5", alice, 5_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "escrow is not a transfer endpoint", func() {
		TransferCC(cross(cur), "tx5", c.escrow, 1_000)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "escrow is not a transfer endpoint", func() {
		ApproveCC(cross(cur), "tx5", c.escrow, 1_000)
	})
	// Approving a non-escrow spender is the ordinary input it must not refuse.
	testing.SetRealm(testing.NewUserRealm(alice))
	ApproveCC(cross(cur), "tx5", testutils.TestAddress("tx-bob5"), 1_000)
	uassert.Equal(t, int64(1_000),
		AllowanceCC("tx5", alice, testutils.TestAddress("tx-bob5")))
}

// Self-transfer and non-positive amounts are refused. Cheap, and a zero or
// negative reaching the ledger is how a transfer becomes a mint.
func TestTransferRefusesNonsense(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tx-alice6")
	bob := testutils.TestAddress("tx-bob6")
	testCourt(cur, "tx6", alice, 5_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "cannot transfer to yourself", func() {
		TransferCC(cross(cur), "tx6", alice, 1_000)
	})
	// THE FULL MESSAGE, not the substring, and the difference is the whole
	// assertion. grc20votes has its own mustBePositive that panics "grc20votes:
	// amount must be positive", so "must be positive" alone is satisfied by
	// EITHER layer — and measured, it is: weakening this guard to `< 0` leaves a
	// zero-amount transfer still aborting, from the ledger, and this test still
	// passed. Naming the realm's own message is what makes it a test of the realm's
	// own guard. The guard is worth keeping despite the ledger's: it refuses before
	// touch(c) and it says which realm refused.
	for _, n := range []int64{0, -1, -5_000_000} {
		testing.SetRealm(testing.NewUserRealm(alice))
		uassert.AbortsContains(t, cur,
			"kourtv2: transfer amount must be positive", func() {
				TransferCC(cross(cur), "tx6", bob, n)
			})
	}
	uassert.Equal(t, int64(0), CoinBalanceOf("tx6", bob))
}

// An allowance is spent once and exactly, and it is spent by the spender against
// the OWNER's balance.
func TestAllowanceIsSpentOnceAgainstTheOwner(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tx-alice7")
	bob := testutils.TestAddress("tx-bob7")
	carol := testutils.TestAddress("tx-carol7")
	testCourt(cur, "tx7", alice, 9_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	ApproveCC(cross(cur), "tx7", bob, 4_000_000)
	uassert.Equal(t, int64(4_000_000), AllowanceCC("tx7", alice, bob))

	// Bob spends alice's coin to carol. Bob's own balance is zero throughout,
	// which is the point: the gate must read alice's, not bob's.
	uassert.Equal(t, int64(0), CoinBalanceOf("tx7", bob))
	testing.SetRealm(testing.NewUserRealm(bob))
	TransferFromCC(cross(cur), "tx7", alice, carol, 4_000_000)

	uassert.Equal(t, int64(5_000_000), CoinBalanceOf("tx7", alice))
	uassert.Equal(t, int64(4_000_000), CoinBalanceOf("tx7", carol))
	uassert.Equal(t, int64(0), CoinBalanceOf("tx7", bob))
	uassert.Equal(t, int64(0), AllowanceCC("tx7", alice, bob))

	// Consumed means consumed: the same approval cannot be drawn twice.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "allowance exceeded", func() {
		TransferFromCC(cross(cur), "tx7", alice, carol, 1)
	})
}

// An allowance never outranks a lock, and the gate reads the OWNER's spendable.
// This is the case a gate keyed on the spender would wave through, and the one
// that would let committed capital be sold via a wrapper or a pool.
func TestAnAllowanceDoesNotOutrankALock(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tx-alice8")
	bob := testutils.TestAddress("tx-bob8")
	carol := testutils.TestAddress("tx-carol8")
	testCourt(cur, "tx8", alice, 10_000_000_000)

	// Approve the FULL balance BEFORE staking, which is the realistic order: an
	// approval granted in good faith and then undercut by a later commitment.
	testing.SetRealm(testing.NewUserRealm(alice))
	ApproveCC(cross(cur), "tx8", bob, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "tx8", "Does an allowance beat a lock?")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "tx8", id, sideYES, 7_000_000_000)

	spend := SpendableOf("tx8", alice)
	// The allowance still reads full — approving does not reserve and does not
	// lock, and this records that a granted allowance is not available capital.
	uassert.Equal(t, int64(10_000_000_000), AllowanceCC("tx8", alice, bob))
	uassert.True(t, spend < 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "not enough unstaked CC", func() {
		TransferFromCC(cross(cur), "tx8", alice, carol, spend+1)
	})
	uassert.Equal(t, int64(0), CoinBalanceOf("tx8", carol))

	// The spendable part still moves, so the refusal above is the lock and not a
	// broken allowance.
	testing.SetRealm(testing.NewUserRealm(bob))
	TransferFromCC(cross(cur), "tx8", alice, carol, spend)
	uassert.Equal(t, spend, CoinBalanceOf("tx8", carol))
}

// Approving zero clears the allowance rather than recording a zero, and a
// negative is refused outright.
func TestApproveZeroClearsAndNegativeIsRefused(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tx-alice9")
	bob := testutils.TestAddress("tx-bob9")
	testCourt(cur, "tx9", alice, 5_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	ApproveCC(cross(cur), "tx9", bob, 2_000_000)
	uassert.Equal(t, int64(2_000_000), AllowanceCC("tx9", alice, bob))

	testing.SetRealm(testing.NewUserRealm(alice))
	ApproveCC(cross(cur), "tx9", bob, 0)
	uassert.Equal(t, int64(0), AllowanceCC("tx9", alice, bob))

	// Prefixed deliberately. The ledger underneath refuses a negative too, with
	// "grc20votes: negative allowance", so a substring assertion on "negative
	// allowance" alone passes with ApproveCC's own guard DELETED — measured, not
	// assumed. The guard is worth keeping for the message (every other refusal in
	// this realm is prefixed kourtv2:, and leaking the package name to a user is
	// an abstraction leak), so the assertion has to be the one that pins it.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "kourtv2: negative allowance", func() {
		ApproveCC(cross(cur), "tx9", bob, -1)
	})
}

// TransferFromCC refuses the same nonsense TransferCC does, so a caller cannot
// route around a guard by taking the allowance door.
func TestTransferFromRefusesTheSameNonsense(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tx-alice10")
	bob := testutils.TestAddress("tx-bob10")
	c := testCourt(cur, "tx10", alice, 5_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	ApproveCC(cross(cur), "tx10", bob, 5_000_000)

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "cannot transfer to yourself", func() {
		TransferFromCC(cross(cur), "tx10", alice, alice, 1_000)
	})
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "escrow is not a transfer endpoint", func() {
		TransferFromCC(cross(cur), "tx10", alice, c.escrow, 1_000)
	})
	testing.SetRealm(testing.NewUserRealm(bob))
	// The realm's message, not the substring the ledger's own guard also matches —
	// see the note in TestTransferRefusesNonsense.
	uassert.AbortsContains(t, cur,
		"kourtv2: transfer amount must be positive", func() {
			TransferFromCC(cross(cur), "tx10", alice, bob, 0)
		})
	uassert.Equal(t, int64(0), CoinBalanceOf("tx10", bob))

	// The ordinary spend it must not refuse.
	testing.SetRealm(testing.NewUserRealm(bob))
	TransferFromCC(cross(cur), "tx10", alice, bob, 1_000)
	uassert.Equal(t, int64(1_000), CoinBalanceOf("tx10", bob))
}

// AN ALLOWANCE CANNOT BE SPENT PAST A VOTE COMMITMENT.
//
// This is the bypass shape worth pinning: grant an allowance while your coin is
// free, vote (committing it), and have the spender pull the committed amount later.
// The grant happened when the coin was disposable and the pull happens when it is
// not, so nothing about the allowance itself is wrong — the gate has to be at the
// SPEND. TransferFromCC calls mustSpendable, which nets out the vote lock, so it is;
// this asserts it rather than leaving it to be read.
//
// tx8 above covers the same surface against the STAKE lock and nothing covered it
// against the vote lock, which matters because the two locks reach through different
// helpers: staking uses mustStakable and is deliberately exempt. A future change
// moving TransferFromCC to mustStakable — plausible reasoning, since the `from`
// party is not the caller — would silently open exactly this. check-epoch-coherence
// arm 6 catches that lexically by pinning mustStakable's single caller; this is the
// behavioural half, and a lexical guard wants one.
func TestAnAllowanceCannotOutrunAVoteCommitment(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tx11-alice")
	bob := testutils.TestAddress("tx11-bob")     // the spender
	carol := testutils.TestAddress("tx11-carol") // the recipient
	whale := testutils.TestAddress("tx11-whale") // authors and answers
	mkr := testutils.TestAddress("tx11-mkr")     // stakes, then opens the dispute
	c := testCourt(cur, "tx11", whale, 40_000_000_000)
	c.coin.Mint(whale, 60_000_000_000)
	c.coin.Mint(mkr, 20_000_000_000)
	c.coin.Mint(alice, 10_000_000_000)

	// The allowance is granted while every unit is free to move.
	testing.SetRealm(testing.NewUserRealm(alice))
	ApproveCC(cross(cur), "tx11", bob, 10_000_000_000)
	uassert.Equal(t, int64(10_000_000_000), AllowanceCC("tx11", alice, bob))

	// Then alice votes, which commits it. Three distinct roles: the author answers
	// and is therefore barred from disputing its own answer, so the staker opens it
	// and alice — party to neither — is the one who can vote.
	id := stakeAnswerDispute(cur, "tx11", whale, mkr)
	testing.SetRealm(testing.NewUserRealm(mkr))
	OpenDispute(cross(cur), "tx11", id)
	testing.SetRealm(testing.NewUserRealm(alice))
	VoteDispute(cross(cur), "tx11", id, "no")
	locked := VoteLockedOf("tx11", alice)
	if locked <= 0 {
		t.Fatal("fixture is vacuous: the vote committed nothing, so there is " +
			"nothing for the allowance to be refused against")
	}
	// The allowance still reads full: approving reserves nothing, which is the
	// whole reason the gate must live at the spend.
	uassert.Equal(t, int64(10_000_000_000), AllowanceCC("tx11", alice, bob))

	// And the spender is refused, naming the vote lock rather than the stake one.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferFromCC(cross(cur), "tx11", alice, carol, locked)
	})
	uassert.Equal(t, int64(0), CoinBalanceOf("tx11", carol))

	// PAIRED: the uncommitted remainder still moves, so the refusal above is the
	// lock and not a broken allowance. alice is topped up past her snapshot so a
	// disposable remainder exists at all.
	testing.SetRealm(testing.NewUserRealm(whale))
	TransferCC(cross(cur), "tx11", alice, 3_000_000_000)
	free := c.coin.BalanceOf(alice) - locked
	if free <= 0 {
		t.Fatalf("fixture is vacuous: no free remainder to move, balance %d "+
			"locked %d", c.coin.BalanceOf(alice), locked)
	}
	testing.SetRealm(testing.NewUserRealm(bob))
	TransferFromCC(cross(cur), "tx11", alice, carol, free)
	uassert.Equal(t, free, CoinBalanceOf("tx11", carol))

	// And one unit more is still refused: the bound is real, not an off-by-one.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "not enough uncommitted CC", func() {
		TransferFromCC(cross(cur), "tx11", alice, carol, 1)
	})
}
