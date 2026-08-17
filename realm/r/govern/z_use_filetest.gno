// PKGPATH: gno.land/r/kourt/usegovern
package usegovern

// Using the realm from outside it, which every other test in this package
// does not do.
//
// The unit tests live in package govern and reach its unexported state
// directly — they can set the minter, swap the electorate, and read the trees.
// None of that proves the exported surface works for somebody who only has the
// import path, which is the only way anybody will actually use this.
//
// It also checks the thing the design turns on: every argument here is a
// string, an address or an int64, because MsgCall converts nothing else. A
// signature that took a struct would compile, pass every unit test, and be
// uncallable from a transaction.

import (
	"chain/runtime"
	"testing"

	"gno.land/r/kourt/govern"
	testutils "gno.land/p/nt/testutils/v0"
)

func main(cur realm) {
	alice := testutils.TestAddress("f-alice")

	// A realm loaded with no deployer has no minter, and that is not a
	// curiosity — it is a dead realm, because without a minter there is no
	// supply, without supply no voting power, and without voting power no
	// proposal can appoint a minter. Printed rather than hidden: this file
	// exists to show what the outside sees, and this is what it sees here.
	println("minter is empty:", govern.Minter() == "")
	println("name:           ", govern.GetName())
	println("symbol:         ", govern.GetSymbol())
	println("decimals:       ", govern.GetDecimals())
	println("supply:         ", govern.TotalSupply())
	println("balance of a stranger:", govern.BalanceOf(alice))
	// The sixth of the six standard reads. It is exercised in the WRITE
	// filetest, which proves it answers — but this is the file budgeted to
	// write nothing at all, and without it Allowance is the one read in the
	// GRC20 surface never shown to be free of side effects.
	println("allowance of a stranger:", govern.Allowance(alice, alice))
	println("votes of a stranger:  ", govern.VotesOf(alice))
	println("delegate defaults to self:", govern.DelegateOf(alice) == alice)

	// The clock advances and the epoch with it, without anybody holding a
	// token — so the read surface works on an empty realm rather than
	// panicking on absent state.
	testing.SetHeight(runtime.ChainHeight() + 100000)
	println("epoch is past one:", govern.Epoch() > 1)
	println("nobody had votes: ", govern.PastVotes(alice, govern.Epoch()-1))

	// And the page renders, which is the surface a reader actually meets.
	println("page mentions the symbol:", len(govern.Render("")) > 0)
}

// Output:
// minter is empty: true
// name:            Cryptocourt Governance
// symbol:          COURT
// decimals:        6
// supply:          0
// balance of a stranger: 0
// allowance of a stranger: 0
// votes of a stranger:   0
// delegate defaults to self: true
// epoch is past one: true
// nobody had votes:  0
// page mentions the symbol: true
