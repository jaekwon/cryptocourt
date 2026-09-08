// PKGPATH: gno.land/r/kourt/ccostkourt
package ccostkourt

// WHAT A CLAIM COSTS TO STORE — the object this suite wrote most and measured
// never.
//
// HOW THE GAP WAS FOUND, because it is the kind that hides in a green gate.
// check-storage exists so "a gas regression fails the ordinary test run", and it
// does hold two kourtv2 filetests against ceilings. Three dead fields were then
// removed from claimState and BOTH figures came back byte-identical — 60360b and
// 44010b, not a byte moved. That is not a small saving, it is no measurement:
// grep OpenClaim in either file and the answer is zero. Neither one persists a
// claimState, so the struct written once per claim, carrying the deposit, the
// phase, four timestamps and four board indexes, had no cost coverage at all.
//
// The consequence is the exact regression class the gate's docstring names: a
// change that inflates a claim's stored size passed silently, and any claim
// about claim storage — a saving from dropping a field, the cost of adding one —
// could only be asserted, never shown.
//
// THREE CLAIMS, NOT ONE, and that is the point of the number. One claim would
// make a per-claim regression a third of the signal it is here: a field added to
// claimState moves this figure by three times its size, so a change too small to
// notice against one claim is visible against three. It is also why the ceiling
// below is deliberately close to the measurement rather than generous.
//
// SEEDED CLAIMS, because a filetest cannot hold coin. OpenClaim escrows a CC
// deposit plus a fee, and CC is only obtainable through Buy, which needs GNOT
// attached to the call — no filetest in this repo sends any, and there is no
// directive here that would. OpenClaimSeeded waives the deposit and the fee and
// is mod-only; the court's creator is its first moderator, so this caller
// qualifies. What that changes for a MEASUREMENT is nothing that matters: the
// waiver moves money, and claimState is persisted with the same shape either
// way. The one honest caveat is that a seeded claim records seeded=true and an
// author draw of zero, so this figure is the cost of a claim's STRUCTURE and
// not of a fully-funded claim's lifecycle.
//
// NOT FOLDED INTO z_events_filetest.gno, which already starts a court and had
// about 1.1kb of headroom left under its own ceiling. Mixing claim writes into
// a ceiling that also covers court creation and five mod-log verbs would mean a
// trip tells you less, not more — the existing comment there says the same
// thing about adding a fourth verb.

import (
	"gno.land/r/kourt/kourtv2"
)

func main(cur realm) {
	// The creator is the court's first moderator, which is what lets the seeded
	// verb through below.
	kourtv2.StartCourt(cross(cur), "ccost", "Claim Cost Court")

	// Titles of a deliberately ordinary length. A claim's title is stored, so a
	// one-character title would understate the object and a paragraph would
	// measure the string rather than the struct.
	a := kourtv2.OpenClaimSeeded(cross(cur), "ccost",
		"The first claim, of an ordinary length for a docket row")
	b := kourtv2.OpenClaimSeeded(cross(cur), "ccost",
		"The second claim, of an ordinary length for a docket row")
	c := kourtv2.OpenClaimSeeded(cross(cur), "ccost",
		"The third claim, of an ordinary length for a docket row")

	// Printed so the filetest fails loudly if the verb ever stops persisting —
	// a run that opened nothing would otherwise report a very cheap court and
	// read as an improvement.
	println("claims:", a, b, c)
	println("count:", kourtv2.ClaimCount("ccost"))
}

// Output:
// claims: 1 2 3
// count: 3
