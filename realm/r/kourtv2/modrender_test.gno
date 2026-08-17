package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// Hiding removes a claim from the court's LIST but never from its own page:
// the deep link still renders, with a banner naming the authority.
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
	testCourt(cur, "sym-two", a, 1_000_000)

	if CourtSymbol("symone") == CourtSymbol("sym-two") {
		t.Fatal("two courts must not share a coin symbol")
	}
	if CourtSymbol("symone") != "SYMONE" {
		t.Fatalf("symbol is the upper-cased slug, got %q", CourtSymbol("symone"))
	}
	// Hyphens are PRESERVED: stripping them would break injectivity, so "ab-c"
	// and "abc" would collide and reintroduce the shared-symbol problem.
	if CourtSymbol("sym-two") != "SYM-TWO" {
		t.Fatalf("hyphens must survive, got %q", CourtSymbol("sym-two"))
	}
}

// Reserved slugs cannot be registered — otherwise a court could mint a coin
// that impersonates the platform token in any symbol-only wallet view.
func TestReservedSlugsRefused(cur realm, t *testing.T) {
	a := testutils.TestAddress("sym-res")
	for _, bad := range []string{"kourt", "court", "gnot", "usdc"} {
		testing.SetRealm(testing.NewUserRealm(a))
		uassert.AbortsContains(t, cur, "reserved", func() {
			StartCourt(cross(cur), bad, "impostor")
		})
	}
	// The meta slug is refused on the PUBLIC path too (init owns it).
	testing.SetRealm(testing.NewUserRealm(a))
	uassert.AbortsContains(t, cur, "reserved", func() {
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
	uassert.AbortsContains(t, cur, "reserved", func() {
		StartCourt(cross(cur), "kourt", "impostor")
	})
	testing.SetRealm(testing.NewUserRealm(a))
	uassert.AbortsContains(t, cur, "reserved", func() {
		StartCourt(cross(cur), "court", "impostor")
	})
}
