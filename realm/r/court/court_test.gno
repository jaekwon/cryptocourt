package court

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

func TestStartCourtWiresACourt(cur realm, t *testing.T) {
	founder := testutils.TestAddress("founder")
	testing.SetRealm(testing.NewUserRealm(founder))

	slug := StartCourt(cross(cur), "eg-court", "Example Court")
	if slug != "eg-court" {
		t.Fatalf("slug should be eg-court, got %q", slug)
	}
	if !Exists("eg-court") {
		t.Fatal("court should exist after StartCourt")
	}
	if CourtName("eg-court") != "Example Court" {
		t.Fatalf("name mismatch: %q", CourtName("eg-court"))
	}
	// A fresh court has issued no coin, taken no GNOT, and holds no open interest.
	if CoinSupply("eg-court") != 0 || Treasury("eg-court") != 0 || OpenInterest("eg-court") != 0 {
		t.Fatal("a fresh court should be zeroed")
	}
}

func TestStartCourtRefusesADuplicateSlug(cur realm, t *testing.T) {
	testing.SetRealm(testing.NewUserRealm(testutils.TestAddress("f2")))
	StartCourt(cross(cur), "dup", "Dup")
	// A crossing-function panic is an abort, not a recoverable panic.
	uassert.AbortsContains(t, cur, "slug is taken", func() {
		StartCourt(cross(cur), "dup", "Dup Again")
	})
}

func TestParamsSanityBounds(t *testing.T) {
	shouldPanic(t, "sub-5001 threshold", func() {
		p := defaultParams()
		p.disputeThresholdBps = 5000
		p.mustSane()
	})
	shouldPanic(t, "zero claim deposit", func() {
		p := defaultParams()
		p.minClaimDepositCC = 0
		p.mustSane()
	})
	// The defaults are themselves sane.
	_ = defaultParams().mustSane()
}

func shouldPanic(t *testing.T, name string, fn func()) {
	t.Helper()
	defer func() {
		if recover() == nil {
			t.Fatalf("%s should have panicked", name)
		}
	}()
	fn()
}
