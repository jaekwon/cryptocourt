package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// Hiding removes a claim from the court's LIST but never from its own page:
// the deep link still renders, with a banner naming the authority.
// Enforces I3: hiding controls DISCOVERY, so the deep link still renders.
func TestRenderHiddenDropsFromListNotDeepLink(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rr1-alice")
	testCourt(cur, "mdr1", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "mdr1", "a very distinctive title")

	if !strings.Contains(Render("mdr1"), "a very distinctive title") {
		t.Fatal("an unhidden claim should be listed")
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	HideItem(cross(cur), "mdr1", id, "off-topic")

	if strings.Contains(Render("mdr1"), "a very distinctive title") {
		t.Fatal("a hidden claim must drop out of the court listing")
	}
	deep := Render("mdr1/1")
	if !strings.Contains(deep, "a very distinctive title") {
		t.Fatal("the deep link must still render the claim")
	}
	if !strings.Contains(deep, "Hidden by this court's moderators") {
		t.Fatal("the deep link must carry a banner naming the authority")
	}
}

// A purged claim renders a category-code tombstone instead of its text, on
// every surface — but its money state still renders.
// Enforces I3's purge arm: a purged claim renders a tombstone, not its text.
func TestRenderPurgedShowsTombstone(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rr2-alice")
	testCourt(cur, "mdr2", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	OpenClaim(cross(cur), "mdr2", "unspeakable text here")

	dadmin := DirectoryAdmin()
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeClaim(cross(cur), "mdr2", 1, "CSAM")

	page := Render("mdr2/1")
	if strings.Contains(page, "unspeakable text here") {
		t.Fatal("purged text must never render")
	}
	if !strings.Contains(page, "removed") || !strings.Contains(page, "CSAM") {
		t.Fatal("a purged row shows its statutory category code")
	}
	if !strings.Contains(page, "Signal") {
		t.Fatal("money/state sections still render for a purged claim")
	}
}

// The moderation log route renders acts and the set's threshold.
func TestRenderModLogRoute(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rr3-alice")
	testCourt(cur, "mdr3", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "mdr3", "logged claim")
	testing.SetRealm(testing.NewUserRealm(alice))
	HideItem(cross(cur), "mdr3", id, "spam")

	page := Render("mdr3/mod")
	if !strings.Contains(page, "Moderation log") {
		t.Fatal("the /mod route should render the log")
	}
	if !strings.Contains(page, "hide") {
		t.Fatal("the log should list the hide act")
	}
	if !strings.Contains(page, "1 of 1") {
		t.Fatal("the log should state the m-of-n threshold")
	}
}

// An answered claim appears under "Needs review" even while hidden.
func TestRenderStripSectionIgnoresHiding(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rr4-alice")
	testCourt(cur, "mdr4", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "mdr4", "policeable claim")
	matureOI(cur, "mdr4", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "mdr4", id, sideYES)
	testing.SetRealm(testing.NewUserRealm(alice))
	HideItem(cross(cur), "mdr4", id, "trying to bury it")

	page := Render("mdr4")
	if !strings.Contains(page, "Needs review") {
		t.Fatal("the strip section should render")
	}
	// The strip lists it even though the ordinary listing dropped it.
	idx := strings.Index(page, "Needs review")
	if !strings.Contains(page[idx:], "policeable claim") {
		t.Fatal("a hidden but policeable claim must appear on the strip")
	}
}

// The front page ranks listed courts by GNOT burned, descending.
func TestDirectoryRanksByBurn(cur realm, t *testing.T) {
	a := testutils.TestAddress("rr5-a")
	testCourt(cur, "mdr5low", a, 1_000_000)
	testCourt(cur, "mdr5high", a, 1_000_000)
	reindexBurn(mustCourt("mdr5low"), 10)
	reindexBurn(mustCourt("mdr5high"), 10_000)

	order := ListedCourtsBy("burn", 0, 100)
	hi, lo := -1, -1
	for i, s := range order {
		if s == "mdr5high" {
			hi = i
		}
		if s == "mdr5low" {
			lo = i
		}
	}
	if hi < 0 || lo < 0 || hi > lo {
		t.Fatalf("the higher-burn court must rank first: high=%d low=%d", hi, lo)
	}
	if CourtBurnedGNOT("mdr5high") != 10_000 {
		t.Fatal("burn total should accumulate")
	}
	// The alternative ordering is available and paginated.
	if got := ListedCourtsBy("new", 0, 1); len(got) != 1 {
		t.Fatalf("creation ordering should paginate, got %v", got)
	}
}

// Court coins must be DISTINGUISHABLE. Every court used to mint its ledger with
// the literal symbol "COURT" — which grc20votes also adopts as the ledger id —
// so two courts' coins were identically labelled and identically identified,
// while being non-fungible and backed by separate one-way curves. Wallets and
// explorers key display on the symbol, not the package path, so that was a live
// phishing vector.
func TestCourtSymbolsAreUniquePerCourt(cur realm, t *testing.T) {
	a := testutils.TestAddress("sym-a")
	testCourt(cur, "symone", a, 1_000_000)
	testCourt(cur, "symtwo", a, 1_000_000)

	if CourtSymbol("symone") == CourtSymbol("symtwo") {
		t.Fatal("two courts must not share a coin symbol")
	}
	if CourtSymbol("symone") != "SYMONE" {
		t.Fatalf("symbol is the upper-cased slug, got %q", CourtSymbol("symone"))
	}
	// INJECTIVITY IS NOW FREE, and this assertion used to buy it. The slug
	// alphabet included the hyphen, so uppercase() had to preserve it or "ab-c"
	// and "abc" would collide into one symbol and two courts would share a coin
	// name. With the alphabet alphanumeric, uppercase() on [a-z0-9] is injective
	// by construction — there is no character left for it to fold away.
	// Kept as the plain identity it now is, rather than deleted: two courts
	// sharing a symbol is the property under test, and the line above still
	// checks the pair. This one checks the mapping is exactly uppercase.
	if CourtSymbol("symtwo") != "SYMTWO" {
		t.Fatalf("symbol is the upper-cased slug, got %q", CourtSymbol("symtwo"))
	}
}

// Reserved slugs cannot be registered — otherwise a court could mint a coin
// that impersonates the platform token in any symbol-only wallet view.
func TestReservedSlugsRefused(cur realm, t *testing.T) {
	a := testutils.TestAddress("sym-res")
	for _, bad := range []string{"kourt", "court", "gnot", "usdc"} {
		testing.SetRealm(testing.NewUserRealm(a))
		uassert.AbortsContains(t, cur, "kourtv2: that slug is reserved", func() {
			StartCourt(cross(cur), bad, "impostor")
		})
	}
	// The meta slug is refused on the PUBLIC path too (init owns it).
	testing.SetRealm(testing.NewUserRealm(a))
	uassert.AbortsContains(t, cur, "kourtv2: the 'meta' slug is reserved", func() {
		StartCourt(cross(cur), metaSlug, "impostor")
	})
}

// Court coins render NAMESPACED outside their own court, so a court ticker can
// never be read as the platform token or as another court's coin.
func TestQualifiedSymbolRendering(cur realm, t *testing.T) {
	a := testutils.TestAddress("qs-a")
	testCourt(cur, "qsone", a, 1_000_000)

	if page := Render("qsone"); !strings.Contains(page, "KOURT:QSONE") {
		t.Fatalf("the court page should show the namespaced ticker:\n%s", page)
	}
	if !strings.Contains(Render(""), "Kourt") {
		t.Fatal("the front page should carry the product name")
	}
	// The platform ticker and its homophone are not squattable as slugs.
	testing.SetRealm(testing.NewUserRealm(a))
	uassert.AbortsContains(t, cur, "kourtv2: that slug is reserved", func() {
		StartCourt(cross(cur), "kourt", "impostor")
	})
	testing.SetRealm(testing.NewUserRealm(a))
	uassert.AbortsContains(t, cur, "kourtv2: that slug is reserved", func() {
		StartCourt(cross(cur), "court", "impostor")
	})
}

// A moderation log is an accountability record, so a page of it that is not the
// whole thing must SAY so — a reader shown a silent slice concludes nothing else
// happened. The walk is bounded on two terms (rows AND claims visited), because
// bounding on rows alone bounds output rather than work: a claimMod carrying few
// acts costs a step and buys no row.
func TestModLogReportsItsOwnTruncation(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mdr9-alice")
	testCourt(cur, "mdr9", alice, 500_000_000_000)

	// One act each on more claims than a page holds.
	for i := 0; i < renderPageSize+5; i++ {
		testing.SetRealm(testing.NewUserRealm(alice))
		id := OpenClaim(cross(cur), "mdr9", "claim "+strconv.Itoa(i))
		testing.SetRealm(testing.NewUserRealm(alice))
		HideItem(cross(cur), "mdr9", id, "spam")
	}

	page := Render("mdr9/mod")
	if !strings.Contains(page, "older acts are not shown") {
		t.Fatal("a truncated moderation log must say it is truncated")
	}
	if !strings.Contains(page, "most recent acts") {
		t.Fatal("the notice should say how many acts are shown")
	}
	// The bound really binds: a page, not the whole history.
	if n := strings.Count(page, "· hide ·"); n != renderPageSize {
		t.Fatalf("the log rendered %d acts, want exactly one page of %d", n, renderPageSize)
	}

	// And a court whose log fits says nothing about truncation, so the notice
	// carries information rather than decorating every page.
	bob := testutils.TestAddress("mdr9-bob")
	testCourt(cur, "mdr9b", bob, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	small := OpenClaim(cross(cur), "mdr9b", "just the one")
	testing.SetRealm(testing.NewUserRealm(bob))
	HideItem(cross(cur), "mdr9b", small, "spam")
	if strings.Contains(Render("mdr9b/mod"), "older acts are not shown") {
		t.Fatal("a log that fits on one page must not claim to be truncated")
	}
}

// An m-of-n set that cannot see what it has half-approved coordinates by
// rumour, and v0.25 gave every unfired approval a 7-day expiry — a deadline
// nobody can see is a trap for a set six days into gathering signatures.
//
// The second assertion is the load-bearing one. A pending proposal's `reason` is
// free text ONE moderator wrote, which no m-of-n has approved. Rendering it
// would hand any single member a publication channel on the court's own page
// without the set's consent — the same authority-without-agreement the m-of-n
// exists to prevent. It appears only once the act carries.
func TestPendingProposalsRenderWithoutTheirReason(cur realm, t *testing.T) {
	alice := testutils.TestAddress("mdrp-alice")
	m2 := testutils.TestAddress("mdrp-m2")
	testCourt(cur, "mdrp", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	AppointMods(cross(cur), "mdrp", 2, alice, m2)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "mdrp", "a claim")

	testing.SetRealm(testing.NewUserRealm(alice))
	HideItem(cross(cur), "mdrp", id, "SECRETSMEAR")
	if HiddenFromListing("mdrp", id) {
		t.Fatal("fixture: one of two must not fire")
	}

	page := Render("mdrp/mod")
	if !strings.Contains(page, "Awaiting approval") {
		t.Fatal("an in-flight proposal must be visible to its own set")
	}
	if !strings.Contains(page, "1 of 2 approved") {
		t.Fatal("the tally so far must render")
	}
	// "expires at <unix> (block <height>)" — the date first, because that is what
	// the realm gates on, with the height beside it as the reference.
	if !strings.Contains(page, "approved, expires at ") || !strings.Contains(page, "(block ") {
		t.Fatal("the deadline must render — an unseen 7-day clock is a trap")
	}
	// AND THE DATE IS ACTUALLY THERE. Asserting the two fragments above is not
	// enough: suppress the date and the row still reads "expires at (block N)",
	// which contains both. Measured — that mutant survived until this line.
	if strings.Contains(page, "expires at (block") {
		t.Fatal("the row printed its reference height with no date before it")
	}
	if strings.Contains(page, "SECRETSMEAR") {
		t.Fatal("an UNAPPROVED reason must not render: that is a publication channel for one member")
	}

	// Once the act carries it leaves the pending list and the reason appears.
	testing.SetRealm(testing.NewUserRealm(m2))
	HideItem(cross(cur), "mdrp", id, "SECRETSMEAR")
	page = Render("mdrp/mod")
	if strings.Contains(page, "Awaiting approval") {
		t.Fatal("a carried act must leave the pending list")
	}
	if !strings.Contains(page, "SECRETSMEAR") {
		t.Fatal("the reason belongs in the log once the set actually agreed")
	}

	// An expired proposal is not pending either — the read agrees with
	// approveAction, which treats it as absent.
	testing.SetRealm(testing.NewUserRealm(alice))
	id2 := OpenClaim(cross(cur), "mdrp", "another claim")
	testing.SetRealm(testing.NewUserRealm(alice))
	HideItem(cross(cur), "mdrp", id2, "stale")
	testing.SkipHeights(pendingTTLBlocks + 1)
	if strings.Contains(Render("mdrp/mod"), "Awaiting approval") {
		t.Fatal("an expired proposal must not read as in-flight")
	}
}

// RENDER SAFETY FOR THE BODY, which is the only place on any claim page where a
// stranger writes multiple LINES. Every other user string is inline (a title, a
// reason, a folder name) and cannot open a markdown block; a body can, and the
// gnoweb pipeline has no HTML sanitiser after the realm — raw HTML blocks pass
// through goldmark, and six markdown extensions are globally enabled and cannot
// be opted out of per page.
//
// So the escaping is not this realm's own: it is sanitize.Block, the STRICT
// variant, which is the one that escapes the doc-spoof markers (ATX headings,
// blockquote markers, list markers, thematic breaks, setext underlines) that
// sanitize.BlockRich deliberately preserves. A body must not be able to forge
// page structure, and "forge an alert callout" is a real one here: gnoweb's
// ext_alerts turns `> [!WARNING]` into a styled admonition, so a body that could
// open a blockquote could put an official-looking warning on somebody's claim.
//
// This test does not re-test the sanitiser. It tests THIS realm's integration of
// it: that the body goes through it at all, and that Block's trailing "\n\n"
// envelope — the thing that stops an unclosed `<div>` from swallowing the chrome
// below it — survives the way render.gno concatenates.
// ARMED BY HAND, twice, and both arms found something. Pointing render.gno at
// claimBodyFor (escaped but not quoted) fails with `a line begins "<div>"`, which
// is the hole that motivated quoting. Removing the moderation branch from
// claimBodyVisible fails TestClaimBodyIsBoundedAndModerated in claim_test.gno.
func TestClaimBodyCannotForgePageStructure(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rsf-alice")
	testCourt(cur, "rsf", alice, 10_000_000_000)

	hostile := "=== \n" + // first-line setext: would promote the chrome above it
		"# Forged heading\n\n" +
		"> [!WARNING]\n> Forged alert callout\n\n" +
		"<div>\n" +
		"<gno-columns>\n" +
		"| forged | table |\n" +
		"--- \n" +
		"```\nunclosed fence\n" +
		"[forgedlabel]: https://example.invalid\n"
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaimP(cross(cur), "rsf", "a claim with a hostile body", hostile)

	page := Render("rsf/" + strconv.FormatUint(id, 10))

	// No line may BEGIN with a construct the body asked for: markdown block
	// structure is decided at line start, so that is where to look. `<div>` is on
	// this list because of what the first version of this test found — Block
	// escapes CM §4.6 HTML types 1-5 but not 6 and 7, so a bare "<div>" DID reach
	// the page at line start and was merely closed by the envelope. Quoting the
	// body puts a `> ` in front of it, which is what makes this assertion hold.
	for _, bad := range []string{"# Forged", "> [!WARNING]", "<div>",
		"<gno-columns>", "| forged |"} {
		if strings.Contains(page, "\n"+bad) {
			t.Fatalf("a body forged page structure: a line begins %q", bad)
		}
	}
	// Positively: the line carrying the body's own words is INSIDE the quotation.
	// Not asserted against a literal — Block escapes the `#` to `\#`, so the line
	// reads "> \# Forged heading" and pinning that spelling would pin the
	// sanitiser's internals rather than this realm's use of it.
	found := false
	for _, line := range strings.Split(page, "\n") {
		if strings.Contains(line, "Forged heading") {
			found = true
			if !strings.HasPrefix(line, "> ") {
				t.Fatalf("the body's line is not quoted: %q", line)
			}
		}
	}
	if !found {
		t.Fatal("the body's text never reached the page")
	}
	// The text still READS — escaping must not have eaten the author's words.
	if !strings.Contains(page, "Forged heading") {
		t.Fatal("the body's text was dropped rather than escaped")
	}
	// And the realm's own chrome BELOW the body is intact. This is the assertion
	// that catches a broken envelope: an unclosed fence or an open <div> would
	// swallow the sections that follow.
	for _, chrome := range []string{"## Signal", "## Status"} {
		if !strings.Contains(page, "\n"+chrome) {
			t.Fatalf("the body swallowed the realm's own %q section", chrome)
		}
	}
}

// A purge code cannot write markup into the moderation log.
//
// modAct's own doc said the opposite — "code is a category/act code (an enum),
// never user text" — and that is false for three of the eleven acts that write a
// log row. Eight pass a fixed string ("hide", "unhide", "meta-clear" and the
// like), but three CONCATENATE a caller-supplied statutory code into it:
// "global-hide:"+categoryCode, "purge:"+code and "purgerow:"+code. And
// mustCategoryCode validates LENGTH ONLY — non-empty, at most maxReasonLen — with
// no alphabet and no enum membership, so those three carry free text with every
// punctuation mark available.
//
// A false "cannot be user text" is worse than no comment, because it is exactly
// what licenses the next reader to render the field raw. renderModLog does
// sanitise it today, defensively and against its own doc, and NOTHING PINNED
// THAT: measured on a staged copy with the anchor count printed and the exit
// status gated, dropping sanitize.InlineText from the code field leaves the whole
// kourtv2 suite green.
//
// The actor is a global DAO member, so this is not an open door — but purge is
// the LEGAL-HOLD act, whose whole purpose is removing text that must not be
// displayed, and the tombstone it leaves would have been a place to put text
// back. gnoweb runs no HTML sanitiser after a realm.
//
// Asserted on the BACKSLASH rather than the payload, for the reason recorded in
// VOTEFLOOR: Contains(out, "<img") matches the ESCAPED form just as well, so it
// passes whether the sanitiser ran or not.
func TestAPurgeCodeCannotWriteMarkupIntoTheModLog(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ci-alice")
	testCourt(cur, "codeinj", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "codeinj", "a claim someone wants gone")

	// The LIVE admin, not DirectoryAdmin(): the global DAO is a package singleton
	// whose seat an earlier test in this process may have moved. m=1 so one
	// signature fires, which is what the ~30 other purge fixtures here do.
	dadmin := ensureGlobalDAO().admin
	testing.SetRealm(testing.NewUserRealm(dadmin))
	SetPurgeThreshold(cross(cur), 1)

	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeClaim(cross(cur), "codeinj", id, "<img src=x onerror=1>")

	out := Render("codeinj/mod")
	for i := 0; i < len(out); i++ {
		if out[i] == '<' && (i == 0 || out[i-1] != '\\') {
			t.Errorf("the moderation log carries an unescaped '<' at byte %d, so a "+
				"purge code reaches the reader as markup:\n%s", i, out)
			break
		}
	}

	// AND THE ORDINARY CODE IT MUST STILL SHOW. The log is the audit trail for an
	// irreversible act, so a code that renders as nothing would be a worse bug
	// than an unescaped one — and without this arm, sanitising to the empty string
	// would pass the loop above.
	testing.SetRealm(testing.NewUserRealm(alice))
	id2 := OpenClaim(cross(cur), "codeinj", "a second claim someone wants gone")
	testing.SetRealm(testing.NewUserRealm(dadmin))
	PurgeClaim(cross(cur), "codeinj", id2, "CSAM")
	if ok := Render("codeinj/mod"); !strings.Contains(ok, "purge:CSAM") {
		t.Errorf("an ordinary purge code no longer appears in the log:\n%s", ok)
	}
}

// A moderation REASON cannot write markup into the moderation log either.
//
// The sibling of the purge-code test above, and the more important half: a code
// could in principle be narrowed to an alphabet, but a reason is prose by design
// and checkReason bounds it by LENGTH ONLY. So escaping at render is the only
// defence this field will ever have.
//
// It had no test. Measured on a staged copy, anchor count printed and exit status
// gated: dropping sanitize.InlineText from the reason field leaves the entire
// kourtv2 suite green. The log's two free-text fields were both unpinned, and
// modtext_test's forge fixtures reach the claim body, the court desc and the
// tombstone code — never a reason, and never this page.
//
// Asserted on the BACKSLASH, not the payload, for the reason recorded in
// VOTEFLOOR: Contains(out, "<img") matches the escaped form just as happily.
func TestAModerationReasonCannotWriteMarkupIntoTheModLog(cur realm, t *testing.T) {
	alice := testutils.TestAddress("ri-alice")
	testCourt(cur, "rsninj", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "rsninj", "a claim to hide")

	testing.SetRealm(testing.NewUserRealm(alice))
	HideItem(cross(cur), "rsninj", id, "<img src=x onerror=1> [f](u)")

	out := Render("rsninj/mod")
	for i := 0; i < len(out); i++ {
		if out[i] == '<' && (i == 0 || out[i-1] != '\\') {
			t.Errorf("the moderation log carries an unescaped '<' at byte %d, so a "+
				"moderation reason reaches the reader as markup:\n%s", i, out)
			break
		}
	}

	// AND THE ORDINARY REASON IT MUST STILL SHOW. The log is why a moderator's act
	// can be reviewed at all, so a reason escaped into nothing would be the worse
	// bug — and it would satisfy the loop above.
	//
	// "spam" and not "off-topic", which is what this arm was written with first: a
	// HYPHEN is in markdown.EscapeInline's set, so an ordinary-looking reason comes
	// back as `off\-topic` and the assertion fails on correct code. The arm has to
	// use a string with nothing escapable in it, or it is testing the escaping it
	// is supposed to be the control for.
	testing.SetRealm(testing.NewUserRealm(alice))
	id2 := OpenClaim(cross(cur), "rsninj", "a second claim to hide")
	testing.SetRealm(testing.NewUserRealm(alice))
	HideItem(cross(cur), "rsninj", id2, "spam")
	if ok := Render("rsninj/mod"); !strings.Contains(ok, "spam") {
		t.Errorf("an ordinary moderation reason no longer appears in the log:\n%s", ok)
	}
}
