package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// mustSpendable's whole job on a refusal is to name the constraint that actually
// binds, and it had four cases while the code had two. The two it was missing each
// told the holder something FALSE, which is worse than a vague message because a
// holder acts on it.
//
// NO LOCK AT ALL. disposable() is then just the balance, so the refusal means the
// balance is short — and the old code fell through to the stake wording and told a
// holder who has never staked that their stake was in the way. This is the most
// common refusal there is: any transfer for more than you hold.
//
// A TIE. disposable() subtracts the MAX of the two locks, not their sum, so when they
// are equal NEITHER is the constraint on its own: release the vote lock and the stake
// lock still holds the same number, and vice versa. Naming one of them implies that
// clearing it would free the coin, which is exactly wrong. The old code named the
// stake, because the vote-lock arm tested `>` and a tie fell through.
//
// The other two arms — only a stake lock, only a vote lock — were already right, and
// three tests assert the stake wording with a stake genuinely binding, so the case
// split had to keep them working rather than merge everything into one message.
func TestARefusalNamesTheLockThatBinds(cur realm, t *testing.T) {
	alice := testutils.TestAddress("lmsg-alice")
	bob := testutils.TestAddress("lmsg-bob")
	testCourt(cur, "lmsg", alice, 10_000_000_000)

	// ---- neither lock binds: the balance is simply short ----
	if LockedOf("lmsg", alice) != 0 || VoteLockedOf("lmsg", alice) != 0 {
		t.Fatal("setup: this arm needs a holder carrying no lock of either kind")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "none of your balance is staked or committed", func() {
		TransferCC(cross(cur), "lmsg", bob, 10_000_000_001)
	})
	// The ordinary transfer it must NOT refuse.
	testing.SetRealm(testing.NewUserRealm(alice))
	TransferCC(cross(cur), "lmsg", bob, 1_000_000)
	uassert.Equal(t, int64(1_000_000), CoinBalanceOf("lmsg", bob))

	// ---- only the stake lock binds ----
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "lmsg", "a claim to stake on")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "lmsg", id, sideYES, 4_000_000_000)
	if LockedOf("lmsg", alice) <= 0 || VoteLockedOf("lmsg", alice) != 0 {
		t.Fatalf("setup: this arm needs a stake lock and no vote lock, got %d and %d",
			LockedOf("lmsg", alice), VoteLockedOf("lmsg", alice))
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "not enough unstaked CC", func() {
		TransferCC(cross(cur), "lmsg", bob, SpendableOf("lmsg", alice)+1)
	})

	// ---- both bind, equally: the tie ----
	// Built like TestStakeAndVoteLocksOverlapRatherThanStack, with one number
	// changed: the voter stakes EXACTLY their sealed snapshot, so the stake lock and
	// the vote lock land on the same figure. The court is kept at the same size for
	// the same reason that test gives — effMinAnswerX is 10 bps of SUPPLY, and a
	// bigger court pushes the answerability floor above the fixture's X-bar.
	whale := testutils.TestAddress("lmsg-whale")
	author := testutils.TestAddress("lmsg-author")
	voter := testutils.TestAddress("lmsg-voter")
	c2 := testCourt(cur, "lmsg2", author, 40_000_000_000)
	c2.coin.Mint(whale, 10_000_000_000)
	c2.coin.Mint(voter, 10_000_000_000)

	disputed := stakeAnswerDispute(cur, "lmsg2", author, whale)
	testing.SetRealm(testing.NewUserRealm(author))
	other := OpenClaim(cross(cur), "lmsg2", "an unanswered claim to stake on")
	testing.SkipHeights(epochBlocks * 2)
	touch(c2)
	// After the seal, so the snapshot stays at 10B while the balance rises to 15B.
	// That gap is what leaves anything free once the locks bite.
	c2.coin.Mint(voter, 5_000_000_000)

	testing.SetRealm(testing.NewUserRealm(voter))
	Stake(cross(cur), "lmsg2", other, sideYES, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(whale))
	OpenDispute(cross(cur), "lmsg2", disputed)
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteDispute(cross(cur), "lmsg2", disputed, "no")

	vl, sl := VoteLockedOf("lmsg2", voter), LockedOf("lmsg2", voter)
	if vl != sl || vl <= 0 {
		t.Fatalf("setup: the tie arm needs the two locks EQUAL and positive, "+
			"vote=%d stake=%d", vl, sl)
	}
	free := c2.coin.BalanceOf(voter) - vl
	if free <= 0 {
		t.Fatalf("setup: the tie arm needs something still free, balance=%d locks=%d",
			c2.coin.BalanceOf(voter), vl)
	}
	// Everything free still moves, so the refusal below is the tie and not a
	// blanket refusal.
	testing.SetRealm(testing.NewUserRealm(voter))
	TransferCC(cross(cur), "lmsg2", whale, free)
	testing.SetRealm(testing.NewUserRealm(voter))
	uassert.AbortsContains(t, cur, "releasing either one on its own frees nothing", func() {
		TransferCC(cross(cur), "lmsg2", whale, 1)
	})
}
