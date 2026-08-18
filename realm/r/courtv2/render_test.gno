package courtv2

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
	if got := strings.Count(out, "courtv2:pg1/"); got > renderPageSize+2 {
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

// N3, the render's page bound, found by the audit-marker sweep. The mutation that
// removes it does not merely survive — it HANGS the suite past ten minutes, which is
// itself the finding: the bound is what stops an attacker-openable, deposit-priced claim
// count turning a page render into unbounded work. Deep links still reach anything the
// capped list omits, so the cap costs no reachability.
//
// Pinned by asserting the cap BINDS on a court with more claims than a page, rather than
// by removing the constant — a fixture that has to survive its own mutation cannot use a
// mutation that hangs.
func TestClaimListIsPageBounded(cur realm, t *testing.T) {
	alice := testutils.TestAddress("n3p-alice")
	c := testCourt(cur, "n3p", alice, 500_000_000_000)
	// The bound is written here INDEPENDENTLY of the constant. Sizing the setup from
	// renderPageSize instead made this fixture self-referential — mutating the constant
	// moved the setup and the expectation together, so the mutation survived. A
	// deliberate page-size change must now update this line, which is the point.
	const wantPage = 50
	if renderPageSize != wantPage {
		t.Fatalf("N3's page bound changed (%d, expected %d): confirm the new cost bound "+
			"is intended, then update this fixture", renderPageSize, wantPage)
	}
	over := wantPage + 5
	for i := 0; i < over; i++ {
		testing.SetRealm(testing.NewUserRealm(alice))
		OpenClaim(cross(cur), "n3p", "claim "+strconv.Itoa(i))
	}
	if c.nextID != uint64(over) {
		t.Fatalf("setup: %d claims must exist, got %d", over, c.nextID)
	}

	page := Render("n3p")
	listed := countSub(page, "](/r/cryptocourt/courtv2:n3p/")
	if listed > wantPage {
		t.Fatalf("N3: the claim list must cap at %d entries, rendered %d",
			wantPage, listed)
	}
	if listed < wantPage {
		t.Fatalf("fixture must EXCEED one page so the cap actually binds: listed %d of %d",
			listed, over)
	}
}

// countSub counts non-overlapping occurrences; the realm imports no strings package.
func countSub(s, sub string) int {
	n, i := 0, 0
	for i+len(sub) <= len(s) {
		if s[i:i+len(sub)] == sub {
			n++
			i += len(sub)
			continue
		}
		i++
	}
	return n
}

// §7.4 swept across claim STATES, which the existing sweep cannot reach.
//
// TestNoRenderPathLeaksTheForbiddenTerms above already walks all four render paths, so
// the pages themselves are covered. What it cannot cover is the STATE it renders them in:
// it drives one claim through its whole life and reads the pages at the END, after
// Crystallize. renderClaim branches on state, and several of those branches exist ONLY
// before that point — the flag-slot line, the counter-re-vote line, the escrowed-slash
// line. Copy on any of them is invisible to a sweep taken at the end.
//
// Measured, not assumed: injecting "backing" into the flag-slot branch — reachable only
// while `!crystallized && !slotConsumed && !provClose` — is caught HERE and not by the
// sweep above.
//
// "ceiling" is included though §7.4 names only the inflation ceiling: a bare "ceiling" in
// public copy is the same disclosure by a shorter name, and the four pages were checked
// to confirm no legitimate copy uses the word.
func TestNoRenderSurfaceLeaksTheForbiddenVocabulary(cur realm, t *testing.T) {
	forbidden := []string{"backing", "redeem", "apr", "inflation", "ceiling"}
	alice := testutils.TestAddress("r74-alice")
	bob := testutils.TestAddress("r74-bob")
	c := testCourt(cur, "r74", alice, 50_000_000_000)
	c.coin.Mint(bob, 10_000_000_000)

	testing.SetRealm(testing.NewUserRealm(alice))
	id := OpenClaim(cross(cur), "r74", "a claim to render")
	matureOI(cur, "r74", id, alice, 200_000_000)
	testing.SetRealm(testing.NewUserRealm(bob))
	Stake(cross(cur), "r74", id, sideNO, 300_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	PostAnswer(cross(cur), "r74", id, sideYES)

	sweep := func(state string) {
		t.Helper()
		paths := []string{"", "r74", "r74/" + strconv.FormatUint(id, 10),
			"r74/" + strconv.FormatUint(id, 10) + "/" + bob.String()}
		for _, p := range paths {
			out := strings.ToLower(Render(p))
			if len(out) == 0 {
				t.Fatalf("%s: path %q rendered nothing, so this sweep proves nothing "+
					"about it", state, p)
			}
			for _, w := range forbidden {
				if strings.Contains(out, w) {
					t.Fatalf("%s: path %q renders the forbidden term %q (§7.4)",
						state, p, w)
				}
			}
		}
	}

	// Every state a reader can arrive at a page in: live, settled, and drawn.
	sweep("answered")
	testing.SkipHeights(settleDelay)
	SettleUndisputed(cross(cur), "r74", id)
	sweep("settled")
	testing.SkipHeights(100_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	Crystallize(cross(cur), "r74", id)
	sweep("crystallized")
}

// No user string can open page structure of its own, on ANY page.
//
// A court name and a claim title are free text from whoever creates them and
// NEITHER is validated at the door: StartCourt stores `name` unchecked and
// OpenClaim stores `title` the same way. The render-time sanitizer is the only
// thing between them and the page — and four of its five call sites had nothing
// holding them, so a name could add a heading and a list row of its own to the
// directory, to the court page, and to the positions page.
//
// The payload is what an attacker would actually write: a forged verdict line
// under a heading that looks like the realm's own.
func TestNoUserStringOpensStructureOnAnyPage(cur realm, t *testing.T) {
	const inject = "x\n## Ratified by the foundation\n- verdict: YES"
	who := testutils.TestAddress("inj-a")
	testing.SetRealm(testing.NewUserRealm(who))
	StartCourt(cross(cur), "aaa-inj", inject)
	c := mustCourt("aaa-inj")
	c.coin.Mint(who, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	id := OpenClaim(cross(cur), "aaa-inj", inject)

	pages := []string{
		Render(""),                              // the directory: the court name
		Render("aaa-inj"),                          // the court page: the name and the title
		Render("aaa-inj/" + strconv.FormatUint(id, 10)),
		Render("aaa-inj/" + strconv.FormatUint(id, 10) + "/" + who.String()),
	}
	if !strings.Contains(pages[0], "/r/cryptocourt/courtv2:aaa-inj)") {
		t.Fatal("setup: the injecting court is not on the directory page, so the " +
			"directory arm below would prove nothing — the list is capped at " +
			"renderPageSize per tier and this suite creates many courts, which is " +
			"why the slug is chosen to sort first")
	}
	for i, page := range pages {
		if strings.Contains(page, "\n## Ratified") {
			t.Errorf("page %d: a user string opened a heading of its own:\n%s", i, page)
		}
		if strings.Contains(page, "\n- verdict: YES") {
			t.Errorf("page %d: a user string opened a list row of its own:\n%s", i, page)
		}
	}
}

// claimStatus names every phase, and the precedence between them.
//
// The states are set outright rather than driven through the lifecycle: this is
// the RENDERER under test, and reaching six phases through the machine would test
// the machine six times and the renderer once.
//
// The sharpest of these is the provisional line. sideYES is ZERO, so the guard has
// to be `provisional >= 0`; written `> 0` a provisional YES verdict falls through
// and the page reports the claim as merely answered — hiding both the escrow
// window it can be reopened in and the losing side's right to withdraw now.
func TestTheClaimStatusNamesEveryPhase(cur realm, t *testing.T) {
	who := testutils.TestAddress("cst-a")
	c := testCourt(cur, "cst1", who, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	id := OpenClaim(cross(cur), "cst1", "every phase")
	cs := mustClaim(c, id)

	if got := claimStatus(cs); !strings.Contains(got, "open — stake") {
		t.Errorf("a fresh claim reads %q", got)
	}
	cs.frozenAt, cs.answerHeight = 100, 100
	if got := claimStatus(cs); !strings.Contains(got, "answered — staking frozen") {
		t.Errorf("an answered claim reads %q", got)
	}
	cs.provisional, cs.escrowUntil = sideYES, 500
	if got := claimStatus(cs); !strings.Contains(got, "provisional verdict YES") {
		t.Errorf("a provisional YES verdict reads %q — sideYES is zero, so a bar "+
			"written `> 0` hides this whole phase", got)
	}
	cs.disputeOpen = true
	if got := claimStatus(cs); !strings.Contains(got, "disputed") {
		t.Errorf("an open dispute reads %q", got)
	}
	cs.disputeOpen = false
	cs.verdictAt = 200
	if got := claimStatus(cs); !strings.Contains(got, "settled") {
		t.Errorf("a settled claim reads %q", got)
	}
	cs.provClose = true
	if got := claimStatus(cs); !strings.Contains(got, "closed without a decision") {
		t.Errorf("a claim closed without a decision reads %q", got)
	}
	cs.provClose = false
	cs.closed = true
	if got := claimStatus(cs); !strings.Contains(got, "closed — never answered") {
		t.Errorf("a closed claim reads %q — dropped, it invites staking on a claim "+
			"that can never be answered", got)
	}
}

// The two names a verdict page turns on. sideName decides what the verdict SAYS,
// and it had nothing on it: every side rendering as NO is a page that reports the
// opposite outcome on every YES claim in the realm.
func TestSideAndTierNamesAreNotSwapped(t *testing.T) {
	if got := sideName(sideYES); got != "YES" {
		t.Errorf("sideYES renders as %q", got)
	}
	if got := sideName(sideNO); got != "NO" {
		t.Errorf("sideNO renders as %q", got)
	}
	if got := tierName(tierLowX); got != "low" {
		t.Errorf("tierLowX renders as %q", got)
	}
	if got := tierName(tierHighX); got != "high" {
		t.Errorf("tierHighX renders as %q", got)
	}
	if got := tierName(tierMidX); got != "mid" {
		t.Errorf("tierMidX renders as %q", got)
	}
}

// An escrowed slash is announced, found surviving. Without the line the page falls
// through to the flag-slot row and OFFERS a slot whose bond is already committed
// elsewhere — it invites a user to pay for something the claim is not in a state
// to sell.
func TestAnEscrowedSlashIsAnnounced(cur realm, t *testing.T) {
	who := testutils.TestAddress("esl-a")
	c := testCourt(cur, "esl1", who, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	id := OpenClaim(cross(cur), "esl1", "an escrowed slash")
	cs := mustClaim(c, id)
	cs.frozenAt, cs.answerHeight, cs.answerBond0 = 100, 100, 1000
	cs.pendingSlash = 500

	page := Render("esl1/" + strconv.FormatUint(id, 10))
	if !strings.Contains(page, "slash is escrowed") {
		t.Errorf("the page does not mention the escrowed slash:\n%s", page)
	}
	if strings.Contains(page, "flag slot open") {
		t.Errorf("the page offers a flag slot while a slash is escrowed:\n%s", page)
	}
}

// The DIRECTORY's N3 page bound, which was unheld while its twin on the claims
// list was already covered by TestRenderCourtPaginatesClaims.
//
// The bound is on the WORK, not the output: a court list that grows with an
// attacker-openable, deposit-priced count makes the cost of the page every user
// reads grow with it. Deep links reach whatever the cap omits, which is what makes
// capping it safe rather than lossy.
//
// It creates only as many courts as it needs to cross the cap, and asserts it HAS
// crossed it. The first version created 51 outright and tripled the mutation
// batch's wall clock — 51 ledger allocations on every one of 673 runs — for a
// property that only needs the population to exceed renderPageSize by one.
func TestTheDirectoryListIsBounded(t *testing.T) {
	if renderPageSize != 50 {
		t.Fatalf("renderPageSize is %d; this test reasons about its exact value", renderPageSize)
	}
	// Registered directly rather than through StartCourt. writeTier reads only a
	// court's name and claim count, and StartCourt allocates a whole ledger per
	// court — which the mutation batch then pays for on all 673 runs. Constructing
	// what the renderer actually reads is both cheaper and narrower.
	for i := len(ListByTier(int(tierListed))); i <= renderPageSize; i++ {
		slug := "n3dir" + strconv.Itoa(i)
		courts.Set(slug, &Court{id: slug, name: "dir court " + strconv.Itoa(i), tier: tierListed})
	}
	listed := len(ListByTier(int(tierListed)))
	if listed <= renderPageSize {
		t.Fatalf("setup: %d listed courts does not exceed the %d-row cap, so nothing "+
			"below can discriminate", listed, renderPageSize)
	}

	dir := Render("")
	if n := strings.Count(dir, "](/r/cryptocourt/courtv2:"); n > 2*renderPageSize {
		t.Errorf("the directory rendered %d rows across its two tiers, past the "+
			"%d-per-tier bound", n, renderPageSize)
	}
	if !strings.Contains(dir, "more; open any court directly") {
		t.Errorf("the directory does not say what it omitted:\n%s", dir)
	}
}

// An OPEN counter re-vote is announced and its tally sealed, found surviving —
// the flag-vote line beside it was held and this one was not. Same failure: the
// page falls through and offers a flag slot while a re-vote is running.
func TestAnOpenCounterReVoteIsAnnounced(cur realm, t *testing.T) {
	who := testutils.TestAddress("ocr-a")
	c := testCourt(cur, "ocr1", who, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	id := OpenClaim(cross(cur), "ocr1", "an open counter re-vote")
	cs := mustClaim(c, id)
	cs.frozenAt, cs.answerHeight, cs.answerBond0 = 100, 100, 1000
	cs.counterOpen = true

	page := Render("ocr1/" + strconv.FormatUint(id, 10))
	if !strings.Contains(page, "counter re-vote open") {
		t.Errorf("the page does not announce the open counter re-vote:\n%s", page)
	}
	if strings.Contains(page, "flag slot open") {
		t.Errorf("the page offers a flag slot during a counter re-vote:\n%s", page)
	}
}

// Render's path handling: the shapes it accepts and the ones it must refuse.
//
// Three legs were unheld. The TRIM is what makes a leading slash work at all, and
// without it every "/slug" link lands on "no court by that slug". SplitN's cap of
// three is what keeps a fourth segment from being folded into the address instead
// of refused. And a non-numeric id has to be refused as one rather than falling
// through as id zero.
func TestRenderAcceptsAndRefusesEveryPathShape(cur realm, t *testing.T) {
	who := testutils.TestAddress("rp-a")
	testCourt(cur, "rps1", who, 50_000_000_000)
	testing.SetRealm(testing.NewUserRealm(who))
	id := OpenClaim(cross(cur), "rps1", "path shapes")
	sid := strconv.FormatUint(id, 10)

	// A leading or trailing slash names the same page as none.
	if Render("/rps1") != Render("rps1") {
		t.Errorf("a leading slash changes the court page:\n%s", Render("/rps1"))
	}
	if Render("rps1/"+sid+"/") != Render("rps1/"+sid) {
		t.Error("a trailing slash changes the claim page")
	}
	// A claim id that is not a number is refused as that, not as a missing claim.
	if got := Render("rps1/notanumber"); !strings.Contains(got, "must be a number") {
		t.Errorf("a non-numeric id renders %q", got)
	}
	// A fourth segment is refused rather than folded into the address.
	if got := Render("rps1/" + sid + "/" + who.String() + "/extra"); !strings.Contains(got, "Not found") {
		t.Errorf("a fourth path segment rendered a page:\n%s", got)
	}
}

