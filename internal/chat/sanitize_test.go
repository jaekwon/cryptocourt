package chat

import (
	"errors"
	"strings"
	"testing"
	"unicode"
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

// REAL WRITING SYSTEMS MUST NOT BE REFUSED, and one was.
//
// maxMarks was 3. Pointed Hebrew puts four marks on a single consonant as a matter of course —
// dagesh, sin-dot, vowel, meteg — and five with a cantillation accent, so a Hebrew speaker quoting
// a pointed text was told their message "stacks too many marks on one character". Fully-voweled
// Arabic and Hebrew niqqud with cantillation both landed exactly ON the old cap, which means the
// scripts that need marks most had no headroom whatsoever.
//
// This table is the paired positive the cap never had. It is written in terms of maxMarks so
// lowering the constant fails here rather than silently starting to refuse these again.
func TestPointedScriptsAreAccepted(t *testing.T) {
	for _, c := range []struct {
		label, s string
		marks    int
	}{
		{"Hebrew, Genesis 1:1 with niqqud", "בְּרֵאשִׁית בָּרָא אֱלֹהִים", 2},
		{"Hebrew, niqqud and cantillation", "בְּרֵאשִׁ֖ית בָּרָ֣א אֱלֹהִ֑ים", 3},
		{"Hebrew, shin with dagesh sin-dot vowel", "שֶּׁ", 3},
		{"Hebrew, and a meteg as well", "שֶּֽׁ", 4},
		{"Hebrew, and a cantillation accent", "שֶּֽׁ֖", 5},
		{"Arabic, the Basmala with full harakat", "بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ", 2},
		{"Arabic, shadda fatha and madda", "اللَّٰهُمَّ", 3},
		{"Thai, vowel above with tone", "เก้าโมงเช้าแล้วครับ", 1},
		{"Devanagari", "क्षत्रिय नमस्ते दुनिया", 1},
		{"Yoruba, underdot with tone", "Ẹ̀kọ́ àti ìmọ̀ràn", 1},
	} {
		t.Run(c.label, func(t *testing.T) {
			if c.marks > maxMarks {
				t.Fatalf("this fixture assumes maxMarks >= %d, it is %d — real pointed text "+
					"reaches %d marks on one base and refusing it tells somebody their "+
					"alphabet is unacceptable", c.marks, maxMarks, c.marks)
			}
			out, err := SanitizeBody(c.s)
			if err != nil {
				t.Fatalf("%q was refused: %v", c.s, err)
			}
			// And it comes back INTACT. Accepting a message while quietly stripping the marks
			// off it would pass an error check and still corrupt the text.
			if out != c.s {
				t.Errorf("accepted but altered:\n  in  %q\n  out %q", c.s, out)
			}
		})
	}
}

// THE PAIRED NEGATIVE: a mark stack that damages the page is still refused. Without this the
// table above would pass just as well for a sanitiser with no cap at all.
func TestAMarkStackThatSmearsIsStillRefused(t *testing.T) {
	for _, n := range []int{maxMarks + 1, 15, 40} {
		s := "s"
		for i := 0; i < n; i++ {
			s += string(rune(0x0300 + i%25))
		}
		s += "cam"
		if _, err := SanitizeBody(s); !errors.Is(err, ErrMarks) {
			t.Errorf("%d marks on one base must be refused, got %v", n, err)
		}
	}
}

// AND THE REASON RAISING THE CAP COSTS NOTHING: evasion resistance was never in this cap.
//
// The top of sanitize.go says it plainly — Sanitize preserves meaning, Skeleton resists evasion —
// but maxMarks was labelled "Zalgo defence", which reads as though lowering it were a security
// measure. It is not, and this measures it rather than asserting the doc: every mark-obscured form
// of a word folds to the SAME skeleton as the plain word, so the duplicate rule and the prefilter
// see through all of them whatever maxMarks is set to.
func TestSkeletonFoldsAnyMarkStackToThePlainWord(t *testing.T) {
	plain := Skeleton("scam")
	if plain != "scam" {
		t.Fatalf("precondition: Skeleton(%q) = %q", "scam", plain)
	}
	for _, s := range []string{
		"s͡c͡a͡m",
		"s̈c̈äm̈",
		"s̸̢̛̪̭̜̮͙̈́͐̈́̚c̷̡̛̭̼̈́̚ä̸̢̛̪̭́m̷̡̛̭̼̈́",
	} {
		if got := Skeleton(s); got != plain {
			t.Errorf("Skeleton(%q) = %q, want %q — if this stops holding, maxMarks becomes "+
				"load-bearing for evasion and its value has to be reconsidered", s, got, plain)
		}
	}
	// The case that matters in practice: an obscured secret-phrase ask must still reduce to
	// something the deterministic prefilter can match.
	if got := Skeleton("send me your s̈ëëd̈ p̈ḧräs̈ë"); got != "sendmeyourseedphrase" {
		t.Errorf("an obscured lure must fold to the plain words, got %q", got)
	}
}

// A NAME LIMIT MUST MEAN THE SAME THING IN EVERY SCRIPT.
//
// MaxMonikerRunes counted code points, and in Hebrew, Arabic, Thai and Devanagari a letter costs
// two or three of them. Measured at the old rune count of 24:
//
//	Bartholomew Smythe-Jones               24 runes  24 letters   accepted
//	عَبْدُ الرَّحْمَٰنِ بْنُ مُحَمَّدٍ                   34 runes  18 letters   REFUSED
//
// An eighteen-letter name refused where a twenty-four-letter one passes. That is the defect
// sanitize.go's header describes one level up — "a byte limit is a length limit for English and a
// censor for everything else" — with runes standing in for bytes, and it survived precisely
// because runes ARE the fix for the byte version.
func TestARealNameIsNotRefusedForItsAlphabet(t *testing.T) {
	for _, c := range []struct {
		label, s string
		letters  int
	}{
		{"English, at the limit", "Bartholomew Smythe-Jones", 24},
		{"Hebrew, pointed", "יְהוֹשֻׁעַ בֶּן נוּן", 12},
		{"Arabic, voweled", "عَبْدُ الرَّحْمَٰنِ", 10},
		{"Arabic, voweled full name", "عَبْدُ الرَّحْمَٰنِ بْنُ مُحَمَّدٍ", 18},
		{"Thai", "ประเสริฐ วงศ์สุวรรณ", 16},
		{"Devanagari, with matras", "श्रीमती राधिका शर्मा", 18},
		{"Vietnamese", "Nguyễn Thị Hương", 16},
		{"Japanese", "山田太郎", 4},
	} {
		t.Run(c.label, func(t *testing.T) {
			out, err := SanitizeMoniker(c.s)
			if err != nil {
				t.Fatalf("%q (%d letters, limit %d) was refused: %v",
					c.s, c.letters, MaxMonikerRunes, err)
			}
			// A moniker loses its spaces by design — "a name is one token and a padded one
			// impersonates" — and that rule is script-neutral: "Mary Jane" becomes "MaryJane"
			// too. So the anti-corruption check is that every LETTER AND MARK survives, which
			// still fails if the marks are stripped. Asserting equality with the input caught
			// the space rule, which is how it got written down here.
			if want := strings.Join(strings.Fields(c.s), ""); out != want {
				t.Errorf("accepted but altered beyond its spaces:\n  in   %q\n  out  %q\n  want %q",
					c.s, out, want)
			}
			// The count itself, so a change to the predicate shows up here as a number rather
			// than as a mysteriously passing table.
			if got := countAgainstLimit(c.s, countMarks); got != c.letters {
				t.Errorf("counted %d letters, expected %d — the fixture or the predicate moved",
					got, c.letters)
			}
		})
	}
}

// AND THE LIMIT MUST STILL BE A LIMIT. Marks not consuming the budget is not marks being free:
// the letters are counted, and a genuinely long name is refused whatever alphabet it is in.
//
// The bases are VARIED, not repeated. strings.Repeat of one marked letter trips maxRunRunes, which
// truncates the identical run and drops the letter count back under the limit — so the naive
// version of this fixture measured the run cap and passed while asserting nothing. It cost two
// runs to notice.
func TestATooLongNameIsStillRefusedInEveryScript(t *testing.T) {
	for _, c := range []struct {
		label string
		bases []string
		mark  string
	}{
		{"English", []string{"a", "b", "c", "d", "e"}, ""},
		{"Hebrew, pointed", []string{"ב", "ג", "ד", "כ", "פ"}, "\u05bc\u05b6"},
		{"Arabic, voweled", []string{"ب", "ت", "ج", "د", "ر"}, "\u0651\u064e"},
		{"Thai, with tone", []string{"ก", "ข", "ค", "ง", "จ"}, "\u0e49"},
	} {
		t.Run(c.label, func(t *testing.T) {
			var b strings.Builder
			for i := 0; i < MaxMonikerRunes+1; i++ {
				b.WriteString(c.bases[i%len(c.bases)])
				b.WriteString(c.mark)
			}
			s := b.String()
			if n := countAgainstLimit(s, countMarks); n != MaxMonikerRunes+1 {
				t.Fatalf("fixture built %d letters, wanted %d", n, MaxMonikerRunes+1)
			}
			if _, err := SanitizeMoniker(s); !errors.Is(err, ErrTooLong) {
				t.Errorf("%d letters must be refused, got %v", MaxMonikerRunes+1, err)
			}
		})
	}
}

// THE EQUIVALENCE, and its LIMIT, both stated because the second is the honest half.
//
// Exactly MaxMonikerRunes letters is acceptable, and one more is not, in every script whose marks
// are non-spacing (Mn) — Hebrew, Arabic, Thai. That is the class the change fixes.
//
// IT DOES NOT FIX EVERYTHING, and the boundary is worth naming rather than discovering later. Go
// skips unicode.Mn and unicode.Me, not Mc — the SPACING combining marks — and a Devanagari matra
// is Mc. So "शि" counts as two letters, not one, and Devanagari still pays roughly half its
// budget to its own orthography. The genuinely correct measure is grapheme clusters, which needs
// a segmentation dependency in Go and Intl.Segmenter in the panel; skipping Mn/Me is an
// approximation that is exact for Mn scripts and partial for Mc ones. The names measured in
// TestARealNameIsNotRefusedForItsAlphabet all fit at 24 either way, which is why the
// approximation was taken rather than the dependency.
//
// Built from VARIED base characters on purpose: repeating one identical letter trips the run cap
// (maxRunRunes truncates identical sequences), so a naive strings.Repeat measures that instead and
// silently passes. The first version of this fixture did exactly that.
func TestTheNameLimitIsTheSameNumberOfLettersInMnScripts(t *testing.T) {
	// Consonants cycled so no identical run forms, each carrying real marks.
	scripts := []struct {
		label string
		bases []string
		mark  string
	}{
		{"Latin", []string{"a", "b", "c", "d", "e"}, ""},
		{"Hebrew with vowel and dagesh", []string{"ב", "ג", "ד", "כ", "פ"}, "\u05bc\u05b6"},
		{"Arabic with shadda and fatha", []string{"ب", "ت", "ج", "د", "ر"}, "\u0651\u064e"},
		{"Thai with tone mark", []string{"ก", "ข", "ค", "ง", "จ"}, "\u0e49"},
	}
	build := func(s struct {
		label string
		bases []string
		mark  string
	}, letters int) string {
		var b strings.Builder
		for i := 0; i < letters; i++ {
			b.WriteString(s.bases[i%len(s.bases)])
			b.WriteString(s.mark)
		}
		return b.String()
	}
	for _, s := range scripts {
		t.Run(s.label, func(t *testing.T) {
			at := build(s, MaxMonikerRunes)
			if n := countAgainstLimit(at, countMarks); n != MaxMonikerRunes {
				t.Fatalf("fixture built %d letters, wanted %d", n, MaxMonikerRunes)
			}
			if _, err := SanitizeMoniker(at); err != nil {
				t.Errorf("exactly %d letters must be accepted in every Mn script: %v",
					MaxMonikerRunes, err)
			}
			over := build(s, MaxMonikerRunes+1)
			if _, err := SanitizeMoniker(over); !errors.Is(err, ErrTooLong) {
				t.Errorf("and %d must not be, got %v", MaxMonikerRunes+1, err)
			}
		})
	}
}

// The Mc boundary, asserted rather than left as prose: a Devanagari matra counts as a letter, so
// twelve syllables cost twenty-four. Pinned so that if somebody later adopts grapheme clusters,
// this fixture is what tells them the behaviour changed on purpose.
func TestSpacingMarksStillCountAsLetters(t *testing.T) {
	syllable := "शि" // consonant + a spacing matra (Mc)
	if n := countAgainstLimit(syllable, countMarks); n != 2 {
		t.Fatalf("a Devanagari matra is Mc and Go counts it as a letter: got %d, want 2 — "+
			"if this is 1 now, the counting rule moved to graphemes and the comment above "+
			"TestTheNameLimitIsTheSameNumberOfLettersInMnScripts needs rewriting", n)
	}
	// Which means the budget buys half as many syllables. Real names still fit; this records
	// the cost rather than claiming it is absent.
	bases := []string{"श", "क", "ग", "म", "र"}
	var b strings.Builder
	for i := 0; i < MaxMonikerRunes/2; i++ {
		b.WriteString(bases[i%len(bases)])
		b.WriteString("ि")
	}
	if _, err := SanitizeMoniker(b.String()); err != nil {
		t.Errorf("%d syllables is %d letters and must be accepted: %v",
			MaxMonikerRunes/2, MaxMonikerRunes, err)
	}
}

// THE BODY STILL COUNTS RUNES, and that asymmetry with the moniker is a decision, so it gets an
// assertion rather than only a comment. A mutation switching the body to letter-counting survived
// every other fixture here.
//
// The reason for the asymmetry is in sanitize.go at countMode: the inequality is real — pointed
// Hebrew runs about 1.9 runes per letter, so those writers get roughly 212 letters against an
// English writer's 400 — but 212 letters is still a long chat message, whereas 18 letters is
// somebody's name. Counting letters in a body would also move the binding constraint to
// MaxInputBytes and roughly double the worst-case stored message, which is a storage decision.
//
// This fixture discriminates the two rules: the text below is over the rune limit while being
// well under any letter limit, so it passes only if the body counts letters.
func TestTheBodyLimitCountsRunesNotLetters(t *testing.T) {
	bases := []string{"a", "b", "c", "d", "e", "f", "g"}
	build := func(letters int) string {
		var b strings.Builder
		for i := 0; i < letters; i++ {
			b.WriteString(bases[i%len(bases)])
			// U+0361 has no precomposed form, so NFKC leaves it as a separate rune. A
			// combining ACUTE would be composed away — "a" + U+0301 becomes "á", one rune —
			// which is how the first version of this fixture accidentally measured nothing.
			// That composition is also why the letters-vs-runes gap barely exists for Latin
			// and fully exists for Hebrew, Arabic, Thai and Devanagari, which do not
			// precompose: the scripts that pay the cost are exactly the ones NFKC cannot help.
			b.WriteString("\u0361")
		}
		return b.String()
	}
	// Half as many letters as runes, and two runes over the limit.
	over := build(MaxBodyRunes/2 + 1)
	runes, letters := len([]rune(over)), countAgainstLimit(over, countMarks)
	if runes <= MaxBodyRunes || letters >= MaxBodyRunes {
		t.Fatalf("fixture must be over the RUNE limit and under the LETTER one: "+
			"%d runes, %d letters, limit %d", runes, letters, MaxBodyRunes)
	}
	if _, err := SanitizeBody(over); !errors.Is(err, ErrTooLong) {
		t.Errorf("the body limit counts runes, so %d runes (%d letters) must be refused, got %v — "+
			"if this changed on purpose, MaxInputBytes becomes the binding constraint and §8's "+
			"storage numbers need revisiting", runes, letters, err)
	}
	// The paired positive: exactly at the limit is accepted, so the refusal above is the limit
	// and not something else in the pipeline objecting to the text.
	at := build(MaxBodyRunes / 2)
	if n := len([]rune(at)); n != MaxBodyRunes {
		t.Fatalf("fixture built %d runes, wanted %d", n, MaxBodyRunes)
	}
	if _, err := SanitizeBody(at); err != nil {
		t.Errorf("exactly %d runes must be accepted: %v", MaxBodyRunes, err)
	}
}

// EVERY PREPENDED CONCATENATION MARK MUST SURVIVE, and this is written against the Unicode
// PROPERTY rather than a list of codepoints, because a list is exactly what went wrong.
//
// erase() exempted nine hand-written codepoints described as "Arabic and Syriac format characters
// ... part of well-formed text in those scripts". That description names a real Unicode property,
// Prepended_Concatenation_Mark, and the list was that property as of an older Unicode. It had
// since gained four members, which fell through to the `remaining Cf` catch-all and were erased
// SILENTLY — no refusal, no diagnostic, just a character removed from somebody's message:
//
//	U+0890   ARABIC POUND MARK ABOVE
//	U+0891   ARABIC PIASTRE MARK ABOVE
//	U+110BD  KAITHI NUMBER SIGN
//	U+110CD  KAITHI NUMBER SIGN ABOVE
//
// Two Arabic CURRENCY marks, in an application about money and claims. A price losing its unit is
// worse than a message being refused, because nobody is told.
//
// Iterating the property means a fifth member added by a future Unicode is covered the day the Go
// toolchain learns about it, rather than the day somebody notices Arabic text is wrong.
func TestEveryPrependedConcatenationMarkSurvives(t *testing.T) {
	pcm, ok := unicode.Properties["Prepended_Concatenation_Mark"]
	if !ok {
		t.Skip("this Go toolchain does not expose the property; erase() reads the same table")
	}
	n := 0
	for r := rune(0); r <= 0x10FFFF; r++ {
		if !unicode.Is(pcm, r) {
			continue
		}
		n++
		// In context, because a lone format character trims to nothing.
		in := "x" + string(r) + "123"
		out, err := SanitizeBody(in)
		if err != nil {
			t.Errorf("U+%04X: a prepended concatenation mark must not be refused: %v", r, err)
			continue
		}
		if !strings.ContainsRune(out, r) {
			t.Errorf("U+%04X was ERASED: %q became %q — it belongs to the text of the script "+
				"that uses it, and dropping it is silent corruption", r, in, out)
		}
	}
	if n < 13 {
		t.Errorf("only %d members found; the property table looks wrong for this audit", n)
	}
	t.Logf("%d prepended concatenation marks, all preserved", n)
}

// THE PAIRED NEGATIVE: the invisibles that exist to make text read as something else are still
// erased. Without this the table above would pass for a sanitiser that erases nothing at all.
//
// LRM, RLM and ALM are in this list DELIBERATELY and they are the uncomfortable entries: they are
// bidi marks with legitimate use in mixed-direction text, not overrides. sanitize.go states the
// trade — the neutrals whose direction they resolve are claim numbers and amounts here — and this
// fixture pins the choice so that changing it is a decision rather than a drift.
func TestTheInvisiblesThatDisguiseTextAreStillErased(t *testing.T) {
	for _, c := range []struct {
		r     rune
		label string
	}{
		{0x00AD, "soft hyphen, splits a word that renders as one"},
		{0x034F, "combining grapheme joiner"},
		{0x200B, "zero-width space"},
		{0x200E, "LRM — a bidi mark, erased deliberately; see sanitize.go"},
		{0x200F, "RLM — likewise"},
		{0x061C, "ALM — likewise"},
		{0x202E, "right-to-left override, the Trojan Source class"},
		{0x2066, "left-to-right isolate"},
		{0x2069, "pop directional isolate"},
		{0x2060, "word joiner"},
		{0xFEFF, "zero-width no-break space"},
		{0x115F, "Hangul choseong filler, pads a name to impersonate"},
		{0x3164, "Hangul filler"},
		{0xFFF9, "interlinear annotation anchor"},
		{0xE0041, "tag character, a prompt-smuggling channel"},
	} {
		in := "x" + string(c.r) + "123"
		out, err := SanitizeBody(in)
		if err != nil {
			t.Errorf("U+%04X (%s): erasure is silent, not a refusal: %v", c.r, c.label, err)
			continue
		}
		if strings.ContainsRune(out, c.r) {
			t.Errorf("U+%04X (%s) survived: %q -> %q", c.r, c.label, in, out)
		}
	}
}

// The case that made this concrete: an Arabic price keeps its currency mark.
func TestAnArabicPriceKeepsItsCurrencyMark(t *testing.T) {
	// "the price" then ARABIC POUND MARK ABOVE then Arabic-Indic 50.
	const price = "السعر ࢐٥٠"
	out, err := SanitizeBody(price)
	if err != nil {
		t.Fatalf("refused: %v", err)
	}
	if out != price {
		t.Errorf("the mark was dropped:\n  in  %q\n  out %q", price, out)
	}
	if !strings.ContainsRune(out, 0x0890) {
		t.Error("U+0890 ARABIC POUND MARK ABOVE must survive; a figure without its unit is " +
			"a different figure")
	}
}
