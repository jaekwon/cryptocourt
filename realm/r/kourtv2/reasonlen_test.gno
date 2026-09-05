package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// maxReasonLen AT ITS OWN BOUNDARY, in both places it is enforced.
//
// A sweep of every cap comparison in the realm found these two unrowed and
// unpinned: narrowing `len(x) > maxReasonLen` to `>=` refuses a reason of EXACTLY
// the maximum, and both mutations survived the whole suite. One of them
// contradicts its own message while doing it — checkReason panics "a moderation
// reason is at most 200 characters", so a 200-character reason being refused makes
// the guard disagree with the sentence it prints. That is the shape worth pinning:
// not a hazard, but a promise the code makes to whoever reads the refusal.
//
// THE LAST LEGAL VALUE IS THE ASSERTION. Both existing arms of these caps test
// overshoot (and the empty case, for the purge code), which leaves the boundary
// itself free in the exclusive direction. A refusal test paired only with a
// comfortable success cannot see an off-by-one; a pair at N and N+1 can.
func TestAReasonOfExactlyTheMaximumLengthIsAccepted(cur realm, t *testing.T) {
	atCap := strings.Repeat("r", maxReasonLen)
	over := strings.Repeat("r", maxReasonLen+1)

	// checkReason is the shared gate for the moderation lane's three reason
	// arguments (moderation.gno's hide, unhide and the category code). It is a pure
	// function of one string, so it is tested as one — a court fixture would add
	// nothing but setup between the bound and the assertion.
	if len(atCap) != 200 || len(over) != 201 {
		t.Fatalf("setup: this test names 200 in its own message assertion, so the "+
			"cap must still be 200; got %d", maxReasonLen)
	}
	// A local recover, the shape court_test.gno uses: checkReason is not a crossing
	// call, so this is a plain panic rather than an abort.
	checkReason(atCap) // must not panic: the message promises "at most 200"
	mustPanicWith(t, "at most 200 characters", func() { checkReason(over) })

	// The purge code is the same cap enforced inline in PurgeFolder, with its own
	// message, so it needs its own arm. Fixture per folderpurge_test: the directory
	// admin sets the threshold to one and purges.
	alice := testutils.TestAddress("rlen-alice")
	testCourt(cur, "rlen", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	f := CreateFolder(cross(cur), "rlen", "Struck", "to be purged")
	testing.SetRealm(testing.NewUserRealm(alice))
	RetireFolder(cross(cur), "rlen", f)

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)

	// Over the cap first, because a purge cannot be undone — the refusal has to be
	// tried while there is still a folder to purge.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "kourtv2: purge needs a statutory category code",
		func() {
			PurgeFolder(cross(cur), "rlen", f, over)
		})
	uassert.False(t, FolderPurged("rlen", f))

	// ...and exactly at the cap is a legal code. This is the arm the mutation
	// breaks: with `>=` this purge is refused and the folder stays unpurged.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeFolder(cross(cur), "rlen", f, atCap)
	uassert.True(t, FolderPurged("rlen", f))
}

// THE SAME CAP, IN A SCRIPT THAT IS NOT LATIN — which is the case the test above
// cannot see, because it spells its bodies with strings.Repeat("r", n) and for
// ASCII a byte and a character are the same thing.
//
// mustCategoryCode counted BYTES while checkReason, ten lines away in the same
// file and reading the same maxReasonLen, counted runes. runeLen exists precisely
// to stop that — its own note records why every cap in this realm moved to
// characters: "a 200-character Russian claim title — about 370 bytes — was refused
// with 'a title is at most 200 characters', about a title that was 200". The purge
// code was the one cap that sweep missed.
//
// WHAT IT COST: a statutory category in Cyrillic ran out around 100 characters and
// one in Japanese around 66, against a stated 200 — and the refusal names no
// length at all, so a moderator was told the code was MISSING when it was present
// and too long. On an m-of-n act that cannot be undone, with the code being the
// part that outlives the claim.
//
// The pairing is the point: both functions share one constant, so one arm per
// function at the same rune count is what proves they mean the same thing by it.
func TestTheCategoryCodeCapCountsCharactersLikeItsSiblingDoes(cur realm, t *testing.T) {
	// 200 CHARACTERS, 400 BYTES. Under the old byte count this was refused at
	// exactly twice the stated limit; the assertion is that it is accepted.
	atCap := strings.Repeat("ф", maxReasonLen)
	if runeLen(atCap) != maxReasonLen || len(atCap) != 2*maxReasonLen {
		t.Fatalf("setup: wanted %d runes in %d bytes, got %d in %d",
			maxReasonLen, 2*maxReasonLen, runeLen(atCap), len(atCap))
	}

	// checkReason first, the sibling that was already right. It is the control:
	// without it a reader cannot tell whether this file is asserting a rule or
	// just describing whatever the code happens to do.
	checkReason(atCap) // must not panic — 200 characters, and it promises 200
	mustPanicWith(t, "at most 200 characters",
		func() { checkReason(strings.Repeat("ф", maxReasonLen+1)) })

	// And now the one that was wrong. Same string, same constant, same answer.
	mustCategoryCode(atCap)
	mustPanicWith(t, "statutory category code",
		func() { mustCategoryCode(strings.Repeat("ф", maxReasonLen+1)) })

	// Through a real purge, because mustCategoryCode is only reachable that way and
	// a pure-function arm cannot show the entrypoint actually passes the code down.
	alice := testutils.TestAddress("rlen2-alice")
	testCourt(cur, "rlen2", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	f := CreateFolder(cross(cur), "rlen2", "Struck", "to be purged")
	testing.SetRealm(testing.NewUserRealm(alice))
	RetireFolder(cross(cur), "rlen2", f)

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)

	// Over the cap in RUNES is still refused — the fix widened the bound, it did
	// not remove it. Tried first, while there is still a folder to purge.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "kourtv2: purge needs a statutory category code",
		func() {
			PurgeFolder(cross(cur), "rlen2", f, strings.Repeat("ф", maxReasonLen+1))
		})
	uassert.False(t, FolderPurged("rlen2", f))

	// ...and 200 Cyrillic characters purges, which is the whole bug in one line.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeFolder(cross(cur), "rlen2", f, atCap)
	uassert.True(t, FolderPurged("rlen2", f))
}
