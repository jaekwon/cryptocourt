package kourtv2

import (
	"strings"
	"strconv"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// The wedjat, and the two eyes nearest it in the block. Written as escapes for
// the same reason the constant is: at this size they are one picture.
const (
	tD010 = "\U00013080" // 𓂀 the mark — a set that opens SHOWN
	tD007 = "\U0001307C" // 𓁼 the other mark — a set that opens HIDDEN
	tD004 = "\U00013079" // 𓁹 an ordinary eye — NOT the mark
	tD006 = "\U0001307B" // another one
)

func TestSetTitleParsesOnlyTheExactMark(cur realm, t *testing.T) {
	name, _, ok := parseSetTitle(tD010 + " Lab leak evidence")
	uassert.True(t, ok)
	uassert.Equal(t, "Lab leak evidence", name)

	/* THE NEAR-MISSES, WHICH ARE THE POINT. These are indistinguishable from the
	   mark on screen, so if any of them parsed, a claim could look like a set to
	   a reader and not be one to the chain — or worse, the reverse. Each is
	   asserted separately rather than in a loop so a failure names the codepoint
	   that got through. */
	for _, bad := range []string{
		tD004 + " Lab leak",  // a different eye
		tD006 + " Lab leak",  // and another
		tD010 + "Lab leak",   // no delimiter: the mark is a prefix, not a first letter
		" " + tD010 + " Lab", // not at the start
		"mod:newset:x/1",  // the other prefix entirely
		"Lab leak " + tD010,  // the mark as decoration at the end
		tD010,                // the mark alone: no name
		tD010 + " ",          // ...and with an empty name
	} {
		if _, _, ok := parseSetTitle(bad); ok {
			t.Fatalf("a near-miss parsed as a set heading: %q", bad)
		}
	}
}

// The name is the rest of the title VERBATIM. If this ever starts trimming, the
// set's name and the claim's title stop matching, which is the one thing the
// feature promises.
func TestSetNameIsTheTitleVerbatim(cur realm, t *testing.T) {
	name, _, ok := parseSetTitle(tD010 + "  two leading spaces")
	uassert.True(t, ok)
	uassert.Equal(t, " two leading spaces", name)

	// ...and a name too long for a folder is not a set heading at all, rather
	// than a set heading that panics later inside the execution.
	long := ""
	for i := 0; i < maxFolderTextLen+1; i++ {
		long += "x"
	}
	if _, _, ok := parseSetTitle(tD010 + " " + long); ok {
		t.Fatal("an over-long name must not parse as a set heading")
	}
}

/* ABLATED, each guard in governedset.gno removed in turn against a control run
   that fails nothing. Recorded as measured, including the one that does not look
   like the others:
     - exactly-once guard      -> TestASettledMarkedClaimBecomesASet fails.
     - name-taken re-check     -> TestAffirmRefusesANameTakenSinceTheClaimOpened.
     - exact-mark parse (made  -> TestSetTitleParsesOnlyTheExactMark AND
       it split on any space)     TestAnUnmarkedClaimIsNeverASet, which is the
                                  pair that matters: one proves near-misses are
                                  refused, the other that ordinary claims are.
     - the retired-parent      -> TestASetIsNotBornUnderARetiredParent, and it was
       guard (step 6)              written RED-FIRST rather than ablated after the
                                   fact: the guard did not exist, so the shipped
                                   source WAS the mutant. It failed 14 ok / 3 FAIL
                                   with "this claim already carries set 2" — the
                                   affirm having succeeded and built a live folder
                                   under a retired one, which is the defect stated
                                   as an error message.
     - ClaimSet made to SKIP   -> TestRetiringABornSetDoesNotFreeTheClaim, and it
       retired rows, matching      dies the second way too: the mutant lets bob's
       folderNameTaken             re-carry SUCCEED, so a live folder takes the
                                   name, and the fresh claim at the end of that
                                   test then aborts UNCAUGHT with "a folder by
                                   that name already exists". Red either way, and
                                   the second failure is the consequence spelled
                                   out — one claim, two live folders.
     - the provClose HALF of   -> NOTHING FAILED, until TestAProvClosedYesCarries-
       the final-YES check         NoSet. Removing the whole `if` is caught (see
                                   below); removing only `|| cs.provClose` was
                                   not, and the two are different mutations. A
                                   guard ablated only as part of a larger
                                   expression is not measured.
     - the final-YES check     -> the suite goes red at rc=2, but as an UNCAUGHT
                                  ABORT with a VM state dump inside this test,
                                  not a clean "--- FAIL" line. Without the check,
                                  New runs on a claim that never settled
                                  and dies deeper in the folder machinery. It is
                                  covered — the suite cannot pass — but a grep
                                  for "--- FAIL" does NOT see it, which is worth
                                  knowing before anyone trusts such a grep to
                                  measure this file.
*/

// THE WHOLE ROUTE: an ordinary claim, marked, staked, answered, settled — and
// only then a set.
func TestASettledMarkedClaimBecomesASet(cur realm, t *testing.T) {
	alice := testutils.TestAddress("gs-alice")
	testCourt(cur, "gs1", alice, 50_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "gs1", tD010+" Lab leak evidence")

	// NOTHING YET. The mark is a request, not an authority: a claim that made a
	// set at open would hand every holder the moderator power this is gated by.
	uassert.True(t, IsSetClaim("gs1", id))
	uassert.Equal(t, uint64(0), ClaimSet("gs1", id))
	uassert.Equal(t, 0, FolderCount("gs1"))

	// ...and it cannot be carried before it settles.
	uassert.AbortsContains(t, cur, "no final verdict", func() {
		New(cross(cur), "gs1", id)
	})

	matureOI(cur, "gs1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "gs1", id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "gs1", id)

	// PERMISSIONLESS: the verdict is the authority. bob is nobody here.
	bob := testutils.TestAddress("gs-bob")
	testing.SetRealm(testing.NewUserRealm(bob))
	fid := New(cross(cur), "gs1", id)
	uassert.True(t, fid != 0)
	uassert.Equal(t, "Lab leak evidence", FolderName("gs1", fid))
	uassert.Equal(t, 1, FolderCount("gs1"))

	// The binding, both ways.
	uassert.Equal(t, fid, ClaimSet("gs1", id))
	uassert.Equal(t, id, SetBornOf("gs1", fid))

	// AND IT IS IN THE TREE ROW, which is where a client actually reads it.
	// SetBornOf answering correctly is not the same claim: the row is what a map
	// draw parses, and it carried nothing until the field moved there — one
	// SetBornOf per folder, a hundred at the cap, for a per-folder bit. Asserted
	// on an AFFIRMED set because every other FolderTree test in this repo makes
	// its folders by hand, so all of them pin the zero and none pins this.
	// "f", because this set was filed with 𓂀: it is ticked when a reader arrives.
	uassert.Equal(t, "1:0:f:"+strconv.FormatUint(id, 10), FolderTree("gs1"))

	// EXACTLY ONCE. Without this anyone re-calls it until the court hits its
	// folder cap.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "already carries set", func() {
		New(cross(cur), "gs1", id)
	})
	uassert.Equal(t, 1, FolderCount("gs1"))
}

// A settled NO carries nothing. The court was asked and said no.
func TestASettledNoCarriesNoSet(cur realm, t *testing.T) {
	alice := testutils.TestAddress("gsn-alice")
	testCourt(cur, "gsn1", alice, 50_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "gsn1", tD010+" Rejected heading")
	matureOI(cur, "gsn1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "gsn1", id, sideNO)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "gsn1", id)

	uassert.AbortsContains(t, cur, "was not YES", func() {
		New(cross(cur), "gsn1", id)
	})
	uassert.Equal(t, 0, FolderCount("gsn1"))
	uassert.Equal(t, uint64(0), ClaimSet("gsn1", id))
}

// An UNMARKED claim is not a set however it settles — otherwise every settled
// YES in the court would be a folder.
func TestAnUnmarkedClaimIsNeverASet(cur realm, t *testing.T) {
	alice := testutils.TestAddress("gsu-alice")
	testCourt(cur, "gsu1", alice, 50_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "gsu1", "An ordinary claim that settles YES")
	matureOI(cur, "gsu1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "gsu1", id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "gsu1", id)

	uassert.False(t, IsSetClaim("gsu1", id))
	uassert.AbortsContains(t, cur, "not a set heading", func() {
		New(cross(cur), "gsu1", id)
	})
	uassert.Equal(t, 0, FolderCount("gsu1"))
}

/* THE NAME TAKEN IN BETWEEN. Weeks pass between opening a claim and carrying it,
   and an ordinary CreateFolder can take the name in that window. The refusal is
   the interesting behaviour: the alternative is two live folders sharing a name,
   which every read that resolves by name would then answer wrongly. */
func TestAffirmRefusesANameTakenSinceTheClaimOpened(cur realm, t *testing.T) {
	alice := testutils.TestAddress("gst-alice")
	testCourt(cur, "gst1", alice, 50_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "gst1", tD010+" Contested name")
	matureOI(cur, "gst1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "gst1", id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "gst1", id)

	// alice is the court's founding moderator; she files it by hand first.
	testing.SetRealm(testing.NewUserRealm(alice))
	CreateFolder(cross(cur), "gst1", "Contested name", "got there first")

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "already exists", func() {
		New(cross(cur), "gst1", id)
	})
	// ...and the hand-made one is untouched and unbound.
	uassert.Equal(t, 1, FolderCount("gst1"))
	uassert.Equal(t, uint64(0), SetBornOf("gst1", 1))
	uassert.Equal(t, uint64(0), ClaimSet("gst1", id))
}

/* THE PARENT COMES FROM THE CLAIM'S OWN FILING, which is the whole of how a
   SUBSET is expressible: the title carries the name and has no room for a path.
   Three arms, because the rule has three cases and only one of them is the
   happy one — and the refusal is the interesting one, since a claim may be
   filed in any number of sets and "the parent" is only defined when there is
   exactly one. */
func TestABornSetNestsWhereItsClaimIsFiled(cur realm, t *testing.T) {
	alice := testutils.TestAddress("gsp-alice")
	testCourt(cur, "gsp1", alice, 50_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	parent := CreateFolder(cross(cur), "gsp1", "Origins", "where it began")

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "gsp1", tD010+" Furin cleavage site")
	// FILED FIRST, and that filing is what declares the parent.
	testing.SetRealm(testing.NewUserRealm(alice))
	AddToFolder(cross(cur), "gsp1", parent, id)

	matureOI(cur, "gsp1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "gsp1", id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "gsp1", id)

	testing.SetRealm(testing.NewUserRealm(alice))
	fid := New(cross(cur), "gsp1", id)
	uassert.Equal(t, parent, FolderParent("gsp1", fid))
	uassert.Equal(t, "Furin cleavage site", FolderName("gsp1", fid))
}

// Filed nowhere, born at the root — the case every set in the seed's first
// generation takes, and the one that must not start nesting by accident.
func TestAnUnfiledSetClaimIsBornAtTheRoot(cur realm, t *testing.T) {
	alice := testutils.TestAddress("gsr-alice")
	testCourt(cur, "gsr1", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "gsr1", tD010+" A root heading")
	matureOI(cur, "gsr1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "gsr1", id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "gsr1", id)
	testing.SetRealm(testing.NewUserRealm(alice))
	fid := New(cross(cur), "gsr1", id)
	uassert.Equal(t, uint64(0), FolderParent("gsr1", fid))
}

/* FILED IN TWO IS A REFUSAL. A claim may belong to any number of sets — that is
   why ClaimFolders returns a slice — so picking one would make the tree depend
   on iteration order: stable until the day it is not. The claim keeps its
   filings and carries no set, so nothing is half-done. */
func TestASetClaimFiledTwiceRefusesToBeBorn(cur realm, t *testing.T) {
	alice := testutils.TestAddress("gsa-alice")
	testCourt(cur, "gsa1", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	a := CreateFolder(cross(cur), "gsa1", "Origins", "one")
	testing.SetRealm(testing.NewUserRealm(alice))
	b := CreateFolder(cross(cur), "gsa1", "Fauci", "two")

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "gsa1", tD010+" Ambiguous parent")
	testing.SetRealm(testing.NewUserRealm(alice))
	AddToFolder(cross(cur), "gsa1", a, id)
	testing.SetRealm(testing.NewUserRealm(alice))
	AddToFolder(cross(cur), "gsa1", b, id)

	matureOI(cur, "gsa1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "gsa1", id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "gsa1", id)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "more than one set", func() {
		New(cross(cur), "gsa1", id)
	})
	uassert.Equal(t, uint64(0), ClaimSet("gsa1", id))
	uassert.Equal(t, 2, FolderCount("gsa1"))   // the two it was filed in, and no third
}

// A moderator's ordinary folder has no claim behind it. This is what stops
// SetBornOf being read as "every folder came from somewhere".
func TestAModeratorFolderIsBornOfNothing(cur realm, t *testing.T) {
	alice := testutils.TestAddress("gsm-alice")
	testCourt(cur, "gsm1", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	fid := CreateFolder(cross(cur), "gsm1", "Hand filed", "by a moderator")
	uassert.Equal(t, uint64(0), SetBornOf("gsm1", fid))
}

/* ABLATED, against a control that fails nothing:
     - open but never file (drop fileInto)  -> 2: the filing test and the
       no-power test, which asserts the set holds exactly bob's one claim.
     - drop the retired guard               -> 1: the retired test alone.
     - ungate AddToFolder itself            -> 2: the no-power test, plus
       TestFolderSuspensionRefuses, which is the moderator gate's own arm — the
       right pair, since that ablation removes exactly one thing and both tests
       depend on it.
   THE FIRST RUN OF THE FIRST ABLATION REPORTED ZERO, and the instrument was at
   fault, not the test: the runner's grep filtered test names to Set|Born|Affirm
   and TestOpenClaimInFilesTheClaimItOpens matches none of those, so its failure
   was invisible rather than absent. A filtered runner cannot be used to measure
   whether a test fires; the second pass greps every line.

FILING AT OPEN, UNGATED NARROWLY. A set page offered "Open a claim" and then
   had to admit a moderator would file it here later; OpenClaimIn closes that.
   What matters is the SHAPE of the ungating, so each arm below is one of the
   limits rather than one of the happy paths: an author files the claim they are
   opening, into one live set, under the same cap a moderator obeys — and gains
   no power over anything else. */
func TestOpenClaimInFilesTheClaimItOpens(cur realm, t *testing.T) {
	alice := testutils.TestAddress("oci-alice")
	c := testCourt(cur, "oci1", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	fid := CreateFolder(cross(cur), "oci1", "Origins", "where it began")

	// NOT A MODERATOR. bob is the whole point: the old path needed the bit.
	// FUNDED, because opening a claim costs a deposit and a fee — the same cost
	// that keeps this ungating from being a spam faucet. An unfunded bob fails
	// on the money, which proves the cost exists but not the filing.
	bob := testutils.TestAddress("oci-bob")
	c.coin.Mint(bob, 5_000_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	id := OpenClaimIn(cross(cur), "oci1", fid, "A claim of fact.", "what would settle it")

	uassert.Equal(t, 1, len(FolderItems("oci1", fid)))
	uassert.Equal(t, id, FolderItems("oci1", fid)[0])
	uassert.Equal(t, 1, len(ClaimFolders("oci1", id)))
	// ...and the claim is bob's, not the moderator's.
	uassert.Equal(t, bob, ClaimAuthor("oci1", id))
}

// A RETIRED SET IS UNREACHABLE, so filing into one would strand the claim
// somewhere no reader can browse to.
func TestOpenClaimInRefusesARetiredSet(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ocr-alice")
	c := testCourt(cur, "ocr1", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	fid := CreateFolder(cross(cur), "ocr1", "Gone", "retired below")
	testing.SetRealm(testing.NewUserRealm(alice))
	RetireFolder(cross(cur), "ocr1", fid)

	bob := testutils.TestAddress("ocr-bob")
	c.coin.Mint(bob, 5_000_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "retired", func() {
		OpenClaimIn(cross(cur), "ocr1", fid, "A claim of fact.", "")
	})
}

/* THE UNGATING DOES NOT LEAK. Opening into a set must not hand an author the
   moderator's verb: bob may file the claim he is creating and still cannot file
   an EXISTING claim — his own or anyone's — into any set. That is the line
   between "open it where I am reading" and "curate this court". */
func TestOpenClaimInGivesNoPowerOverOtherClaims(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ocl-alice")
	c := testCourt(cur, "ocl1", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	fid := CreateFolder(cross(cur), "ocl1", "Origins", "")

	bob := testutils.TestAddress("ocl-bob")
	c.coin.Mint(bob, 5_000_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	mine := OpenClaimIn(cross(cur), "ocl1", fid, "Bob's own claim.", "")
	testing.SetRealm(testing.NewUserRealm(bob))
	other := OpenClaim(cross(cur), "ocl1", "A separate claim nobody filed.")

	// His own, already open: still a moderator's call.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "moderator", func() {
		AddToFolder(cross(cur), "ocl1", fid, other)
	})
	uassert.Equal(t, 1, len(FolderItems("ocl1", fid)))
	uassert.Equal(t, mine, FolderItems("ocl1", fid)[0])
}

/* A CLAIM CLOSED WITHOUT A DECISION CARRIES NOTHING, and this is the one guard
 * of New's five that reads as redundant and is not.
 *
 * THE PAIR IS LOAD-BEARING BECAUSE OF ONE CONSTANT: sideYES = 0. provCloseClaim
 * STAMPS verdictAt — the claim really is over — and leaves `provisional` holding
 * the answer that never got a vote behind it. So a claim answered YES and then
 * closed after three failed rounds has verdictAt != 0 AND provisional == 0, which
 * is byte-for-byte the state a settled YES leaves. Neither of New's other
 * two verdict checks can tell them apart; only `cs.provClose` can, and the court
 * in this story never decided anything — three rounds tried and three failed.
 *
 * MEASURED, NOT ASSUMED. With `|| cs.provClose` deleted the whole realm suite
 * still passed, which is what sent this test in: every other governed-set test
 * settles or refuses through a path that guard never touches.
 *
 * THE REAL PATH, NOT A HAND-SET FIELD. Two tests in this repo reach provClose by
 * writing cs.provClose = true, and either would pass against a realm where
 * provCloseClaim had stopped stamping verdictAt — the exact overlap this test is
 * about would go unmodelled. So it disputes three times and lets each round time
 * out, and asserts the overlap it depends on before asserting the refusal.
 */
func TestAProvClosedYesCarriesNoSet(cur realm, t *testing.T) {
	alice := testutils.TestAddress("gsp-alice")
	bob := testutils.TestAddress("gsp-bob")
	c := testCourt(cur, "gsx1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	// Three rounds have to FIT inside the escrow window, or the claim finalizes
	// on the way rather than failing its way to a close.
	c.params.escrowMinBlocks = 450_000
	c.params.escrowMaxBlocks = 450_000

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "gsx1", tD010+" Never actually decided")
	matureOI(cur, "gsx1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "gsx1", id, sideYES)

	for round := 0; round < maxFailedRounds; round++ {
		testing.SetRealm(testing.NewUserRealm(bob))
		OpenDispute(cross(cur), "gsx1", id)
		testing.SkipHeights(c.params.votingBlocks + 1)
		ResolveDispute(cross(cur), "gsx1", id)
	}

	cs := mustClaim(c, id)
	if !cs.provClose {
		t.Fatalf("setup: three failed rounds must close the claim: failedRounds=%d",
			cs.failedRounds)
	}
	// THE OVERLAP ITSELF, asserted so this test still means something if either
	// half of it ever moves. If provCloseClaim stops stamping verdictAt, or if
	// sideYES stops being 0, the guard is no longer the only thing standing
	// between a court that never decided and a set — and a reader deserves to
	// find that out here rather than by deleting the guard and seeing green.
	uassert.True(t, cs.verdictAt != 0)
	uassert.Equal(t, int8(sideYES), cs.provisional)

	uassert.AbortsContains(t, cur, "no final verdict", func() {
		New(cross(cur), "gsx1", id)
	})
	uassert.Equal(t, 0, FolderCount("gsx1"))
	uassert.Equal(t, uint64(0), ClaimSet("gsx1", id))
}

/* THE LONGEST HEADING A COURT CAN ACTUALLY FILE, carried end to end.
 *
 * TWO CAPS THAT HAVE NEVER MET. A claim title is 1..200 runes (claim.gno) and a
 * folder name is 1..maxFolderTextLen, which is also 200 — and parseSetTitle
 * spends two runes of the title on the mark and its space. So the longest title
 * a court can file yields a 198-rune name, and folderTextOK has never once
 * refused one. The over-long branch that TestSetNameIsTheTitleVerbatim exercises
 * is real, but it is reachable only by calling parseSetTitle DIRECTLY; nothing
 * that can be opened as a claim gets there.
 *
 * WHICH IS WHY THE HEADROOM IS PINNED RATHER THAN LEFT AS ARITHMETIC. It is a
 * coincidence of two independent constants, not an invariant anything enforces.
 * Raise the title cap alone and a long marked title opens fine, stakes fine and
 * settles YES — and then IsSetClaim quietly answers false, so the overlay draws
 * no eye and no affirm button, and New refuses with "not a set heading" on
 * a title that visibly begins with the mark. A silent no is the worst available
 * shape for that failure. Better a red line here.
 *
 * AND IT IS CARRIED, not merely parsed, because the length has to survive the
 * whole route: parseSetTitle at open, parseSetTitle AGAIN inside New, and
 * folderTextOK inside newFolderCore. Asserting the parse alone would leave the
 * two later reads unmeasured.
 */
func TestTheLongestFilableHeadingCanBeCarried(cur realm, t *testing.T) {
	alice := testutils.TestAddress("gsl-alice")
	testCourt(cur, "gsl1", alice, 50_000_000_000)

	// The longest title claim.gno accepts, spelled as mark + space + the rest,
	// so the arithmetic is the realm's rather than a number copied into a test.
	name := ""
	for runeLen(tD010+" "+name) < 200 {
		name += "x"
	}
	title := tD010 + " " + name
	uassert.Equal(t, 200, runeLen(title))
	uassert.Equal(t, 198, runeLen(name))

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "gsl1", title)
	uassert.True(t, IsSetClaim("gsl1", id))

	matureOI(cur, "gsl1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "gsl1", id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "gsl1", id)

	fid := New(cross(cur), "gsl1", id)
	uassert.True(t, fid != 0)
	// VERBATIM, at the cap. The name the folder carries is the title's own tail
	// and not a truncation of it — a silent trim here would make the set's name
	// and the claim's title disagree at exactly the length nobody tests by hand.
	uassert.Equal(t, name, FolderName("gsl1", fid))
}

/* RETIRING THE SET DOES NOT FREE THE CLAIM TO MAKE ANOTHER ONE.
 *
 * THE BINDING OUTLIVES THE FOLDER, and it has to. ClaimSet walks every folder
 * row and matches bornOf — retired ones included — which reads at first like an
 * oversight beside folderNameTaken, three lines below it, which deliberately
 * SKIPS retired rows so a name comes free again. The asymmetry is the point: a
 * name is a label and can be reused, a birth is an event and happened once.
 *
 * WHAT THE SYMMETRIC VERSION WOULD COST. Make ClaimSet skip retired rows and
 * New's exactly-once guard reads zero again on a claim whose set was
 * retired — so it mints a second folder, and a moderator who retires each one in
 * turn can pump a single settled claim against the 100-folder cap, one carry per
 * retirement. RestoreFolder then puts them all back. That is precisely the
 * failure guard 3 exists to prevent, arriving through a door nobody was watching,
 * and it is a plausible "cleanup" for someone reading these two functions side by
 * side and noticing they disagree.
 *
 * THE OVERLAY IS THE OTHER HALF, and it already behaves: chainFolders skips
 * retired rows, so bornClaimIds never learns of the set, and the claim comes back
 * to the map and the docket as an ordinary claim. Retiring a set un-hides the
 * claim that made it — it does not un-make it.
 */
func TestRetiringABornSetDoesNotFreeTheClaim(cur realm, t *testing.T) {
	alice := testutils.TestAddress("gsq-alice")
	testCourt(cur, "gsq1", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	AppointMods(cross(cur), "gsq1", 1, alice)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "gsq1", tD010+" Reading room")
	matureOI(cur, "gsq1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "gsq1", id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "gsq1", id)
	fid := New(cross(cur), "gsq1", id)
	uassert.Equal(t, 1, FolderCount("gsq1"))

	testing.SetRealm(testing.NewUserRealm(alice))
	RetireFolder(cross(cur), "gsq1", fid)
	uassert.True(t, FolderRetired("gsq1", fid))

	// THE BINDING SURVIVES, both ways, and the row is still there to carry it.
	uassert.Equal(t, fid, ClaimSet("gsq1", id))
	uassert.Equal(t, id, SetBornOf("gsq1", fid))

	// SO THE SECOND CARRY IS STILL REFUSED — by anyone, not just the moderator
	// who retired it, since New is permissionless and the pump would be too.
	bob := testutils.TestAddress("gsq-bob")
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "already carries set", func() {
		New(cross(cur), "gsq1", id)
	})
	uassert.Equal(t, 1, FolderCount("gsq1"))

	// THE NAME, MEANWHILE, IS FREE — folderNameTaken skips retired rows, so a
	// DIFFERENT claim may ask for the same heading. Asserted here because it is
	// the other side of the asymmetry above: if this ever starts refusing, the
	// two functions have been made symmetric in the wrong direction.
	testing.SetRealm(testing.NewUserRealm(alice))
	id2 := OpenClaim(cross(cur), "gsq1", tD010+" Reading room")
	matureOI(cur, "gsq1", id2, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "gsq1", id2, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "gsq1", id2)
	fid2 := New(cross(cur), "gsq1", id2)
	uassert.True(t, fid2 != fid)
	uassert.Equal(t, "Reading room", FolderName("gsq1", fid2))
}

/* A SET IS NOT BORN INSIDE A FOLDER THAT HAS BEEN STRUCK FROM THE TREE.
 *
 * REACHABLE WITH ONE ORDINARY MODERATOR CALL, and confirmed on a running chain
 * before this was written: AddToFolder has no retired guard and mustFolder hands
 * back a retired row like any other, so a claim can be filed INTO a retired
 * folder — and ClaimFolders reports it, because that read skips purged rows and
 * only purged rows.
 *
 * SO STEP 5 COULD PICK A RETIRED PARENT. newFolderCore's mustNestable checks
 * depth and cycles, not liveness, and the result is a LIVE folder hanging under a
 * retired one — precisely the shape RetireFolder refuses to create ("retire the
 * folders inside it first, so the tree cannot grow orphans"), arrived at from
 * underneath instead of from above. The overlay survives it — nestChainFolders
 * roots a folder whose parent was skipped rather than dropping it — but a client
 * being defensive is not the same as the chain being right.
 *
 * REFUSED, NOT RE-ROOTED, on the argument step 5 already makes about multiple
 * filings: "a guess" is the wrong answer when the caller can say. A retired
 * parent is one RestoreFolder or one RemoveFromFolder away from being decidable,
 * and either is cheaper than a set that quietly went somewhere else than the page
 * said it would.
 *
 * AND IT BELONGS AT EXECUTION, with the name check beside it, for that guard's
 * own stated reason: weeks pass between opening a claim and carrying it, so what
 * was true at filing has to be re-established now.
 */
func TestASetIsNotBornUnderARetiredParent(cur realm, t *testing.T) {
	alice := testutils.TestAddress("gsv-alice")
	testCourt(cur, "gsv1", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	AppointMods(cross(cur), "gsv1", 1, alice)

	testing.SetRealm(testing.NewUserRealm(alice))
	parent := CreateFolder(cross(cur), "gsv1", "Origins", "where it began")
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "gsv1", tD010+" Furin cleavage site")
	testing.SetRealm(testing.NewUserRealm(alice))
	AddToFolder(cross(cur), "gsv1", parent, id)

	matureOI(cur, "gsv1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "gsv1", id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "gsv1", id)

	// THE PARENT GOES AWAY IN THE WINDOW. RetireFolder clears the item list, so
	// this re-files afterwards — which is the whole point: the filing survives
	// the retirement because nothing stops it being made again.
	testing.SetRealm(testing.NewUserRealm(alice))
	RetireFolder(cross(cur), "gsv1", parent)
	testing.SetRealm(testing.NewUserRealm(alice))
	AddToFolder(cross(cur), "gsv1", parent, id)
	uassert.Equal(t, 1, len(ClaimFolders("gsv1", id))) // the precondition, asserted

	before := FolderCount("gsv1")
	uassert.AbortsContains(t, cur, "has been retired", func() {
		New(cross(cur), "gsv1", id)
	})
	uassert.Equal(t, before, FolderCount("gsv1")) // and nothing was created
	uassert.Equal(t, uint64(0), ClaimSet("gsv1", id))

	// RESTORE IT AND THE SAME CALL WORKS, so the refusal is a "not yet" rather
	// than a "never" — the claim keeps everything the court gave it.
	testing.SetRealm(testing.NewUserRealm(alice))
	RestoreFolder(cross(cur), "gsv1", parent)
	fid := New(cross(cur), "gsv1", id)
	uassert.Equal(t, parent, FolderParent("gsv1", fid))
}


/* TWO MARKS, ONE DIFFERENCE. Both 𓂀 and 𓁼 make a set; which one the author
 * filed under decides whether it opens shown or hidden, and nothing else.
 *
 * WHY THE TITLE AND NOT A FIELD: the mark had to be in the title anyway for the
 * claim to be a set at all, so the default costs no storage, no argument and no
 * second read. And a title cannot be edited, which makes the default immutable
 * for free — a set opens the way it was filed, or it is a different set.
 *
 * D007 IS NOT "CLOSED" IN UNICODE, and the realm's own comment says so. It is
 * the eye with painted lids; this court uses it to mean not-seeing by
 * convention. The test pins the convention, since nothing else can.
 */
func TestTheMarkChoosesWhetherTheSetOpensShownOrHidden(cur realm, t *testing.T) {
	// The parser first, both ways round, because everything below rests on it.
	if n, shown, ok := parseSetTitle(tD010 + " Lab leak evidence"); !ok || !shown || n != "Lab leak evidence" {
		t.Fatalf("𓂀 must parse as a set that starts ticked: %q %v %v", n, shown, ok)
	}
	if n, shown, ok := parseSetTitle(tD007 + " Retired filings"); !ok || shown || n != "Retired filings" {
		t.Fatalf("𓁼 must parse as an ordinary set: %q %v %v", n, shown, ok)
	}
	// ...and the name is the rest either way: the two marks differ in the default
	// they set and in NOTHING else, which is the whole claim of this feature.
	nA, _, _ := parseSetTitle(tD010 + " Same name")
	nB, _, _ := parseSetTitle(tD007 + " Same name")
	uassert.Equal(t, nA, nB)

	// IsSetClaim does not care which: both are sets.
	alice := testutils.TestAddress("tm-alice")
	testCourt(cur, "tm1", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	shownID := OpenClaim(cross(cur), "tm1", tD010+" Shown by default")
	testing.SetRealm(testing.NewUserRealm(alice))
	hiddenID := OpenClaim(cross(cur), "tm1", tD007+" Hidden by default")
	uassert.True(t, IsSetClaim("tm1", shownID))
	uassert.True(t, IsSetClaim("tm1", hiddenID))

	// And once carried, the choice is on the FOLDER and in the tree row — which
	// is where a client reads it, without a read of its own.
	fA := affirmFor(cur, t, "tm1", alice, shownID)
	fB := affirmFor(cur, t, "tm1", alice, hiddenID)
	uassert.True(t, mustFolderOf("tm1", fA).focusByDefault)
	uassert.False(t, mustFolderOf("tm1", fB).focusByDefault)

	tree := FolderTree("tm1")
	if !strings.Contains(tree, ":f:") {
		t.Fatalf("the 𓂀 set must carry the f flag: %q", tree)
	}
	if !strings.Contains(tree, ":-:") {
		t.Fatalf("the 𓁼 set must carry no flag: %q", tree)
	}
}

// mustFolderOf reaches the folder record the way the realm does, so the test
// asserts the stored bit rather than a rendering of it.
func mustFolderOf(slug string, fid uint64) *folder {
	return mustCourt(slug).mod.mustFolder(fid)
}

// affirmFor walks the whole route — ripen, answer, settle, carry — because New
// refuses anything short of a final verdict and the default under test is only
// written at the last step.
func affirmFor(cur realm, t *testing.T, slug string, who address, id uint64) uint64 {
	t.Helper()
	matureOI(cur, slug, id, who, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	PostAnswer(cross(cur), slug, id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), slug, id)
	testing.SetRealm(testing.NewUserRealm(who))
	fid := New(cross(cur), slug, id)
	if fid == 0 {
		t.Fatalf("New returned 0 for claim %d", id)
	}
	return fid
}
