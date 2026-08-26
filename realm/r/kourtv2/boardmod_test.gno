package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	sanitize "gno.land/p/nt/markdown/sanitize/v0"
	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// modFixture: a court whose creator is its 1-of-1 moderator, a live claim, and
// one comment on it by a second address.
//
// IT ESTABLISHES THE DIRECTORY ADMIN FIRST, ON A THROWAWAY COURT, and that is
// load-bearing for every "a moderator is not enough" arm in this file.
// directoryAdmin is the FIRST court creator in the package, so a test that runs
// before any other makes its own moderator the bootstrap global-DAO member — and
// the refusals then assert the reverse of what they say. Two tests here hit it,
// both invisible when run with neighbours and both caught by the isolation
// sweep. The fixture is where the trap lives, so the fix belongs here rather
// than in each test.
func modFixture(cur realm, slug string, mod, poster address) (uint64, uint64) {
	testCourt(cur, slug+"z", testutils.TestAddress("boot-"+slug), 10_000_000_000)
	if d := DirectoryAdmin(); d == mod || d == poster {
		panic("modFixture: a subject of the test is the bootstrap DAO member")
	}
	c := postingFixture(cur, slug, mod, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(mod))
	id := OpenClaim(cross(cur), slug, "a claim with something to discuss")
	// BOTH buy a pass. A moderator is throttled like anyone else — the design
	// deliberately gives the mod set no posting exemption — so a fixture where
	// only the poster can write would make every moderator-writes arm fail for a
	// reason that has nothing to do with moderation.
	testing.SetRealm(testing.NewUserRealm(mod))
	BuyCommentPass(cross(cur), slug)
	c.coin.Mint(poster, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(poster))
	BuyCommentPass(cross(cur), slug)
	testing.SetRealm(testing.NewUserRealm(poster))
	row := PostComment(cross(cur), slug, id, 0, "a comment a moderator may dislike")
	return id, row
}

// speechM is min(n, max(2, m)), and the arithmetic is the whole of §7.1. The
// v1.0 formula max(2, ceil(m/2)) demanded two approvals from a one-member set,
// which approveAction answers by returning false while the entrypoint returns
// normally — a successful transaction that does nothing.
func TestSpeechMIsSatisfiableAtEveryConfiguration(cur realm, t *testing.T) {
	for _, tc := range []struct{ n, m, want int }{
		{1, 1, 1}, // the modal court: capped by n, NOT 2
		{2, 1, 2},
		{2, 2, 2},
		{3, 1, 2},
		{3, 3, 3},
		{9, 4, 4},
		{32, 32, 32},
	} {
		got := speechM(&courtMod{n: tc.n, m: tc.m})
		if got != tc.want {
			t.Fatal("speechM(n=" + strconv.Itoa(tc.n) + ",m=" + strconv.Itoa(tc.m) +
				") = " + strconv.Itoa(got) + ", want " + strconv.Itoa(tc.want))
		}
		if got > tc.n {
			t.Fatal("speechM above n is unsatisfiable: a set that can never act")
		}
		if got < tc.m {
			t.Fatal("speechM below the set's own m gives speech a looser rule than money")
		}
	}
}

func TestABoardSanctionRefusesEveryoneButAModerator(cur realm, t *testing.T) {
	mod := testutils.TestAddress("bm1-mod")
	poster := testutils.TestAddress("bm1-poster")
	id, row := modFixture(cur, "bm1", mod, poster)

	for _, who := range []address{poster, testutils.TestAddress("bm1-stranger")} {
		testing.SetRealm(testing.NewUserRealm(who))
		uassert.AbortsContains(t, cur, "not a moderator of this court", func() {
			HideBoardRow(cross(cur), "bm1", id, row, boardCodeSpam)
		})
		testing.SetRealm(testing.NewUserRealm(who))
		uassert.AbortsContains(t, cur, "not a moderator of this court", func() {
			SlashStanding(cross(cur), "bm1", poster, 1, boardCodeSpam)
		})
		testing.SetRealm(testing.NewUserRealm(who))
		uassert.AbortsContains(t, cur, "not a moderator of this court", func() {
			FreezeBoard(cross(cur), "bm1", poster, 100, boardCodeAbuse)
		})
		testing.SetRealm(testing.NewUserRealm(who))
		uassert.AbortsContains(t, cur, "not a moderator of this court", func() {
			FreezeClaimBoard(cross(cur), "bm1", id, 100, boardCodeSpam)
		})
	}

	// THE CONTROL: the same call from the moderator lands, so the refusals above
	// are about authority and not about a fixture that cannot succeed.
	testing.SetRealm(testing.NewUserRealm(mod))
	HideBoardRow(cross(cur), "bm1", id, row, boardCodeSpam)
	if BoardRowState("bm1", id, row) != "h" {
		t.Fatal("the moderator's own hide must land, or the refusals prove nothing")
	}
	// The ROW leaves the ranked index, not merely its text. Asking whether the
	// text is in Top proves nothing — boardTextFor withholds it either way.
	if topHasRow("bm1", id, row) {
		t.Fatal("a hidden row must leave the ranked index")
	}

	// THE UNDO HAS ITS OWN PERIMETER, and it is not the same one: requireMod
	// rather than requireActiveMod. Deleting that check left the suite green,
	// exactly as the pre-existing UnhideItem gap did, because every test called
	// it AS a moderator.
	for _, who := range []address{poster, testutils.TestAddress("bm1-stranger")} {
		testing.SetRealm(testing.NewUserRealm(who))
		uassert.AbortsContains(t, cur, "not a moderator of this court", func() {
			UnhideBoardRow(cross(cur), "bm1", id, row)
		})
		testing.SetRealm(testing.NewUserRealm(who))
		uassert.AbortsContains(t, cur, "not a moderator of this court", func() {
			UnfreezeBoard(cross(cur), "bm1", poster)
		})
	}

	testing.SetRealm(testing.NewUserRealm(mod))
	UnhideBoardRow(cross(cur), "bm1", id, row)
	if BoardRowState("bm1", id, row) != "." {
		t.Fatal("an unhide must lift the hide it just set")
	}
	if !topHasRow("bm1", id, row) {
		t.Fatal("an unhidden row must return to the ranked index")
	}
}

// A slash lands ON a rung, never touches highWater, and is fully reversible.
func TestASlashRatchetsWholeLevelsAndIsReversible(cur realm, t *testing.T) {
	mod := testutils.TestAddress("bm2-mod")
	poster := testutils.TestAddress("bm2-poster")
	modFixture(cur, "bm2", mod, poster)
	c := mustCourt("bm2")

	// Put the poster at the top rung by fiat: this test is about the sanction,
	// not about earning, and the earning hooks have their own tests.
	r := getStanding(c, poster)
	r.score = levelFloor(c, 3) * 2
	r.highWater = r.score
	before := r.score
	if postLevel(c, poster) != 3 {
		t.Fatal("the fixture must start at the top rung")
	}

	testing.SetRealm(testing.NewUserRealm(mod))
	SlashStanding(cross(cur), "bm2", poster, 1, boardCodeSpam)
	if got := postLevel(c, poster); got != 2 {
		t.Fatal("a one-level slash must land exactly one rung down, got level " +
			strconv.FormatInt(got, 10))
	}
	if r.highWater != before {
		t.Fatal("a slash must never touch highWater; that asymmetry is the whole " +
			"of the reversibility argument")
	}

	// Two more levels from level 2 floors at 0 rather than going negative.
	testing.SetRealm(testing.NewUserRealm(mod))
	SlashStanding(cross(cur), "bm2", poster, 3, boardCodeAbuse)
	if postLevel(c, poster) != 0 {
		t.Fatal("a slash past the bottom must floor at level 0")
	}
	if r.score < 0 {
		t.Fatal("standing must never go negative")
	}
	// AND THE PASS IS FORFEIT. Without this the slash is defeatable for 0.1 CC:
	// postLevel floors a pass-holder at level 1, so a zeroed address would keep
	// posting at entry rate forever and only the 12h freeze would remain.
	if r.passHeld {
		t.Fatal("a slash to level 0 must forfeit the entry pass, or the sanction " +
			"is worth 0.1 CC to defeat permanently")
	}
	// A PARTIAL slash must NOT: destroying a purchase is a bigger act than the
	// one the set voted for.
	other := testutils.TestAddress("bm2-other")
	c.coin.Mint(other, 20_000_000_000)
	testing.SetRealm(testing.NewUserRealm(other))
	BuyCommentPass(cross(cur), "bm2")
	or := getStanding(c, other)
	or.score, or.highWater = levelFloor(c, 3)*2, levelFloor(c, 3)*2
	testing.SetRealm(testing.NewUserRealm(mod))
	SlashStanding(cross(cur), "bm2", other, 1, boardCodeSpam)
	if !or.passHeld {
		t.Fatal("a one-level slash must leave the pass alone")
	}

	// A SUB-RUNG SCORE STILL ZEROES. postLevel already reports 0 for a score of
	// 1, so target is -1, and the address lands at 0 rather than staying where a
	// "nothing to take" reading would leave it.
	//
	// The `if r.score > want` conditional guarding that assignment is NOT tested,
	// and cannot be: target is always strictly below the current level, so
	// levelFloor(target) < levelFloor(level) <= score, and the branch never
	// fails. It is kept as the correct expression of "ratchet" rather than
	// simplified away, because passHeld already makes postLevel over-report for a
	// zero score, and one more floor of that kind turns an unconditional
	// assignment into a grant. Recorded in mutations-kourtv2-KNOWN-GAPS.json with
	// this proof.
	low := testutils.TestAddress("bm2-low")
	lr := getStanding(c, low)
	lr.score, lr.highWater = 1, 1
	testing.SetRealm(testing.NewUserRealm(mod))
	SlashStanding(cross(cur), "bm2", low, 1, boardCodeSpam)
	if lr.score != 0 {
		t.Fatal("a slash of a sub-rung score must zero it: got " +
			strconv.FormatInt(lr.score, 10))
	}
	if lr.highWater != 1 {
		t.Fatal("and must still leave highWater alone")
	}

	// And the repair puts back exactly what was taken — no more.
	testing.SetRealm(testing.NewUserRealm(mod))
	got := RestoreStanding(cross(cur), "bm2", poster)
	if got != before || r.score != before {
		t.Fatal("a restore must return the score to highWater exactly, got " +
			strconv.FormatInt(got, 10) + " want " + strconv.FormatInt(before, 10))
	}
	// Restoring again is a refusal: a restore that is idempotent-and-silent
	// cannot be told apart from one that minted.
	testing.SetRealm(testing.NewUserRealm(mod))
	uassert.AbortsContains(t, cur, "nothing to restore", func() {
		RestoreStanding(cross(cur), "bm2", poster)
	})
	// A slash of 0 or 4 levels is not a slash.
	for _, bad := range []int64{0, -1, 4} {
		testing.SetRealm(testing.NewUserRealm(mod))
		uassert.AbortsContains(t, cur, "1, 2 or 3 whole levels", func() {
			SlashStanding(cross(cur), "bm2", poster, bad, boardCodeSpam)
		})
	}
}

// The freeze bars board writes and NOTHING else. The allowlist is the point.
func TestAFreezeBarsBoardWritesAndNothingElse(cur realm, t *testing.T) {
	mod := testutils.TestAddress("bm3-mod")
	poster := testutils.TestAddress("bm3-poster")
	id, row := modFixture(cur, "bm3", mod, poster)
	c := mustCourt("bm3")

	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeBoard(cross(cur), "bm3", poster, 100, boardCodeAbuse)
	if BoardFrozenUntil("bm3", poster) == 0 {
		t.Fatal("the freeze must be visible to the person under it")
	}

	testing.SetRealm(testing.NewUserRealm(poster))
	uassert.AbortsContains(t, cur, "frozen out of this court's boards", func() {
		PostComment(cross(cur), "bm3", id, 0, "let me back in")
	})
	// An upvote is a board write too — the throttle draws on the same bucket.
	testing.SetRealm(testing.NewUserRealm(mod))
	modRow := PostComment(cross(cur), "bm3", id, 0, "the moderator's own comment")
	testing.SetRealm(testing.NewUserRealm(poster))
	uassert.AbortsContains(t, cur, "frozen out of this court's boards", func() {
		UpvoteComment(cross(cur), "bm3", id, modRow)
	})

	// THE ALLOWLIST. Everything the election needs, and the money paths, still
	// work: a freeze that reached these could silence the vote that removes the
	// set that imposed it.
	testing.SetRealm(testing.NewUserRealm(poster))
	other := OpenClaim(cross(cur), "bm3", "a frozen address may still open a claim")
	if other == 0 {
		t.Fatal("a frozen address must still be able to open a claim")
	}
	testing.SetRealm(testing.NewUserRealm(poster))
	Stake(cross(cur), "bm3", other, sideYES, 1_000_000)
	if !boardFrozen(c, poster) {
		t.Fatal("none of the allowlisted acts may clear the freeze")
	}
	// And the row it already wrote stays readable: a freeze is prospective.
	if BoardRowState("bm3", id, row) != "." {
		t.Fatal("a freeze must not retroactively withhold what the address wrote")
	}

	// It EXPIRES, lazily — nothing sweeps.
	testing.SkipHeights(101)
	if boardFrozen(c, poster) {
		t.Fatal("a freeze must expire on its own, with no sweep")
	}
	if BoardFrozenUntil("bm3", poster) != 0 {
		t.Fatal("an expired freeze must read as no freeze")
	}
}

// The ceiling is only a ceiling if a set cannot re-freeze in the next block.
func TestTheFreezeCeilingIsNotAPerTransactionFormality(cur realm, t *testing.T) {
	mod := testutils.TestAddress("bm4-mod")
	poster := testutils.TestAddress("bm4-poster")
	modFixture(cur, "bm4", mod, poster)

	testing.SetRealm(testing.NewUserRealm(mod))
	uassert.AbortsContains(t, cur, "at most freezeMaxBlocks", func() {
		FreezeBoard(cross(cur), "bm4", poster, freezeMaxBlocks+1, boardCodeAbuse)
	})
	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeBoard(cross(cur), "bm4", poster, freezeMaxBlocks, boardCodeAbuse)

	// Immediately after it expires, the gap still bites.
	testing.SkipHeights(freezeMaxBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(mod))
	uassert.AbortsContains(t, cur, "frozen too recently", func() {
		FreezeBoard(cross(cur), "bm4", poster, 10, boardCodeAbuse)
	})
	// Past the gap it is allowed again — otherwise this is a permanent ban
	// wearing a ceiling's clothes.
	testing.SkipHeights(freezeGapBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeBoard(cross(cur), "bm4", poster, 10, boardCodeAbuse)
	if BoardFrozenUntil("bm4", poster) == 0 {
		t.Fatal("past the gap a fresh freeze must be allowed, or the gap is a ban")
	}
}

// One claim's board closes; the claim itself stays fully live.
func TestFreezingOneBoardLeavesTheClaimLive(cur realm, t *testing.T) {
	mod := testutils.TestAddress("bm5-mod")
	poster := testutils.TestAddress("bm5-poster")
	id, _ := modFixture(cur, "bm5", mod, poster)

	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeClaimBoard(cross(cur), "bm5", id, 100, boardCodeOffTopic)
	if ClaimBoardFrozenUntil("bm5", id) == 0 {
		t.Fatal("the freeze must be visible")
	}
	testing.SetRealm(testing.NewUserRealm(poster))
	uassert.AbortsContains(t, cur, "board is frozen by moderators", func() {
		PostComment(cross(cur), "bm5", id, 0, "still talking")
	})
	// The CLAIM. Staking on it is untouched — a board freeze is a speech
	// sanction, not a market halt.
	testing.SetRealm(testing.NewUserRealm(poster))
	Stake(cross(cur), "bm5", id, sideYES, 1_000_000)

	testing.SetRealm(testing.NewUserRealm(mod))
	ThawClaimBoard(cross(cur), "bm5", id)
	testing.SetRealm(testing.NewUserRealm(poster))
	PostComment(cross(cur), "bm5", id, 0, "back on")

	// THE RE-FREEZE GAP, which this verb shipped without — so the one freeze a
	// set could hold at a 100% duty cycle was the one aimed at a whole claim's
	// board rather than at one person. Thawing must not buy a fresh window.
	testing.SetRealm(testing.NewUserRealm(mod))
	uassert.AbortsContains(t, cur, "frozen too recently", func() {
		FreezeClaimBoard(cross(cur), "bm5", id, 5, boardCodeOffTopic)
	})

	// AND THE GAP IS THE FULL CEILING, NOT THE LENGTH ASKED FOR. A second claim,
	// frozen for one block, waited past `1 + freezeGapBlocks` and short of
	// `freezeMaxBlocks + freezeGapBlocks` — the only window where the two
	// stampings differ. A shorter wait is refused under both and proves nothing.
	testing.SetRealm(testing.NewUserRealm(mod))
	id2 := OpenClaim(cross(cur), "bm5", "a second claim to time the gap on")
	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeClaimBoard(cross(cur), "bm5", id2, 1, boardCodeOffTopic)
	testing.SkipHeights(1 + freezeGapBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(mod))
	uassert.AbortsContains(t, cur, "frozen too recently", func() {
		FreezeClaimBoard(cross(cur), "bm5", id2, 1, boardCodeOffTopic)
	})

	// Past the full window it freezes again, and expires on its own — lazily,
	// with nothing sweeping.
	testing.SkipHeights(freezeMaxBlocks + freezeGapBlocks)
	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeClaimBoard(cross(cur), "bm5", id, 5, boardCodeOffTopic)
	if ClaimBoardFrozenUntil("bm5", id) == 0 {
		t.Fatal("past the gap a fresh board freeze must land, or the gap is a ban")
	}
	testing.SkipHeights(6)
	if ClaimBoardFrozenUntil("bm5", id) != 0 {
		t.Fatal("a claim-board freeze must expire lazily")
	}
}

// The undos survive a suspension; the sanctions do not. A suspended set that
// could still sanction would be unpunishable, and one that could not de-escalate
// would make its own mistakes permanent.
func TestASuspendedSetMayOnlyDeEscalate(cur realm, t *testing.T) {
	mod := testutils.TestAddress("bm6-mod")
	poster := testutils.TestAddress("bm6-poster")
	id, row := modFixture(cur, "bm6", mod, poster)
	c := mustCourt("bm6")

	testing.SetRealm(testing.NewUserRealm(mod))
	HideBoardRow(cross(cur), "bm6", id, row, boardCodeSpam)
	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeBoard(cross(cur), "bm6", poster, 100, boardCodeAbuse)
	r := getStanding(c, poster)
	r.score, r.highWater = levelFloor(c, 3)*2, levelFloor(c, 3)*2
	testing.SetRealm(testing.NewUserRealm(mod))
	SlashStanding(cross(cur), "bm6", poster, 1, boardCodeSpam)

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalSuspendSet(cross(cur), "bm6")

	// Sanctions refused.
	for _, call := range []func(){
		func() { HideBoardRow(cross(cur), "bm6", id, row, boardCodeSpam) },
		func() { SlashStanding(cross(cur), "bm6", poster, 1, boardCodeSpam) },
		func() { FreezeBoard(cross(cur), "bm6", poster, 10, boardCodeAbuse) },
		func() { FreezeClaimBoard(cross(cur), "bm6", id, 10, boardCodeSpam) },
	} {
		testing.SetRealm(testing.NewUserRealm(mod))
		uassert.AbortsContains(t, cur, "suspended", call)
	}

	// Undos allowed — this is the half a suspension must not take away.
	testing.SetRealm(testing.NewUserRealm(mod))
	UnhideBoardRow(cross(cur), "bm6", id, row)
	testing.SetRealm(testing.NewUserRealm(mod))
	UnfreezeBoard(cross(cur), "bm6", poster)
	testing.SetRealm(testing.NewUserRealm(mod))
	RestoreStanding(cross(cur), "bm6", poster)
	if boardFrozen(c, poster) || r.score != r.highWater ||
		BoardRowState("bm6", id, row) != "." {
		t.Fatal("a suspended set must still be able to undo its own acts")
	}
}

// The global backstop, and the reason it is one integer rather than a walk.
func TestTheGlobalBackstopClearsEveryFreezeInOneWrite(cur realm, t *testing.T) {
	mod := testutils.TestAddress("bm7-mod")
	a := testutils.TestAddress("bm7-a")
	b := testutils.TestAddress("bm7-b")
	id, _ := modFixture(cur, "bm7", mod, a)
	c := mustCourt("bm7")
	c.coin.Mint(b, 20_000_000_000)

	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeBoard(cross(cur), "bm7", a, 1000, boardCodeAbuse)
	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeBoard(cross(cur), "bm7", b, 1000, boardCodeAbuse)
	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeClaimBoard(cross(cur), "bm7", id, 1000, boardCodeSpam)
	if !boardFrozen(c, a) || !boardFrozen(c, b) || !claimBoardFrozen(c, id) {
		t.Fatal("the fixture must have three live freezes")
	}

	// THE PERIMETER FIRST. The court's own moderator is not enough: these verbs
	// exist for the case where that set IS the problem, so a mod-reachable
	// backstop is no backstop. Both were deletable with the suite green.
	for _, who := range []address{mod, testutils.TestAddress("bm7-stranger")} {
		testing.SetRealm(testing.NewUserRealm(who))
		uassert.AbortsContains(t, cur, "may clear board bits (recovery)", func() {
			GlobalClearBoardBits(cross(cur), "bm7")
		})
		testing.SetRealm(testing.NewUserRealm(who))
		uassert.AbortsContains(t, cur, "may restore standing (recovery)", func() {
			GlobalRestoreStanding(cross(cur), "bm7", a)
		})
	}

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalClearBoardBits(cross(cur), "bm7")
	if boardFrozen(c, a) || boardFrozen(c, b) || claimBoardFrozen(c, id) {
		t.Fatal("one write must clear every board freeze in the court")
	}
	// THE RECOVERY VERB DOES NOT RE-ARM THE POWER AGAINST THE ADDRESS IT JUST
	// FREED. The gap stamp survives the epoch bump on purpose: a backstop that
	// let the same set re-freeze `a` in the next block would be a backstop that
	// bought the set a fresh window every time it was used.
	testing.SetRealm(testing.NewUserRealm(mod))
	uassert.AbortsContains(t, cur, "frozen too recently", func() {
		FreezeBoard(cross(cur), "bm7", a, 1000, boardCodeAbuse)
	})
	// But the POWER is intact — a different address freezes normally. Without
	// this arm the refusal above would read the same if the clear had disabled
	// freezing outright.
	fresh := testutils.TestAddress("bm7-fresh")
	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeBoard(cross(cur), "bm7", fresh, 1000, boardCodeAbuse)
	if !boardFrozen(c, fresh) {
		t.Fatal("bumping the epoch must not disable freezing, only clear what was set")
	}

	// A slash is NOT a bit and survives the bit clear — the per-address verb is
	// what undoes it, and the global DAO may put back only what was taken.
	r := getStanding(c, a)
	r.score, r.highWater = levelFloor(c, 3)*2, levelFloor(c, 3)*2
	testing.SetRealm(testing.NewUserRealm(mod))
	SlashStanding(cross(cur), "bm7", a, 2, boardCodeSpam)
	slashed := r.score
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalClearBoardBits(cross(cur), "bm7")
	if r.score != slashed {
		t.Fatal("clearing board bits must not silently un-slash: a score is not a bit")
	}
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalRestoreStanding(cross(cur), "bm7", a)
	if r.score != r.highWater {
		t.Fatal("the global restore must put the score back to highWater")
	}
	// And it may not MINT: highWater is the ceiling for the global DAO too.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "nothing to restore", func() {
		GlobalRestoreStanding(cross(cur), "bm7", a)
	})
}

// A reset takes n to 0, so nobody is left who could unfreeze. A freeze that
// outlived the set that imposed it would be a sanction with no author.
func TestResettingAModSetClearsItsFreezes(cur realm, t *testing.T) {
	mod := testutils.TestAddress("bm8-mod")
	poster := testutils.TestAddress("bm8-poster")
	modFixture(cur, "bm8", mod, poster)
	c := mustCourt("bm8")

	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeBoard(cross(cur), "bm8", poster, 1000, boardCodeAbuse)
	if !boardFrozen(c, poster) {
		t.Fatal("the fixture must have a live freeze")
	}
	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	ResetModSet(cross(cur), "bm8")
	if boardFrozen(c, poster) {
		t.Fatal("a reset to n=0 must not leave an unliftable freeze behind")
	}
}

// Every sanction and every undo reaches the court-level log, and the log has its
// own purge verb because its row ids are a separate sequence.
func TestEverySanctionReachesTheCourtLog(cur realm, t *testing.T) {
	mod := testutils.TestAddress("bm9-mod")
	poster := testutils.TestAddress("bm9-poster")
	modFixture(cur, "bm9", mod, poster)
	c := mustCourt("bm9")
	r := getStanding(c, poster)
	r.score, r.highWater = levelFloor(c, 3)*2, levelFloor(c, 3)*2

	testing.SetRealm(testing.NewUserRealm(mod))
	SlashStanding(cross(cur), "bm9", poster, 1, boardCodeSpam)
	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeBoard(cross(cur), "bm9", poster, 50, boardCodeAbuse)
	testing.SetRealm(testing.NewUserRealm(mod))
	UnfreezeBoard(cross(cur), "bm9", poster)
	testing.SetRealm(testing.NewUserRealm(mod))
	RestoreStanding(cross(cur), "bm9", poster)

	log := renderModLog("bm9")
	for _, want := range []string{"slash:1", "spam", "freeze:50", "abuse", "unfreeze", "restore"} {
		if !strings.Contains(log, sanitize.InlineText(want)) {
			t.Fatal("the court log does not record " + want + ":\n" + log)
		}
	}
	// The row id is printed, because it is the handle PurgeCourtLogRow takes.
	if !strings.Contains(log, "court row 1") {
		t.Fatal("a court log row must print its id, or its purge verb is unusable")
	}

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "no such court log row", func() {
		PurgeCourtLogRow(cross(cur), "bm9", 9999, "csam")
	})
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeCourtLogRow(cross(cur), "bm9", 1, "csam")
	after := renderModLog("bm9")
	if !strings.Contains(after, "reason removed on legal grounds") {
		t.Fatal("a purged court row must say so")
	}
	// THE REASON LEFT STATE, READ FROM STATE. The render hides a purged row's
	// reason on the `purged` bit alone, so every render-level assertion here
	// passes with the line that clears the string deleted — which is exactly what
	// happened: the mutant survived a test that looked right.
	if c.mod.log[0].reason != "" {
		t.Fatal("a purge must remove the reason from state, not merely hide it at " +
			"render: found " + c.mod.log[0].reason)
	}
	if !c.mod.log[0].purged {
		t.Fatal("and must mark the row purged")
	}
	// ONE ROW. The neighbour's reason is untouched, in state and on the page.
	if c.mod.log[1].reason == "" {
		t.Fatal("a purge must reach exactly one row")
	}
	if !strings.Contains(after, sanitize.InlineText("abuse")) {
		t.Fatal("the neighbour's reason still renders")
	}
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("bm9-stranger")))
	uassert.AbortsContains(t, cur, "only a global DAO member may purge", func() {
		PurgeCourtLogRow(cross(cur), "bm9", 2, "csam")
	})
}

// THE THREE BUGS THE SIMPLIFICATION REVIEW FOUND. Each of these failed against
// the code as shipped an hour before it was written.

// An author must not be able to reverse a moderator's speechM-of-n act by
// calling the verb that governs their OWN bit. Both used to write one field.
func TestAnAuthorCannotReverseAModeratorHide(cur realm, t *testing.T) {
	mod := testutils.TestAddress("bmx-mod")
	poster := testutils.TestAddress("bmx-poster")
	id, row := modFixture(cur, "bmx", mod, poster)
	c := mustCourt("bmx")
	cs := mustClaim(c, id)

	testing.SetRealm(testing.NewUserRealm(mod))
	HideBoardRow(cross(cur), "bmx", id, row, boardCodeSpam)

	// The author's own verb still works — it is their bit — and must change
	// nothing about the row's visibility while the moderator's bit is set.
	testing.SetRealm(testing.NewUserRealm(poster))
	HideOwnComment(cross(cur), "bmx", id, row, false)
	if BoardRowState("bmx", id, row) != "h" {
		t.Fatal("one call from the sanctioned author reversed an m-of-n moderator act")
	}
	if topHasRow("bmx", id, row) {
		t.Fatal("and re-published the row into the ranked index")
	}
	if !mustBoardRow(cs, row).hiddenByMod {
		t.Fatal("the moderator's bit must be untouched by the author's verb")
	}
	// AND THE PAGE MUST SAY WHOSE ACT IT WAS. "Withdrawn from this listing" over
	// a moderator removal puts the court's act in the author's mouth, which is
	// an assertion about a person MODERATION §6 forbids this realm from making.
	listing := renderBoardPage("bmx", id)
	if !strings.Contains(listing, "by this court's moderators") {
		t.Fatal("a moderator hide must be reported as one:\n" + listing)
	}
	if strings.Contains(listing, "_Withdrawn from this listing") {
		t.Fatal("a moderator hide must not be reported as the author's withdrawal")
	}

	// SYMMETRICALLY: a moderator's unhide must not expose a row its author
	// withdrew. Same field, other direction, equally untested before now.
	testing.SetRealm(testing.NewUserRealm(poster))
	HideOwnComment(cross(cur), "bmx", id, row, true)
	testing.SetRealm(testing.NewUserRealm(mod))
	UnhideBoardRow(cross(cur), "bmx", id, row)
	if BoardRowState("bmx", id, row) != "h" {
		t.Fatal("a moderator unhide exposed a row its author had withdrawn")
	}
	if topHasRow("bmx", id, row) {
		t.Fatal("and put it back in the ranked index")
	}

	// Only when BOTH are clear does the row return.
	testing.SetRealm(testing.NewUserRealm(poster))
	HideOwnComment(cross(cur), "bmx", id, row, false)
	if BoardRowState("bmx", id, row) != "." || !topHasRow("bmx", id, row) {
		t.Fatal("with both authorities clear the row must read and rank again")
	}
}

// freeze -> unfreeze -> freeze must not slip the gap. It did: UnfreezeBoard
// zeroes frozenUntil, which the gap check used to read.
func TestUnfreezingDoesNotBuyAFreshFreezeWindow(cur realm, t *testing.T) {
	mod := testutils.TestAddress("bmy-mod")
	poster := testutils.TestAddress("bmy-poster")
	modFixture(cur, "bmy", mod, poster)

	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeBoard(cross(cur), "bmy", poster, freezeMaxBlocks, boardCodeAbuse)
	testing.SetRealm(testing.NewUserRealm(mod))
	UnfreezeBoard(cross(cur), "bmy", poster)

	// De-escalating must not be a way to re-arm. Without this the ceiling was
	// defeated for the price of one extra speechM round, indefinitely.
	testing.SetRealm(testing.NewUserRealm(mod))
	uassert.AbortsContains(t, cur, "frozen too recently", func() {
		FreezeBoard(cross(cur), "bmy", poster, freezeMaxBlocks, boardCodeAbuse)
	})

	// A SHORT freeze must not buy a short cooldown either — the gap is stamped
	// at the full CEILING, not at the length asked for, or a set buys the gap
	// off one block at a time: freeze for 1, wait 1+gap, freeze again, forever.
	//
	// The wait below is past `1 + freezeGapBlocks` and short of
	// `freezeMaxBlocks + freezeGapBlocks`, which is the only window where the two
	// stampings differ. A shorter wait is refused under both and proves nothing.
	other := testutils.TestAddress("bmy-other")
	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeBoard(cross(cur), "bmy", other, 1, boardCodeAbuse)
	testing.SkipHeights(1 + freezeGapBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(mod))
	uassert.AbortsContains(t, cur, "frozen too recently", func() {
		FreezeBoard(cross(cur), "bmy", other, 1, boardCodeAbuse)
	})

	// Past the full window it is allowed again, or the gap is a permanent ban.
	testing.SkipHeights(freezeMaxBlocks + freezeGapBlocks)
	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeBoard(cross(cur), "bmy", other, 10, boardCodeAbuse)
	if BoardFrozenUntil("bmy", other) == 0 {
		t.Fatal("past the full window a fresh freeze must land")
	}
}

// THE PARAMETER OVERRIDES ARE THE MOST POWERFUL SPEECH LEVER IN THE REALM, and
// they shipped as requireActiveMod alone — one member, no vote, no log, no
// event, no expiry, and no verb outside the set that could undo them.
func TestACourtParameterOverrideTakesTheSpeechThreshold(cur realm, t *testing.T) {
	mod := testutils.TestAddress("bmp-mod")
	mod2 := testutils.TestAddress("bmp-mod2")
	poster := testutils.TestAddress("bmp-poster")
	modFixture(cur, "bmp", mod, poster)
	c := mustCourt("bmp")

	// Seat a second moderator so speechM is 2 and a single key is not enough.
	// On the 1-of-1 court the fixture builds, speechM is 1 and every arm below
	// would fire on the first call — proving nothing about the threshold.
	testing.SetRealm(testing.NewUserRealm(mod))
	AppointMods(cross(cur), "bmp", 1, mod, mod2)
	if SpeechThreshold("bmp") != 2 {
		t.Fatal("the fixture must give this court a speech threshold above 1")
	}

	// THE THROTTLE. mustLadder accepts this — strictly increasing, within
	// bounds — and it puts every address below 99.98% of supply at level 0.
	testing.SetRealm(testing.NewUserRealm(mod))
	SetCourtLadder(cross(cur), "bmp", 9998, 9999, 10000, 1, 2)
	if c.ladder != nil {
		t.Fatal("one member of a 2-threshold set installed a court-wide throttle alone")
	}
	if postLevel(c, poster) == 0 {
		t.Fatal("...and it took effect")
	}

	// A SECOND MEMBER PROPOSING A DIFFERENT TUPLE MUST NOT COMPLETE THE FIRST.
	// Without the values in the action key, these two would each count toward one
	// threshold and the set would install whichever arrived last.
	testing.SetRealm(testing.NewUserRealm(mod2))
	SetCourtLadder(cross(cur), "bmp", 6, 26, 101, 3, 10)
	if c.ladder != nil {
		t.Fatal("two members approving DIFFERENT ladders combined into one act")
	}

	// Agreeing on the same tuple installs it.
	testing.SetRealm(testing.NewUserRealm(mod2))
	SetCourtLadder(cross(cur), "bmp", 9998, 9999, 10000, 1, 2)
	if c.ladder == nil {
		t.Fatal("speechM members agreeing must install the override")
	}
	if !strings.Contains(renderModLog("bmp"), sanitize.InlineText("setladder:9998:9999:10000:1:2")) {
		t.Fatal("a court-wide speech act must be in the log, with what was set")
	}

	// The same three properties for the earning rates.
	testing.SetRealm(testing.NewUserRealm(mod))
	SetCourtCreditRates(cross(cur), "bmp", 2, 2, 2, 1, 1)
	if c.creditRates != nil {
		t.Fatal("one member alone cut every earning rate ~5000x")
	}
	// Same "different tuples must not combine" arm as the ladder above. It has
	// to be here too: the two setters have separate action keys, so one of them
	// keying on the values proves nothing about the other, and the rates key
	// survived deletion until this arm existed.
	testing.SetRealm(testing.NewUserRealm(mod2))
	SetCourtCreditRates(cross(cur), "bmp", 3, 3, 2, 1, 1)
	if c.creditRates != nil {
		t.Fatal("two members approving DIFFERENT rate tuples combined into one act")
	}
	testing.SetRealm(testing.NewUserRealm(mod2))
	SetCourtCreditRates(cross(cur), "bmp", 2, 2, 2, 1, 1)
	if c.creditRates == nil {
		t.Fatal("speechM members agreeing must install the rates")
	}

	// THE BACKSTOP. A court moderator is not enough — the verb exists for the
	// case where that set IS the problem.
	for _, who := range []address{mod, poster} {
		testing.SetRealm(testing.NewUserRealm(who))
		uassert.AbortsContains(t, cur, "clear court parameters (recovery)", func() {
			GlobalClearCourtParams(cross(cur), "bmp")
		})
	}
	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalClearCourtParams(cross(cur), "bmp")
	if c.ladder != nil || c.creditRates != nil {
		t.Fatal("one write must drop both overrides")
	}
	if postLevel(c, poster) == 0 {
		t.Fatal("clearing the override must actually restore the court's board")
	}
	testing.SetRealm(testing.NewUserRealm(dadmin))
	uassert.AbortsContains(t, cur, "no parameter overrides", func() {
		GlobalClearCourtParams(cross(cur), "bmp")
	})
}

// Returning to the realm default is de-escalation, so it must outlive a
// suspension — otherwise the set that got itself suspended for throttling a
// court is the one set that cannot lift the throttle.
func TestASuspendedSetCanStillClearItsOwnOverride(cur realm, t *testing.T) {
	mod := testutils.TestAddress("bmq-mod")
	poster := testutils.TestAddress("bmq-poster")
	modFixture(cur, "bmq", mod, poster)
	c := mustCourt("bmq")

	testing.SetRealm(testing.NewUserRealm(mod))
	SetCourtLadder(cross(cur), "bmq", 9998, 9999, 10000, 1, 2)
	testing.SetRealm(testing.NewUserRealm(mod))
	SetCourtCreditRates(cross(cur), "bmq", 2, 2, 2, 1, 1)

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalSuspendSet(cross(cur), "bmq")

	// Setting is refused while suspended...
	testing.SetRealm(testing.NewUserRealm(mod))
	uassert.AbortsContains(t, cur, "suspended", func() {
		SetCourtLadder(cross(cur), "bmq", 5, 25, 100, 3, 10)
	})
	// ...but clearing is not.
	testing.SetRealm(testing.NewUserRealm(mod))
	ClearCourtLadder(cross(cur), "bmq")
	testing.SetRealm(testing.NewUserRealm(mod))
	ClearCourtCreditRates(cross(cur), "bmq")
	if c.ladder != nil || c.creditRates != nil {
		t.Fatal("a suspended set must be able to lift its own override")
	}
	// And a clear with nothing to clear is a refusal, not a silent no-op — an
	// idempotent clear cannot be told apart from one that never had authority.
	testing.SetRealm(testing.NewUserRealm(mod))
	uassert.AbortsContains(t, cur, "no ladder override", func() {
		ClearCourtLadder(cross(cur), "bmq")
	})
	testing.SetRealm(testing.NewUserRealm(mod))
	uassert.AbortsContains(t, cur, "no standing-rate override", func() {
		ClearCourtCreditRates(cross(cur), "bmq")
	})
}

// A page that tells a frozen person to buy a pass that will not work is worse
// than a page that says nothing. Neither freeze read had a caller anywhere.
func TestAFrozenAddressIsToldSoAndNotSoldAPass(cur realm, t *testing.T) {
	mod := testutils.TestAddress("bmz-mod")
	poster := testutils.TestAddress("bmz-poster")
	id, _ := modFixture(cur, "bmz", mod, poster)
	c := mustCourt("bmz")

	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeBoard(cross(cur), "bmz", poster, 500, boardCodeAbuse)

	page := renderStanding("bmz", poster.String())
	if !strings.Contains(page, "frozen you out of its boards") {
		t.Fatalf("the page must say they are frozen:\n%s", page)
	}
	if !strings.Contains(page, "will not lift it") {
		t.Fatal("and must say a pass would not help, rather than offering one")
	}
	if !strings.Contains(page, "you may still stake") {
		t.Fatal("and must state the allowlist — a freeze that looked total would " +
			"discourage the very election that is the remedy")
	}

	// The CLAIM board freeze, on the board page, which rendered nothing at all.
	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeClaimBoard(cross(cur), "bmz", id, 500, boardCodeOffTopic)
	bp := renderBoardPage("bmz", id)
	if !strings.Contains(bp, "paused on this claim") {
		t.Fatalf("a frozen board must say so instead of being a silent wall:\n%s", bp)
	}
	if !strings.Contains(bp, "answers, stakes and the verdict continue") {
		t.Fatal("and must say the claim itself is unaffected")
	}

	// A SLASHED address must not be told "yet", and must be told where the pass
	// went. The forfeit is silent otherwise: the only trace is a bare integer.
	r := getStanding(c, poster)
	r.score, r.highWater = levelFloor(c, 3)*2, levelFloor(c, 3)*2
	testing.SetRealm(testing.NewUserRealm(mod))
	SlashStanding(cross(cur), "bmz", poster, 3, boardCodeSpam)
	page = renderStanding("bmz", poster.String())
	if !strings.Contains(page, "with it the\nentry pass") {
		t.Fatalf("a zeroed address must be told the pass is forfeit:\n%s", page)
	}
	if strings.Contains(page, "cannot comment here yet") {
		t.Fatal("\"yet\" says nothing happened to you; a slash did")
	}
	// While the freeze is live the purchase is NOT offered — it would not help.
	if strings.Contains(page, "buy a new pass") {
		t.Fatal("a frozen address must not be invited to buy a pass")
	}
	// Once it lifts, the route back IS offered: a slash is reversible and the
	// page must say how, or the sanction reads as permanent.
	testing.SkipHeights(600)
	page = renderStanding("bmz", poster.String())
	if !strings.Contains(page, "buy a new pass") {
		t.Fatalf("a thawed, slashed address must be told the way back:\n%s", page)
	}
}

// The mod page stated the wrong rule: board acts fire at speechM, not at m.
func TestTheModPageStatesTheBoardThreshold(cur realm, t *testing.T) {
	mod := testutils.TestAddress("bms-mod")
	mod2 := testutils.TestAddress("bms-mod2")
	mod3 := testutils.TestAddress("bms-mod3")
	modFixture(cur, "bms", mod, testutils.TestAddress("bms-poster"))

	testing.SetRealm(testing.NewUserRealm(mod))
	AppointMods(cross(cur), "bms", 1, mod, mod2, mod3)
	if SpeechThreshold("bms") != 2 {
		t.Fatal("a 1-of-3 set must need 2 for a board act")
	}
	log := renderModLog("bms")
	if !strings.Contains(log, "1 of 3 must agree") {
		t.Fatal("the money threshold must still be stated")
	}
	if !strings.Contains(log, "2 of 3 for a **board** act") {
		t.Fatalf("the board threshold differs and must be stated:\n%s", log)
	}
}

// HIDING A COMMENT TAKES speechM, AND EVERY TEST BEFORE THIS ONE RAN ON A 1-OF-1
// COURT where speechM is 1 and the first call always fires — so deleting the
// threshold entirely left the suite green. The mutant only became visible once
// the harness stopped counting a non-building mutant as a caught one.
func TestHidingAComentTakesMoreThanOneModeratorWhereItShould(cur realm, t *testing.T) {
	mod := testutils.TestAddress("th-mod")
	mod2 := testutils.TestAddress("th-mod2")
	poster := testutils.TestAddress("th-poster")
	id, row := modFixture(cur, "th", mod, poster)

	testing.SetRealm(testing.NewUserRealm(mod))
	AppointMods(cross(cur), "th", 1, mod, mod2)
	if SpeechThreshold("th") != 2 {
		t.Fatal("the fixture must put the board threshold above 1")
	}

	testing.SetRealm(testing.NewUserRealm(mod))
	HideBoardRow(cross(cur), "th", id, row, boardCodeSpam)
	if BoardRowState("th", id, row) != "." {
		t.Fatal("one moderator of a 2-threshold set hid a comment alone")
	}
	testing.SetRealm(testing.NewUserRealm(mod2))
	HideBoardRow(cross(cur), "th", id, row, boardCodeSpam)
	if BoardRowState("th", id, row) != "h" {
		t.Fatal("two agreeing moderators must be able to hide it")
	}

	// The undo carries the same threshold — a set that needed two to hide must
	// not be reversible by one, or the threshold is only half a rule.
	testing.SetRealm(testing.NewUserRealm(mod))
	UnhideBoardRow(cross(cur), "th", id, row)
	if BoardRowState("th", id, row) != "h" {
		t.Fatal("one moderator reversed a 2-threshold hide alone")
	}
	testing.SetRealm(testing.NewUserRealm(mod2))
	UnhideBoardRow(cross(cur), "th", id, row)
	if BoardRowState("th", id, row) != "." {
		t.Fatal("two agreeing moderators must be able to lift it")
	}
}

// DESTROYING ONE COMMENT TAKES d.purgeM. Same blind spot as above, one authority
// up: the bootstrap DAO is 1-of-1, so every purge test fired on its first call.
func TestPurgingOneCommentTakesTheGlobalThreshold(cur realm, t *testing.T) {
	mod := testutils.TestAddress("tp-mod")
	poster := testutils.TestAddress("tp-poster")
	id, row := modFixture(cur, "tp", mod, poster)
	// THE DAO'S OWN ADMIN, not DirectoryAdmin(). ensureGlobalDAO stamps `admin`
	// once, from whatever directoryAdmin was when the DAO first materialised, and
	// TransferGlobalAdmin can move it afterwards — so the two are the same
	// address by default and not by rule. SetPurgeThreshold checks d.admin, and
	// assuming the directory admin refused this test outright.
	dadmin := ensureGlobalDAO().admin
	mod2 := testutils.TestAddress("tp-gmod")

	testing.SetRealm(testing.NewUserRealm(dadmin))
	AddGlobalMod(cross(cur), mod2)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 2)

	// Both calls FIRST, then restore, then assert — and the ordering is not
	// style. testing.SetRealm inside a DEFERRED closure does not take effect:
	// the deferred restore ran as the body's last caller (mod2) rather than as
	// the admin, and SetPurgeThreshold refused it. A defer here therefore
	// protects nothing and hides the real failure behind its own panic. Doing
	// the restore inline, before any assertion that can t.Fatal, is what
	// actually keeps purgeM from leaking into other files.
	cs := mustClaim(mustCourt("tp"), id)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeBoardRow(cross(cur), "tp", id, row, "csam")
	oneKeyState, oneKeyText := BoardRowState("tp", id, row), mustBoardRow(cs, row).text

	testing.SetRealm(testing.NewUserRealm(mod2))
	PurgeBoardRow(cross(cur), "tp", id, row, "csam")
	twoKeyState, twoKeyText := BoardRowState("tp", id, row), mustBoardRow(cs, row).text

	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	RemoveGlobalMod(cross(cur), mod2)

	if oneKeyState == "x" {
		t.Fatal("one key destroyed a comment irreversibly, alone")
	}
	if oneKeyText == "" {
		t.Fatal("...and took its bytes with it")
	}
	if twoKeyState != "x" || twoKeyText != "" {
		t.Fatal("two agreeing members must be able to purge")
	}
}

// AUDIT D9: suspending a set masks nothing, and the mod page said it did.
//
// §7.4 asks for it — "suspension masks hides and freezes" — and no visibility
// predicate anywhere consults `cm.suspended`. Every reader of that flag is an
// authority gate or a state transition. So a suspended set's board hides keep
// hiding and its freezes keep freezing, while the court's own moderation page
// printed "their hides are masked and they cannot act". Half of that was true.
//
// The copy is fixed here. Whether masking should actually be BUILT is a ruling,
// because it cuts the other way too: unmasking on suspension republishes whatever
// the set had hidden, including content hidden for good reason, at the exact
// moment nobody is authorised to re-hide it.
func TestSuspensionStopsNewSanctionsAndMasksNothing(cur realm, t *testing.T) {
	mod := testutils.TestAddress("d9s-mod")
	poster := testutils.TestAddress("d9s-poster")
	id, row := modFixture(cur, "d9s", mod, poster)
	c := mustCourt("d9s")

	testing.SetRealm(testing.NewUserRealm(mod))
	HideBoardRow(cross(cur), "d9s", id, row, boardCodeSpam)
	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeBoard(cross(cur), "d9s", poster, 500, boardCodeAbuse)

	dadmin := ensureGlobalDAO().admin
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalSuspendSet(cross(cur), "d9s")
	if !CourtSuspended("d9s") {
		t.Fatal("the fixture must suspend the set")
	}

	// THE SANCTIONS STAND. Both of them, unchanged.
	if BoardRowState("d9s", id, row) != "h" {
		t.Fatal("a suspended set's board hide is still in force")
	}
	if !boardFrozen(c, poster) {
		t.Fatal("a suspended set's freeze is still in force")
	}
	testing.SetRealm(testing.NewUserRealm(poster))
	uassert.AbortsContains(t, cur, "frozen out of this court's boards", func() {
		PostComment(cross(cur), "d9s", id, 0, "am I unfrozen now?")
	})

	// AND THE PAGE SAYS SO HONESTLY. It used to claim the hides were masked.
	log := renderModLog("d9s")
	if !strings.Contains(log, "suspended") {
		t.Fatal("the page must say the set is suspended")
	}
	if strings.Contains(log, "hides are masked") {
		t.Fatal("the page must not claim a masking the realm does not do")
	}
	if !strings.Contains(log, "stand until cleared") {
		t.Fatalf("the page must say the existing sanctions stand:\n%s", log)
	}

	// The de-escalation half IS real: any member may still lift their own acts.
	testing.SetRealm(testing.NewUserRealm(mod))
	UnhideBoardRow(cross(cur), "d9s", id, row)
	testing.SetRealm(testing.NewUserRealm(mod))
	UnfreezeBoard(cross(cur), "d9s", poster)
	if BoardRowState("d9s", id, row) != "." || boardFrozen(c, poster) {
		t.Fatal("a suspended set must still be able to lift its own sanctions")
	}
}

// AUDIT D14: the two verbs that UNDO a court's sanctions left no trace on the
// court's own page.
//
// The authority matrix across all 26 write verbs showed it: every global verb in
// this lane writes a court-log row — GlobalHideRow, GlobalClearRow,
// PurgeBoardRow, PurgeBoardRange, PurgeCourtLogRow, GlobalClearCourtParams — and
// these two emitted an event and wrote nothing. So /mod recorded the slash and
// the freeze, and nothing recorded the platform reversing them: the accusation
// without the acquittal.
func TestTheGlobalRecoveryVerbsAreOnTheRecord(cur realm, t *testing.T) {
	mod := testutils.TestAddress("d14-mod")
	poster := testutils.TestAddress("d14-poster")
	modFixture(cur, "d14", mod, poster)
	c := mustCourt("d14")
	dadmin := ensureGlobalDAO().admin

	r := getStanding(c, poster)
	r.score, r.highWater = levelFloor(c, 3)*2, levelFloor(c, 3)*2
	testing.SetRealm(testing.NewUserRealm(mod))
	SlashStanding(cross(cur), "d14", poster, 2, boardCodeSpam)
	testing.SetRealm(testing.NewUserRealm(mod))
	FreezeBoard(cross(cur), "d14", poster, 500, boardCodeAbuse)

	// Both sanctions are on the record, which is the half that already worked.
	log := renderModLog("d14")
	if !strings.Contains(log, sanitize.InlineText("slash:2")) ||
		!strings.Contains(log, sanitize.InlineText("freeze:500")) {
		t.Fatal("the sanctions must be logged")
	}

	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalClearBoardBits(cross(cur), "d14")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalRestoreStanding(cross(cur), "d14", poster)

	// And now so are the reversals.
	after := renderModLog("d14")
	if !strings.Contains(after, sanitize.InlineText("global-clear-board-bits")) {
		t.Fatalf("clearing every freeze must be on the court's record:\n%s", after)
	}
	if !strings.Contains(after, sanitize.InlineText("global-restore-standing")) {
		t.Fatalf("restoring standing must be on the court's record:\n%s", after)
	}
	if !strings.Contains(after, dadmin.String()) {
		t.Fatal("and the record must name who intervened")
	}
}
