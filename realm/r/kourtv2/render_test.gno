package kourtv2

import (
	"strconv"
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
	// The court-wide wallet picture. Bob holds 10,000 CC and has committed 300 of
	// them, so 9,700 are free. Since staking became a lock in place the balance
	// alone is misleading — the staked CC is still in it — and a client that shows
	// only the balance tells him he can bond coins that are already committed.
	//
	// The PARTITION is the assertion that matters: held must equal committed plus
	// free. Checking the three numbers separately would pass just as well if the
	// page printed the balance three times under different labels.
	if !strings.Contains(out, "held: 10000000000") {
		t.Fatalf("the page must show what bob holds:\n%s", out)
	}
	if !strings.Contains(out, "committed as stake: 300000000") {
		t.Fatalf("the page must show what is committed:\n%s", out)
	}
	if !strings.Contains(out, "free to commit: 9700000000") {
		t.Fatalf("the page must show what is free:\n%s", out)
	}
	if got := LockedOf("rp1", bob) + SpendableOf("rp1", bob); got != CoinBalanceOf("rp1", bob) {
		t.Fatalf("committed + free = %d, but bob holds %d", got, CoinBalanceOf("rp1", bob))
	}
	// It is labelled court-wide, because the stake figures above it are this
	// claim's and the two would otherwise be read as the same scope.
	if !strings.Contains(out, "all claims") {
		t.Fatal("the wallet section must say it is court-wide, not claim-scoped")
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

func TestRenderCourtPaginatesClaims(cur realm, t *testing.T) {
	alice := testutils.TestAddress("pg-alice")
	testCourt(cur, "pg1", alice, 500_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	// Open one past a page so truncation triggers.
	n := renderPageSize + 5
	for i := 0; i < n; i++ {
		OpenClaim(cross(cur), "pg1", "Claim number "+strconv.Itoa(i))
	}
	out := Render("pg1")
	// The newest claim shows; the oldest (id 1) does not; the truncation note does.
	if !strings.Contains(out, "pg1/"+strconv.Itoa(n)+")") {
		t.Fatal("the newest claim must be on the page")
	}
	if strings.Contains(out, "pg1/1)") {
		t.Fatal("the oldest claim must be paged off")
	}
	if !strings.Contains(out, "older; open any by id") {
		t.Fatalf("a truncation hint must appear:\n%s", out[len(out)-300:])
	}
	// The page renders a bounded number of claim bullets (page + hint), not n.
	if got := strings.Count(out, "kourtv2:pg1/"); got > renderPageSize+2 {
		t.Fatalf("the claim loop must be bounded: %d links", got)
	}
}

func TestRenderShowsAnswererRecord(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rr-alice")
	testCourt(cur, "rr1", alice, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "rr1", "Record badge claim")
	matureOI(cur, "rr1", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "rr1", id, sideYES)
	out := Render("rr1/1")
	if !strings.Contains(out, "answerer's difficulty record (this court): 0") {
		t.Fatalf("the answerer record line must render:\n%s", out)
	}
	// Gate is cold (0 qualified < coldStart) → no priority line yet.
	if strings.Contains(out, "answer priority is live") {
		t.Fatal("the priority line must be hidden until the gate is armed")
	}
}

// math-audit MED-1: pct must not wrap when num is a conviction-CC value (stake×
// time, NOT bounded by supply). A whale on a long-open claim can drive
// convToCC past MaxInt64/10000; the 128-bit pct must still yield a sane ratio.
func TestPctNoOverflowAtWhaleConviction(cur realm, t *testing.T) {
	// yc near the convToCC ceiling (~7e18); a bare yc*10000 would wrap negative.
	yc := int64(7_000_000_000_000_000_000)
	if got := pct(yc, yc); got != "100.00%" {
		t.Fatalf("pct(yc,yc) must be 100%%, got %q (bare *10000 would have wrapped)", got)
	}
	// ~two-thirds split at huge magnitude stays sane, never negative.
	out := pct(2*(yc/3), yc)
	if len(out) == 0 || out[0] == '-' {
		t.Fatalf("pct must never render a negative/garbage ratio: %q", out)
	}
	// Degenerate guards.
	if pct(0, 0) != "—" || pct(-1, 10) != "—" {
		t.Fatal("pct guards den<=0 and num<0")
	}
}

// §7.4 across EVERY render path, not one word on one page. The existing coverage
// checks only the literal "backing" and only the DIRECTORY, while §7.4 forbids four
// things — backing, redeem, APR, and the inflation ceiling — and the court and claim
// pages are the ones carrying money numbers. An owner-locked constraint enforced on a
// quarter of its surface is close to unenforced.
//
// Driven through a FULL lifecycle so the pages have real figures to leak: stake, an
// answer, a flag with a conclusive tier, settle, and crystallize. A page that renders
// nothing cannot violate §7.4, so an empty-state check would prove little.
func TestNoRenderPathLeaksTheForbiddenTerms(cur realm, t *testing.T) {
	alice := testutils.TestAddress("s74-alice")
	flagger := testutils.TestAddress("s74-flag")
	voter := testutils.TestAddress("s74-voter")
	c := testCourt(cur, "s74", alice, 50_000_000_000)
	c.coin.Mint(flagger, 10_000_000_000)
	c.coin.Mint(voter, 20_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "s74", "A claim with real numbers on it")
	matureOI(cur, "s74", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "s74", id, sideYES)
	testing.SetRealm(testing.NewUserRealm(flagger))
	OpenFlag(cross(cur), "s74", id)
	testing.SetRealm(testing.NewUserRealm(voter))
	VoteQuality(cross(cur), "s74", id, qualityMid)
	testing.SkipHeights(c.params.votingBlocks + 1)
	ResolveFlag(cross(cur), "s74", id)
	SettleUndisputed(cross(cur), "s74", id)
	testing.SkipHeights(priorityWindowBlocks + 1)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "s74", id)

	idStr := strconv.FormatUint(id, 10)
	pages := map[string]string{
		"directory": Render(""),
		"court":     Render("s74"),
		"claim":     Render("s74/" + idStr),
		"positions": Render("s74/" + idStr + "/" + alice.String()),
	}
	// Lowercased, because §7.4 is about what a reader sees, not about casing. "apr"
	// is checked as a whole word: it is a substring of ordinary English ("appraisal"),
	// and a guard that fires on those would be deleted by the next person.
	for name, body := range pages {
		if body == "" {
			t.Fatalf("%s rendered nothing, so it proves nothing about §7.4", name)
		}
		low := lowerASCII(body)
		for _, banned := range []string{"backing", "redeem", "inflation", "ceiling"} {
			if containsSub(low, banned) {
				t.Fatalf("§7.4: the %s page renders %q", name, banned)
			}
		}
		if hasWordAPR(low) {
			t.Fatalf("§7.4: the %s page renders APR", name)
		}
	}
}

// lowerASCII folds A-Z; the realm imports no strings package and §7.4 is
// case-insensitive from a reader's point of view.
func lowerASCII(s string) string {
	b := []byte(s)
	for i := 0; i < len(b); i++ {
		if b[i] >= 'A' && b[i] <= 'Z' {
			b[i] += 32
		}
	}
	return string(b)
}

// hasWordAPR finds "apr" only as a whole word, so "appraisal" does not trip it.
func hasWordAPR(s string) bool {
	for i := 0; i+3 <= len(s); i++ {
		if s[i:i+3] != "apr" {
			continue
		}
		if i > 0 && isAlnumByte(s[i-1]) {
			continue
		}
		if i+3 < len(s) && isAlnumByte(s[i+3]) {
			continue
		}
		return true
	}
	return false
}

func isAlnumByte(ch byte) bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9')
}
