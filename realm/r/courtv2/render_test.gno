package courtv2

import (
	"strings"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

func TestRenderPagesAndSanitization(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rn-alice")
	c := testCourt(cur, "rn1", alice, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "rn1", "Hostile [link](x) *title* <tag>")
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "rn1", id, sideYES, 3_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Stake(cross(cur), "rn1", id, sideNO, 1_000_000_000)

	dir := Render("")
	if !strings.Contains(dir, "principal always returns 1×") {
		t.Fatal("the directory leads with the differentiator")
	}
	if strings.Contains(dir, "backing") {
		t.Fatal("no backing figure may ever render")
	}
	court := Render("rn1")
	if !strings.Contains(court, "Test Court rn1") || !strings.Contains(court, "reservoir") {
		t.Fatal("the court page shows supply/emission/reservoir")
	}
	claim := Render("rn1/1")
	if !strings.Contains(claim, "75.00% YES") {
		t.Fatalf("instantaneous ratio must render: %s", claim)
	}
	if strings.Contains(claim, "[link](x)") {
		t.Fatal("attacker markdown must be sanitized")
	}
	if !strings.Contains(claim, "open — stake YES or NO") {
		t.Fatal("the status line renders")
	}
	if !strings.Contains(Render("rn1/99"), "Not found") ||
		!strings.Contains(Render("nope"), "Not found") ||
		!strings.Contains(Render("rn1/abc"), "must be a number") {
		t.Fatal("not-found routes")
	}
	_ = c
}

func TestRenderLifecycleLines(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rl-alice")
	c := testCourt(cur, "rl1", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "rl1", "Lifecycle lines")
	cs := mustClaim(c, id)

	mustContain := func(stage, want string) {
		t.Helper()
		out := Render("rl1/1")
		if !strings.Contains(out, want) {
			t.Fatalf("%s: missing %q in:\n%s", stage, want, out)
		}
	}
	mustContain("open", "open — stake YES or NO")

	// Answered: crafted state (the dispute tests exercise the real paths;
	// render only reads).
	cs.frozenAt, cs.answer, cs.answerBond0, cs.answerHeight = 10, sideNO, 777, 10
	cs.xBarFrozen = 1_000_000 // so the dispute-bond quote is positive
	mustContain("answered", "settles undisputed")
	mustContain("answered", "answer: NO (bond 777 CC units)")
	mustContain("answered", "disputing this answer now costs")

	cs.disputeOpen, cs.round = true, 1
	mustContain("disputed", "sealed vote")
	mustContain("disputed", "sealed until the vote closes")
	if strings.Contains(Render("rl1/1"), "yes:") {
		t.Fatal("an open vote must never render a running tally")
	}

	cs.disputeOpen, cs.provisional, cs.escrowUntil, cs.failedRounds = false, int8(sideNO), 99999, 1
	mustContain("provisional", "provisional verdict NO")
	mustContain("provisional", "withdraw 1× now")
	mustContain("provisional", "failed dispute rounds: 1 of 3")

	cs.verdictAt, cs.route, cs.tier = 100, "vote", tierMidX
	mustContain("settled", "settled — every stake withdraws 1×")
	mustContain("settled", "verdict: NO — vote")
	mustContain("settled", "quality: mid (default")
	mustContain("settled", "flag slot open — bond")
	cs.tier, cs.tierFinal = tierHighX, true
	mustContain("quality", "quality: high (final)")
	cs.flagOpen = true
	mustContain("flagging", "flag vote open — the tally is sealed")
	cs.flagOpen = false
	cs.crystallized, cs.drawWinners, cs.carrotPool = true, 12345, 77
	mustContain("crystallized", "accuracy 12345")
	mustContain("crystallized", "participation remaining 77")

	cs.provClose = true
	mustContain("provclose", "closed without a decision")
}

func TestRenderPositionsPage(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rp-alice")
	bob := testutils.TestAddress("rp-bob")
	c := testCourt(cur, "rp1", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "rp1", "Positions page claim")
	matureOI(cur, "rp1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "rp1", id, sideNO, 300_000_000)

	// Bad inputs degrade gracefully.
	if !strings.Contains(Render("rp1/1/not-an-address"), "not a valid address") {
		t.Fatal("an invalid address must render the not-found notice")
	}
	if !strings.Contains(Render("nope/1/"+bob.String()), "No court") {
		t.Fatal("unknown court must render not-found")
	}

	// Bob's page: his NO stake and conviction show; staking-open hint.
	out := Render("rp1/1/" + bob.String())
	if !strings.Contains(out, "Your positions") || !strings.Contains(out, bob.String()) {
		t.Fatal("the page must name the address")
	}
	if !strings.Contains(out, "NO: 300000000") {
		t.Fatalf("bob's live NO stake must show:\n%s", out)
	}
	if !strings.Contains(out, "staking is open") {
		t.Fatal("pre-answer, the hint is that staking is open")
	}
	// The claim page links to the positions route.
	if !strings.Contains(Render("rp1/1"), "append your address") {
		t.Fatal("the claim page must hint the positions route")
	}

	// After answer + settle, the hint flips to withdraw.
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "rp1", id, sideYES)
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "rp1", id)
	if !strings.Contains(Render("rp1/1/"+bob.String()), "withdraw your principal") {
		t.Fatal("post-verdict, the hint is to withdraw principal")
	}
}
