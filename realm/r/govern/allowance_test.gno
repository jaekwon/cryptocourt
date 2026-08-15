package govern

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// The allowance surface, which is exported and had never been run.
//
// The interesting part is not the arithmetic, it is that voting power has to
// follow tokens moved by somebody who does not own them — and has to arrive at
// the OWNER'S delegate, not the spender's. Getting that wrong hands the say to
// whoever was authorised to move the money.
func TestAnAllowanceMovesVotingPowerToTheOwnersDelegate(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = alice
	owner := testutils.TestAddress("al-owner")
	spender := testutils.TestAddress("al-spender")
	taker := testutils.TestAddress("al-taker")
	proxy := testutils.TestAddress("al-proxy")

	testing.SetRealm(testing.NewUserRealm(alice))
	Mint(cross(cur), owner, 1000)

	// The owner delegates their say to a third party, then authorises a
	// spender to move the money. Two different people now hold two different
	// halves of what that balance means.
	testing.SetRealm(testing.NewUserRealm(owner))
	Delegate(cross(cur), proxy)
	Approve(cross(cur), spender, 400)

	if got := Allowance(owner, spender); got != 400 {
		t.Fatalf("allowance = %d, want 400", got)
	}
	if got := VotesOf(proxy); got != 1000 {
		t.Fatalf("the proxy holds %d votes, want 1000", got)
	}

	testing.SetRealm(testing.NewUserRealm(spender))
	TransferFrom(cross(cur), owner, taker, 250)

	if got := BalanceOf(owner); got != 750 {
		t.Errorf("owner balance = %d, want 750", got)
	}
	if got := BalanceOf(taker); got != 250 {
		t.Errorf("taker balance = %d, want 250", got)
	}
	// The say left the OWNER'S delegate, not the spender.
	if got := VotesOf(proxy); got != 750 {
		t.Errorf("the proxy holds %d votes, want 750 — power must follow the "+
			"owner's delegation, not the person authorised to move the money", got)
	}
	if got := VotesOf(spender); got != 0 {
		t.Errorf("the spender gained %d votes by moving somebody else's tokens", got)
	}
	if got := VotesOf(taker); got != 250 {
		t.Errorf("the taker holds %d votes, want 250", got)
	}

	// The allowance is spent down, not merely checked.
	if got := Allowance(owner, spender); got != 150 {
		t.Errorf("allowance after spending 250 of 400 = %d, want 150", got)
	}
	testing.SetRealm(testing.NewUserRealm(spender))
	uassert.AbortsContains(t, cur, "allowance exceeded", func() {
		TransferFrom(cross(cur), owner, taker, 151)
	})

	// Spending it exactly empties it rather than leaving a zero behind, which
	// is the difference between a key that costs storage forever and one that
	// is refunded.
	TransferFrom(cross(cur), owner, taker, 150)
	if got := Allowance(owner, spender); got != 0 {
		t.Errorf("allowance = %d after being spent out", got)
	}
	// Whether the emptied key is actually GIVEN BACK, and whether everyone's
	// power still sums to the supply, are the ledger's own properties. They are
	// asserted inside p/cryptocourt/grc20votes, which can see its own trees;
	// what belongs here is that this realm's entrypoints reach them correctly.
	//
	// The balances are the visible half of the same thing, so they are checked
	// here rather than taken on trust.
	// 250 then 150, so 400 in all — the whole allowance, spent in two goes.
	if got := BalanceOf(taker); got != 400 {
		t.Errorf("the taker holds %d of the 400 spent through the allowance", got)
	}
	if got := VotesOf(taker); got != 400 {
		t.Errorf("the taker votes %d after being paid 400", got)
	}
}

// Approving zero withdraws the authorisation rather than recording a zero.
func TestApprovingZeroWithdrawsIt(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = alice
	owner := testutils.TestAddress("az-owner")
	spender := testutils.TestAddress("az-spender")

	testing.SetRealm(testing.NewUserRealm(alice))
	Mint(cross(cur), owner, 10)
	testing.SetRealm(testing.NewUserRealm(owner))
	Approve(cross(cur), spender, 5)
	Approve(cross(cur), spender, 0)

	if got := Allowance(owner, spender); got != 0 {
		t.Errorf("a withdrawn allowance still reads %d", got)
	}
	testing.SetRealm(testing.NewUserRealm(spender))
	uassert.AbortsContains(t, cur, "allowance exceeded", func() {
		TransferFrom(cross(cur), owner, spender, 1)
	})
}

// Nobody can spend an allowance they were never given.
func TestAStrangerHasNoAllowance(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = alice
	owner := testutils.TestAddress("as-owner")
	stranger := testutils.TestAddress("as-stranger")

	testing.SetRealm(testing.NewUserRealm(alice))
	Mint(cross(cur), owner, 10)
	testing.SetRealm(testing.NewUserRealm(stranger))
	uassert.AbortsContains(t, cur, "allowance exceeded", func() {
		TransferFrom(cross(cur), owner, stranger, 1)
	})
	if got := BalanceOf(owner); got != 10 {
		t.Errorf("owner balance = %d, want 10", got)
	}
}
