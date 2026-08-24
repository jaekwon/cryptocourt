// PKGPATH: gno.land/r/kourt/readccwrap
package readccwrap

// ccwrap's read surface, exercised from OUTSIDE the package and budgeted at None
// in check-storage.py — it must write nothing at all.
//
// It did not exist, and its absence was the exact drift check-storage.py's own
// registry comment describes about kourtv2: "one realm hardcoded, which is how
// kourtv2 came to have no filetest at all and therefore no guard against the
// defect below". The coverage check there catches a realm that HAS a filetest
// with no budget entry. A realm with NO filetest is invisible to it, and ccwrap
// — which has six exported reads and two render routes — was that realm.
//
// The defect it guards against is a query that lazily ALLOCATES: the transitions
// are thrown away with the query, so the only symptom is storage that grows on
// reads, months later, under load. Two of those had already happened in kourtv2
// and both were found by hand.
//
// WHAT THIS DOES NOT COVER, stated so the None is not read as more than it is.
// WrappedSupply and Render(slug) both go through mustWrapped and panic unless a
// wrap exists, and enabling one is a WRITE — so those two reads cannot be
// reached by a file that writes nothing. WrapRoom is reachable because it never
// calls mustWrapped: it reads the court's votable supply and this realm's escrow
// balance directly. Covering the other two needs a second, writing filetest with
// a measured ceiling, which is not this file.
//
// A second boundary: the reads below cross into kourtv2, and storage is reported
// PER REALM. An allocation that happened inside kourtv2 on one of these calls
// would be attributed to kourtv2, not to the ccwrap line this file budgets.

import (
	"gno.land/r/kourt/ccwrap"
)

func main(cur realm) {
	// Nothing is enabled on a fresh deploy, because Enable is a write and this
	// file performs none. That is what the None budget means.
	println("enabled(meta):      ", ccwrap.Enabled("meta"))
	println("wrappable(meta):    ", ccwrap.WrappableSlug("meta"))
	println("wrappable(empty):   ", ccwrap.WrappableSlug(""))
	println("wrappable(11 chars):", ccwrap.WrappableSlug("abcdefghijk"))
	println("token key(meta):    ", ccwrap.TokenKey("meta"))
	println("wrap room(meta):    ", ccwrap.WrapRoom("meta"))
	println("front page renders: ", len(ccwrap.Render("")) > 0)
}

// Output:
// enabled(meta):       false
// wrappable(meta):     true
// wrappable(empty):    false
// wrappable(11 chars): false
// token key(meta):     gno.land/r/kourt/ccwrap.wMETA
// wrap room(meta):     0
// front page renders:  true
