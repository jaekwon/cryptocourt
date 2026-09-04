package chat

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// The panel's limits must match the ones the server enforces.
//
// internal/chat/sanitize.go is the authority: it refuses what is too long, and a request that
// gets past the panel still has to pass it. web/chat.js repeats the numbers so a user hears
// "too long" before a round trip instead of after one — which makes them two definitions of one
// thing, in two languages, with a build that cannot see the mismatch. That shape has produced
// most of the bugs in this service, and every previous instance was found by measuring rather
// than by compiling.
//
// Drift is quiet in both directions and neither is acceptable:
//
//	panel smaller than the server   text the server would take is refused locally, and the
//	                                user is told their own message is too long when it is not
//	panel larger than the server    the composer accepts it, the POST comes back 400, and the
//	                                message the user actually wrote is gone
//
// `maxlength` matters as much as the validate call, because it stops the keystroke rather than
// showing a message: a stale value there is a capability removed with no diagnostic at all.
//
// This test lives in Go, next to the authority, rather than in web/tests/ — the JS harnesses
// can only check that the panel agrees with itself.
func TestThePanelsLimitsMatchTheServers(t *testing.T) {
	path := filepath.Join("..", "..", "web", "chat.js")
	src, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("the panel is part of this service's contract and must be readable: %v", err)
	}

	// One declaration in the panel, so this reads one place rather than hunting five.
	decl := regexp.MustCompile(
		`const CHATLIMITS = \{body: (\d+), moniker: (\d+), bytes: (\d+)\}`).FindSubmatch(src)
	if decl == nil {
		t.Fatal("web/chat.js must declare CHATLIMITS = {body, moniker, bytes} in one place; " +
			"if it was reshaped, reshape this test with it rather than deleting it")
	}
	num := func(b []byte) int {
		n, err := strconv.Atoi(string(b))
		if err != nil {
			t.Fatal(err)
		}
		return n
	}
	for _, c := range []struct {
		name  string
		panel int
		want  int
	}{
		{"body runes", num(decl[1]), MaxBodyRunes},
		{"moniker runes", num(decl[2]), MaxMonikerRunes},
		{"input bytes", num(decl[3]), MaxInputBytes},
	} {
		if c.panel != c.want {
			t.Errorf("%s: web/chat.js says %d, internal/chat/sanitize.go enforces %d — "+
				"the panel and the server must agree, and the server is the authority",
				c.name, c.panel, c.want)
		}
	}

	// THE DEFAULT NAME IS ONE WORD IN TWO FILES, and the panel SHOWS it while the server
	// STORES it — so a drift here is a panel promising "anon" over a store full of
	// something else, with nothing failing in between. Same reason the limits are pinned.
	if d := regexp.MustCompile(`const CHATDEFAULTNAME = "([^"]*)"`).FindSubmatch(src); d == nil {
		t.Error(`web/chat.js must declare CHATDEFAULTNAME = "…" in one place`)
	} else if string(d[1]) != DefaultMoniker {
		t.Errorf("default name: web/chat.js says %q, internal/chat stores %q — "+
			"the panel and the server must agree, and the server is the authority",
			d[1], DefaultMoniker)
	}
	// And the placeholder is that constant rather than a word typed twice: it is the only
	// place a reader is told what leaving the field blank will call them.
	if !regexp.MustCompile(`placeholder="' \+ chatEsc\(CHATDEFAULTNAME\)`).Match(src) {
		t.Error("the name field's placeholder must come from CHATDEFAULTNAME")
	}

	// The maxlength attributes are generated FROM that declaration, not written out again.
	// Checked because they are the half that stops a keystroke, and because a future edit
	// hardcoding them would leave this test passing while the composer disagreed.
	for _, lit := range []string{`maxlength="24"`, `maxlength="400"`, `maxlength="4096"`} {
		if regexp.MustCompile(regexp.QuoteMeta(lit)).Match(src) {
			t.Errorf("web/chat.js hardcodes %s; it must come from CHATLIMITS so it cannot "+
				"drift from the server", lit)
		}
	}
	if !regexp.MustCompile(`maxlength="' \+ CHATMONIKERUNITS`).Match(src) ||
		!regexp.MustCompile(`maxlength="' \+ CHATLIMITS\.body`).Match(src) {
		t.Error("both composer inputs must take maxlength from a CHATLIMITS-derived value")
	}
	// The moniker's attribute is deliberately LOOSER than its limit, and derived from it.
	// `maxlength` counts UTF-16 units, so an attribute equal to a LETTER limit stops a voweled
	// Arabic or pointed Hebrew name from being typed at all — no message, just a dead keystroke,
	// which is the worst way for a limit to be wrong.
	if !regexp.MustCompile(`CHATMONIKERUNITS = CHATLIMITS\.moniker \* \d`).Match(src) {
		t.Error("CHATMONIKERUNITS must be derived from CHATLIMITS.moniker so it cannot drift")
	}

	// And the validate path must COMPARE against the declaration, not against a literal that
	// happens to agree with it today.
	//
	// Counting references was the first version of this and it was too weak: replacing
	// `[...b].length > CHATLIMITS.body` with `> 400` left two references intact — the markup
	// and the error message's own text — so the mutation survived. The property is about what
	// the comparison reads, so the function's own body is what gets checked.
	fn := regexp.MustCompile(`(?s)function chatValidate\(.*?\n\}`).Find(src)
	if fn == nil {
		t.Fatal("chatValidate not found in web/chat.js; it is the panel's half of these limits")
	}
	for _, field := range []string{"CHATLIMITS.moniker", "CHATLIMITS.body", "CHATLIMITS.bytes"} {
		if !regexp.MustCompile(regexp.QuoteMeta(field)).Match(fn) {
			t.Errorf("chatValidate does not read %s; a declaration nothing compares against "+
				"agrees with the server by coincidence", field)
		}
	}
	// No bare copy of any limit inside the comparison logic. Written from the Go constants, so
	// changing one there cannot leave a stale literal here looking correct.
	for _, n := range []int{MaxBodyRunes, MaxMonikerRunes, MaxInputBytes} {
		if regexp.MustCompile(`[^0-9]` + strconv.Itoa(n) + `[^0-9]`).Match(fn) {
			t.Errorf("chatValidate contains the literal %d; it must read CHATLIMITS so the "+
				"number lives in exactly one place", n)
		}
	}
}

// The same discipline for the one other number the panel mirrors: the throttle's interval is
// quoted at the user in an error the SERVER writes, so there is nothing to drift — but the
// panel does repeat the 200-message read cap, and that one is worth pinning because exceeding
// it silently returns fewer messages than asked for.
func TestThePanelDoesNotAskForMoreThanTheServerWillGive(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("..", "..", "web", "chat.js"))
	if err != nil {
		t.Fatal(err)
	}
	// chatFetch's default limit, and any explicit one it passes.
	m := regexp.MustCompile(`limit=" \+ \(limit \|\| (\d+)\)`).FindSubmatch(src)
	if m == nil {
		t.Skip("chatFetch no longer builds its limit that way; re-derive this check")
	}
	want, err := strconv.Atoi(string(m[1]))
	if err != nil {
		t.Fatal(err)
	}
	// The server clamps anything over 200 down to 50 — silently, which is the point: a panel
	// asking for 500 would quietly receive 50 and look like an empty room after a purge.
	if want > 200 {
		t.Errorf("the panel asks for %d messages; the server clamps above 200 and would "+
			"silently return 50", want)
	}
	if want <= 0 {
		t.Errorf("the panel's default limit is %d, which the server would replace with its "+
			"own default rather than honour", want)
	}
}

// THE MONIKER LIMIT COUNTS LETTERS, AND BOTH SIDES MUST COUNT THEM THE SAME WAY.
//
// A number matching is not enough once the two sides can disagree about what they are counting.
// The moniker's limit counts letters rather than code points — in Hebrew, Arabic, Thai and
// Devanagari a letter costs two or three, so an eighteen-letter voweled Arabic name is 34 code
// points and a rune limit refused it while a twenty-four-letter English name passed.
//
// Go decides with `unicode.Is(unicode.Mn, r) || unicode.Is(unicode.Me, r) || joiner(r)`. The
// panel has to make the identical decision, and the trap is \p{M}: it includes \p{Mc}, the
// SPACING combining marks, which Devanagari matras are and which Go counts as letters. A panel
// using \p{M} would refuse Devanagari names the server accepts.
func TestThePanelCountsMonikerLettersTheSameWayTheServerDoes(t *testing.T) {
	src, err := os.ReadFile(filepath.Join("..", "..", "web", "chat.js"))
	if err != nil {
		t.Fatal(err)
	}
	fn := regexp.MustCompile(`(?s)function chatValidate\(.*?\n\}`).Find(src)
	if fn == nil {
		t.Fatal("chatValidate not found")
	}
	if !regexp.MustCompile(`chatLetters\(m\)`).Match(fn) {
		t.Error("the moniker check must count letters via chatLetters, not code points; " +
			"[...m].length refuses an 18-letter Arabic name and accepts a 24-letter English one")
	}
	// The body still counts code points, matching MaxBodyRunes. Asserted so the two limits do
	// not quietly converge on one rule when they intentionally use different ones.
	if !regexp.MustCompile(`\[\.\.\.b\]\.length`).Match(fn) {
		t.Error("the body limit counts code points, like MaxBodyRunes; if that changed on the " +
			"server too, change both and say so at internal/chat/sanitize.go's countMode")
	}

	skip := regexp.MustCompile(`const CHATSKIP = /\[([^\]]*)\]/u;`).FindSubmatch(src)
	if skip == nil {
		t.Fatal("web/chat.js must declare CHATSKIP as the set of runes that are not letters")
	}
	set := string(skip[1])
	for _, want := range []string{`\p{Mn}`, `\p{Me}`, `\u200C`, `\u200D`, `\uFE0F`} {
		if !strings.Contains(set, want) {
			t.Errorf("CHATSKIP is missing %s; Go skips Mn, Me and the three joiners", want)
		}
	}
	// The trap, asserted directly.
	if strings.Contains(set, `\p{Mc}`) || regexp.MustCompile(`\\p\{M\}`).MatchString(set) {
		t.Error(`CHATSKIP must not use \p{M} or \p{Mc}: Go counts SPACING combining marks as ` +
			`letters, so a panel skipping them would refuse Devanagari names the server accepts`)
	}
}

// THE COUNTDOWN FIELD IS A THIRD THING THE TWO SIDES MUST AGREE ABOUT, and its failure mode is
// silent: the panel falls back to `until - Date.now()`, which is the skew bug it was added to fix,
// and nothing breaks loudly. A renamed JSON tag would look like a working panel with a wrong number
// on it — the state would still be right, so only the duration would lie.
//
// Read from both sides: the struct tag the server emits, and the property the panel reads.
func TestThePanelReadsTheCountdownFieldTheServerEmits(t *testing.T) {
	// The name the server puts on the wire.
	store, err := os.ReadFile("store.go")
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`Seconds\s+int64\s+` + "`" + `json:"([a-z_]+)`).FindSubmatch(store)
	if m == nil {
		t.Fatal("Status.Seconds no longer carries a json tag; if the countdown moved, move this " +
			"check with it rather than deleting it")
	}
	field := string(m[1])

	// The name the panel looks for.
	panel, err := os.ReadFile(filepath.Join("..", "..", "web", "chat.js"))
	if err != nil {
		t.Fatal(err)
	}
	fn := regexp.MustCompile(`(?s)function chatStatusLine\(.*?\n\}`).Find(panel)
	if fn == nil {
		t.Fatal("chatStatusLine not found in web/chat.js")
	}
	if !regexp.MustCompile(`you\.` + regexp.QuoteMeta(field) + `\b`).Match(fn) {
		t.Errorf("the server sends you.%s and chatStatusLine does not read it; the panel would "+
			"fall back to subtracting from the local clock, which is the skew bug this field "+
			"exists to fix, and it would fail silently because only the DURATION would be wrong",
			field)
	}
	// And it must still prefer that field over the subtraction, not merely mention it.
	if !regexp.MustCompile(`fromServer > 0 \? fromServer :`).Match(fn) {
		t.Error("chatStatusLine must PREFER the server's countdown; mentioning the field while " +
			"computing from the local clock anyway is the same bug with a decoration on it")
	}
}

// THE PANEL'S BYTE CAP IS DEAD CODE TODAY, AND ITS COMMENT USED TO CLAIM OTHERWISE.
//
// chatValidate checks runes before bytes, so anything reaching its byte branch has already passed
// the rune cap. UTF-8 tops out at four bytes per rune, so the worst case there is
// MaxBodyRunes * 4 bytes — 1600 against a cap of 4096. The branch cannot fire. Measured through
// the shipped function: 400 astral characters is 1600 bytes and validates clean, and 401 is
// refused by the RUNE check.
//
// The server orders these the other way: clean() rejects on len(s) > MaxInputBytes before it
// looks at runes at all, so ErrOversize is reachable there and its sentence is real. That
// asymmetry is why the panel's copy went unexamined, and its message was the one refusal in
// chatValidate that named no limit.
//
// This test exists for the day somebody raises the rune cap. Past 1024 the branch goes live, its
// wording starts mattering, and the two sides' orderings start disagreeing about which rule
// refused a message — so that change should not be silent.
func TestThePanelsByteCapIsUnreachableUntilTheRuneCapMoves(t *testing.T) {
	if MaxBodyRunes*4 > MaxInputBytes {
		t.Fatalf("MaxBodyRunes is %d, so a body at the rune cap can reach %d bytes and exceed "+
			"MaxInputBytes (%d). web/chat.js's byte branch is now REACHABLE: check that its "+
			"sentence still names the right limit and that the panel and the server agree about "+
			"which rule refused the message — the server checks bytes FIRST, the panel checks "+
			"runes first, so the same input can now be refused for different stated reasons",
			MaxBodyRunes, MaxBodyRunes*4, MaxInputBytes)
	}

	// And the branch still has to be THERE, with its limit in it. A guard deleted because it
	// cannot fire today is a guard missing on the day the constant moves.
	src, err := os.ReadFile(filepath.Join("..", "..", "web", "chat.js"))
	if err != nil {
		t.Fatal(err)
	}
	fn := regexp.MustCompile(`(?s)function chatValidate\(.*?\n\}`).Find(src)
	if fn == nil {
		t.Fatal("chatValidate not found in web/chat.js")
	}
	if !regexp.MustCompile(`CHATLIMITS\.bytes`).Match(fn) {
		t.Error("chatValidate no longer checks CHATLIMITS.bytes; it mirrors MaxInputBytes and " +
			"must stay, because it is what catches a body the server would refuse once the " +
			"rune cap allows one")
	}
	// The limit must be quoted, like every other refusal in that function. §5's rule is that a
	// refusal says what would be accepted, and this was the one that did not.
	if !regexp.MustCompile(`far too long to process.*CHATLIMITS\.bytes`).Match(fn) {
		t.Error("the byte refusal must name its limit and follow the server's wording " +
			`("far too long to process"), or the two contradict each other about one rule`)
	}
}
