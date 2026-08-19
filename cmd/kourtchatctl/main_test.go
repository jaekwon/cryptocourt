package main

import (
	"bytes"
	"context"
	"fmt"
	"github.com/jaekwon/kourt/internal/chat"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"
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

// THE HELP TEXT IS A THIRD COPY OF THE FLAGS, so it drifts like the other two.
//
// takesValue is one copy and has its own guard above. The usage text is another, and it had
// drifted furthest — measured before this test existed:
//
//	kick     showed only -for, omitting -msg, -net AND -why
//	ban      omitted -msg
//	unban    omitted -by
//	list     omitted -n
//	review   omitted -n
//	prune    omitted -n
//	revoke   an accepted alias for unban, mentioned nowhere
//
// The kick line was the one that mattered. -msg is the path `review`'s own output tells an
// operator to use, and -net widens a consequence to a whole /24 or /48 — the only consequence
// that reaches more than one address, and the help did not say the verb could do it. An operator
// reading --help would have concluded kick takes a hash and a duration and nothing else.
//
// A flag nobody can discover is a flag nobody uses, and here that means reaching for a broader
// tool than the situation needed.
func TestEveryVerbsHelpListsTheFlagsItActuallyTakes(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	usage := regexp.MustCompile(`(?s)func usage\(\) \{.*?\n\}`).Find(src)
	if usage == nil {
		t.Fatal("usage() not found; if it was reshaped, reshape this guard with it")
	}

	// A verb's entry runs from its own line to the next verb's line. Continuation lines are
	// indented far enough not to be mistaken for one.
	entryOf := func(verb string) string {
		re := regexp.MustCompile(`(?m)^  ` + verb + `\b.*(?:\n {10,}.*)*`)
		return string(re.Find(usage))
	}

	// 1. Every verb the dispatcher accepts is documented, including aliases.
	verbs := regexp.MustCompile(`case "([a-z]+)"(?:, "([a-z]+)")?:\n\t\tcmd`).FindAllSubmatch(src, -1)
	if len(verbs) < 8 {
		t.Fatalf("only %d dispatched verbs found; the pattern has stopped matching", len(verbs))
	}
	for _, m := range verbs {
		primary := string(m[1])
		if entryOf(primary) == "" {
			t.Errorf("verb %q is dispatched but absent from the help", primary)
		}
		if alias := string(m[2]); alias != "" && !bytes.Contains(usage, []byte(alias)) {
			t.Errorf("verb %q is an accepted alias for %q and is mentioned nowhere in the help",
				alias, primary)
		}
	}

	// 2. Every flag a verb defines appears in its entry, and nothing is shown that does not exist.
	sets := regexp.MustCompile(`flag\.NewFlagSet\("([a-z]+)"`).FindAllSubmatchIndex(src, -1)
	checked := 0
	for _, loc := range sets {
		verb := string(src[loc[2]:loc[3]])
		// The body of that command, up to its closing brace at column 0.
		rest := src[loc[1]:]
		if end := bytes.Index(rest, []byte("\n}\n")); end >= 0 {
			rest = rest[:end]
		}
		flags := map[string]bool{}
		for _, f := range regexp.MustCompile(`fs\.[A-Za-z0-9]+\("([a-z-]+)"`).FindAllSubmatch(rest, -1) {
			flags[string(f[1])] = true
		}
		if len(flags) == 0 {
			continue
		}
		entry := entryOf(verb)
		if entry == "" {
			t.Errorf("verb %q has flags %v and no help entry", verb, keysOf(flags))
			continue
		}
		checked++
		shown := map[string]bool{}
		for _, s := range regexp.MustCompile(`-([a-z-]+)`).FindAllStringSubmatch(entry, -1) {
			shown[s[1]] = true
		}
		for f := range flags {
			if !shown[f] {
				t.Errorf("%s takes -%s and the help does not mention it; a flag nobody can "+
					"discover is a flag nobody uses", verb, f)
			}
		}
		for s := range shown {
			if !flags[s] {
				t.Errorf("the help for %s shows -%s, which it does not accept — worse than "+
					"omitting one, because somebody will type it", verb, s)
			}
		}
	}
	if checked < 5 {
		t.Fatalf("only %d verbs with flags were checked; the guard is not reaching the file", checked)
	}
}

func keysOf(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// A CONSEQUENCE THAT WAS NOT RECORDED MUST NOT BE REPORTED AS ONE.
//
// Consequence returns (0, nil) when the partial unique index on (evidence_id, kind) rejects a
// replay. That is deliberate and load-bearing — it stops a crash between "punish" and "mark
// scanned" from walking the ladder — but the tool printed it as a success. Measured live:
//
//	kicked address daa27c05ac6b for 1h0m0s [consequence 0]
//	reverse it early with: kourtchatctl unban 0
//
// A kick that never happened, an id that cannot exist, and an instruction pointing at it. The
// instruction now fails honestly too, since Revoke learned to say "no consequence 0" this commit —
// but being told the kick landed was the lie that mattered.
func TestAReplayedConsequenceIsReportedAsOne(t *testing.T) {
	s, err := chat.Open(filepath.Join(t.TempDir(), "c.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Unix(1_700_000_000, 0)
	s.Now = func() time.Time { return now }
	ctx := context.Background()

	id, err := s.Post(ctx, chat.PostInput{
		Chain: "dev", Court: "orem", Moniker: "troll", Body: "a message to act on twice",
		IPHash: "ip-a", NetHash: "net-a",
	})
	if err != nil {
		t.Fatal(err)
	}
	inf, err := s.Consequence(ctx, chat.Infraction{
		IPHash: "ip-a", Kind: chat.KindKick, Reason: chat.ReasonManual,
		Duration: time.Hour, EvidenceID: id,
	})
	if err != nil || inf == 0 {
		t.Fatalf("precondition: the first consequence must record: id=%d err=%v", inf, err)
	}

	got := replayReport(ctx, s, "ip-a", id, chat.KindKick, "kick")
	for _, want := range []string{"no new consequence was recorded", "duplicate",
		fmt.Sprintf("message %d", id), fmt.Sprintf("consequence %d", inf), "unban"} {
		if !strings.Contains(got, want) {
			t.Errorf("the report must contain %q, got:\n%s", want, got)
		}
	}
	// It must not read as success, and must never print the zero it was handed.
	for _, mustNot := range []string{"kicked ", "[consequence 0]", "unban 0"} {
		if strings.Contains(got, mustNot) {
			t.Errorf("the report must not contain %q, got:\n%s", mustNot, got)
		}
	}

	// THE PAIRED CASE: when no matching row can be found the report still refuses to claim a
	// consequence, rather than falling through to something that reads like success.
	orphan := replayReport(ctx, s, "ip-nobody", id, chat.KindKick, "kick")
	if !strings.Contains(orphan, "no new consequence was recorded") {
		t.Errorf("with no row to name it must still say nothing was recorded, got:\n%s", orphan)
	}
	if strings.Contains(orphan, "unban") {
		t.Errorf("and must not point at an id it did not find, got:\n%s", orphan)
	}
}

// AND BOTH VERBS MUST ACTUALLY CHECK FOR THE ZERO, which the test above cannot see: it calls
// replayReport directly, so deleting the `if id == 0` guard in cmdKick would leave that test green
// while the tool went back to printing "[consequence 0]".
//
// Read from the source, like the takesValue and help-text guards in this file. The property is
// narrow and mechanical — a success line must not be reachable with a zero id — and the failure it
// prevents is a punishment reported that never happened.
func TestKickAndBanCheckForAReplayBeforeClaimingSuccess(t *testing.T) {
	src, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct{ fn, verb string }{
		{"cmdKick", "kicked"},
		{"cmdBan", "banned"},
	} {
		body := regexp.MustCompile(`(?s)func ` + c.fn + `\(.*?\n\}`).Find(src)
		if body == nil {
			t.Errorf("%s not found; if it was reshaped, reshape this guard with it", c.fn)
			continue
		}
		// The guard, and it must come BEFORE the line that claims the action happened.
		guard := bytes.Index(body, []byte("if id == 0 {"))
		claim := bytes.Index(body, []byte(`fmt.Printf("`+c.verb))
		switch {
		case guard < 0:
			t.Errorf("%s does not check for a replayed consequence; Consequence returns (0, nil) "+
				"when the unique index rejects one, and printing the success line then reports a "+
				"%s that never happened", c.fn, c.verb)
		case claim < 0:
			t.Errorf("%s no longer prints a %q line; re-derive this check", c.fn, c.verb)
		case guard > claim:
			t.Errorf("%s checks for the replay AFTER claiming success, which is no check at all",
				c.fn)
		}
		// And the replay branch must return rather than fall through into the success line.
		if guard >= 0 {
			after := body[guard:]
			if end := bytes.Index(after, []byte("\n\t}")); end > 0 {
				if !bytes.Contains(after[:end], []byte("return")) {
					t.Errorf("%s's replay branch must return; without it the success line still "+
						"prints", c.fn)
				}
			}
		}
	}
}

// A DURATION MUST READ THE WAY A PERSON READS ONE, because "876000h0m0s" does not read as a hundred
// years and that is exactly the typo it hides.
//
// Measured: `kick -for 876000h` is accepted and `list` shows "876000h0m0s left". A hundred-year
// timeout is a ban wearing a kick's label — the tool refuses a MISSING -for with "a timeout with no
// end is a ban" and then accepts one with no end in practice. A policy ceiling would be arbitrary
// wherever it landed and would refuse a legitimate long timeout, so the fix is to make the extra
// zero visible instead.
func TestADurationReadsTheWayAPersonReadsOne(t *testing.T) {
	for _, c := range []struct {
		in   time.Duration
		want string
	}{
		{876000 * time.Hour, "about 100 years"},
		{876 * time.Hour, "about 1 month"}, // the typo's intent, and SINGULAR
		{24 * time.Hour, "about 1 day"},
		{48 * time.Hour, "about 2 days"},
		{time.Hour, "about 1 hour"},
		{90 * time.Minute, "about 2 hours"}, // coarse on purpose: 90 minutes is not 90 of anything
		{45 * time.Minute, "about 45 minutes"},
		{time.Minute, "about 1 minute"},
		{30 * time.Second, "about 30 seconds"},
		{time.Second, "about 1 second"},
	} {
		if got := humanDuration(c.in); got != c.want {
			t.Errorf("humanDuration(%s) = %q, want %q", c.in, got, c.want)
		}
	}

	// The pluralisation is asserted above and here as a rule, because this repo had already caught
	// "paused for another 1 hours" in the panel and I reintroduced it in this file.
	for _, d := range []time.Duration{time.Second, time.Minute, time.Hour, 24 * time.Hour,
		30 * 24 * time.Hour, 365 * 24 * time.Hour} {
		if got := humanDuration(d); strings.Contains(got, "1 ") && strings.HasSuffix(got, "s") {
			t.Errorf("humanDuration(%s) = %q — a singular with a plural unit", d, got)
		}
	}

	// And the case that says nobody is affected, which is the other end of the same problem: a
	// nanosecond kick leaves state=ok while still hiding the author's last ten minutes.
	if got := humanDuration(time.Nanosecond); !strings.Contains(got, "nobody is kept out") {
		t.Errorf("a sub-second timeout must say it keeps nobody out, got %q", got)
	}
}

// And the hide note must state the half the duration does not govern.
func TestTheHideNoteNamesTheWindowAndTheReversal(t *testing.T) {
	got := hideNote(42)
	for _, want := range []string{"hidden", "unban 42", chat.HideWindow.String(),
		"does not govern"} {
		if !strings.Contains(got, want) {
			t.Errorf("the note must contain %q, got %q", want, got)
		}
	}
	// It must take the window from the constant, not a literal, so raising HideWindow updates the
	// sentence rather than leaving it wrong.
	if strings.Contains(got, "10m0s") && chat.HideWindow.String() != "10m0s" {
		t.Errorf("the window looks hardcoded: %q", got)
	}
}
