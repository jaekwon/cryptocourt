package main

import (
	"os"
	"reflect"
	"regexp"
	"sort"
	"strings"
	"testing"
	"unicode/utf8"
)

// takesValue IS A COPY OF THE FLAG DEFINITIONS, so it needs a guard.
//
// split() has to know which flags consume the next argument BEFORE the FlagSet is parsed, which is
// why the list is hand-written — the comment there says asking the FlagSet cannot be done, and at
// runtime that is true. In a test it is not: the definitions are right there in the source.
//
// The failure this prevents is quiet. A new value-taking flag missing from the list means split()
// leaves its value in `positional`, so
//
//	kick -newthing 5 <hash> -for 1h
//
// hands cmdKick the positional list ["5", "<hash>"], and it acts on "5" — or dies saying it takes
// one hash while the operator can see two arguments. Either way the diagnostic points away from the
// cause.
//
// This is the same shape as the stale Unicode table in internal/chat: a copy of a list is a
// threshold that moves on its own. The list is CORRECT today; it is guarded so it stays that way.
func TestTakesValueMatchesTheFlagsActuallyDefined(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	// Type names contain digits (Int64) — a hand-audit of this same list missed exactly that and
	// concluded a defined flag was undefined, so the pattern allows them deliberately.
	def := regexp.MustCompile(`(?:fs|flag)\.([A-Za-z0-9]+)\("([a-z-]+)"`).FindAllSubmatch(src, -1)
	if len(def) < 10 {
		t.Fatalf("only %d matches found; the pattern has stopped matching this file and would "+
			"pass vacuously", len(def))
	}
	// Classified EXPLICITLY rather than "anything that is not Bool", because the same expression
	// also matches flag.NewFlagSet("ban", ...) — which is a command name, not a flag, and treating
	// it as one made the first run of this test report seven imaginary missing flags.
	valueTaking := map[string]bool{
		"String": true, "Int": true, "Int64": true, "Uint": true, "Uint64": true,
		"Float64": true, "Duration": true, "Var": true, "TextVar": true, "Func": true,
		"Bool": false,
	}
	notAFlag := map[string]bool{"NewFlagSet": true}
	wantValue := map[string]bool{}
	for _, m := range def {
		typ, name := string(m[1]), string(m[2])
		if notAFlag[typ] {
			continue
		}
		needs, known := valueTaking[typ]
		if !known {
			t.Errorf("unrecognised flag method %q for %q: add it to this test's table rather "+
				"than letting it be classified by guesswork", typ, name)
			continue
		}
		wantValue[name] = wantValue[name] || needs
	}

	var missing, extra []string
	for name, needs := range wantValue {
		switch {
		case needs && !takesValue(name):
			missing = append(missing, name)
		case !needs && takesValue(name):
			extra = append(extra, name)
		}
	}
	sort.Strings(missing)
	sort.Strings(extra)
	if len(missing) > 0 {
		t.Errorf("takesValue is missing %v — split() will leave their values in the positional "+
			"list, and the command will act on the wrong argument", missing)
	}
	if len(extra) > 0 {
		t.Errorf("takesValue claims %v take a value, but they are booleans — split() will "+
			"swallow the NEXT argument, which is usually the hash being acted on", extra)
	}
	// And nothing in takesValue that no longer exists: a stale entry swallows an argument for a
	// flag the FlagSet will reject anyway, so the operator gets an error naming the wrong problem.
	//
	// Read from the source rather than from a list written here. The first version of this check
	// DID write the list out again — a copy of the copy — so adding a bogus entry to takesValue
	// survived it. That is precisely the defect this file exists to catch, committed inside the
	// catcher.
	listed := regexp.MustCompile(`(?s)func takesValue\(.*?\n\}`).Find(src)
	if listed == nil {
		t.Fatal("takesValue not found in main.go; if it was reshaped, reshape this check with it")
	}
	// Only the `case` line, because the function also contains strings.TrimLeft(f, "-") and a
	// bare `"([a-z-]+)"` sweep matched that "-" as a flag name — failing on correct code, and
	// "catching" a planted stale entry for the wrong reason.
	caseLine := regexp.MustCompile(`case ("[a-z-]+"(?:, "[a-z-]+")*):`).Find(listed)
	if caseLine == nil {
		t.Fatal("takesValue's case list not found; reshape this check with it")
	}
	names := regexp.MustCompile(`"([a-z-]+)"`).FindAllSubmatch(caseLine, -1)
	if len(names) < 5 {
		t.Fatalf("only %d flag names found inside takesValue; the pattern would pass vacuously",
			len(names))
	}
	for _, m := range names {
		name := string(m[1])
		if _, ok := wantValue[name]; !ok {
			t.Errorf("takesValue lists %q but no flag by that name is defined anywhere", name)
		}
	}
}

// split() exists for one operator-facing reason: Go's flag package stops at the first non-flag
// argument, so `unban 1 -by jae` — the order anybody would type — fails with "needs one id".
//
// Pinned because the reordering is easy to break and the symptom is a confusing refusal on a
// correct command, at the moment an operator is reversing a bad decision.
func TestSplitAcceptsFlagsOnEitherSideOfThePositionals(t *testing.T) {
	for _, c := range []struct {
		name      string
		argv      []string
		wantFlags []string
		wantPos   []string
	}{
		{"flags after the id, the order anybody types",
			[]string{"1", "-by", "jae"}, []string{"-by", "jae"}, []string{"1"}},
		{"flags before the id",
			[]string{"-by", "jae", "1"}, []string{"-by", "jae"}, []string{"1"}},
		{"both sides",
			[]string{"-msg", "41", "-for", "1h", "-why", "spam"},
			[]string{"-msg", "41", "-for", "1h", "-why", "spam"}, nil},
		{"equals form does not swallow the next argument",
			[]string{"-for=1h", "abc123"}, []string{"-for=1h"}, []string{"abc123"}},
		{"a boolean does not swallow the hash",
			[]string{"-net", "abc123"}, []string{"-net"}, []string{"abc123"}},
		{"a boolean before a value flag",
			[]string{"-net", "-why", "spam", "abc123"},
			[]string{"-net", "-why", "spam"}, []string{"abc123"}},
		{"a negative-looking value is not taken as a flag's value",
			[]string{"-why", "-net", "abc123"}, []string{"-why", "-net"}, []string{"abc123"}},
	} {
		t.Run(c.name, func(t *testing.T) {
			flags, pos := split(c.argv)
			if !reflect.DeepEqual(flags, c.wantFlags) {
				t.Errorf("flags = %q, want %q", flags, c.wantFlags)
			}
			if !reflect.DeepEqual(pos, c.wantPos) {
				t.Errorf("positional = %q, want %q", pos, c.wantPos)
			}
		})
	}
}

// BAN AND KICK MUST SAY WHAT THEY ACTED ON when given `-msg`.
//
// Neither did, and both had the body in hand. A mistyped id — `-msg 14` for `-msg 41` — produced
// "kicked address 28cb400fe2b6 for 1h [consequence 3]" and nothing to check it against; the
// operator had to run `why` to discover who they had punished. Message ids are rowids that restart
// once prune empties a court, so an id read from `review` earlier can resolve to somebody else.
//
// It cannot prevent the wrong action — the tool is non-interactive on purpose, and a prompt would
// break scripting — but it makes the wrong action visible where it happens, beside the unban line
// that reverses it.
func TestEvidenceLineShowsTheMessageAndTruncatesByRunes(t *testing.T) {
	if got := evidenceLine(0, "anything"); got != "" {
		t.Errorf("a hash-based action cites no message and must print nothing, got %q", got)
	}
	if got := evidenceLine(41, "send me your seed phrase"); !strings.Contains(got, "41") ||
		!strings.Contains(got, "send me your seed phrase") {
		t.Errorf("the line must name the id and the body, got %q", got)
	}
	// The trap: truncating a multibyte body by BYTES severs a character. Cyrillic is two bytes per
	// rune, so a 100-rune body is 200 bytes and a byte cut would land mid-character.
	long := strings.Repeat("ф", 100)
	got := evidenceLine(7, long)
	if !utf8.ValidString(got) {
		t.Errorf("the truncated line must still be valid UTF-8: %q", got)
	}
	// 72 runes kept, plus the ellipsis. Counted inside the quoted body rather than on the whole
	// line, which also carries the prefix.
	body := got[strings.Index(got, "\"")+1 : strings.LastIndex(got, "\"")]
	if n := len([]rune(body)); n != 73 {
		t.Errorf("expected 72 runes plus an ellipsis, got %d runes in %q", n, body)
	}
	if !strings.HasSuffix(body, "…") {
		t.Errorf("a truncated body must say so, got %q", body)
	}
	// And a short body is untouched — the paired positive, so this is not a formatter that
	// mangles everything.
	short := "is the settle window still open"
	if got := evidenceLine(9, short); !strings.Contains(got, short) || strings.Contains(got, "…") {
		t.Errorf("a short body must appear whole and unmarked, got %q", got)
	}
}
