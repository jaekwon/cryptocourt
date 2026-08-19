package chat

import (
	"errors"
	"strings"
	"testing"
)

// Every "must be rejected" case is paired with the ordinary text it must NOT
// reject. A sanitiser that refuses everything passes a table of refusals, which
// is the same failure `make mutate` exists for elsewhere in this repo: a green
// suite that would also be green against a guard you deleted.
func TestSanitizeBody(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string // "" with wantErr nil means: any non-empty output
		err  error  // nil = must be accepted
	}{
		// --- ordinary traffic, which must survive untouched ---------------
		{"plain", "gm, when does the settle window close?", "gm, when does the settle window close?", nil},
		{"criticism", "this court is a joke and the mods are useless", "this court is a joke and the mods are useless", nil},
		{"turkish", "merhaba, bu mahkeme hakkında ne düşünüyorsunuz", "", nil},
		{"cyrillic word", "привет всем", "привет всем", nil},
		{"mixed sentence", "gm привет here", "gm привет here", nil},
		{"gno address", "sent it to g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5", "", nil},
		{"emoji", "nice ⚖︎ result", "", nil},

		// --- normalisation: renders the same, must STORE the same ---------
		{"math bold folds", "\U0001D42C\U0001D41C\U0001D41A\U0001D426", "scam", nil},
		{"fullwidth folds", "ｓｃａｍ", "scam", nil},

		// --- invisibles: render as one thing, tokenise as another ---------
		{"soft hyphen", "s­c­a­m", "scam", nil},
		{"zero width", "s​c​a​m", "scam", nil},
		{"bidi override", "abc‮def", "abcdef", nil},
		{"tag chars", "hi\U000E0041\U000E0042", "hi", nil},
		{"non-emoji variation selectors still go", "hi\ufe00 there", "hi there", nil},
		{"hangul filler pad", "alㅤice", "alice", nil},

		// --- shape ---------------------------------------------------------
		{"collapse spaces", "a     b", "a b", nil},
		{"trim", "   hi   ", "hi", nil},
		{"newline becomes space", "a\nb", "a b", nil},
		{"long run capped", "no" + rep("o", 40), "n" + rep("o", maxRunRunes), nil},

		// --- refusals -------------------------------------------------------
		{"empty", "", "", ErrEmpty},
		{"only spaces", "    ", "", ErrEmpty},
		{"only invisibles", "​​", "", ErrEmpty},
		{"too long", varied(MaxBodyRunes + 1), "", ErrTooLong},
		{"oversize input", rep("a", MaxInputBytes+1), "", ErrOversize},
		{"control char", "a\x00b", "", ErrControl},
		{"stacked marks", "s" + rep("\u0361", 10) + "cam", "", ErrMarks},
		{"joiner run", rep("\u200d", maxJoinerRun+1) + "x", "", ErrJoiners},
		// Density, not quantity: joiners must not outnumber what a reader can see. This is
		// the abuse the old whole-message total was aimed at, and it is still refused.
		{"joiners outnumber the text", "hi" + rep("\u200d", 100) + "there", "", ErrJoiners},

		// --- THE FIRST DRAFT BROKE ALL OF THESE. They are ordinary text and
		// --- must survive byte for byte; the regression is locked out here.
		{"emoji family keeps its joiners", "\U0001F468\u200d\U0001F469\u200d\U0001F467",
			"\U0001F468\u200d\U0001F469\u200d\U0001F467", nil},
		{"emoji presentation kept", "\u2764\ufe0f", "\u2764\ufe0f", nil},
		{"persian zwnj kept", "\u0645\u06cc\u200c\u0631\u0648\u0645",
			"\u0645\u06cc\u200c\u0631\u0648\u0645", nil},
		{"hyphenated compound", "Bitcoin-\u0431\u0438\u0440\u0436\u0430",
			"Bitcoin-\u0431\u0438\u0440\u0436\u0430", nil},
		{"idn address", "alice@\u043f\u043e\u0447\u0442\u0430.\u0440\u0444",
			"alice@\u043f\u043e\u0447\u0442\u0430.\u0440\u0444", nil},
		{"cjk has no spaces", "\u65e5\u672c\u8a9e\u306e\u30c6\u30b9\u30c8",
			"\u65e5\u672c\u8a9e\u306e\u30c6\u30b9\u30c8", nil},
		{"markup is not an attack", "use <| here", "use <| here", nil},
		{"arabic format char kept", "\u0600 x", "", nil},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := SanitizeBody(c.in)
			if c.err != nil {
				if !errors.Is(err, c.err) {
					t.Fatalf("want error %v, got %v (out %q)", c.err, err, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("ordinary text was refused: %v", err)
			}
			if c.want != "" && got != c.want {
				t.Fatalf("want %q, got %q", c.want, got)
			}
			if got == "" {
				t.Fatal("accepted but produced nothing")
			}
		})
	}
}

// The length limit counts RUNES. A byte limit would let 400 ASCII characters
// through and cut a Cyrillic sentence in half at 200 — a length rule that is
// stricter for anyone not writing English.
func TestLimitsAreRunesNotBytes(t *testing.T) {
	// Cyrillic, two bytes per rune, and cycled so the run cap cannot shorten it.
	s := ""
	for i := 0; i < MaxBodyRunes; i++ {
		s += string([]rune("абвгд")[i%5])
	}
	if len(s) <= MaxBodyRunes {
		t.Fatal("fixture: this string must be longer in bytes than in runes")
	}
	if _, err := SanitizeBody(s); err != nil {
		t.Fatalf("a message at exactly the rune limit was refused: %v", err)
	}
	if _, err := SanitizeBody(s + "е"); !errors.Is(err, ErrTooLong) {
		t.Fatalf("one rune over the limit must be refused, got %v", err)
	}
}

func TestSanitizeMoniker(t *testing.T) {
	cases := []struct {
		name, in, want string
		err            error
	}{
		{"plain", "alice", "alice", nil},
		{"spaces removed", "a l i c e", "alice", nil},
		{"filler pad stripped", "alㅤice", "alice", nil},
		{"too long", varied(MaxMonikerRunes + 1), "", ErrTooLong},
		{"empty", "", "", ErrEmpty},
		{"only spaces", "   ", "", ErrEmpty},
		{"cyrillic name is fine", "алиса", "алиса", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := SanitizeMoniker(c.in)
			if c.err != nil {
				if !errors.Is(err, c.err) {
					t.Fatalf("want %v, got %v (out %q)", c.err, err, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("refused: %v", err)
			}
			if got != c.want {
				t.Fatalf("want %q, got %q", c.want, got)
			}
		})
	}
}

// The invariant the whole design leans on: sanitising is IDEMPOTENT, so the
// bytes the scanner reads are the bytes the reader sees. If this ever fails, a
// message can be scanned in one form and displayed in another.
func TestSanitizeIsIdempotent(t *testing.T) {
	for _, in := range []string{
		"gm all", "s­c­a­m", "ｓｃａｍ", "a     b", "  hi  ",
		"\U0001D42C\U0001D41C\U0001D41A\U0001D426", "no" + rep("o", 40),
	} {
		once, err := SanitizeBody(in)
		if err != nil {
			continue
		}
		twice, err := SanitizeBody(once)
		if err != nil {
			t.Fatalf("%q sanitised once to %q, which is then refused: %v", in, once, err)
		}
		if once != twice {
			t.Fatalf("%q: not idempotent, %q -> %q", in, once, twice)
		}
	}
}

// varied builds an n-rune string with no long identical runs, so the run cap
// cannot collapse it and shorten what the length rule sees.
func varied(n int) string {
	const alphabet = "abcdefghijklmnopqrstuvwxyz"
	out := make([]rune, n)
	for i := 0; i < n; i++ {
		out[i] = rune(alphabet[i%len(alphabet)])
	}
	return string(out)
}

func rep(s string, n int) string {
	out := make([]byte, 0, len(s)*n)
	for i := 0; i < n; i++ {
		out = append(out, s...)
	}
	return string(out)
}

// Skeleton is where evasion resistance moved, so the cases Sanitize deliberately
// lets through must collapse HERE. Each spelling of "scam" that a reader would
// read as "scam" must reduce to the same string, and unrelated text must not.
func TestSkeleton(t *testing.T) {
	same := []struct{ name, in string }{
		{"plain", "scam"},
		{"upper", "SCAM"},
		{"spaced", "S C A M"},
		{"punctuated", "s.c.a.m"},
		{"digits", "5c4m"},
		{"cherokee", "\u13da\u13df\u13aa\u13b7"},
		{"combining marks", "s\u0361c\u0361a\u0361m"},
		{"fullwidth", "\uff53\uff43\uff41\uff4d"},
		{"math bold", "\U0001D42C\U0001D41C\U0001D41A\U0001D426"},
		{"zero width", "s\u200bc\u200ba\u200bm"},
	}
	for _, c := range same {
		t.Run(c.name, func(t *testing.T) {
			if got := Skeleton(c.in); got != "scam" {
				t.Fatalf("%q should read as scam, got %q", c.in, got)
			}
		})
	}
	// The pairing that makes the above mean something: a skeleton that collapsed
	// everything to one value would pass every case above.
	if Skeleton("perfectly ordinary message") == "scam" {
		t.Fatal("Skeleton collapses unrelated text onto the same value")
	}
	if a, b := Skeleton("hello there"), Skeleton("goodbye now"); a == b {
		t.Fatalf("distinct messages must have distinct skeletons: %q", a)
	}
	// Armenian homoglyphs, which the first draft passed untouched.
	if got := Skeleton("\u0578\u0581\u0581\u0585\u0582\u0576\u0581"); got == "" {
		t.Fatal("Armenian text produced an empty skeleton")
	}
}

// Skeleton must never be mistaken for display text: it is lossy, and the point of
// keeping them separate is that Sanitize preserves what Skeleton throws away.
func TestSkeletonIsNotDisplayText(t *testing.T) {
	body, err := SanitizeBody("Bitcoin-\u0431\u0438\u0440\u0436\u0430 opens at 09:00")
	if err != nil {
		t.Fatal(err)
	}
	if Skeleton(body) == body {
		t.Fatal("Skeleton returned something displayable; it is meant to be lossy")
	}
	if !containsRune(body, '\u0431') {
		t.Fatal("the displayed body lost its Cyrillic")
	}
}

func containsRune(s string, r rune) bool {
	for _, c := range s {
		if c == r {
			return true
		}
	}
	return false
}

// THE JOINER CAP MUST NOT REFUSE A LANGUAGE.
//
// It was a whole-message total of 16, and measured against ordinary text it refused:
//
//	Persian prose, 20 ZWNJ words, 177 runes   REFUSED
//	six family emoji, 48 runes                REFUSED
//
// §4 exists because the first sanitiser refused `Bitcoin-биржа` and `alice@почта.рф` as
// homoglyph attacks. This was the same failure surviving in a different constant: ZWNJ is
// orthographically required in Persian, so a total cap punishes the language and not the abuse.
// A long legitimate message legitimately contains more joiners than a short one.
//
// The replacement bounds density instead — consecutive runs, and joiners against visible
// characters — and it is safe to be this permissive because the cap was never what stopped
// joiner-interleaved evasion. Skeleton reduces "s‍c‍a‍m" to "scam" on its own, which is
// asserted below so the reasoning cannot quietly stop being true.
func TestJoinersDoNotRefuseOrdinaryText(t *testing.T) {
	// Persian words that each carry a ZWNJ, as ordinary as "don't" in English.
	fa := []string{"می‌روم", "نمی‌دانم", "کتاب‌ها", "بچه‌ها", "خانه‌اش",
		"می‌توانم", "نمی‌شود", "دانش‌جویان", "روزنامه‌نگار", "بی‌نهایت"}
	var words []string
	for i := 0; i < 3; i++ {
		words = append(words, fa...)
	}
	for _, n := range []int{10, 16, 20, 30} {
		text := strings.Join(words[:n], " ")
		if _, err := SanitizeBody(text); err != nil {
			t.Errorf("%d Persian ZWNJ words (%d runes) must be accepted: %v",
				n, len([]rune(text)), err)
		}
	}

	// Emoji families: four people joined by three ZWJ each.
	fam := "\U0001F468‍\U0001F469‍\U0001F467‍\U0001F466"
	for _, n := range []int{1, 2, 4, 6, 8} {
		text := strings.TrimSpace(strings.Repeat(fam+" ", n))
		if _, err := SanitizeBody(text); err != nil {
			t.Errorf("%d family emoji (%d runes) must be accepted: %v",
				n, len([]rune(text)), err)
		}
	}
	// The one that stacks joiners inside a single glyph: heart, VS16, ZWJ, fire.
	if _, err := SanitizeBody("❤️‍\U0001F525 nice"); err != nil {
		t.Errorf("heart-on-fire stacks two joiners in one glyph and must survive: %v", err)
	}

	// PAIRED REFUSALS, so this is not a test that everything is accepted.
	//
	// The third one is what makes the RUN cap earn its place, and it took a surviving mutation
	// to notice: every other refusal here also violates the density rule, so deleting the run
	// cap changed nothing. A long message can hide a burst of invisible joiners while staying
	// comfortably under the ratio, and that burst is exactly the layout abuse the run cap is
	// for — 6 consecutive joiners against 100 visible characters is a density of 0.06.
	long := strings.Repeat("ordinary words about the docket ", 4) // ~128 visible runes
	for _, c := range []struct{ name, in string }{
		{"joiners outnumbering the text", "hi" + strings.Repeat("‍ ", 60)},
		{"nothing but joiners", strings.Repeat("‍", 3)},
		{"a burst hidden in a long message", long + strings.Repeat("‍", 6) + long},
	} {
		if _, err := SanitizeBody(c.in); err == nil {
			t.Errorf("%s must still be refused", c.name)
		}
	}
	// And the same message with a LEGAL burst is accepted, so the boundary is pinned in both
	// directions rather than only the refusing one.
	if _, err := SanitizeBody(long + strings.Repeat("‍", maxJoinerRun) + long); err != nil {
		t.Errorf("a burst of exactly maxJoinerRun must be accepted: %v", err)
	}

	// AND THE REASON THE ABOVE IS SAFE: interleaving joiners does not defeat comparison, so
	// the display path does not have to fight it. If this stops holding, the permissiveness
	// above needs revisiting rather than the test deleting.
	for _, in := range []string{"s‍c‍a‍m", "s‌c‌a‌m"} {
		clean, err := SanitizeBody(in)
		if err != nil {
			t.Fatalf("%q should be storable: %v", in, err)
		}
		if got := Skeleton(clean); got != "scam" {
			t.Errorf("Skeleton must see through joiners: %q -> %q, want \"scam\"", in, got)
		}
	}
}
