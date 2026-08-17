package kourtv2

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
	uassert.AbortsContains(t, cur, "slug is 1..11", func() {
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
