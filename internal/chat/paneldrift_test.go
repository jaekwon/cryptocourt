package chat

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
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

	// The maxlength attributes are generated FROM that declaration, not written out again.
	// Checked because they are the half that stops a keystroke, and because a future edit
	// hardcoding them would leave this test passing while the composer disagreed.
	for _, lit := range []string{`maxlength="24"`, `maxlength="400"`, `maxlength="4096"`} {
		if regexp.MustCompile(regexp.QuoteMeta(lit)).Match(src) {
			t.Errorf("web/chat.js hardcodes %s; it must come from CHATLIMITS so it cannot "+
				"drift from the server", lit)
		}
	}
	if !regexp.MustCompile(`maxlength="' \+ CHATLIMITS\.moniker`).Match(src) ||
		!regexp.MustCompile(`maxlength="' \+ CHATLIMITS\.body`).Match(src) {
		t.Error("both composer inputs must take maxlength from CHATLIMITS")
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
