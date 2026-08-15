// PKGPATH: gno.land/r/cryptocourt/holder
package holder

// A realm holding a position, writing to the token from outside it.
//
// The other two filetests read the realm and offer it a Kind. Neither writes to
// the ledger, because a filetest realm has no deployer and therefore no minter,
// so nothing can be minted and nothing can be voted — which is why the write
// surface has only ever been exercised from INSIDE package govern, where a test
// can assign the minter and reach the trees directly.
//
// Two entrypoints do not need a balance, and they are the two worth having from
// out here anyway:
//
//	Delegate — hand the say to somebody, holding nothing yet. The intent has to
//	           persist until there is something to move, which is exactly the
//	           case a realm treasury is in before it is funded.
//	Approve  — let another address spend from you, which needs no balance
//	           either, and which a realm doing anything financial will do.
//
// What this proves that no unit test can: that the caller identity a crossing
// write sees is the CALLING REALM's address, not a user's. A realm can hold
// tokens and act on them, which is the whole point of the token being a
// governance token rather than a wallet balance.

import (
	testutils "gno.land/p/nt/testutils/v0"
	"gno.land/r/cryptocourt/govern"
)

func main(cur realm) {
	// cur IS this realm, and it is what govern sees as the caller.
	me := cur.Address()
	agent := testutils.TestAddress("h-agent")
	spender := testutils.TestAddress("h-spender")

	// Before anything, a realm is self-delegated like everybody else.
	println("delegate starts as itself:", govern.DelegateOf(me) == me)

	// Hand the say away while holding nothing. This has to stick, or the
	// intent is lost the moment the treasury is funded.
	govern.Delegate(cross(cur), agent)
	println("delegated to the agent:   ", govern.DelegateOf(me) == agent)
	println("still holds nothing:      ", govern.BalanceOf(me))
	println("and votes nothing:        ", govern.VotesOf(me))

	// Take it back. Self is spelled the same way as anybody else.
	govern.Delegate(cross(cur), me)
	println("took the say back:        ", govern.DelegateOf(me) == me)

	// An allowance needs no balance either.
	govern.Approve(cross(cur), spender, 250)
	println("allowance granted:        ", govern.Allowance(me, spender))
	govern.Approve(cross(cur), spender, 0)
	println("allowance withdrawn:      ", govern.Allowance(me, spender))
}

// Output:
// delegate starts as itself: true
// delegated to the agent:    true
// still holds nothing:       0
// and votes nothing:         0
// took the say back:         true
// allowance granted:         250
// allowance withdrawn:       0
