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
