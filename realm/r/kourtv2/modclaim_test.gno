package kourtv2

import (
	"testing"
	"time"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// The polish window (I7): staking is closed for stakeOpenDelayBlocks, then
// opens; a default (0-delay) court is unaffected.
//
// This one walks the window with SkipHeights, which moves height and time
// together at exactly 5s a block — so it cannot say which clock the gate read.
// TestThePolishWindowClosesOnWallClockNotOnBlocks below separates them.
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

// THE POLISH WINDOW IS A DURATION, AND A DURATION IS NOT A BLOCK COUNT.
//
// A court opts into "720 blocks" meaning an hour. On a chain that is not running
// at 5s a block it is not an hour, and the author's hour to fix a typo becomes
// forty minutes or four days depending on nothing they can see. The window is
// converted through blocksToSecs for the same reason EditClaimTitle's half of it
// already was — and the two halves must agree on the instant, because the title
// freezes exactly when staking opens. That agreement is asserted below.
//
// The window is short enough (720 blocks = 3600s) to pin its EXACT second, which
// the SkipHeights test above could not do for either clock.
func TestThePolishWindowClosesOnWallClockNotOnBlocks(cur realm, t *testing.T) {
	alice := testutils.TestAddress("pwc-alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourtP(cross(cur), "pwc", "Polish Clock Court", 720)
	c := mustCourt("pwc")
	c.coin.Mint(alice, 20_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "pwc", "wording to polish")
	cs := mustClaim(c, id)
	if cs.openedAtTime == 0 {
		t.Fatal("fixture: no open stamp, so this would test the height fallback instead")
	}
	openedH := heightNow()

	// One second short of the hour. Time only — the height has not moved, so the
	// block arithmetic still reads this as block 0 of 720 either way.
	bump := func(d int64) {
		ctx := testing.GetContext()
		ctx.Time = ctx.Time.Add(time.Duration(d) * time.Second)
		testing.SetContext(ctx)
	}
	bump(3599)
	uassert.Equal(t, openedH, heightNow()) // time moved, height did not
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "polish window is open", func() {
		Stake(cross(cur), "pwc", id, sideYES, 1_000_000_000)
	})

	// The 3600th second. Staking opens with no block having been mined, which is
	// the whole claim of the conversion.
	bump(1)
	uassert.Equal(t, openedH, heightNow())
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "pwc", id, sideYES, 1_000_000_000)
	if y, _ := StakePools("pwc", id); y != 1_000_000_000 {
		t.Fatal("staking should open on the wall clock, with no blocks mined")
	}

	// AND THE OTHER HALF OF THE SAME WINDOW AGREES. At this instant the title
	// must be frozen — one window, two gates, opposite polarity. If these ever
	// disagree there is an instant where a claim can be both re-titled and staked,
	// which is the race the window exists to prevent.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "polish window has closed", func() {
		EditClaimTitle(cross(cur), "pwc", id, "wording, polished")
	})

	// ---- AND A PRE-STAMP CLAIM STILL READS HEIGHT, TO ITS EXACT BLOCK ----
	testing.SetRealm(testing.NewUserRealm(alice))
	id2 := OpenClaim(cross(cur), "pwc", "a claim from before the stamps")
	cs2 := mustClaim(c, id2)
	cs2.openedAtTime = 0 // the pre-upgrade shape: a height, no stamp
	target := cs2.openedAt + 720
	if d := target - 1 - heightNow(); d > 0 {
		testing.SkipHeights(d)
	}
	uassert.Equal(t, target-1, heightNow())
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "polish window is open", func() {
		Stake(cross(cur), "pwc", id2, sideYES, 1_000_000_000)
	})
	testing.SkipHeights(1)
	uassert.Equal(t, target, heightNow())
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "pwc", id2, sideYES, 1_000_000_000)
	if y, _ := StakePools("pwc", id2); y != 1_000_000_000 {
		t.Fatal("a pre-stamp claim's window must still open on its exact block")
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
