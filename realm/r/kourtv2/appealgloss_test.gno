package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// Every verb has a description, and it is the right one.
//
// The page rendered "- action: **setmods**" — a raw verb code — on the surface
// where the review court's heaviest acts are approved: seating moderators on
// somebody else's court, disarming a set, hiding a claim over its court's head.
// A voter asked to approve an act named only by its code is being asked to
// approve a word.
//
// EXHAUSTIVE HERE AND NOT THROUGH THE PAGE, because a meta claim costs a deposit
// that scales with meta's supply and six of them exhaust any balance the test
// can mint. The gloss is a pure function, so the switch gets a case per arm for
// free; the wiring gets one claim per branch in the test below.
func TestEveryReviewVerbHasItsOwnDescription(cur realm, t *testing.T) {
	seen := map[string]bool{}
	for _, tc := range []struct{ verb, want string }{
		{verbUnhide, "un-hides a claim its own court's moderators hid"},
		{verbClear, "clears a hide the review court itself placed"},
		{verbHide, "hides a claim across the platform, over its court's head"},
		{verbSuspend, "disarms a court's moderator set"},
		{verbUnsuspend, "re-applies the hides that were masked while it was disarmed"},
		{verbSetmods, "installs a moderator set on that court"},
	} {
		got := appealVerbGloss(tc.verb)
		if !strings.Contains(got, tc.want) {
			t.Fatalf("%q: want %q, got %q", tc.verb, tc.want, got)
		}
		// SIX DISTINCT DESCRIPTIONS. A switch that fell through would give two
		// verbs the same words, and the two that matter most — setmods and
		// suspend — are exactly the pair a reader must not confuse.
		if seen[got] {
			t.Fatalf("%q reuses another verb's description: %q", tc.verb, got)
		}
		seen[got] = true
	}
	// An unknown verb admits it rather than inventing a description. Not
	// reachable through AppealParse, which validates — but a render that makes
	// something up is worse than one that says it does not know.
	if !strings.Contains(appealVerbGloss("nonesuch"), "does not recognise") {
		t.Fatal("an unknown verb must not be given an invented meaning")
	}
}

// What SILENCE does, which is the opposite fact for the two kinds of verb.
//
// meta.gno's rule 4 refuses an aggressive verb unless a quorate round decided it
// against real opposition, while a restorative verb may carry on the undisputed
// route. So abstaining defeats one kind and passes the other — and the page said
// neither, leaving a voter unable to tell which their inaction was.
func TestAReviewRequestSaysWhatSilenceDoes(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ag2-alice")
	testCourt(cur, "ag2", alice, 10_000_000_000)
	// DERIVED FROM THE LIVE COST, not guessed at. Meta's claim deposit is
	// bps × RAW supply, so every mint raises the very bar it is trying to clear
	// — a bigger constant is a treadmill, and I rode it twice before measuring.
	// Each round raises the bar by only bps of what it adds, so this converges;
	// the loop is bounded rather than open because a test that can hang is worse
	// than one that fails. It must also work run ALONE, which check-isolation
	// does to every test: with no sibling having minted, supply starts at zero
	// and anything proportional to it is zero.
	mc := mustCourt(metaSlug)
	for i := 0; i < 8; i++ {
		need := effMinDeposit(mc)
		need += need * depositFeeBps / 10000
		if mc.coin.BalanceOf(alice) >= need*4 {
			break
		}
		mc.coin.Mint(alice, need*8+1_000_000_000)
	}

	// AGGRESSIVE: silence defeats it.
	// NO CLOSURE. testing.SetRealm does not take effect inside ANY closure, so a
	// `render := func(...)` helper runs as whatever caller was already current —
	// which here holds no CC, and fails on the deposit with a message about
	// balances rather than about identity. Recorded in docs/VERIFYING.md, and
	// walked into anyway.
	testing.SetRealm(testing.NewUserRealm(alice))
	aggID := OpenClaim(cross(cur), metaSlug, "mod:setmods:ag2/1")
	agg := Render(metaSlug + "/" + strconv.FormatUint(aggID, 10))
	if !verbIsAggressive(verbSetmods) {
		t.Fatal("the fixture disagrees with verbIsAggressive")
	}
	if !strings.Contains(agg, "installs a moderator set on that court") {
		t.Fatalf("the gloss must reach the page:\n%s", agg)
	}
	if !strings.Contains(agg, "Silence defeats it.") {
		t.Fatalf("an aggressive verb must say silence defeats it:\n%s", agg)
	}
	if !strings.Contains(agg, "real opposition turned out for") {
		t.Fatal("it must say what kind of vote an aggressive verb needs")
	}
	if strings.Contains(agg, "Silence lets it through.") {
		t.Fatal("an aggressive verb must not read as carrying on silence")
	}
	// The raw code stays beside the gloss: it is what the claim's title actually
	// contains, and a reader checking the title needs to find it.
	if !strings.Contains(agg, "action: **setmods**") {
		t.Fatal("the verb code must still appear")
	}

	// RESTORATIVE: silence passes it.
	testing.SetRealm(testing.NewUserRealm(alice))
	resID := OpenClaim(cross(cur), metaSlug, "mod:unhide:ag2/1")
	res := Render(metaSlug + "/" + strconv.FormatUint(resID, 10))
	if verbIsAggressive(verbUnhide) {
		t.Fatal("the fixture disagrees with verbIsAggressive")
	}
	if !strings.Contains(res, "un-hides a claim its own court's moderators hid") {
		t.Fatalf("the gloss must reach the page:\n%s", res)
	}
	if !strings.Contains(res, "Silence lets it through.") {
		t.Fatalf("a restorative verb must say silence passes it:\n%s", res)
	}
	if strings.Contains(res, "Silence defeats it.") {
		t.Fatal("a restorative verb must not read as defeated by silence")
	}
}
