package kourtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

// field pulls one key out of AdminParams' packed line, splitting each pair on
// the FIRST colon only — which is the rule AdminParams' own doc states, so this
// helper doubles as a check that the stated parse actually works.
func field(packed, key string) string {
	for _, pair := range strings.Split(packed, ";") {
		i := strings.Index(pair, ":")
		if i < 0 {
			continue
		}
		if pair[:i] == key {
			return pair[i+1:]
		}
	}
	return "<missing>"
}

// ONE LINE, and this is the arm that keeps it that way. The overlay's
// parseTyped splits raw output on newlines before it matches a typed value, so
// a multi-line answer does not merely look untidy — it parses as garbage and
// the page shows nothing, which is the failure mode this whole read exists to
// avoid. media.gno's MediaHosts carries the same constraint.
func TestAdminParamsIsASingleLine(cur realm, t *testing.T) {
	maker := testutils.TestAddress("ap-maker")
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(maker))
	if !Exists("ap0") {
		StartCourt(cross(cur), "ap0", "Params Fixture")
	}

	packed := AdminParams()
	if strings.Contains(packed, "\n") {
		t.Fatalf("AdminParams must be one line: %q", packed)
	}
	if strings.Contains(packed, "\t") {
		t.Fatalf("AdminParams must not contain tabs: %q", packed)
	}
	// Every documented key is present. A listing that silently drops a
	// parameter is worse than no listing: it reads as "these are all of them".
	for _, k := range []string{
		"admin", "creationBurn", "assocBond", "purgeM",
		"t1", "t2", "t3", "entry", "l2", "l3",
		"flag", "dispute", "authorHigh", "conviction", "unadjudicated",
		"domain", "mediaExact", "mediaSuffix",
	} {
		if got := field(packed, k); got == "<missing>" {
			t.Fatalf("AdminParams is missing %q: %q", k, packed)
		}
	}
}

// IT REPORTS THE LIVE VALUE, NOT A REMEMBERED ONE. This is the arm that matters:
// a listing that keeps its own copy of a default is wrong the first time
// somebody changes one, and it would still pass every "is the key present"
// check above. So a real setter is driven and the listing is read back.
func TestAdminParamsFollowsTheSetters(cur realm, t *testing.T) {
	maker := testutils.TestAddress("ap-follow")
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(maker))
	if !Exists("ap1") {
		StartCourt(cross(cur), "ap1", "Params Fixture Two")
	}

	admin := ensureGlobalDAO().admin
	burn0 := courtCreationBurn
	bond0 := assocBondDefault
	defer func() {
		testing.SetRealm(testing.NewUserRealm(admin))
		SetCourtCreationBurn(cross(cur), burn0)
		testing.SetRealm(testing.NewUserRealm(admin))
		SetAssociationBondDefault(cross(cur), bond0)
	}()

	testing.SetRealm(testing.NewUserRealm(admin))
	SetCourtCreationBurn(cross(cur), 7_500_000)
	testing.SetRealm(testing.NewUserRealm(admin))
	SetAssociationBondDefault(cross(cur), 1_250_000)

	packed := AdminParams()
	if got := field(packed, "creationBurn"); got != "7500000" {
		t.Fatalf("creationBurn must follow its setter: %q in %q", got, packed)
	}
	if got := field(packed, "assocBond"); got != "1250000" {
		t.Fatalf("assocBond must follow its setter: %q in %q", got, packed)
	}
	if got := field(packed, "admin"); got != admin.String() {
		t.Fatalf("admin must be the DAO's own: %q vs %s", got, admin.String())
	}

	// AND THE RENDERED PAGE FOLLOWS TOO. The page reads the same globals rather
	// than parsing the packed line, which is what keeps the two from
	// disagreeing — but that also means the page could be wired to a different
	// global and nothing above would notice. 7.5 is the trimmed decimal
	// ugnotAmt produces for 7_500_000.
	page := renderAdminParams()
	if !strings.Contains(page, "7.5 GNOT") {
		t.Fatalf("the page must show the live burn: %q", page[:min(len(page), 400)])
	}
	if !strings.Contains(page, admin.String()) {
		t.Fatal("the page must name the admin it is describing")
	}
	// Each setting names the verb that changes it — the question after "what is
	// it" is always "how do I change it".
	for _, verb := range []string{
		"SetCourtCreationBurn", "SetAssociationBondDefault", "SetPurgeThreshold",
		"SetLadderDefault", "SetCreditRatesDefault", "SetSiteDomain", "SetMediaHosts",
	} {
		if !strings.Contains(page, verb) {
			t.Fatalf("the page must say how to set each param, missing %q", verb)
		}
	}
}

// THE ROUTE CANNOT BE SHADOWED BY A COURT, which is the whole reason the path
// is twelve characters. Asserted against maxSlugLen rather than against the
// literal 11, so raising the slug cap fails HERE — at the one place that would
// otherwise silently hand this page to whoever registered the slug.
func TestAdminParamsRouteCannotCollideWithASlug(cur realm, t *testing.T) {
	if len(adminParamsPath) <= maxSlugLen {
		t.Fatalf("the params route (%d chars) must be longer than any slug (%d)",
			len(adminParamsPath), maxSlugLen)
	}
	maker := testutils.TestAddress("ap-route")
	testing.SetOriginSend(nil)
	testing.SetRealm(testing.NewUserRealm(maker))
	if !Exists("ap2") {
		StartCourt(cross(cur), "ap2", "Route Fixture")
	}
	out := Render(adminParamsPath)
	if !strings.Contains(out, "Realm parameters") {
		t.Fatalf("the route must render the params page: %q", out[:min(len(out), 200)])
	}
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
