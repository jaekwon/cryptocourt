package courtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

func TestStartCourtCreatesABareCourt(cur realm, t *testing.T) {
	alice := testutils.TestAddress("v2-alice")
	testing.SetRealm(testing.NewUserRealm(alice))
	slug := StartCourt(cross(cur), "v2eg", "V2 Example Court")
	if slug != "v2eg" || !Exists("v2eg") {
		t.Fatal("the court should exist under its slug")
	}
	if CourtName("v2eg") != "V2 Example Court" || CoinSupply("v2eg") != 0 {
		t.Fatal("a bare court has its name and zero supply")
	}
	if CourtTier("v2eg") != int(tierListed) {
		t.Fatal("a new court starts listed")
	}
	if EmittedTotal("v2eg") != 0 {
		t.Fatal("a bare court has emitted nothing")
	}
	// The FIRST creator across the suite becomes the directory admin — this
	// test may not run first (suites share package state), so assert the
	// invariant, not the identity: an admin exists once any court does.
	if DirectoryAdmin() == "" {
		t.Fatal("a directory admin exists once any court does")
	}
}

func TestSlugAndParamGuards(cur realm, t *testing.T) {
	who := testutils.TestAddress("v2-guards")
	testing.SetRealm(testing.NewUserRealm(who))
	uassert.AbortsContains(t, cur, "slug is lowercase", func() {
		StartCourt(cross(cur), "Bad Slug!", "x")
	})
	uassert.AbortsContains(t, cur, "slug is 1..64", func() {
		StartCourt(cross(cur), "", "x")
	})
	// mustSane rejections (exercised directly — params are frozen defaults).
	shouldPanicV2(t, "tie threshold", func() {
		p := defaultParams()
		p.disputeThresholdBps = 5000
		p.mustSane()
	})
	shouldPanicV2(t, "zero deposit", func() {
		p := defaultParams()
		p.minClaimDepositCC = 0
		p.mustSane()
	})
	shouldPanicV2(t, "malformed escrow window", func() {
		p := defaultParams()
		p.escrowMaxBlocks = p.escrowMinBlocks - 1
		p.mustSane()
	})
}

func shouldPanicV2(t *testing.T, name string, fn func()) {
	t.Helper()
	defer func() {
		if recover() == nil {
			t.Fatalf("%s should have panicked", name)
		}
	}()
	fn()
}

// mustSlug's CHARSET check is load-bearing for a security property in a DIFFERENT
// file, and only its length check was tested. render.gno writes the slug RAW into
// markdown link targets — `](/r/cryptocourt/courtv2:` + slug + `)` at :71 and :107 —
// while every other user string there goes through sanitize.InlineText. That raw
// interpolation is safe ONLY because [a-z0-9-] cannot close a link target, open a
// markdown construct, or traverse a path. AGENTS.md names exactly this class: never
// write path segments or user-supplied keys straight into markdown output.
//
// So if anyone ever loosens this charset — to allow uppercase, or an underscore, or a
// slash for namespacing — the render becomes injectable and nothing else in the suite
// notices. This pins the charset to the characters that would break it.
func TestSlugCharsetIsWhatMakesTheRawRenderSafe(cur realm, t *testing.T) {
	alice := testutils.TestAddress("slug-alice")
	testCourt(cur, "slug-ok", alice, 1_000_000_000) // the happy path still works

	// Each of these would escape the link target, open a markdown construct, or
	// traverse the path if it reached render.gno unsanitized.
	for _, bad := range []string{
		"has)paren",   // closes the link target early
		"has(paren",   //
		"has]bracket", // closes the label
		"has[bracket", //
		"has/slash",   // path traversal into another realm path segment
		"has:colon",   // splits the realm:path separator
		"has space",
		"has\nnewline",
		"HasUpper",     // case-folding could collide two courts
		"has_under",    // not in the charset
		"has.dot",      //
		"has\\back",    //
		"has`tick",     // code span
		"has*star",     // emphasis
		"has<angle",    // raw HTML
	} {
		testing.SetRealm(testing.NewUserRealm(alice))
		uassert.AbortsContains(t, cur, "lowercase letters, digits, and hyphens only",
			func() {
				StartCourt(cross(cur), bad, "Bad Slug Court")
			})
	}

	// And the permitted set really is permitted, so the guard is not merely
	// rejecting everything.
	for _, good := range []string{"abc", "a-b-c", "a1", "9", "-", "with-9-digits"} {
		testing.SetRealm(testing.NewUserRealm(alice))
		StartCourt(cross(cur), good, "Good Slug Court")
		if CourtTier(good) != int(tierListed) {
			t.Fatalf("a valid slug must create a court: %q", good)
		}
	}
}

// Params.mustSane's six guards, none of which had a test. They are unreachable today —
// StartCourt hardcodes defaultParams() and there is no params setter anywhere — so this
// calls the method directly rather than trying to construct an unreachable court, the
// same approach used for mulDiv128 and capBonus.
//
// Worth pinning now rather than later because mustSane becomes load-bearing the moment a
// setter exists, and PLAN §12 row 37 already contemplates one (the deposit lever, 1 CC →
// 5 CC). A validator that has never been exercised is a poor thing to discover a
// governance path with. Each case also asserts the DEFAULTS pass, so the guards cannot
// hold by rejecting everything.
func TestParamsMustSaneRefusesEachMalformedField(cur realm, t *testing.T) {
	mustPanicWith := func(want string, fn func()) {
		t.Helper()
		defer func() {
			r := recover()
			if r == nil {
				t.Fatalf("expected a panic saying %q; nothing panicked", want)
			}
			got, ok := r.(string)
			if !ok || !containsSub(got, want) {
				t.Fatalf("panic %v, want one saying %q", r, want)
			}
		}()
		fn()
	}

	// The defaults are sane — the control.
	_ = defaultParams().mustSane()

	// The overturn threshold is a STRICT majority band: 5000 would let a tie overturn.
	for _, bad := range []int64{5000, 0, -1, 10001} {
		p := defaultParams()
		p.disputeThresholdBps = bad
		mustPanicWith("overturn threshold must be in [5001, 10000]", func() { p.mustSane() })
	}
	// Both boundaries accepted.
	for _, ok := range []int64{5001, 10000} {
		p := defaultParams()
		p.disputeThresholdBps = ok
		_ = p.mustSane()
	}

	// A zero voting or grace window would close a vote in the block it opened.
	for _, f := range []func(p *Params){
		func(p *Params) { p.votingBlocks = 0 },
		func(p *Params) { p.graceBlocks = 0 },
		func(p *Params) { p.votingBlocks = -1 },
	} {
		p := defaultParams()
		f(&p)
		mustPanicWith("vote and grace windows must be positive", func() { p.mustSane() })
	}

	// minAnswerX is the answerability floor; zero would let a claim with no stake be
	// answered, and every %-of-X̄ bar would then price off nothing.
	p := defaultParams()
	p.minAnswerX = 0
	mustPanicWith("minAnswerX must be positive", func() { p.mustSane() })

	// A zero deposit makes claim-opening free, which is the anti-spam price.
	p = defaultParams()
	p.minClaimDepositCC = 0
	mustPanicWith("claim deposit must never be zero", func() { p.mustSane() })

	// The escrow window must be a window: positive, and max not below min.
	p = defaultParams()
	p.escrowMinBlocks = 0
	mustPanicWith("escrow window is malformed", func() { p.mustSane() })
	p = defaultParams()
	p.escrowMaxBlocks = p.escrowMinBlocks - 1
	mustPanicWith("escrow window is malformed", func() { p.mustSane() })
	// Equal is allowed: a fixed-length window is legitimate (several fixtures set it).
	p = defaultParams()
	p.escrowMaxBlocks = p.escrowMinBlocks
	_ = p.mustSane()

	// A negative cap would read as "uncapped" through the `> 0` test at PostAnswer.
	p = defaultParams()
	p.answerBondCapCC = -1
	mustPanicWith("answerBondCapCC must be non-negative", func() { p.mustSane() })
	// Zero is the documented "uncapped" sentinel and must stay legal.
	p = defaultParams()
	p.answerBondCapCC = 0
	_ = p.mustSane()
}

// THE CALIBRATION PINS — the prices and durations of the system, asserted as LITERALS.
//
// Sixteen constants were mutated and TEN survived: the P7 carrot split, both comp arms,
// the flag bond floor and its frozen multiple, both slash arms, the deposit fee, the
// settle delay, the priority window, and the reservoir's cap in periods. Every one is a
// number somebody calibrated — slashDrawBps carries "k=1.6 lands the 12-wk mill q* on the
// ~0.22 target (three-designer convergence)" — and none of them was pinned.
//
// They survived for one reason, and it is the reason this fixture uses LITERALS on the
// right-hand side. Every existing fixture computes its expectation FROM the constant:
// `wantBond := xbar * disputeBondXBps / 10000`, `testing.SkipHeights(settleDelay)`. Change
// the constant and both sides move together, so the assertion holds and the price has
// silently changed. A fixture that references the symbol can only check that the code
// agrees with itself. Writing the number out is the whole point — if a value must change,
// this test must be edited too, which is exactly the deliberate act a calibration deserves.
//
// This is NOT a claim that these values are right. It is a claim that they are what the
// design settled on, so drift cannot be silent.
func TestEconomicConstantsAreTheCalibratedValues(t *testing.T) {
	for _, k := range []struct {
		name string
		got  int64
		want int64
		what string
	}{
		{"budgetWeeklyBps", budgetWeeklyBps, 38, "the weekly emission budget — the LOCKED ceiling's source"},
		{"stepDownPeriods", stepDownPeriods, 104, "the halving horizon in weeks"},
		{"rMaxPeriods", rMaxPeriods, 4, "how many quiet weeks the reservoir may bank"},
		{"tierLowX", tierLowX, 0, "low draws NOTHING — bucket value and draw multiplier at once"},
		{"tierMidX", tierMidX, 1, "mid is the unit draw"},
		{"tierHighX", tierHighX, 2, "high doubles it"},
		{"splitWinners", splitWinners, 80, "the accuracy pool's share of D"},
		{"splitAuthor", splitAuthor, 8, "the author's share"},
		{"splitAnswerer", splitAnswerer, 5, "the answerer's share"},
		{"splitCarrot", splitCarrot, 7, "policing pay's share"},
		{"answerBondBps", answerBondBps, 5000, "the answer bond is 50% of X-bar"},
		{"disputeBondXBps", disputeBondXBps, 2000, "a dispute bond is 20% of X-bar"},
		{"disputeBondOfAnswerBps", disputeBondOfAnswerBps, 4000, "or 40% of the answer bond, whichever is less"},
		{"compOwnX", compOwnX, 2, "comp is capped at twice the disputer's own bond"},
		{"compOfBurnBps", compOfBurnBps, 8000, "and at 80% of what burned"},
		{"flagBondXBps", flagBondXBps, 200, "a flag bond is 2% of X-bar"},
		{"flagMinCC", flagMinCC, 1_000_000, "with a floor of 1 CC — flagging must never be nearly free"},
		{"flagFrozenMultX", flagFrozenMultX, 4, "the bond freezes at 4x b0 after three inconclusives"},
		{"slashXBps", slashXBps, 450, "the slash floor is 4.5% of X-bar"},
		{"slashDrawBps", slashDrawBps, 16000, "and its draw arm is 1.6x midGross (k=1.6, v0.40)"},
		{"depositFeeBps", depositFeeBps, 1000, "the claim fee is 10% of the deposit"},
		{"quorumSupplyBps", quorumSupplyBps, 500, "the full bar's supply floor is 5%"},
		{"settleDelay", settleDelay, 51_840, "72h before an undisputed answer settles"},
		{"priorityWindowBlocks", priorityWindowBlocks, 17_280, "24h of answer priority"},
		{"deadClaimTimeout", deadClaimTimeout, 1_451_520, "12 weeks before an unanswered claim closes"},
		{"periodBlocks", periodBlocks, 120_960, "one week — the emission accounting period"},
		{"epochBlocks", epochBlocks, 720, "the checkpoint epoch"},
		{"curveDenom", curveDenom, 1_000_000_000, "the curve's reciprocal slope"},
	} {
		if k.got != k.want {
			t.Errorf("%s is %d, the design says %d (%s) — if this change is deliberate, "+
				"edit this pin in the same commit", k.name, k.got, k.want, k.what)
		}
	}

	// And the RELATIONSHIPS the source comments assert, which a table of values does not
	// cover: these are what make the numbers consistent with each other.
	if splitWinners+splitAuthor+splitAnswerer+splitCarrot != 100 {
		t.Errorf("the P7 split must exhaust D: %d+%d+%d+%d",
			splitWinners, splitAuthor, splitAnswerer, splitCarrot)
	}
	// court.gno's own claim beside slashXBps: "bounty 2% <= 80% x 4.5%". The flag bond is
	// the bounty's own arm, so the slash floor must cover it at the comp ratio.
	if flagBondXBps*10000 > slashXBps*compOfBurnBps {
		t.Errorf("a flag bond (%d bps of X-bar) must stay inside 80%% of the slash floor "+
			"(%d bps), or flagging pays more than the slash it earns",
			flagBondXBps, slashXBps)
	}
	// The frozen flag bond is 4x b0 = 8% of X-bar, which the comment states outright.
	if flagFrozenMultX*flagBondXBps != 800 {
		t.Errorf("the frozen flag bond must be 8%% of X-bar: %d x %d bps",
			flagFrozenMultX, flagBondXBps)
	}
}

// The other half of the calibration: defaultParams(), the PER-COURT knobs. Distinct from
// the const block above because these are fields a court carries and fixtures freely
// override (`c.params.escrowMaxBlocks = 450_000` appears in several), which is a second
// reason nothing pinned their defaults — the tests that touch them are testing something
// else and set their own values first.
//
// Eight were mutated and SIX survived: the overturn threshold, the grace window, the
// answerability floor, the claim deposit, and both escrow bounds. Literals again, for the
// same reason: every fixture reads `c.params.votingBlocks` rather than a number, so the
// symbol cannot pin itself.
func TestDefaultParamsAreTheCalibratedValues(t *testing.T) {
	p := defaultParams()
	for _, k := range []struct {
		name string
		got  int64
		want int64
		what string
	}{
		{"disputeThresholdBps", p.disputeThresholdBps, 5001,
			"a bare majority overturns — 5001 is a MAJORITY, not a supermajority"},
		{"votingBlocks", p.votingBlocks, 120_960, "one week of voting on every lane"},
		{"graceBlocks", p.graceBlocks, 17_280, "24h of grace"},
		{"minAnswerX", p.minAnswerX, 100_000_000, "100 CC of trailing stake before a claim is answerable"},
		{"minClaimDepositCC", p.minClaimDepositCC, 1_000_000, "1 CC to open a claim — the spam price"},
		{"escrowMinBlocks", p.escrowMinBlocks, 120_960, "the escrow window's floor: one week"},
		{"escrowMaxBlocks", p.escrowMaxBlocks, 362_880, "and its cap: three weeks (§12 row 30's geometry)"},
	} {
		if k.got != k.want {
			t.Errorf("defaultParams().%s is %d, the design says %d (%s) — if this change "+
				"is deliberate, edit this pin in the same commit", k.name, k.got, k.want, k.what)
		}
	}

	// answerBondCapCC gets its own assertion because ZERO is load-bearing far outside
	// this function. Wiring a cap makes three guards elsewhere live at once — the
	// draw-arm/flat-arm asymmetry PostAnswer's floor comment warns about, and the two
	// clamps that comment lists — none of which has a fixture that can reach them while
	// the cap is 0. See the note beside the collateralization floor in answer.gno.
	if p.answerBondCapCC != 0 {
		t.Errorf("answerBondCapCC must default to 0 (uncapped): got %d. Wiring it arms "+
			"guards in three other files; mutate those first", p.answerBondCapCC)
	}

	// The relationships mustSane enforces at runtime, asserted on the DEFAULTS so a
	// change that would abort every StartCourt fails here first, with a clearer reason.
	if p.escrowMinBlocks > p.escrowMaxBlocks {
		t.Errorf("the escrow window's floor must not exceed its cap: %d > %d",
			p.escrowMinBlocks, p.escrowMaxBlocks)
	}
	if p.disputeThresholdBps < 5001 || p.disputeThresholdBps > 10000 {
		t.Errorf("the overturn threshold must stay in [5001, 10000]: %d",
			p.disputeThresholdBps)
	}
}
