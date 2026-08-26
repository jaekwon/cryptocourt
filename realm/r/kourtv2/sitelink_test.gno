package kourtv2

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

// The seat: the global DAO ADMIN, and nobody else. Not a court's moderators, not
// a global DAO member who is not the admin, not the meta court.
func TestOnlyTheAdminSetsTheSiteDomain(cur realm, t *testing.T) {
	mod := testutils.TestAddress("sl1-mod")
	poster := testutils.TestAddress("sl1-poster")
	modFixture(cur, "sl1", mod, poster)
	admin := ensureGlobalDAO().admin

	// A COURT MODERATOR CANNOT. This is the case the design exists to refuse: a
	// court that could set the domain could route its own readers anywhere while
	// wearing the platform's name.
	testing.SetRealm(testing.NewUserRealm(mod))
	uassert.AbortsContains(t, cur, "only the global DAO admin sets the site domain", func() {
		SetSiteDomain(cross(cur), "evil.example")
	})
	// NOR A STRANGER.
	testing.SetRealm(testing.NewUserRealm(poster))
	uassert.AbortsContains(t, cur, "only the global DAO admin sets the site domain", func() {
		SetSiteDomain(cross(cur), "evil.example")
	})
	// NOR A GLOBAL DAO MEMBER WHO IS NOT THE ADMIN. Membership carries the
	// redaction and purge powers; it does not carry the front door.
	member := testutils.TestAddress("sl1-member")
	testing.SetRealm(testing.NewUserRealm(admin))
	AddGlobalMod(cross(cur), member)
	testing.SetRealm(testing.NewUserRealm(member))
	uassert.AbortsContains(t, cur, "only the global DAO admin sets the site domain", func() {
		SetSiteDomain(cross(cur), "evil.example")
	})
	testing.SetRealm(testing.NewUserRealm(admin))
	RemoveGlobalMod(cross(cur), member)

	if SiteDomain() != "" {
		t.Fatal("no refused caller may have set it")
	}

	// THE CONTROL: the admin's own call lands, so the three refusals are about
	// the seat and not about a fixture that could never succeed.
	testing.SetRealm(testing.NewUserRealm(admin))
	SetSiteDomain(cross(cur), "kourt.xyz")
	if SiteDomain() != "kourt.xyz" {
		t.Fatal("the admin must be able to set it")
	}
	// And clear it, on the same seat — restored inline so no later test inherits
	// a header.
	testing.SetRealm(testing.NewUserRealm(mod))
	uassert.AbortsContains(t, cur, "only the global DAO admin clears the site domain", func() {
		ClearSiteDomain(cross(cur))
	})
	testing.SetRealm(testing.NewUserRealm(admin))
	ClearSiteDomain(cross(cur))
	if SiteDomain() != "" {
		t.Fatal("the admin must be able to clear it")
	}
	testing.SetRealm(testing.NewUserRealm(admin))
	uassert.AbortsContains(t, cur, "no site domain is set", func() {
		ClearSiteDomain(cross(cur))
	})
}

// A hostname and only a hostname. The validator is what makes the value safe to
// print, and what stops an admin from smuggling a path into every page.
//
// Each bad input is paired with the REASON it must be refused, not merely with
// the fact of a refusal: a validator that rejects everything for one reason
// passes a test that only checks that it rejected.
func TestTheSiteDomainIsAHostnameAndNothingElse(cur realm, t *testing.T) {
	// The fixture comes FIRST: ensureGlobalDAO panics when no court exists, and
	// reading the admin before bootstrapping has already broken two tests here.
	modFixture(cur, "sl2", testutils.TestAddress("sl2-mod"), testutils.TestAddress("sl2-poster"))
	admin := ensureGlobalDAO().admin
	long := ""
	for i := 0; i < 101; i++ {
		long += "a"
	}
	for _, tc := range []struct{ bad, why string }{
		{"", "4..100 characters"},
		{"abc", "4..100 characters"},
		{long + ".xyz", "4..100 characters"},
		{"kourtxyz", "needs a dot"},
		{".kourt.xyz", "begin or end with a dot"},
		{"kourt.xyz.", "begin or end with a dot"},
		{"-kourt.xyz", "begin or end with a dot"},
		{"kourt.xyz-", "begin or end with a dot"},
		{"kourt..xyz", "empty label"},
		// Everything below is refused by the character set — which is the same
		// rule that keeps the stored value printable inside a markdown link.
		{"https://kourt.xyz", "no scheme, no path, no port"}, // a scheme
		{"kourt.xyz/asdasdasd", "no scheme, no path, no port"}, // a PATH: the thing that must never be storable
		{"kourt.xyz:8080", "no scheme, no path, no port"},    // a port
		{"kourt.xyz?a=b", "no scheme, no path, no port"},     // a query
		{"Kourt.XYZ", "no scheme, no path, no port"},         // uppercase
		{"kourt xyz.com", "no scheme, no path, no port"},     // whitespace
		{"kourt.xyz)](http://e", "no scheme, no path, no port"}, // a markdown break-out
		{"kourt.xyz`", "no scheme, no path, no port"},        // a backtick
		{"kourt.xyz\n# heading", "no scheme, no path, no port"}, // a newline
	} {
		testing.SetRealm(testing.NewUserRealm(admin))
		uassert.AbortsContains(t, cur, tc.why, func() {
			SetSiteDomain(cross(cur), tc.bad)
		}, "must refuse "+tc.bad)
	}
	if SiteDomain() != "" {
		t.Fatal("a refused domain must not be stored")
	}
	// And the shapes that are legitimate — so the refusals above are about the
	// inputs and not about a validator that refuses everything.
	for _, ok := range []string{"kourt.xyz", "a.io", "my-kourt.example.co.uk", "k2.dev"} {
		testing.SetRealm(testing.NewUserRealm(admin))
		SetSiteDomain(cross(cur), ok)
		if SiteDomain() != ok {
			t.Fatal("refused a legitimate domain: " + ok)
		}
	}
	testing.SetRealm(testing.NewUserRealm(admin))
	ClearSiteDomain(cross(cur))
}

// The header appears on every page, pointing at the SAME thing over there — and
// the realm owns the path, so a claim page can only ever deep-link to that claim.
func TestTheHeaderRoutesEachPageToItsCounterpart(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sl3-alice")
	c, id := boardFixture(cur, "sl3", alice)
	admin := ensureGlobalDAO().admin
	sid := strconv.FormatUint(id, 10)
	_ = c

	// With no domain configured, no header anywhere — a realm with no website
	// renders exactly as it always did.
	for _, p := range []string{"", "sl3", "sl3/" + sid, "sl3/" + sid + "/board", "sl3/me"} {
		if strings.Contains(Render(p), "Read this on") {
			t.Fatal("an unconfigured realm must carry no header: " + p)
		}
	}

	testing.SetRealm(testing.NewUserRealm(admin))
	SetSiteDomain(cross(cur), "kourt.xyz")

	for _, tc := range []struct{ path, want string }{
		{"", "https://kourt.xyz/#/"},
		{"sl3", "https://kourt.xyz/#/c/sl3"},
		{"sl3/" + sid, "https://kourt.xyz/#/c/sl3/" + sid},
		// A board, a row and a positions page all belong to their CLAIM: the
		// overlay has no route for them, and the claim is the nearest true thing.
		{"sl3/" + sid + "/board", "https://kourt.xyz/#/c/sl3/" + sid},
		{"sl3/" + sid + "/board/1", "https://kourt.xyz/#/c/sl3/" + sid},
		{"sl3/me", "https://kourt.xyz/#/me"},
		{"sl3/mod", "https://kourt.xyz/#/c/sl3"},
		// A malformed claim id is not a claim, so it routes to the court rather
		// than fabricating a claim link.
		{"sl3/notanumber", "https://kourt.xyz/#/c/sl3"},
	} {
		got := Render(tc.path)
		if !strings.Contains(got, "Read this on kourt.xyz") {
			t.Fatalf("no header on %q", tc.path)
		}
		if !strings.Contains(got, "]("+tc.want+")") {
			t.Fatalf("header on %q points at the wrong page; want %q", tc.path, tc.want)
		}
	}
	// It is FIRST — a reader who stops reading after one line still sees it.
	r := Render("sl3/" + sid)
	if strings.Index(r, "Read this on") > strings.Index(r, "#") {
		t.Fatal("the header must precede the page's own heading")
	}

	testing.SetRealm(testing.NewUserRealm(admin))
	ClearSiteDomain(cross(cur))
}

// The fail-closed guard, reached the only way it can be: by putting a value in
// the variable that the setter would never have accepted.
//
// This is white-box on purpose. The guard exists for the case where a value
// arrives without passing mustSiteDomain — a future setter, a migration, a
// state load — and no black-box test can produce that. Written as a black-box
// test it would be unreachable code with a corpus row that always survives.
func TestABadStoredDomainCostsTheHeaderAndNotThePage(cur realm, t *testing.T) {
	alice := testutils.TestAddress("sl4-alice")
	_, id := boardFixture(cur, "sl4", alice)
	path := "sl4/" + strconv.FormatUint(id, 10)
	good := Render(path)

	for _, bad := range []string{
		"evil.example/#/c/other/1",  // a path: would deep-link somewhere it does not say
		"evil.example)](http://e",   // would break out of the markdown link
		"evil example.com",          // would terminate the link destination early
		"x",                         // too short to be a host at all
	} {
		siteDomain = bad
		got := Render(path)
		if strings.Contains(got, "Read this on") {
			t.Fatal("a domain that does not validate must print no header: " + bad)
		}
		// And the page itself is unharmed — the cost is the header, never the
		// claim underneath it.
		if got != good {
			t.Fatal("a bad domain changed the page below the header: " + bad)
		}
	}
	siteDomain = ""
}
