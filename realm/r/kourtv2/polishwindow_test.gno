package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// THE NUMBER A CLIENT CANNOT GUESS. StartCourt passes 0 and StartCourtP opts in,
// so whether a court has a polish window is invisible from outside — and on a
// zero court the window shuts before the opening transaction returns, making
// EditClaimTitle refuse every call. A client offering "fix the title" without
// this read is offering a form the realm will always refuse; a client hiding it
// is hiding a window that may be genuinely open. It could not tell which.
func TestStakeOpenDelayIsReadable(cur realm, t *testing.T) {
	alice := testutils.TestAddress("pw-a")
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "pwzero", "No Window")
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourtP(cross(cur), "pwopen", "With Window", 600)

	// The default is the one worth pinning: it is what every court started
	// through StartCourt has, and it means "no window" rather than "unset".
	uassert.Equal(t, int64(0), CourtStakeOpenDelay("pwzero"))
	uassert.Equal(t, int64(600), CourtStakeOpenDelay("pwopen"))
}

// A read on a court that is not there refuses rather than answering zero, which
// would be indistinguishable from a real court with no window.
//
// PanicsContains, not AbortsContains: this is a plain read, so it panics where a
// crossing call would abort, and the abort form reports a failure even when the
// panic it wanted did happen.
func TestStakeOpenDelayRefusesAnUnknownCourt(cur realm, t *testing.T) {
	uassert.PanicsContains(t, cur, "no such court", func() {
		CourtStakeOpenDelay("pwnobody")
	})
}

// AND THE BEHAVIOUR THE NUMBER PREDICTS, so the read cannot drift away from the
// rule it exists to describe. On a zero-delay court the title is frozen from the
// start; on a court with a window the author may still fix it.
func TestTheDelayPredictsWhetherATitleCanBeFixed(cur realm, t *testing.T) {
	alice := testutils.TestAddress("pw2-a")
	testCourt(cur, "pw2zero", alice, 200_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "pw2zero", "a claim with a typoo")

	uassert.Equal(t, int64(0), CourtStakeOpenDelay("pw2zero"))
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "polish window has closed", func() {
		EditClaimTitle(cross(cur), "pw2zero", id, "a claim with a typo")
	})
}
