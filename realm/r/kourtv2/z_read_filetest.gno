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

	// The m-of-n pending queue, both trees. PendingApproval is the newest read
	// in the realm and the one most likely to allocate by accident: it reaches
	// through c.mod and through globalDAO, each created lazily, and each with an
	// ensure* function sitting right beside the accessor it must NOT call.
	pa, pexp := kourtv2.PendingApproval("meta", "hide:1")
	println("pending approvals: ", pa, pexp)
	ga, gexp := kourtv2.PendingApproval("", "purge:meta:1")
	println("global pending:    ", ga, gexp)
	m, n := kourtv2.ModThreshold("meta")
	println("meta threshold:    ", m, n)

	// The escrow-share reads (v0.29). These are the only window onto whether a
	// court's dispute lane is reachable, so they must answer on an empty court
	// and must not allocate reaching for it.
	rawS, escS, votS := kourtv2.VotableSupply("meta")
	println("supply raw/esc/vot:", rawS, escS, votS)

	// The strips, and the franchise ledger.
	println("strip size:        ", kourtv2.DirectoryStripSize())
	println("stranger franchise:", kourtv2.FranchiseOf(stranger))
	// The standing reads, exercised on an address that has NEVER participated —
	// which is the case that would allocate if the read ever reached the
	// allocating accessor instead of its non-allocating twin. This filetest is
	// budgeted to write nothing, so that regression shows up here as a byte
	// count rather than as a green suite.
	println("stranger standing:", kourtv2.Standing("meta", stranger))
	println("stranger breakdown:", kourtv2.StandingBreakdown("meta", stranger))
	// The rate read, on a court that has never overridden — so it exercises the
	// inherit branch, which is the one that would allocate if the resolver ever
	// reached for an ensure* helper to materialise a default.
	println("meta rates:", kourtv2.CreditRates("meta"))

	// And the pages a reader actually meets. Render is the biggest read
	// surface in the realm and the one most likely to settle something.
	// THE BOARD LANE. Nineteen exported reads landed with the comment board and
	// none of them was in this file — so the STATIC purity census covered them
	// (check-read-purity greps for allocator names) and the DYNAMIC one did not.
	// The defect this file exists for is a read that lazily allocates, and the
	// board lane is where lazy allocation actually lives now: ensureKids,
	// ensureScoreIdx and ensureVoted were introduced deliberately, so a read
	// reaching one of them is a live possibility rather than a hypothetical.
	println("board codes:       ", kourtv2.BoardCodes() != "")
	// 0, and correctly: the meta court has no courtMod object until something
	// moderates it, and SpeechThreshold answers for that rather than allocating
	// one to find out. Allocating here is exactly the defect this file catches.
	println("meta speech thresh:", kourtv2.SpeechThreshold("meta"))
	println("meta ladder:       ", kourtv2.Ladder("meta") != "")
	println("meta pass price:   ", kourtv2.PassPrice("meta"))
	println("stranger has pass: ", kourtv2.HoldsPass("meta", stranger))
	println("stranger level:    ", kourtv2.PostLevel("meta", stranger))
	println("stranger per day:  ", kourtv2.PostsPerDay("meta", stranger))
	println("stranger available:", kourtv2.PostsAvailable("meta", stranger))
	println("stranger frozen:   ", kourtv2.BoardFrozenUntil("meta", stranger))

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
// pending approvals:  0 0
// global pending:     0 0
// meta threshold:     1 1
// supply raw/esc/vot: 0 0 0
// strip size:         0
// stranger franchise: 0
// stranger standing: 0
// stranger breakdown: score:0;highwater:0;flag:0;dispute:0;author:0;conviction:0
// meta rates: flag:10000;dispute:10000;author:2000;conviction:1000;unadjudicated:5000;inherited:1
// board codes:        true
// meta speech thresh: 0
// meta ladder:        true
// meta pass price:    0
// stranger has pass:  false
// stranger level:     0
// stranger per day:   0
// stranger available: 0
// stranger frozen:    0
// front page renders: true
// court page renders: true
