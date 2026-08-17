package kourtv1

import (
	"strconv"
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

func TestRenderPages(cur realm, t *testing.T) {
	who := testutils.TestAddress("r-who")
	fundAndBuy(cur, "rnd", "Render Court", who, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	cid := OpenClaim(cross(cur), "rnd", "Is the sky blue?")
	testing.SetRealm(testing.NewUserRealm(who))
	AppendBody(cross(cur), "rnd", cid, "The evidence follows.")

	if !strings.Contains(Render(""), "Render Court") {
		t.Fatal("the directory should list the court")
	}
	court := Render("rnd")
	if !strings.Contains(court, "Render Court") || !strings.Contains(court, "coin price") {
		t.Fatal("the court page should show its name and coin price")
	}
	if !strings.Contains(court, "Is the sky blue?") {
		t.Fatal("the court page should list the claim")
	}
	claim := Render("rnd/" + strconv.FormatUint(cid, 10))
	if !strings.Contains(claim, "Is the sky blue?") || !strings.Contains(claim, "The evidence follows") {
		t.Fatal("the claim page should show the title and body")
	}
	if !strings.Contains(Render("no-such-court"), "Not found") {
		t.Fatal("a missing court should render Not found")
	}
}

func TestRenderSealsTheLiveTally(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rs-alice")
	carol := testutils.TestAddress("rs-carol")
	testing.SetRealm(testing.NewUserRealm(alice))
	StartCourt(cross(cur), "rseal", "Seal Court")
	buyCoin(cur, "rseal", carol, 500_000_000)
	buyCoin(cur, "rseal", alice, 100_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	cid := OpenClaim(cross(cur), "rseal", "Contested claim")
	matureOI(cur, "rseal", cid, alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "rseal", cid, outcomeYES)
	testing.SetRealm(testing.NewUserRealm(carol))
	OpenDispute(cross(cur), "rseal", cid)
	testing.SetRealm(testing.NewUserRealm(carol))
	VoteDispute(cross(cur), "rseal", cid, "yes")

	page := Render("rseal/" + strconv.FormatUint(cid, 10))
	if !strings.Contains(page, "sealed until the vote closes") {
		t.Fatal("an open dispute should render as sealed")
	}
	// The live tally (carol's large yes weight) must not appear.
	if strings.Contains(page, "yes:") || strings.Contains(page, "votes for") {
		t.Fatal("the live tally must never render while the vote is open")
	}
}
