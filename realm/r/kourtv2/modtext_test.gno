package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// A SWEEP OF modrender.gno FOUND THE SANITISE RULE HELD ON THREE SURFACES OF EIGHT.
// The file's own header states the discipline — "everything else is sanitized", and a
// purged claim "answers with NOTHING" — and the tests behind it covered the claim
// title, the court name and the quoted body. These pin what was left, and the two
// moderation GATES that were not held at all.
//
// Every string below is the same forge attempt: an ATX heading, a blockquote marker
// and a link, which are exactly what sanitize.InlineText and sanitize.Block exist to
// neutralise. Asserted as "the raw marker does not appear at the start of a line",
// because that is what forging page structure actually requires — a `#` inside a
// sentence is harmless and banning it would pin the formatter instead of the rule.

const forge = "# FORGED HEADING\n> forged quote\n[link](http://x)"

// hasLineStarting reports whether any line of s begins with the given marker, which
// is the shape a structure forgery needs and an escaped copy cannot have.
func hasLineStarting(s, marker string) bool {
	for _, ln := range strings.Split(s, "\n") {
		if strings.HasPrefix(strings.TrimLeft(ln, " \t"), marker) {
			return true
		}
	}
	return false
}

// A PURGED CLAIM'S BODY, on both surfaces. claimBodyVisible is the ONLY moderation
// gate the body has — claimBodyFor (the ClaimBody read) and claimBodyQuoted (the
// markdown page) both go through it and add nothing but a filter — and render.gno
// states the property in a comment: "gated by claimBodyFor, so a purged or
// globally-redacted claim prints nothing". Nothing enforced it. Its `purged ||
// global` weakened to `&&` survived the whole suite, and a purge alone then leaks the
// body on both surfaces, which is the one act where the text must be unreachable.
//
// The two arms are asserted SEPARATELY on separate claims, because the mutation that
// survived is exactly the one a single-arm fixture cannot see: with `&&`, a claim that
// is both purged and globally hidden still withholds.
func TestAPurgedOrHiddenBodyIsWithheldOnEverySurface(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mdt1-alice")
	testCourt(cur, "mdt1", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	purged := OpenClaimP(cross(cur), "mdt1", "title one", "body of the purged claim")
	testing.SetRealm(testing.NewUserRealm(alice))
	hidden := OpenClaimP(cross(cur), "mdt1", "title two", "body of the hidden claim")
	testing.SetRealm(testing.NewUserRealm(alice))
	plain := OpenClaimP(cross(cur), "mdt1", "title three", "body of an ordinary claim")

	// The ordinary claim's body IS served, so the withholding below is the gate and
	// not a fixture with no bodies in it.
	if got := ClaimBody("mdt1", plain); !strings.Contains(got, "ordinary claim") {
		t.Fatalf("setup: an unmoderated body must be served, got %q", got)
	}
	if !strings.Contains(Render("mdt1/"+itoa(int64(plain))), "ordinary claim") {
		t.Fatal("setup: an unmoderated body must render on the page too")
	}

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeClaim(cross(cur), "mdt1", purged, "CSAM")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	GlobalHide(cross(cur), "mdt1", hidden, "LEGAL")

	// PURGED, arm one: nothing on either surface.
	if got := ClaimBody("mdt1", purged); got != "" {
		t.Errorf("a purged claim's ClaimBody must be empty, got %q", got)
	}
	if page := Render("mdt1/" + itoa(int64(purged))); strings.Contains(page, "purged claim") {
		t.Error("a purged claim's body must not render on its page")
	}
	// GLOBALLY HIDDEN, arm two: the same, and this is the arm a purge-only fixture
	// would have missed.
	if got := ClaimBody("mdt1", hidden); got != "" {
		t.Errorf("a globally hidden claim's ClaimBody must be empty, got %q", got)
	}
	if page := Render("mdt1/" + itoa(int64(hidden))); strings.Contains(page, "hidden claim") {
		t.Error("a globally hidden claim's body must not render on its page")
	}
}

// A PURGED COURT'S DESCRIPTION. courtDescFor is documented as "behind the same gate as
// the name", and the name's gate is pinned while the description's was not: removing it
// entirely survived the suite. §2 lists court text in the inventory a purge must reach,
// and a description is 240 characters of free text — the same surface as the name, which
// is the one the gate exists for.
//
// The same test carries the description's SANITISER, which also survived. mustCourtDesc
// bounds length and refuses newlines and nothing else, so `#`, `>` and `[` all reach the
// renderer, and InlineText is what stops them opening structure.
func TestAPurgedCourtWithholdsItsDescriptionAndSanitisesItUntilThen(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mdt2-alice")
	testCourt(cur, "mdt2", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	// Single paragraph, because mustCourtDesc refuses newlines — so the forge attempt
	// for THIS surface is the inline half of it.
	SetCourtDesc(cross(cur), "mdt2", "# forged desc heading [link](http://x)")

	// BEFORE the purge: the description renders, and renders NEUTRALISED. Both halves
	// matter — without the first, the gate below could pass on an empty description.
	page := Render("mdt2")
	if !strings.Contains(page, "forged desc heading") {
		t.Fatalf("setup: an unpurged court must show its description: %s", page)
	}
	if hasLineStarting(page, "# forged") {
		t.Error("a court description must not open a heading of its own")
	}

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeCourt(cross(cur), "mdt2", "ILLEGAL")
	if !CourtPurged("mdt2") {
		t.Fatal("setup: one approval at threshold one must purge the court")
	}

	// AFTER: the description is gone from every court surface, not merely from the
	// court's own page.
	after := Render("mdt2")
	if strings.Contains(after, "forged desc heading") {
		t.Error("a purged court must withhold its description, not just its name")
	}
	if !strings.Contains(after, "removed") {
		t.Fatalf("setup: a purged court still shows its tombstone: %s", after)
	}
	if strings.Contains(Render(""), "forged desc heading") {
		t.Error("a purged court's description must be gone from the directory too")
	}
}

// THE TOMBSTONE CODES THEMSELVES, on all three surfaces that print one: a claim
// title, a court name, and the hide banner on a deep link. All three sanitise the
// code and none of the three was held — the code is free text, since checkReason
// bounds its LENGTH at 200 characters and checks nothing else, so a purge act can
// carry markdown and the tombstone is the one string on the page that a moderation
// act wrote.
//
// The claim body's STRICT filter rides along, because it is the fourth surface the
// sweep found unheld: claimBodyFor uses sanitize.Block where the markdown page uses
// Blockquote, and only the Blockquote path had a test.
func TestEveryModerationTombstoneAndTheStrictBodyFilterAreSanitised(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mdt3-alice")
	testCourt(cur, "mdt3", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaimP(cross(cur), "mdt3", "a title", forge)

	// The ClaimBody read, before any moderation: the strict filter must neutralise a
	// body that tries to open a heading.
	body := ClaimBody("mdt3", id)
	if body == "" {
		t.Fatal("setup: an unmoderated body must be served at all")
	}
	if hasLineStarting(body, "# ") {
		t.Errorf("the ClaimBody read must not pass an ATX heading through: %q", body)
	}
	if hasLineStarting(body, "> ") {
		t.Errorf("the ClaimBody read must not pass a blockquote through: %q", body)
	}

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	// A category code that tries to forge structure. Single line, since it shares a
	// line with the tombstone's own text on every surface.
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeClaim(cross(cur), "mdt3", id, "# FORGED CODE [x](http://y)")

	page := Render("mdt3/" + itoa(int64(id)))
	if !strings.Contains(page, "FORGED CODE") {
		t.Fatalf("setup: the tombstone code must appear at all, or nothing is being "+
			"measured: %s", page)
	}
	if hasLineStarting(page, "# FORGED") {
		t.Error("a tombstone code must not open a heading on the claim page")
	}
	uassert.False(t, strings.Contains(page, "](http://y)"),
		"a tombstone code must not carry a live link onto the page")

	// The court name's tombstone, same code, and the directory as well as the court
	// page — a purged court's name appears on both.
	bob := testutils.TestAddress("mdt3-bob")
	testCourt(cur, "mdt4", bob, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeCourt(cross(cur), "mdt4", "# FORGED COURT [x](http://y)")
	cpage := Render("mdt4")
	if !strings.Contains(cpage, "FORGED COURT") {
		t.Fatalf("setup: a purged court shows its code: %s", cpage)
	}
	// A COURT tombstone cannot open a heading whatever it says, because it is printed
	// INSIDE "[removed · … ]" and so never starts a line — which is why the heading
	// assertion above passes with the sanitiser removed and the LINK assertion is the
	// one that measures this surface. Getting that wrong is how a test comes to cover
	// a surface only in appearance.
	if strings.Contains(cpage, "](http://y)") {
		t.Error("a court tombstone code must not carry a live link onto the court page")
	}
	if strings.Contains(Render(""), "](http://y)") {
		t.Error("a court tombstone code must not carry a live link onto the directory")
	}
}

// THE ONE SANITISER IN THIS FILE THAT CANNOT MATTER, and the premise that makes it
// so — pinned here, because the premise is what could change. qualifiedSymbol wraps
// the coin symbol in InlineText and removing that survived everything, for a reason
// no test stated: courtSymbol is strings.ToUpper(slug), and a slug is validated as
// lowercase letters, digits and hyphens, 1..11 characters. So a symbol's alphabet is
// [A-Z0-9-] and contains no markdown metacharacter at all — the sanitiser has nothing
// to do and no test can make it do something.
//
// This asserts the ALPHABET rather than the sanitiser. If slug validation ever widens,
// this goes red and the KNOWN-GAPS row that calls the sanitiser redundant stops being
// true — which is the only way that row can be maintained honestly.
func TestACourtSymbolsAlphabetIsWhatMakesItsSanitiserRedundant(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mdt5-alice")
	for _, slug := range []string{"a", "z9", "withhyph", "abcdefghijk"} {
		testCourt(cur, slug, alice, 1_000_000)
		sym := CourtSymbol(slug)
		if sym == "" {
			t.Fatalf("setup: court %q must have a symbol", slug)
		}
		for i := 0; i < len(sym); i++ {
			ch := sym[i]
			ok := (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-'
			if !ok {
				t.Fatalf("symbol %q carries %q, which is outside [A-Z0-9-] — the "+
					"premise that makes qualifiedSymbol's sanitiser redundant no "+
					"longer holds, so restore the row for it", sym, string(ch))
			}
		}
	}
}
