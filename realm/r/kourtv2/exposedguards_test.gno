package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// THE REFUSALS BEHIND THE BUTTONS THIS SESSION ADDED.
//
// A scan of every `panic("kourtv2: ...")` in folders, argument, court and claim
// against every string the suite asserts turned up twenty with no test naming
// them. Most are mustSane's deploy-time invariants — "the tier-scaled split must
// sum to 93 points" fires only if somebody edits a constant, and the constant is
// the test. Three were not like that, and all three guard an entrypoint that had
// no path in the product until this session and now has one, which is exactly
// when an unasserted refusal starts mattering: nobody could reach it before.

// EditClaimTitle's OR, both sides. `cs.closed || cs.frozenAt != 0` is one
// condition made of two, and a test of either half leaves the other free to be
// deleted — so both are here. A settled claim's wording is part of what was
// settled; a dead one's is part of the record of what died.
func TestATitleIsFrozenOnceTheClaimIsAnsweredOrDead(cur realm, t *testing.T) {
	alice := testutils.TestAddress("edt-a")
	testCourt(cur, "edt", alice, 50_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	answered := OpenClaim(cross(cur), "edt", "answered, so the wording is settled too")
	matureOI(cur, "edt", answered, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "edt", answered, sideYES)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "no longer editable", func() {
		EditClaimTitle(cross(cur), "edt", answered, "a better wording")
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	dead := OpenClaim(cross(cur), "edt", "nobody answered this one")
	testing.SkipHeights(deadClaimTimeout + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	CloseDeadClaim(cross(cur), "edt", dead)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "no longer editable", func() {
		EditClaimTitle(cross(cur), "edt", dead, "too late to fix it")
	})
}

// StartCourtP's window is now offered on the front page, so a number somebody
// types goes straight at this bound. maxStakeOpenDelay is 24h; the cap ITSELF
// must be allowed, or the guard is off by one in the direction that quietly
// refuses the most generous legal window.
func TestStartCourtPBoundsThePolishWindow(cur realm, t *testing.T) {
	alice := testutils.TestAddress("pwb-a")

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "polish window must be in", func() {
		StartCourtP(cross(cur), "pwb-too", "Too Long", maxStakeOpenDelay+1)
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "polish window must be in", func() {
		StartCourtP(cross(cur), "pwb-neg", "Negative", -1)
	})

	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourtP(cross(cur), "pwb-max", "At The Cap", maxStakeOpenDelay)
	uassert.Equal(t, maxStakeOpenDelay, CourtStakeOpenDelay("pwb-max"))
}

// And the court name, which every Start button on the front page carries.
func TestACourtNameIsBounded(cur realm, t *testing.T) {
	alice := testutils.TestAddress("cnb-a")

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "a court name is 1..100", func() {
		StartCourt(cross(cur), "cnb-empty", "")
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "a court name is 1..100", func() {
		StartCourt(cross(cur), "cnb-long", strings.Repeat("x", maxCourtNameLen+1))
	})
	// The cap itself is a legal name.
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "cnb-ok", strings.Repeat("x", maxCourtNameLen))
	uassert.Equal(t, maxCourtNameLen, len(CourtName("cnb-ok")))
}
