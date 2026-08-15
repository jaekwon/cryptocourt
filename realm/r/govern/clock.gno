// Sorting keys, and nothing else.
//
// The clock moved to the ledger, which is what quantises history and so is the
// only thing that can answer what epoch it is. What is left here is the one
// encoding decision this realm makes for itself.
package govern

import (
	cford32 "gno.land/p/nt/cford32/v0"
)

// enc is a fixed-width, order-preserving key for a number that has to sort.
//
// Proposal ids are listed in order, so they cannot be decimal strings: "10"
// sorts before "9".
func enc(u uint64) string {
	b := cford32.PutUint64Lower(u)
	return string(b[:])
}
