// PKGPATH: gno.land/r/kourt/readkourt
package readkourt

// The read surface, exercised from OUTSIDE the package — and budgeted, so that
// a read which starts writing fails the ordinary test run.
//
// Every other test in this realm lives in package kourtv2 and reaches the
// unexported state directly. None of them can see the defect this file exists
// for: a query that lazily ALLOCATES. Two of those were found by hand in one
// afternoon — five election reads calling ensureMod, and ensureClaimMod running
// before the m-of-n it was gated on — and both had the same shape govern's
// z_use_filetest was written to catch: the transitions are thrown away with the
// query, so the only symptom is storage that grows on reads, months later,
// under load. govern has had that guard since the beginning; kourtv2 had no
// filetest at all, which is why this one is budgeted in check-storage.go rather
// than merely passing.
//
// The meta court is the fixture: it is created at realm init, so the whole read
// surface can be walked without a single write from this file.

import (
	"gno.land/r/kourt/kourtv2"
	testutils "gno.land/p/nt/testutils/v0"
)

func main(cur realm) {
	stranger := testutils.TestAddress("fr-stranger")

	// The directory. One court exists — the review court, deployed at init.
	println("courts:            ", kourtv2.CourtCount())
	println("meta exists:       ", kourtv2.Exists("meta"))
	println("meta name:         ", kourtv2.CourtName("meta"))
	println("meta symbol:       ", kourtv2.CourtSymbol("meta"))
	println("claims on meta:    ", kourtv2.ClaimCount("meta"))
	// Empty here, and that is the honest reading rather than a bug: the meta
	// court is created at init from unsafe.OriginCaller(), and a filetest has
	// no deployer to be. On chain MsgAddPackage supplies one. govern's
	// z_use_filetest records the same condition about its minter. Printed
	// rather than hidden — this file exists to show what the outside sees.
	println("admin is set:      ", kourtv2.DirectoryAdmin() != "")
	println("burn sink is set:  ", kourtv2.BurnSink() != "")
	println("burned GNOT:       ", kourtv2.BurnedGNOT())

	// The coin and curve reads, on a court nobody has bought into.
	println("supply:            ", kourtv2.CoinSupply("meta"))
	println("curve position:    ", kourtv2.CurvePosition("meta"))
	println("stranger balance:  ", kourtv2.CoinBalanceOf("meta", stranger))
	println("emitted total:     ", kourtv2.EmittedTotal("meta"))
	println("court burn:        ", kourtv2.CourtBurnedGNOT("meta"))
	println("escrow is set:     ", kourtv2.CourtEscrow("meta") != "")

	// The moderation reads. These are the ones that were allocating: a court
	// with no moderation state must answer every one of them without creating
	// any, and a stranger must not be a moderator of a court that has no set.
	println("suspended:         ", kourtv2.CourtSuspended("meta"))
	println("purged:            ", kourtv2.CourtPurged("meta"))
	println("stranger is a mod: ", kourtv2.IsCourtMod("meta", stranger))
	println("folders:           ", kourtv2.FolderCount("meta"))

	// The election reads, which queried through ensureMod until recently.
	println("election open:     ", kourtv2.ElectionOpen("meta"))
	println("election cooldown: ", kourtv2.ElectionCooldownUntil("meta"))

	// The strips, and the franchise ledger.
	println("strip size:        ", kourtv2.DirectoryStripSize())
	println("stranger franchise:", kourtv2.FranchiseOf(stranger))

	// And the pages a reader actually meets. Render is the biggest read
	// surface in the realm and the one most likely to settle something.
	println("front page renders:", len(kourtv2.Render("")) > 0)
	println("court page renders:", len(kourtv2.Render("meta")) > 0)
}

// Output:
// courts:             1
// meta exists:        true
// meta name:          Review Court
// meta symbol:        META
// claims on meta:     0
// admin is set:       false
// burn sink is set:   true
// burned GNOT:        0
// supply:             0
// curve position:     0
// stranger balance:   0
// emitted total:      0
// court burn:         0
// escrow is set:      true
// suspended:          false
// purged:             false
// stranger is a mod:  false
// folders:            0
// election open:      false
// election cooldown:  0
// strip size:         0
// stranger franchise: 0
// front page renders: true
// court page renders: true
