package grc20votes

import (
	"testing"

	"gno.land/p/nt/testutils/v0"
)

// mustPanic is uassert.PanicsWithMessage without the realm argument, which a
// /p/ test cannot supply: taking `cur realm` here would declare a crossing
// function, and a pure package may not have one.
func mustPanic(t *testing.T, want string, fn func()) {
	t.Helper()
	defer func() {
		r := recover()
		if r == nil {
			t.Errorf("expected a panic saying %q; nothing panicked", want)
			return
		}
		got, ok := r.(string)
		if !ok || got != want {
			t.Errorf("panicked with %v, want %q", r, want)
		}
	}()
	fn()
}

var (
	alice = testutils.TestAddress("lalice")
	bob   = testutils.TestAddress("lbob")
	carl  = testutils.TestAddress("lcarl")
)

// fresh is a ledger with nothing in it. Each test gets its own, which is the
// point of the package being instance-based: there is no package state to
// reset and so no order dependency to have.
func fresh() *Ledger { return NewLedger("Test Token", "TEST", 6, 720) }

// mint gets the supply into a sealed epoch, since every past-reading refuses
// the epoch it is in.
func mintAndSeal(t *testing.T, l *Ledger, who address, amount int64) uint32 {
	t.Helper()
	l.Mint(who, amount)
	at := l.Epoch()
	testing.SkipHeights(int64(720))
	return at
}

// Everyone's voting power sums to exactly the supply.
//
// This is the property that makes a quorum reachable, and OpenZeppelin cannot
// state it: getPastTotalSupply counts all supply while getPastVotes counts only
// DELEGATED supply, so the denominator exceeds the achievable numerator and a
// quorum is unreachable wherever few have delegated. Here delegation defaults
// to self, so the two agree by construction — and this is what says so.
//
// Asserted after every operation that moves power, because each of them is a
// separate chance to break it: a transfer that credits the wrong side, a mint
// that forgets the delegate, a burn that debits the holder rather than whoever
// votes for them.
func TestEveryonesPowerSumsToTheSupply(t *testing.T) {
	l := fresh()
	check := func(what string) {
		t.Helper()
		var sum int64
		l.accounts.Iterate("", "", func(_ string, v any) bool {
			sum += v.(*account).votes.Value()
			return false
		})
		if sum != l.TotalSupply() {
			t.Fatalf("after %s power sums to %d against a supply of %d",
				what, sum, l.TotalSupply())
		}
	}

	l.Mint(alice, 1000)
	check("a mint")
	l.Transfer(alice, bob, 400)
	check("a transfer")
	l.Delegate(bob, carl)
	check("a delegation")
	l.Transfer(alice, bob, 100)
	check("a transfer to a delegator")
	l.Burn(bob, 50)
	check("a burn by a delegator")
	l.Delegate(bob, bob)
	check("an undelegation")
	l.Approve(alice, bob, 200)
	l.TransferFrom(bob, alice, carl, 200)
	check("a transferFrom")
}

// An emptied allowance gives its key back.
//
// The alternative — leaving a zero behind — is a key per approval that ever
// existed, paid for forever, to record the same thing an absent key already
// says.
func TestAnEmptiedAllowanceHoldsNoKey(t *testing.T) {
	l := fresh()
	l.Mint(alice, 1000)

	l.Approve(alice, bob, 150)
	if !l.allowances.Has(string(alice) + sep + string(bob)) {
		t.Fatal("an approval recorded nothing")
	}
	l.TransferFrom(bob, alice, carl, 150)
	if got := l.Allowance(alice, bob); got != 0 {
		t.Errorf("allowance = %d after being spent out", got)
	}
	if l.allowances.Has(string(alice) + sep + string(bob)) {
		t.Error("an emptied allowance is still holding a key")
	}

	// And approving zero withdraws it the same way.
	l.Approve(alice, bob, 90)
	l.Approve(alice, bob, 0)
	if l.allowances.Has(string(alice) + sep + string(bob)) {
		t.Error("approving zero left the key behind")
	}
}

// Two ledgers in one program do not see each other.
//
// The whole reason this is a /p/ package with an allocated value rather than
// package state: a realm running several courts needs several coins, and a
// package-level ledger could only ever be one. Package state in /p/ is frozen
// after init in any case, so there was never a version of this that worked by
// accident.
func TestTwoLedgersAreIndependent(t *testing.T) {
	a, b := NewLedger("A", "AAA", 6, 720), NewLedger("B", "BBB", 2, 720)

	a.Mint(alice, 1000)
	b.Mint(alice, 7)

	if got := a.BalanceOf(alice); got != 1000 {
		t.Errorf("ledger A holds %d for alice, want 1000", got)
	}
	if got := b.BalanceOf(alice); got != 7 {
		t.Errorf("ledger B holds %d for alice, want 7 — the two share state", got)
	}
	if a.TotalSupply() == b.TotalSupply() {
		t.Error("both ledgers report the same supply")
	}
	if a.Symbol() == b.Symbol() || a.Decimals() == b.Decimals() {
		t.Error("the two ledgers share an identity")
	}
	// The ID especially, because it is what every emitted event is tagged
	// with: two ledgers reporting one id means an indexer sums both into one
	// balance sheet and neither is right.
	if a.ID() == b.ID() {
		t.Errorf("both ledgers tag their events %q", a.ID())
	}
	if a.ID() != "AAA" {
		t.Errorf("ledger A's id is %q, want its symbol", a.ID())
	}
	// And a realm that knows its own path can qualify it.
	a.SetID("gno.land/r/someone/court.AAA")
	if a.ID() != "gno.land/r/someone/court.AAA" {
		t.Errorf("SetID did not take: %q", a.ID())
	}
}

// A ledger refuses an identity it cannot render.
func TestALedgerNeedsAnIdentityAndAClock(t *testing.T) {
	mustPanic(t, "grc20votes: a token needs a name and a symbol", func() {
		NewLedger("", "X", 6, 720)
	})
	mustPanic(t, "grc20votes: a token needs a name and a symbol", func() {
		NewLedger("X", "", 6, 720)
	})
	mustPanic(t, "grc20votes: decimals must be between 0 and 18", func() {
		NewLedger("X", "X", 19, 720)
	})
	// An epoch of zero blocks divides by zero in Epoch(), which is a crash
	// rather than a refusal unless it is caught here.
	mustPanic(t, "grc20votes: an epoch has to be at least one block long", func() {
		NewLedger("X", "X", 6, 0)
	})
}

// The current epoch cannot be read, whichever way it is asked.
//
// This is the anti-flash-loan property, and it is an invariant rather than a
// convention: a transaction runs inside one block and a block inside one epoch,
// so refusing the epoch we are in refuses everything bought this transaction.
func TestTheCurrentEpochCannotBeQueried(t *testing.T) {
	l := fresh()
	l.Mint(alice, 1000)
	now := l.Epoch()

	mustPanic(t, "grc20votes: that epoch has not been sealed yet", func() {
		l.PastVotes(alice, now)
	})
	mustPanic(t, "grc20votes: that epoch has not been sealed yet", func() {
		l.PastTotal(now)
	})
	// Epoch zero is not an epoch: it is the sentinel for "before this existed".
	mustPanic(t, "grc20votes: that epoch has not been sealed yet", func() {
		l.PastVotes(alice, 0)
	})
}

// A balance acquired after an epoch sealed cannot vote in it.
func TestPastVotesIgnoreLaterBalances(t *testing.T) {
	l := fresh()
	at := mintAndSeal(t, l, alice, 1000)

	if got := l.PastVotes(alice, at); got != 1000 {
		t.Fatalf("alice had %d at the sealed epoch, want 1000", got)
	}
	if got := l.PastVotes(bob, at); got != 0 {
		t.Fatalf("bob had %d before he held anything, want 0", got)
	}

	l.Transfer(alice, bob, 400)
	if got := l.PastVotes(bob, at); got != 0 {
		t.Errorf("bob has %d at an epoch that sealed before he was paid — a "+
			"balance bought after the question was asked is voting on it", got)
	}
	if got := l.PastVotes(alice, at); got != 1000 {
		t.Errorf("alice has %d at the sealed epoch after sending some away; "+
			"selling out afterwards is supposed to cost nothing", got)
	}
	if got := l.PastTotal(at); got != 1000 {
		t.Errorf("the sealed supply reads %d, want 1000", got)
	}
}

// Power follows a delegation, and it is one hop rather than a chain.
func TestDelegationMovesPowerNotBalance(t *testing.T) {
	l := fresh()
	l.Mint(alice, 1000)
	l.Delegate(alice, bob)

	if got := l.BalanceOf(alice); got != 1000 {
		t.Errorf("delegating moved alice's balance: %d", got)
	}
	if got := l.VotesOf(alice); got != 0 {
		t.Errorf("alice still votes %d after delegating it away", got)
	}
	if got := l.VotesOf(bob); got != 1000 {
		t.Errorf("bob votes %d, want alice's 1000", got)
	}
	if got := l.DelegateOf(alice); got != bob {
		t.Errorf("DelegateOf says %s", got)
	}

	// One hop. bob delegating on does not carry alice's weight with it.
	l.Delegate(bob, carl)
	if got := l.VotesOf(carl); got != 0 {
		t.Errorf("carl votes %d — bob holds no balance of his own, so a "+
			"transitive walk is the only way this is non-zero", got)
	}
	if got := l.VotesOf(bob); got != 1000 {
		t.Errorf("bob votes %d after delegating his own nothing away; "+
			"alice's weight is supposed to stay with him", got)
	}

	// Self by default, and normalised so there is one representation of it.
	if got := l.DelegateOf(carl); got != carl {
		t.Errorf("an untouched address delegates to %s rather than itself", got)
	}
}

// Voting power cannot be driven below zero.
func TestVotingPowerCannotGoNegative(t *testing.T) {
	l := fresh()
	l.Mint(alice, 100)
	mustPanic(t, "grc20votes: insufficient balance", func() {
		l.Transfer(alice, bob, 101)
	})
	mustPanic(t, "grc20votes: insufficient balance", func() {
		l.Burn(alice, 101)
	})
	mustPanic(t, "grc20votes: insufficient balance", func() {
		l.Transfer(bob, alice, 1)
	})
}

// The supply cannot outgrow what a tally can weigh.
//
// Every threshold comparison multiplies by Bps, so a supply past MaxInt64/Bps
// wraps — and a wrapped tally goes negative rather than failing, which reports
// a won vote as lost. Refused at the mint, which is the only place it can be.
func TestTheSupplyCannotOutgrowTheTally(t *testing.T) {
	l := fresh()
	l.Mint(alice, MaxSupply)
	mustPanic(t,
		"grc20votes: supply would exceed what a tally can weigh without overflowing",
		func() { l.Mint(bob, 1) })

	// And the boundary is reachable rather than one short of it.
	if got := l.TotalSupply(); got != MaxSupply {
		t.Errorf("the supply stopped at %d rather than the %d it allows", got, MaxSupply)
	}
	if got := l.VotesOf(alice); got != MaxSupply {
		t.Errorf("alice votes %d at the ceiling", got)
	}
}

// The ledger refuses nonsense at the door.
func TestTheLedgerRefusesNonsense(t *testing.T) {
	l := fresh()
	l.Mint(alice, 1000)

	mustPanic(t, "grc20votes: not an address", func() {
		l.Transfer(alice, "not-an-address", 1)
	})
	mustPanic(t, "grc20votes: amount must be positive", func() {
		l.Transfer(alice, bob, 0)
	})
	mustPanic(t, "grc20votes: amount must be positive", func() {
		l.Transfer(alice, bob, -1)
	})
	mustPanic(t, "grc20votes: negative allowance", func() {
		l.Approve(alice, bob, -1)
	})
	mustPanic(t, "grc20votes: allowance exceeded", func() {
		l.TransferFrom(bob, alice, carl, 1)
	})
	mustPanic(t, "grc20votes: not an address", func() {
		l.Delegate(alice, "nope")
	})
}

// Self-delegating from nothing writes nothing.
//
// Everybody is self-delegated already, so a record here would buy a key to
// store a fact true of every address that has never existed.
func TestSelfDelegatingFromNothingWritesNothing(t *testing.T) {
	l := fresh()
	before := l.accounts.Size()
	l.Delegate(alice, alice)
	if got := l.accounts.Size(); got != before {
		t.Errorf("self-delegating from nothing opened %d account(s)", got-before)
	}

	// Naming somebody else DOES have to persist, for when the address is
	// funded later.
	l.Delegate(alice, bob)
	if got := l.accounts.Size(); got == before {
		t.Error("delegating to somebody else recorded nothing, so funding " +
			"alice later would credit the wrong account")
	}
	if got := l.DelegateOf(alice); got != bob {
		t.Errorf("DelegateOf says %s after delegating from an empty account", got)
	}
}

// seal moves the clock on by whole epochs, so a past-read has something sealed
// to answer from.
func seal(l *Ledger, n int64) { testing.SkipHeights(l.EpochBlocks() * n) }

// A holder's history is answerable at every epoch, not just the recent two.
//
// Two points live inline on the account record and the rest roll into the
// paged archive. Forty rounds is well past that, so the archive scan is
// exercised rather than answered from the inline slots.
func TestAHoldersHistoryIsAnswerableAtEveryEpoch(t *testing.T) {
	l := fresh()
	ann := testutils.TestAddress("hist-ann")
	ben := testutils.TestAddress("hist-ben")

	// One epoch with nobody in it, so there is always an epoch that predates
	// both holders wherever the clock happened to start.
	seal(l, 1)
	empty := l.Epoch() - 1

	const rounds = 40
	wantAnn := map[uint32]int64{}
	wantBen := map[uint32]int64{}

	for i := 0; i < rounds; i++ {
		// One epoch per round, and both holders move in every one, so each has
		// a checkpoint at every epoch rather than a sparse history the inline
		// slots could answer by luck.
		l.Mint(ann, 10)
		l.Mint(ben, 3)
		e := l.Epoch()
		wantAnn[e] = l.VotesOf(ann)
		wantBen[e] = l.VotesOf(ben)
		seal(l, 1)
	}

	for e, want := range wantAnn {
		if got := l.PastVotes(ann, e); got != want {
			t.Fatalf("ann at epoch %d = %d, want %d — the archive is not "+
				"answering for an epoch that rolled out of the inline slots",
				e, got, want)
		}
	}
	for e, want := range wantBen {
		if got := l.PastVotes(ben, e); got != want {
			t.Fatalf("ben at epoch %d = %d, want %d — one holder's scan read "+
				"another's history", e, got, want)
		}
	}

	// An epoch before either existed reads zero, not the neighbour's first
	// entry and not a panic.
	if got := l.PastVotes(ann, empty); got != 0 {
		t.Errorf("ann at epoch %d, before she existed = %d, want 0", empty, got)
	}
}

// Checkpointing does not charge per transfer, which is the economic claim the
// whole design rests on.
//
// Two halves. Repeated changes inside one epoch coalesce into a record already
// being written, so they add no keys; and history pages, so a long-lived
// holder buys one key per many checkpoints rather than one each.
func TestCheckpointingDoesNotPayPerTransfer(t *testing.T) {
	l := fresh()
	src := testutils.TestAddress("cost-src")
	dst := testutils.TestAddress("cost-dst")

	l.Mint(src, 100000)
	seal(l, 1)

	// Claim one: repeated changes inside a single epoch add no keys at all.
	// This is what makes an active trader cheap — the second and every later
	// move in an hour updates a record that was already being written.
	l.Transfer(src, dst, 1) // the first in this epoch, which may roll
	pagesBefore := l.archive.Size()
	accountsBefore := l.accounts.Size()
	for i := 0; i < 50; i++ {
		l.Transfer(src, dst, 1)
	}
	if got := l.archive.Size(); got != pagesBefore {
		t.Errorf("fifty transfers in one epoch added %d archive keys, want 0 — "+
			"same-epoch coalescing is not working and every trade is paying "+
			"for history nobody asked for", got-pagesBefore)
	}
	if got := l.accounts.Size(); got != accountsBefore {
		t.Errorf("fifty transfers between existing holders added %d account "+
			"keys, want 0", got-accountsBefore)
	}

	// Claim two: history costs one key per page of activity, not one per
	// checkpoint.
	pagesBefore = l.archive.Size()
	const epochs = int64(3 * 32) // three pages' worth, for both holders
	for i := int64(0); i < epochs; i++ {
		seal(l, 1)
		l.Transfer(src, dst, 1)
	}
	added := l.archive.Size() - pagesBefore
	written := int(2 * epochs)
	// Deliberately NOT expressed in terms of the page size. Dividing by that
	// constant on both sides means setting it to 1 — which is the whole
	// regression, one key per checkpoint — scales the expectation with the bug.
	// An assertion parameterised by the thing it is checking cannot fail.
	if added*8 > written {
		t.Errorf("%d checkpoints across %d epochs added %d archive keys — one "+
			"key is meant to buy many checkpoints, and this is close to buying "+
			"one each", written, epochs, added)
	}
	if added == 0 {
		t.Error("no archive keys at all after 96 epochs of changes, so this " +
			"test is not exercising the archive and proves nothing")
	}
}

// Redelegating to where the power already sits writes nothing.
func TestRedelegatingToTheSamePlaceWritesNothing(t *testing.T) {
	l := fresh()
	l.Mint(alice, 100)
	l.Delegate(alice, bob)
	seal(l, 1)

	pages := l.archive.Size()
	l.Delegate(alice, bob)
	if got := l.archive.Size(); got != pages {
		t.Errorf("redelegating to the same address added %d archive keys", got-pages)
	}
	if got := l.VotesOf(bob); got != 100 {
		t.Errorf("bob votes %d after a no-op redelegation", got)
	}
}

// Receiving while delegated credits the delegate, not the holder.
func TestReceivingWhileDelegatedCreditsTheDelegate(t *testing.T) {
	l := fresh()
	l.Mint(alice, 100)
	l.Delegate(bob, carl) // bob holds nothing yet, and still names carl
	l.Mint(bob, 40)

	if got := l.VotesOf(bob); got != 0 {
		t.Errorf("bob votes %d after being paid while delegated away", got)
	}
	if got := l.VotesOf(carl); got != 40 {
		t.Errorf("carl votes %d, want the 40 bob was paid", got)
	}
	if got := l.BalanceOf(bob); got != 40 {
		t.Errorf("bob holds %d — delegating moves power, not coins", got)
	}
}

// Burning moves the denominator a quorum is measured against.
//
// Minting checkpoints the supply and has a test for it. Burning checkpoints it
// too, and a test for the one is not a test for the other: delete the write on
// this side and a suite covering only mints stays green.
func TestBurningMovesTheDenominator(t *testing.T) {
	l := fresh()
	l.Mint(alice, 1000)
	seal(l, 1)
	before := l.Epoch() - 1

	l.Burn(alice, 400)
	seal(l, 1)
	after := l.Epoch() - 1

	if got := l.PastTotal(before); got != 1000 {
		t.Errorf("the supply before the burn reads %d, want 1000", got)
	}
	if got := l.PastTotal(after); got != 600 {
		t.Errorf("the supply after burning 400 of 1000 reads %d, want 600 — a "+
			"burn that does not checkpoint leaves every later proposal "+
			"measuring turnout against a supply that no longer exists", got)
	}
	if got := l.TotalSupply(); got != 600 {
		t.Errorf("the live supply reads %d after the burn", got)
	}
}

// mustBeValid and mustBePositive guard seven call sites between them and NO test
// exercised either with a rejected input. That matters beyond this package:
// kourtv2's claim.gno builds a security guard on the STATED behaviour of this one —
// its slashFlagger field carries a comment reasoning that "grc20votes.Mint calls
// mustBeValid and PANICS, so the entitlement is unpayable forever while reservedTail
// has already advanced", which is why v0.50 added a `slashFlagger != ""` check
// instead of falling back to cs.flagger. A consumer's money-path design resting on
// an untested validator in its dependency is exactly the coupling worth pinning.
//
// The zero address is the case that reaches kourtv2: an unset `address` field is "",
// which IsValid rejects.
//
// Mutation testing showed kourtv2's conclusion is ROBUST but its stated reason is
// over-specific: with mustBeValid deleted from Mint the call still panics, one layer
// down, as "checkpoint: a key may not be empty". So the unpayable-entitlement
// reasoning survives even if this guard moves — two layers reject it, not one. The
// same probe found the opposite for amounts: with mustBePositive deleted, a NEGATIVE
// mint is still caught deeper ("voting power would go negative") but a ZERO mint
// silently succeeds. mustBePositive is therefore the only thing rejecting zero, which
// is the case worth pinning here.
func TestInvalidAddressIsRejectedAtEveryEntryPoint(t *testing.T) {
	alice := testutils.TestAddress("gv-alice")
	l := fresh()
	l.Mint(alice, 1_000_000)

	var zero address // the unset field kourtv2 reasons about
	if zero.IsValid() {
		t.Fatal("premise: the zero address must be invalid")
	}

	// Mint — the site kourtv2's comment names.
	mustPanic(t, "grc20votes: not an address", func() { l.Mint(zero, 1) })
	// Transfer/move — the same guard on the recipient.
	mustPanic(t, "grc20votes: not an address", func() { l.Transfer(alice, zero, 1) })
	// Approve — the spender.
	mustPanic(t, "grc20votes: not an address", func() { l.Approve(alice, zero, 1) })
	// Delegate — the delegatee.
	mustPanic(t, "grc20votes: not an address", func() { l.Delegate(alice, zero) })

	// A rejected call must not have moved anything.
	if got := l.BalanceOf(alice); got != 1_000_000 {
		t.Fatalf("a rejected call must not move balances: %d", got)
	}
	if got := l.TotalSupply(); got != 1_000_000 {
		t.Fatalf("a rejected mint must not move supply: %d", got)
	}
}

// mustBePositive's three sites, same reasoning: zero and negative amounts must be
// refused, not silently applied. A negative mint would inflate a balance by
// subtracting, and a negative transfer would move value the wrong way.
func TestNonPositiveAmountsAreRejected(t *testing.T) {
	alice := testutils.TestAddress("gv2-alice")
	bob := testutils.TestAddress("gv2-bob")
	l := fresh()
	l.Mint(alice, 1_000_000)

	for _, amt := range []int64{0, -1, -1_000_000} {
		mustPanic(t, "grc20votes: amount must be positive", func() { l.Mint(bob, amt) })
		mustPanic(t, "grc20votes: amount must be positive", func() { l.Transfer(alice, bob, amt) })
	}
	if got := l.BalanceOf(bob); got != 0 {
		t.Fatalf("no rejected amount may reach a balance: %d", got)
	}
	if got := l.BalanceOf(alice); got != 1_000_000 {
		t.Fatalf("a rejected transfer must not debit the sender: %d", got)
	}
}
