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
	mustPanicWith := func(want string, fn func()) {
		t.Helper()
		defer func() {
			r := recover()
			if r == nil {
				t.Fatalf("expected a panic saying %q; nothing panicked", want)
			}
			if got, ok := r.(string); !ok || !containsSub(got, want) {
				t.Fatalf("panic %v, want one saying %q", r, want)
			}
		}()
		fn()
	}
	checkReason(atCap) // must not panic: the message promises "at most 200"
	mustPanicWith("at most 200 characters", func() { checkReason(over) })

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
