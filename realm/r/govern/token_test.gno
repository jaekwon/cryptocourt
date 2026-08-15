package govern

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

var (
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
	carol = testutils.TestAddress("carol")
)

// seal moves to a fresh epoch so the one just used can be queried.
//
// SetHeight rather than SkipHeights: SkipHeights builds a whole new context and
// resets OriginCaller, CurrentRealm and ChainID to zero
// (gnovm/tests/stdlibs/testing/context_testing.gno, SkipHeights), which silently
// unauthenticates whoever the test was acting as.
// Only SetHeight, deliberately. SkipHeights builds a fresh context and resets
// OriginCaller, CurrentRealm and ChainID
// (gnovm/tests/stdlibs/testing/context_testing.gno, SkipHeights), which silently
// unauthenticates whoever the test was acting as. And nothing that touches the
// realm override may live in a helper: SetRealm is keyed by FRAME INDEX, so
// from here it would land on this function's caller instead.
func seal(t *testing.T, epochs int64) {
	t.Helper()
	advanceEpochs(epochs)
}

// property an invariant rather than a convention.
func TestTheCurrentEpochCannotBeQueried(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	// PanicsContains, not AbortsContains: PastVotes is an ordinary read rather
	// than a crossing call, so its refusal is a plain panic. The two are not
	// interchangeable and the failure when you pick wrong is opaque.
	uassert.PanicsContains(t, cur, "has not been sealed", func() {
		PastVotes(alice, Epoch())
	})
}

// Delegation moves the say without moving the money.
func TestDelegationMovesPowerNotBalance(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = alice
	testing.SetRealm(testing.NewUserRealm(alice))
	Mint(cross(cur), carol, 500)

	testing.SetRealm(testing.NewUserRealm(carol))
	Delegate(cross(cur), bob)

	if got := BalanceOf(carol); got != 500 {
		t.Errorf("delegating moved carol's balance: %d, want 500", got)
	}
	if got := VotesOf(carol); got != 0 {
		t.Errorf("carol kept %d votes after delegating them away", got)
	}
	if got := VotesOf(bob); got < 500 {
		t.Errorf("bob has %d votes, want at least carol's 500", got)
	}

	// And back. Delegating to yourself is spelled the same way.
	Delegate(cross(cur), carol)
	if got := VotesOf(carol); got != 500 {
		t.Errorf("carol took her votes back and has %d, want 500", got)
	}
}

// incoming transfer at a time, without either party doing anything.
func TestReceivingWhileDelegatedCreditsTheDelegate(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = alice
	testing.SetRealm(testing.NewUserRealm(alice))
	Mint(cross(cur), carol, 100)

	testing.SetRealm(testing.NewUserRealm(carol))
	Delegate(cross(cur), bob)

	// Now somebody pays carol, who is not the one entitled to vote it.
	testing.SetRealm(testing.NewUserRealm(alice))
	Mint(cross(cur), alice, 60)
	Transfer(cross(cur), carol, 60)

	if got := BalanceOf(carol); got != 160 {
		t.Errorf("carol's balance is %d, want 160 — the tokens themselves "+
			"went astray, which is a different bug from the one this is for", got)
	}
	if got := VotesOf(carol); got != 0 {
		t.Errorf("carol holds %d votes after being paid while delegated, want "+
			"0 — her delegation lapsed the moment somebody sent her something", got)
	}
	if got := VotesOf(bob); got != 160 {
		t.Errorf("bob votes %d, want 160 — carol's delegate was credited for "+
			"what she held but not for what she was sent", got)
	}
}

// confident 0 is the difference between noticing that and not.
func TestEpochZeroIsNotAnEpoch(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = alice
	testing.SetRealm(testing.NewUserRealm(alice))
	Mint(cross(cur), alice, 500)
	seal(t, 1)

	uassert.PanicsContains(t, cur, "has not been sealed", func() {
		PastVotes(alice, 0)
	})
	uassert.PanicsContains(t, cur, "has not been sealed", func() {
		PastTotalVotes(0)
	})

	// And the epoch that DID happen answers, so the guard is a boundary rather
	// than a wall.
	//
	// Read as Epoch()-1 rather than as the literal 1: this suite's clock only
	// moves forward, so which epoch the mint above lands in depends on how many
	// tests ran first. Written as a literal it passed alone and failed in
	// company, which is the order-dependence that makes a test report on
	// something other than what it names.
	at := Epoch() - 1
	if got := PastVotes(alice, at); got != 500 {
		t.Errorf("alice at the last sealed epoch (%d) = %d, want 500", at, got)
	}
}

// The mint is a realm policy, not a ledger one.
//
// p/cryptocourt/grc20votes has no minter and cannot have one: who may create
// supply depends on who is calling, and a pure package has no caller. So the
// rule lives here, and these are the assertions that say the wiring holds.
func TestTheMintIsThisRealmsPolicyAndNotTheLedgers(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = alice

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "only the minter may mint", func() {
		Mint(cross(cur), bob, 100)
	})
	if got := TotalSupply(); got != 0 {
		t.Fatalf("a refused mint still moved the supply to %d", got)
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	Mint(cross(cur), bob, 100)
	if got := BalanceOf(bob); got != 100 {
		t.Errorf("the minter's mint credited %d", got)
	}

	// And with the mint given up there is no address that can present as the
	// minter, because the empty one can never sign.
	minter = ""
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "the supply is fixed", func() {
		Mint(cross(cur), bob, 1)
	})
}

// Not tested here: that every write refuses a stale realm.
//
// The guard is on all six, and on the governor's eight. What cannot be written
// is a test for it: the harness has no way to hand an entrypoint a realm value
// from a frame that has returned, because cross() is IsCurrent-strict and a
// function literal cannot take a realm argument under any name but `cur`. An
// assertion that cannot fail is worse than none, so there is not one.
//
// It is defence in depth rather than a live hole — see errStaleRealm — and the
// thing that actually holds it is that all fourteen entrypoints are one line
// each, checkable by reading.
