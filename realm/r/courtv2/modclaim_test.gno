package courtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// The polish window (I7): staking is closed for stakeOpenDelayBlocks, then
// opens; a default (0-delay) court is unaffected.
func TestPolishWindowGatesStaking(cur realm, t *testing.T) {
	alice := testutils.TestAddress("pw-alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourtP(cross(cur), "pw", "Polish Window Court", 720)
	c := mustCourt("pw")
	c.coin.Mint(alice, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "pw", "wording to polish")
	// Staking is refused during the window.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "polish window is open", func() {
		Stake(cross(cur), "pw", id, sideYES, 1_000_000_000)
	})
	// After the window, staking works.
	testing.SkipHeights(720)
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "pw", id, sideYES, 1_000_000_000)
	if y, _ := StakePools("pw", id); y != 1_000_000_000 {
		t.Fatal("staking should open after the window")
	}
}

// A default court (StartCourt, 0 delay) stakes immediately — no regression, no
// fixture sweep needed.
func TestDefaultCourtNoWindow(cur realm, t *testing.T) {
	alice := testutils.TestAddress("pw0-alice")
	c := testCourt(cur, "pw0", alice, 10_000_000_000)
	_ = c
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "pw0", "no window")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "pw0", id, sideYES, 1_000_000_000) // works with no delay
	if y, _ := StakePools("pw0", id); y != 1_000_000_000 {
		t.Fatal("a 0-delay court stakes immediately")
	}
}

// Seeded claims (§8): mod-only, deposit+fee waived, seeded flag set.
func TestOpenClaimSeeded(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sd-alice")
	c := testCourt(cur, "sd", alice, 10_000_000_000)
	escrow0 := c.coin.BalanceOf(c.escrow)

	// A non-moderator cannot seed.
	bob := testutils.TestAddress("sd-bob")
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "not a moderator", func() {
		OpenClaimSeeded(cross(cur), "sd", "spam seed")
	})
	// The creator-moderator seeds: no deposit/fee moves.
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaimSeeded(cross(cur), "sd", "seeded starter")
	if !ClaimSeeded("sd", id) {
		t.Fatal("the claim should be marked seeded")
	}
	if c.coin.BalanceOf(c.escrow) != escrow0 {
		t.Fatal("a seeded claim waives the deposit and fee — no money moves")
	}
	// A suspended set cannot seed.
	suspendSet(c, alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "suspended", func() {
		OpenClaimSeeded(cross(cur), "sd", "nope")
	})
}

// Title edits (I4): author-only, during the window, frozen after.
func TestEditClaimTitleWindow(cur realm, t *testing.T) {
	alice := testutils.TestAddress("et-alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourtP(cross(cur), "et", "Edit Title Court", 720)
	c := mustCourt("et")
	c.coin.Mint(alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "et", "typo in titel")

	// A non-author cannot edit.
	bob := testutils.TestAddress("et-bob")
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "only the author", func() {
		EditClaimTitle(cross(cur), "et", id, "hijack")
	})
	// The author edits during the window.
	testing.SetRealm(testing.NewUserRealm(alice))
	EditClaimTitle(cross(cur), "et", id, "typo in title, fixed")
	if ClaimTitle("et", id) != "typo in title, fixed" {
		t.Fatal("the author should be able to fix wording in the window")
	}
	// After the window closes, the title is frozen.
	testing.SkipHeights(720)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "frozen", func() {
		EditClaimTitle(cross(cur), "et", id, "too late")
	})
}

// The whole-court purge gate (§3.2 carve-out #2): a purged court opens no new
// claims, but existing claims still run their lifecycle (I1).
func TestPurgedCourtGate(cur realm, t *testing.T) {
	alice := testutils.TestAddress("pc-alice")
	g2 := testutils.TestAddress("pc-g2")
	testCourt(cur, "pc", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	pre := OpenClaim(cross(cur), "pc", "before purge")

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	AddGlobalMod(cross(cur), g2)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 2)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeCourt(cross(cur), "pc", "ILLEGAL")
	testing.SetRealm(testing.NewUserRealm(g2))
	PurgeCourt(cross(cur), "pc", "ILLEGAL")
	if !CourtPurged("pc") {
		t.Fatal("two approvals should purge the court")
	}
	// No new claims.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "court is purged", func() {
		OpenClaim(cross(cur), "pc", "after purge")
	})
	// But an existing claim still runs its lifecycle: staking works.
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "pc", pre, sideYES, 1_000_000_000)
	if y, _ := StakePools("pc", pre); y != 1_000_000_000 {
		t.Fatal("a pre-purge claim must still accept stake (lifecycle intact)")
	}
}
