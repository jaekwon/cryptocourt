package govern

import (
	governor "gno.land/p/cryptocourt/governor/v0"
)

// minterKind moves or gives up the power to mint.
//
//	govern:minter   "g1..."   hand it to that address
//	govern:minter   "none"    give it up permanently
//
// This closes the last unilateral power here. New supply is new voting power,
// so an unchecked minter can out-vote every holder at will and no proposal can
// stop them.
//
// The natural destination is the realm's own address, after which minting is a
// proposal. "none" is stronger: a fixed supply nobody can add to, which is a
// promise that cannot be made any other way, because there is nobody left to
// break it.
type minterKind struct{}

func (minterKind) Name() string { return governor.Reserved + "minter" }

func (minterKind) Describe(payload string) string {
	if payload == noMinter {
		return "give up the power to mint, permanently — the supply becomes fixed"
	}
	return "hand the power to mint to " + payload
}

func (minterKind) Check(payload string) error {
	if payload == noMinter {
		return nil
	}
	if !address(payload).IsValid() {
		return govErr("not an address, and not \"" + noMinter + "\"")
	}
	if address(payload) == minter {
		return govErr("that is already the minter")
	}
	return nil
}

func (minterKind) Do(_ int, rlm realm, payload string) error {
	if payload == noMinter {
		// The empty address can never sign, and Mint compares against it with
		// an equality that a caller cannot satisfy — cur.Previous().Address()
		// is always a real address.
		minter = ""
		return nil
	}
	// Unreachable, and kept. Execute runs Check immediately before Do, and
	// nothing between them changes whether a string parses as an address, so no
	// test can reach this line.
	//
	// Said plainly rather than left looking load-bearing. Kept anyway, because
	// batchKind.Do shows the general case does not hold: a batch member CAN
	// invalidate a later member's world.
	if !address(payload).IsValid() {
		return govErr("not an address")
	}
	minter = address(payload)
	return nil
}

// noMinter is spelled out rather than being an empty payload, so that giving
// up the supply forever cannot happen by sending a blank field.
const noMinter = "none"
