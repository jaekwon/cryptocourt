package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// The wedjat, and the two eyes nearest it in the block. Written as escapes for
// the same reason the constant is: at this size they are one picture.
const (
	tD010 = "\U00013080" // 𓂀 the mark
	tD004 = "\U00013079" // 𓁹 an ordinary eye — NOT the mark
	tD006 = "\U0001307B" // another one
)

func TestSetTitleParsesOnlyTheExactMark(cur realm, t *testing.T) {
	name, ok := parseSetTitle(tD010 + " Lab leak evidence")
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
		if _, ok := parseSetTitle(bad); ok {
			t.Fatalf("a near-miss parsed as a set heading: %q", bad)
		}
	}
}

// The name is the rest of the title VERBATIM. If this ever starts trimming, the
// set's name and the claim's title stop matching, which is the one thing the
// feature promises.
func TestSetNameIsTheTitleVerbatim(cur realm, t *testing.T) {
	name, ok := parseSetTitle(tD010 + "  two leading spaces")
	uassert.True(t, ok)
	uassert.Equal(t, " two leading spaces", name)

	// ...and a name too long for a folder is not a set heading at all, rather
	// than a set heading that panics later inside the execution.
	long := ""
	for i := 0; i < maxFolderTextLen+1; i++ {
		long += "x"
	}
	if _, ok := parseSetTitle(tD010 + " " + long); ok {
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
     - the final-YES check     -> the suite goes red at rc=2, but as an UNCAUGHT
                                  ABORT with a VM state dump inside this test,
                                  not a clean "--- FAIL" line. Without the check,
                                  AffirmSet runs on a claim that never settled
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
		AffirmSet(cross(cur), "gs1", id)
	})

	matureOI(cur, "gs1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "gs1", id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "gs1", id)

	// PERMISSIONLESS: the verdict is the authority. bob is nobody here.
	bob := testutils.TestAddress("gs-bob")
	testing.SetRealm(testing.NewUserRealm(bob))
	fid := AffirmSet(cross(cur), "gs1", id)
	uassert.True(t, fid != 0)
	uassert.Equal(t, "Lab leak evidence", FolderName("gs1", fid))
	uassert.Equal(t, 1, FolderCount("gs1"))

	// The binding, both ways.
	uassert.Equal(t, fid, ClaimSet("gs1", id))
	uassert.Equal(t, id, SetBornOf("gs1", fid))

	// EXACTLY ONCE. Without this anyone re-calls it until the court hits its
	// folder cap.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "already carries set", func() {
		AffirmSet(cross(cur), "gs1", id)
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
		AffirmSet(cross(cur), "gsn1", id)
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
		AffirmSet(cross(cur), "gsu1", id)
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
		AffirmSet(cross(cur), "gst1", id)
	})
	// ...and the hand-made one is untouched and unbound.
	uassert.Equal(t, 1, FolderCount("gst1"))
	uassert.Equal(t, uint64(0), SetBornOf("gst1", 1))
	uassert.Equal(t, uint64(0), ClaimSet("gst1", id))
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
