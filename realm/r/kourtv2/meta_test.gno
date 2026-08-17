package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// The parser accepts only exact schemas; a near-miss is an ordinary claim, so
// it can never masquerade as binding. Pure — touches no state.
func TestMetaParser(cur realm, t *testing.T) {
	ok := []struct {
		title string
		verb  string
		court string
		tgt   uint64
	}{
		{"mod:unhide:foo/7", verbUnhide, "foo", 7},
		{"mod:clear:foo-bar/1", verbClear, "foo-bar", 1},
		{"mod:hide:x9/42", verbHide, "x9", 42},
		{"mod:setmods:foo/3", verbSetmods, "foo", 3},
		{"mod:suspend:foo", verbSuspend, "foo", 0},
		{"mod:unsuspend:foo", verbUnsuspend, "foo", 0},
	}
	for _, c := range ok {
		p := parseModTitle(c.title)
		if !p.valid || p.verb != c.verb || p.court != c.court || p.target != c.tgt {
			t.Fatalf("should parse %q", c.title)
		}
	}
	bad := []string{
		"xmod:hide:foo/1", "mod:hide:foo", "mod:hide:foo/", "mod:hide:/1",
		"mod:hide:foo/0", "mod:hide:FOO/1", "mod:bogus:foo/1", "mod:suspend:foo/1",
		"mod:hide:foo/abc", "ordinary claim title", "mod:",
	}
	for _, ti := range bad {
		if parseModTitle(ti).valid {
			t.Fatalf("should NOT parse %q", ti)
		}
	}
	// The setmods latch is keyed per COURT, so two different candidate sets on
	// one court contend for the same slot (unlimited parallel installs on one
	// court were how a banked-verdict attack would have worked).
	a := latchKey(modParse{verb: verbSetmods, court: "foo", target: 1})
	b := latchKey(modParse{verb: verbSetmods, court: "foo", target: 2})
	if a != b {
		t.Fatal("setmods must share one latch per court")
	}
	if latchKey(modParse{verb: verbUnhide, court: "foo", target: 1}) ==
		latchKey(modParse{verb: verbUnhide, court: "foo", target: 2}) {
		t.Fatal("item verbs latch per target")
	}
}

// The meta court is a SINGLETON created at realm init, and gno resets the block
// height between test functions — so every test that drives meta's lifecycle
// must live in one function, or a later test writes a coin checkpoint at a
// lower epoch than an earlier one ("the clock went backwards"). Hence one
// sequential scenario covering every execution guard.
func TestMetaLifecycleGuards(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mtx-alice")
	bob := testutils.TestAddress("mtx-bob")
	mc := mustCourt(metaSlug)
	mc.coin.Mint(alice, 500_000_000_000)
	mc.coin.Mint(bob, 500_000_000_000)

	// appeal drives a meta claim to VERDICT_FINAL on the undisputed route.
	appeal := func(title string) uint64 {
		testing.SkipHeights(1) // the target must strictly predate the appeal
		testing.SetRealm(testing.NewUserRealm(alice))
		id := OpenClaim(cross(cur), metaSlug, title)
		matureOI(cur, metaSlug, id, alice, 200_000_000)
		testing.SetRealm(testing.NewUserRealm(alice))
		PostAnswer(cross(cur), metaSlug, id, sideYES)
		testing.SkipHeights(settleDelay + 1)
		testing.SetRealm(testing.NewUserRealm(alice))
		SettleUndisputed(cross(cur), metaSlug, id)
		return id
	}

	// ---- 1. a RESTORATIVE verb executes from silence, exactly once ----------
	testCourt(cur, "mtx1", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	t1 := OpenClaim(cross(cur), "mtx1", "hidden by mods")
	testing.SetRealm(testing.NewUserRealm(alice))
	HideItem(cross(cur), "mtx1", t1, "spam")

	ap1 := appeal("mod:unhide:mtx1/1")
	testing.SetRealm(testing.NewUserRealm(alice))
	ExecuteMetaVerdict(cross(cur), ap1)
	if HiddenFromListing("mtx1", t1) {
		t.Fatal("a restorative verdict should clear the courtMod bit")
	}
	if !AppealExecuted(ap1) {
		t.Fatal("the appeal should be marked executed")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "already executed", func() {
		ExecuteMetaVerdict(cross(cur), ap1)
	})

	// ---- 2. an AGGRESSIVE verb is REFUSED on silence ------------------------
	testCourt(cur, "mtx2", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	OpenClaim(cross(cur), "mtx2", "target")
	ap2 := appeal("mod:hide:mtx2/1")
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "decided contested vote", func() {
		ExecuteMetaVerdict(cross(cur), ap2)
	})
	if HiddenFromListing("mtx2", 1) {
		t.Fatal("silence must never hide")
	}

	// ---- 3. a NO-OP unhide stamps nothing -----------------------------------
	testCourt(cur, "mtx3", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	OpenClaim(cross(cur), "mtx3", "never hidden")
	before := ModLogLen("mtx3", 1)
	ap3 := appeal("mod:unhide:mtx3/1")
	testing.SetRealm(testing.NewUserRealm(alice))
	ExecuteMetaVerdict(cross(cur), ap3)
	if ModLogLen("mtx3", 1) != before {
		t.Fatal("a no-op unhide must not write a moderation act (no cooldown stamp)")
	}

	// ---- 4. the EXECUTION EXPIRY: a verdict is not a sleeper round ----------
	testCourt(cur, "mtx4", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	t4 := OpenClaim(cross(cur), "mtx4", "target")
	testing.SetRealm(testing.NewUserRealm(alice))
	HideItem(cross(cur), "mtx4", t4, "spam")
	ap4 := appeal("mod:unhide:mtx4/1")
	testing.SkipHeights(mc.params.votingBlocks + 2)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "expired", func() {
		ExecuteMetaVerdict(cross(cur), ap4)
	})
	if !HiddenFromListing("mtx4", t4) {
		t.Fatal("an expired verdict must change nothing")
	}

	// ---- 5. the STRICT PREDATE guard ---------------------------------------
	testCourt(cur, "mtx5", alice, 10_000_000_000)
	testing.SkipHeights(1)
	testing.SetRealm(testing.NewUserRealm(alice))
	ap5 := OpenClaim(cross(cur), metaSlug, "mod:unhide:mtx5/1")
	testing.SkipHeights(2)
	testing.SetRealm(testing.NewUserRealm(alice)) // the target claim is born AFTER the appeal
	OpenClaim(cross(cur), "mtx5", "created after the appeal")
	matureOI(cur, metaSlug, ap5, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), metaSlug, ap5, sideYES)
	testing.SkipHeights(settleDelay + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	SettleUndisputed(cross(cur), metaSlug, ap5)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "does not predate", func() {
		ExecuteMetaVerdict(cross(cur), ap5)
	})

	// ---- 6b. the LATCH RELEASES at a terminal transition --------------------
	// ap2 was correctly refused (aggressive verb on silence). Its latch must NOT
	// outlive the appeal claim: it used to be freed only on a SUCCESSFUL
	// execution, so every refused/expired/voted-down appeal held its target's
	// review slot forever — permanently bricking that target's appeals lane and
	// permanently reverting PostAnswer for it.
	if AppealLatchHolder(verbHide, "mtx2", 1) != ap2 {
		t.Fatal("the refused appeal should hold its slot until a terminal transition")
	}
	testing.SkipHeights(priorityWindowBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), metaSlug, ap2)
	if AppealLatchHolder(verbHide, "mtx2", 1) != 0 {
		t.Fatal("a terminal transition must free the target's review slot")
	}

	// ---- 6c. the ballot must SHOW what it is asking voters to approve -------
	// Without this the electorate votes on an opaque title string and cannot see
	// which addresses a setmods appeal would seat — the amplifier that made the
	// bait-and-switch finding worth a HIGH.
	testing.SkipHeights(1)
	testing.SetRealm(testing.NewUserRealm(alice))
	seatMe := testutils.TestAddress("mtx-seat")
	candID := RegisterModCandidate(cross(cur), "mtx1", []address{seatMe}, 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	shown := OpenClaim(cross(cur), metaSlug,
		"mod:setmods:mtx1/"+strconv.FormatUint(candID, 10))
	page := Render(metaSlug + "/" + strconv.FormatUint(shown, 10))
	if !strings.Contains(page, "Review request") || !strings.Contains(page, "setmods") {
		t.Fatalf("a valid appeal must render its action:\n%s", page)
	}
	if !strings.Contains(page, seatMe.String()) {
		t.Fatalf("a setmods appeal must list the addresses it would seat:\n%s", page)
	}
	// An appeal naming a candidate that does not exist yet is the bait-and-switch
	// shape and must be called out, not rendered blank.
	testing.SetRealm(testing.NewUserRealm(alice))
	ghost := OpenClaim(cross(cur), metaSlug, "mod:setmods:mtx1/9999")
	gp := Render(metaSlug + "/" + strconv.FormatUint(ghost, 10))
	if !strings.Contains(gp, "does not exist yet") {
		t.Fatalf("an unregistered candidate must be flagged:\n%s", gp)
	}

	// ---- 6. FIRST-TO-ANSWER takes the target's review slot ------------------
	testCourt(cur, "mtx6", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	t6 := OpenClaim(cross(cur), "mtx6", "contested target")
	testing.SetRealm(testing.NewUserRealm(alice))
	HideItem(cross(cur), "mtx6", t6, "spam")
	testing.SkipHeights(1)
	testing.SetRealm(testing.NewUserRealm(alice))
	first := OpenClaim(cross(cur), metaSlug, "mod:unhide:mtx6/1")
	testing.SetRealm(testing.NewUserRealm(bob))
	second := OpenClaim(cross(cur), metaSlug, "mod:unhide:mtx6/1")
	matureOI(cur, metaSlug, first, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), metaSlug, first, sideYES)
	if AppealLatchHolder(verbUnhide, "mtx6", 1) != first {
		t.Fatal("the first answerer should hold the review slot")
	}
	matureOI(cur, metaSlug, second, bob, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "review slot", func() {
		PostAnswer(cross(cur), metaSlug, second, sideYES)
	})
}
