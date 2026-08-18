package kourtv2

import (
	"strings"
	"testing"
	"time"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// The latch is the whole safety argument, so these tests attack it rather than
// demonstrate it: a stranger must not arm it, a used realm must not arm it, and
// nothing may reopen it once shut.

// testingTime is the block clock as the harness reports it, for tests that arm
// the latch by hand (the public path is covered by the filetest).
func testingTime() int64 { return time.Now().Unix() }

func resetTestClock(deployer address) {
	tcDeployer, tcArmed, tcSealed, tcSkew, tcBase, tcFloor = deployer, false, false, 0, 0, 0
	tcEverArmed, tcPeakSkew = false, 0
}

// NOTE ON SCOPE: every test in this package shares one realm, and by the time
// any of them runs, some earlier test has created a court — so the VIRGIN
// arming path cannot be reached from here at all. That path is exercised from
// a fresh deploy in z_testclock_filetest.gno; what these tests own is the
// guards and the semantics.

func TestTestClockSurvivesCourtCreation(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-alice")
	bob := testutils.TestAddress("tc-bob")
	resetTestClock(alice)
	tcArmed, tcBase, tcFloor = true, testingTime(), testingTime() // a fresh scenario chain

	// A claim whose settle window is days away — the case no integration test
	// could reach by waiting.
	c := testCourt(cur, "tc1", alice, 50_000_000_000)
	c.coin.Mint(bob, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "tc1", "Can a test walk a 72-hour window?")
	Stake(cross(cur), "tc1", id, sideYES, 9_000_000_000)
	cs := mustClaim(c, id)
	touch(c)
	cs.frozenAt = testingHeight()
	cs.rateAccAtFreeze = c.rateAccFP
	cs.answerHeight = testingHeight()
	cs.answeredAtTime = nowTime()
	cs.answer = sideYES
	cs.answerer = bob

	// Creating a court must NOT disarm it: seeding a court and then advancing
	// time is the whole purpose, and the implicit seal also threw already-written
	// stamps into the future (audit HIGH-4).
	if !TestClockActive() {
		t.Error("starting a court must not disarm the test clock")
	}
}

// Arming BEFORE any court, then advancing, must carry a claim past a deadline
// without a single block of waiting.
func TestTestClockCarriesAClaimPastItsDeadline(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-c")
	bob := testutils.TestAddress("tc-d")
	resetTestClock(alice)
	tcArmed, tcBase, tcFloor = true, testingTime(), testingTime() // armed at deploy
	c := testCourt(cur, "tc2", alice, 50_000_000_000)
	// StartCourt leaves the clock alone now; the scenario stays armed.
	c.coin.Mint(bob, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "tc2", "Does the skew move a real gate?")
	Stake(cross(cur), "tc2", id, sideYES, 9_000_000_000)
	cs := mustClaim(c, id)
	testing.SkipHeights(10)
	touch(c)
	cs.frozenAt = testingHeight()
	cs.rateAccAtFreeze = c.rateAccFP
	cs.answerHeight = testingHeight()
	cs.answeredAtTime = nowTime()
	cs.answer = sideYES
	cs.answerer = bob

	// Not yet: the settle window has not passed on any clock.
	uassert.AbortsContains(t, cur, "has not aged", func() {
		SettleUndisputed(cross(cur), "tc2", id)
	})

	// 72 hours in one transaction, no blocks waited.
	testing.SetRealm(testing.NewUserRealm(alice))
	AdvanceTestClock(cross(cur), 72*3600+1)
	SettleUndisputed(cross(cur), "tc2", id)
	if cs.verdictAt == 0 {
		t.Fatal("the advance should have carried the claim past its settle window")
	}
	// And the record's own stamp reflects the skewed clock, consistently.
	if cs.verdictAtTime < cs.answeredAtTime+72*3600 {
		t.Error("the verdict stamp must sit past the window it waited out")
	}
}

func TestTestClockRefusesStrangersAndBackwardsTime(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-e")
	mallory := testutils.TestAddress("tc-m")
	resetTestClock(alice)

	// A stranger cannot arm it, even on a virgin realm — the race a public
	// chain would otherwise lose.
	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsContains(t, cur, "only the deployer", func() {
		EnableTestClock(cross(cur))
	})
	if TestClockActive() {
		t.Fatal("a stranger armed the clock")
	}
	// A stranger is refused as a stranger — before learning anything about the
	// latch's state (audit LOW-2: the reverse order was free reconnaissance).
	uassert.AbortsContains(t, cur, "only the deployer", func() {
		AdvanceTestClock(cross(cur), 60)
	})
	// Nor seal it.
	uassert.AbortsContains(t, cur, "only the deployer", func() {
		SealTestClock(cross(cur))
	})

	// Armed (the filetest covers the arming path); time only moves forward.
	testing.SetRealm(testing.NewUserRealm(alice))
	tcArmed, tcBase, tcFloor = true, testingTime(), testingTime()
	uassert.AbortsContains(t, cur, "moves forward", func() {
		AdvanceTestClock(cross(cur), -3600)
	})
	uassert.AbortsContains(t, cur, "moves forward", func() {
		AdvanceTestClock(cross(cur), 0)
	})
	before := TestClockSkew()
	AdvanceTestClock(cross(cur), 3600)
	if TestClockSkew() != before+3600 {
		t.Error("the skew must accumulate")
	}

	// Sealing is one-way, and it takes the skew with it.
	SealTestClock(cross(cur))
	if TestClockActive() || TestClockSkew() != 0 {
		t.Error("sealing must disarm and zero the skew")
	}
	uassert.AbortsContains(t, cur, "sealed", func() {
		EnableTestClock(cross(cur))
	})
}

// A realm that already carries courts is not virgin, whoever asks.
func TestTestClockRefusesAUsedRealm(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-f")
	resetTestClock(alice)
	_ = testCourt(cur, "tc3", alice, 1_000_000_000) // uses the realm
	tcSealed = false                                // even with the seal cleared by hand,
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "already has courts", func() {
		EnableTestClock(cross(cur)) // the court count still refuses
	})
}

// ------------------------------------------------------------ audit fixes --

// HIGH-1: arming must not hand the wheel to the world. Only the deployer may
// advance an ARMED clock — the first draft checked nothing here, and a proof
// showed a stranger maturing every deadline in the realm with one call.
func TestAdvanceIsDeployerOnlyWhileArmed(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-g")
	mallory := testutils.TestAddress("tc-h")
	resetTestClock(alice)
	tcArmed, tcBase, tcFloor = true, testingTime(), testingTime()

	testing.SetRealm(testing.NewUserRealm(mallory))
	uassert.AbortsContains(t, cur, "only the deployer", func() {
		AdvanceTestClock(cross(cur), 7257600)
	})
	if TestClockSkew() != 0 {
		t.Error("a stranger moved an armed clock")
	}
}

// HIGH-3: two maximal "forward" steps wrapped int64 and walked the clock
// BACKWARDS. Both the step and the running total are capped now.
func TestAdvanceCannotWrapTheClockBackwards(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-i")
	resetTestClock(alice)
	tcArmed, tcBase, tcFloor = true, testingTime(), testingTime()
	testing.SetRealm(testing.NewUserRealm(alice))

	maxI64 := int64(9223372036854775807)
	uassert.AbortsContains(t, cur, "at most ten years", func() {
		AdvanceTestClock(cross(cur), maxI64)
	})
	// Walk to the ceiling in legal steps; the one that would cross it is refused.
	for i := 0; i < 10; i++ {
		AdvanceTestClock(cross(cur), maxAdvanceStep)
	}
	uassert.AbortsContains(t, cur, "as far as it may", func() {
		AdvanceTestClock(cross(cur), maxAdvanceStep)
	})
	if tcNow() <= tcBase {
		t.Error("the clock must never end up at or below where it started")
	}
}

// HIGH-4: sealing used to zero the base, so stamps written under a long advance
// landed in the FUTURE and reopened windows that had expired. The floor keeps
// them in the past.
func TestSealingNeverRewindsBelowWhatWasShown(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-j")
	resetTestClock(alice)
	tcArmed, tcBase, tcFloor = true, testingTime(), testingTime()
	testing.SetRealm(testing.NewUserRealm(alice))
	AdvanceTestClock(cross(cur), maxAdvanceStep) // ten years out

	stamped := nowTime() // what a claim would have recorded
	SealTestClock(cross(cur))
	if after := nowTime(); after < stamped {
		t.Errorf("sealing rewound the clock: stamp %d, now %d", stamped, after)
	}
	if TestClockActive() {
		t.Error("sealing must disarm")
	}
}

// MEDIUM-1: the zero instant is clock.gno's "this claim predates the stamps"
// sentinel. The clock must never hand it out.
func TestClockNeverReadsTheZeroSentinel(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-k")
	resetTestClock(alice)
	tcArmed, tcBase, tcFloor = true, 1, 1
	if nowTime() <= 0 {
		t.Fatal("nowTime() handed out a non-positive instant")
	}
	tcArmed, tcBase, tcSkew, tcFloor = false, 0, 0, 0
	if nowTime() <= 0 {
		t.Fatal("the unarmed clock handed out a non-positive instant")
	}
}

// The disclosure has to outlive the capability. Sealing clears every driving
// flag, and an earlier version cleared the disclosure with them: a chain full of
// invented dates then reported a perfectly clean clock, which is the exact
// moment a reader is most likely to trust a fabricated date. Found by seeding a
// real node and querying it after the seal, not in review.
func TestSealingKeepsTheDisclosure(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-seal-disc")
	resetTestClock(alice)
	tcArmed, tcEverArmed, tcBase, tcFloor = true, true, testingTime(), testingTime()
	testing.SetRealm(testing.NewUserRealm(alice))
	AdvanceTestClock(cross(cur), 7257600) // twelve weeks, as the smoke scenario does

	if !TestClockFabricated() {
		t.Fatal("an armed clock must report fabricated dates")
	}
	SealTestClock(cross(cur))

	if TestClockActive() {
		t.Error("sealing must remove the capability")
	}
	if !TestClockFabricated() {
		t.Error("sealing must NOT remove the disclosure — the dates stay invented")
	}
	if got := TestClockPeakSkew(); got != 7257600 {
		t.Errorf("peak skew must survive sealing: want 7257600, got %d", got)
	}
	if TestClockSkew() != 0 {
		t.Error("current skew must be zero once sealed — nothing is being driven")
	}
	if b := testClockBanner(); b == "" {
		t.Error("a sealed test chain must still render its banner")
	} else if !strings.Contains(b, "sealed") || !strings.Contains(b, "fabricated") {
		t.Errorf("the sealed banner must say both sealed and fabricated: %q", b)
	}
}

// Peak skew is a high-water mark, not a running total that sealing resets.
func TestPeakSkewTracksTheFurthestAdvance(cur realm, t *testing.T) {
	alice := testutils.TestAddress("tc-peak")
	resetTestClock(alice)
	tcArmed, tcEverArmed, tcBase, tcFloor = true, true, testingTime(), testingTime()
	testing.SetRealm(testing.NewUserRealm(alice))
	AdvanceTestClock(cross(cur), 3600)
	AdvanceTestClock(cross(cur), 7200)
	if got := TestClockPeakSkew(); got != 10800 {
		t.Errorf("peak must accumulate with the clock: want 10800, got %d", got)
	}
	if TestClockSkew() != 10800 {
		t.Error("while armed, skew and peak agree")
	}
}
