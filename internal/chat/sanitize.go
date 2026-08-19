// Package chat is the off-chain court chat: storage, throttling and enforcement.
//
// Nothing here touches a realm. Chat needs a client IP, a wall clock, and a
// mutable moderation record, and a Gno realm has none of those — no network, a
// deterministic VM, and a storage deposit per byte. Chat on chain would also be
// permanent and unmoderatable, which is the opposite of what a kick/ban system
// is for.
package chat

import (
	"errors"
	"strings"
	"unicode"
	"unicode/utf8"

	"golang.org/x/text/unicode/norm"
)

// TWO JOBS, TWO FUNCTIONS. The first draft of this file did both at once and did
// both badly — measured, not supposed: it turned "👨‍👩‍👧" into three separate
// people, "❤️" into "❤", the Persian "می‌روم" into the wrong word, and it
// REFUSED "Bitcoin-биржа" and "alice@почта.рф" as homoglyph attacks — while
// Cherokee "ᏚᏟᎪᎷ" (which reads as SCAM) and combining-mark "s͡c͡a͡m" passed
// untouched. Too aggressive on real text and too permissive on the actual evasion
// class, because one string cannot be both faithfully displayable and
// aggressively comparable.
//
//	Sanitize — makes text safe to STORE and DISPLAY, preserving meaning. This is
//	           what a reader sees and what the scanner is shown. Conservative: it
//	           removes only what cannot be displayed honestly.
//	Skeleton — makes text COMPARABLE. Folds confusables, drops everything
//	           decorative. Never displayed, never stored as a body. Evasion
//	           resistance lives here: duplicate detection and the scanner's
//	           "what does this actually say" signal.
//
// Evasion resistance had to move out of Sanitize because mutating displayed text
// to fight homoglyphs corrupts the text of everyone whose alphabet is not English.

// Limits, in RUNES rather than bytes. A byte limit is a length limit for English
// and a censor for everything else: "мошенничество" is 26 bytes.
const (
	MaxBodyRunes    = 400
	MaxMonikerRunes = 24
	maxRunRunes     = 8 // identical consecutive runes, TRUNCATED rather than refused

	// maxMarks caps combining marks on ONE base character, and it was 3, which
	// refuses scripture.
	//
	// Measured. `שֶּֽׁ` — shin with dagesh, sin-dot, segol and meteg — is ordinary
	// pointed Hebrew and carries four marks; add a cantillation accent, as a
	// pointed bible does, and it carries five. At 3 both were REFUSED OUTRIGHT,
	// and the message a Hebrew speaker got was that their message "stacks too
	// many marks on one character". Fully-voweled Arabic (`اللَّٰهُمَّ`) and
	// Hebrew niqqud with cantillation both land exactly ON 3, so the cap had no
	// headroom at all for the scripts that need it most:
	//
	//	consonant + vowel                      1   accepted
	//	+ dagesh                               2   accepted
	//	shin + dagesh + sin-dot + vowel        3   accepted
	//	+ meteg                                4   REFUSED
	//	+ cantillation accent as well          5   REFUSED
	//
	// AND IT WAS DEFENDING NOTHING. This cap was labelled "Zalgo defence", but
	// evasion resistance lives in Skeleton by explicit design — see the top of
	// this file — and Skeleton already folds every mark away: "s͡c͡a͡m", "s̈c̈äm̈" and a
	// 14-mark monster all reduce to exactly "scam", and "send me your s̈ëëd̈
	// p̈ḧräs̈ë" reduces to "sendmeyourseedphrase", which the prefilter matches on
	// its own. Raising this cap costs zero evasion resistance, and that is
	// measured rather than argued: see TestSkeletonFoldsAnyMarkStackToThePlainWord.
	//
	// What remains is the LAYOUT argument, which is real but only at volume: a
	// stack sits above its character until roughly a dozen marks and only then
	// smears up through the line above. So the cap goes above real text's ceiling
	// rather than on top of it — 8, three clear of the measured maximum of five,
	// with room for scripts not sampled here, and still far below where a stack
	// damages a page.
	maxMarks = 8

	// maxJoinerRun caps CONSECUTIVE ZWJ/ZWNJ/VS16, and the ratio below caps their density.
	// Both replaced a single whole-message total of 16, which was measured refusing ordinary
	// text:
	//
	//	Persian prose, 20 ZWNJ words, 177 runes    REFUSED
	//	six family emoji, 48 runes                 REFUSED
	//
	// §4 exists because the first sanitiser refused `Bitcoin-биржа` and `alice@почта.рф`, and
	// this was the same failure surviving in a different constant: ZWNJ is orthographically
	// required in Persian, so a total cap punishes the language rather than the abuse.
	//
	// The abuse is DENSITY, not quantity. A run of bare joiners is invisible padding; joiners
	// outnumbering the visible characters is a message that is mostly nothing. Both are
	// bounded here, and neither bound is what stops joiner-interleaved evasion — `Skeleton`
	// already reduces "s‍c‍a‍m" to "scam", measured, so the comparison path never depended on
	// this cap at all.
	//
	// 4 rather than 2 because legitimate sequences do stack them: ❤️‍🔥 is heart, VS16, ZWJ,
	// fire — two consecutive joiners in one glyph — and complex emoji use more.
	maxJoinerRun = 4

	// MaxInputBytes is a cruder ceiling on what we will even look at, and it
	// exists because the rules below fight each other: collapsing runs turns ten
	// megabytes of "aaaa..." into eight characters, so the rune limit alone would
	// ACCEPT that message after normalising all ten megabytes first. The rune
	// limit is the product rule; this is the DoS guard, checked before any work.
	MaxInputBytes = 4096
)

var (
	ErrEmpty    = errors.New("message is empty")
	ErrTooLong  = errors.New("message is too long")
	ErrControl  = errors.New("message contains control characters")
	ErrOversize = errors.New("message is far too long to process")
	ErrJoiners  = errors.New("message contains too many invisible joiners")
	ErrMarks    = errors.New("message stacks too many marks on one character")
)

// joiner reports the invisible characters that are PRESERVED, because writing
// systems require them: ZWNJ is orthographically necessary in Persian, ZWJ
// carries Indic conjuncts and holds emoji sequences together, and VS16 selects
// emoji presentation. Stripping these was the first draft's worst bug — it
// silently rewrote users' words. They are capped in number instead: two is a
// family emoji, four hundred is an attack.
func joiner(r rune) bool {
	return r == 0x200C || r == 0x200D || r == 0xFE0F
}

// erase reports the invisibles with no legitimate use in a chat line — the ones
// whose purpose is to make text render as something other than what it is.
//
//	bidi overrides     reorder visible text arbitrarily
//	tag characters     invisible, and a known prompt-smuggling channel
//	soft hyphen, CGJ   split a word that still renders as one ("s­c­a­m")
//	Hangul fillers     pad a name to impersonate another
//	remaining Cf       formatting with no place in a single line
//
// Arabic and Syriac format characters (U+0600-0605, U+06DD, U+070F, U+08E2) are
// part of well-formed text in those scripts and are deliberately NOT erased.
func erase(r rune) bool {
	switch {
	case joiner(r):
		return false
	case r >= 0x0600 && r <= 0x0605, r == 0x06DD, r == 0x070F, r == 0x08E2:
		return false // required by the scripts that use them
	case r == 0x00AD, r == 0x034F:
		return true
	case r >= 0x200B && r <= 0x200F: // ZWSP, and the LRM/RLM pair
		return true
	case r >= 0x202A && r <= 0x202E, r >= 0x2066 && r <= 0x2069: // bidi
		return true
	case r >= 0x2060 && r <= 0x2064, r == 0xFEFF, r == 0x180E:
		return true
	case r == 0x115F, r == 0x1160, r == 0x3164, r == 0xFFA0: // Hangul fillers
		return true
	case r >= 0xFE00 && r <= 0xFE0E: // variation selectors except VS16
		return true
	case r >= 0xE0000 && r <= 0xE007F: // tag characters
		return true
	case unicode.Is(unicode.Cf, r):
		return true
	}
	return false
}

// clean is the shared core, and it is conservative on purpose: it removes what
// cannot be displayed honestly, refuses what cannot be displayed at all, and does
// not try to defeat a determined evader. That is Skeleton's job.
//
// NFKC first, because NFC is a CANONICAL form ("are these the same character")
// where this needs a COMPATIBILITY form ("does this render as that"). NFC leaves
// mathematical bold and fullwidth alone: "𝐬𝐜𝐚𝐦" and "ｓｃａｍ" read perfectly to a
// human and tokenise as unrelated junk. NFKC folds both, and folding them is
// display-safe.
//
// The result is stored once and read by both the renderer and the scanner, so the
// two can never disagree about what a message says.
func clean(s string, maxRunes int) (string, error) {
	if len(s) > MaxInputBytes {
		return "", ErrOversize
	}
	s = norm.NFKC.String(s)

	var b strings.Builder
	b.Grow(len(s))
	var last rune = -1
	run, marks := 0, 0
	joiners, joinerRun, bases := 0, 0, 0
	for _, r := range s {
		// Ranging a string yields U+FFFD for invalid UTF-8, so this catches
		// malformed input and a literal replacement character alike.
		if r == utf8.RuneError || !utf8.ValidRune(r) {
			return "", ErrControl
		}
		if erase(r) {
			continue
		}
		if joiner(r) {
			joiners++
			if joinerRun++; joinerRun > maxJoinerRun {
				return "", ErrJoiners
			}
			b.WriteRune(r)
			continue // not a base character, and it breaks no run
		}
		joinerRun = 0
		if unicode.Is(unicode.Mn, r) || unicode.Is(unicode.Me, r) {
			// Stacked marks smear over neighbouring text and tokenise as noise:
			// both an evasion and a way to wreck a page's layout. A handful is
			// ordinary in many scripts.
			if marks++; marks > maxMarks {
				return "", ErrMarks
			}
			b.WriteRune(r)
			continue
		}
		marks = 0
		if r == '\t' || r == '\n' || r == '\r' {
			r = ' ' // a chat line is one line
		}
		if unicode.IsControl(r) {
			return "", ErrControl
		}
		if unicode.IsSpace(r) {
			r = ' '
			if last == ' ' {
				continue
			}
		}
		if r == last {
			if run++; run >= maxRunRunes {
				continue
			}
		} else {
			run = 0
		}
		b.WriteRune(r)
		bases++
		last = r
	}

	// Density, checked once at the end because a ratio is meaningless part-way through a
	// string. Joiners must not outnumber the characters a reader can see: Persian prose runs
	// about 0.13, a message of family emoji about 0.6, and "hello" with a hundred bare ZWJ
	// wedged in runs 10.
	if joiners > bases {
		return "", ErrJoiners
	}

	out := strings.TrimSpace(b.String())
	if out == "" {
		return "", ErrEmpty
	}
	if n := len([]rune(out)); n > maxRunes {
		return "", ErrTooLong
	}
	return out, nil
}

// SanitizeBody normalises a chat message for storage and display.
//
// Note what it no longer refuses. Chat-template markers ("<|", "[INST]") were
// rejected in the first draft, which false-positived on the only audience this
// application has: people in a crypto court paste code, diffs and markup. The
// prompt boundary is the right place for that problem, and the scanner solves it
// by passing the message as a structured JSON field rather than as prose a model
// might read as a frame.
func SanitizeBody(s string) (string, error) { return clean(s, MaxBodyRunes) }

// SanitizeMoniker normalises a display name: same rules, shorter, and with no
// spaces, because a name is one token and a padded one impersonates.
func SanitizeMoniker(s string) (string, error) {
	out, err := clean(s, MaxMonikerRunes)
	if err != nil {
		return "", err
	}
	if out = strings.Join(strings.Fields(out), ""); out == "" {
		return "", ErrEmpty
	}
	return out, nil
}

// confusables folds the letters actually used to disguise text into their Latin
// lookalikes.
//
// HOW GOOD THIS TABLE IS, stated plainly: it is HAND-BUILT, not generated from
// Unicode's confusables.txt, and it is therefore incomplete and partly a
// judgement about glyph shapes. Writing it, I mapped the wrong Cherokee codepoint
// for "M" — U+13E7 instead of U+13B7 — and only the test caught it, which is
// exactly the error mode a hand-built table has. Treat a miss as expected rather
// than surprising: Skeleton is a signal for the scanner and for duplicate
// detection, and nothing that punishes anybody may depend on this table being
// exhaustive. Generating it from confusables.txt is the real fix and is worth
// doing if this ever carries weight.
//
// Scope: Cyrillic and Greek (the classic pair), plus Cherokee and Armenian, which
// have whole-alphabet lookalikes and both of which passed the first draft
// untouched.
//
// Only ever applied when building a Skeleton. Applying it to displayed text would
// rewrite Russian as gibberish, which is precisely the bug this replaced.
var confusables = map[rune]rune{
	// Cyrillic
	'а': 'a', 'в': 'b', 'с': 'c', 'е': 'e', 'н': 'h', 'к': 'k', 'м': 'm',
	'о': 'o', 'р': 'p', 'т': 't', 'у': 'y', 'х': 'x', 'і': 'i', 'ѕ': 's',
	'ј': 'j', 'ԁ': 'd',
	// Greek
	'α': 'a', 'β': 'b', 'ε': 'e', 'η': 'n', 'ι': 'i', 'κ': 'k', 'ο': 'o',
	'ρ': 'p', 'τ': 't', 'υ': 'u', 'χ': 'x', 'ν': 'v', 'μ': 'm',
	// Cherokee: "ᏚᏟᎪᎷ" reads as SCAM
	'Ꮪ': 's', 'Ꮢ': 'r', 'Ꮖ': 't', 'Ꭺ': 'a', 'Ꮷ': 'm', 'Ꮯ': 'c', 'Ꭰ': 'd',
	'Ꭼ': 'e', 'Ꮋ': 'h', 'Ꭶ': 'g', 'Ꮮ': 'l', 'Ꮎ': 'o', 'Ꮲ': 'p', 'Ꮩ': 'v',
	'Ꮃ': 'w', 'Ꭹ': 'y', 'Ꮶ': 'k', 'Ꮕ': 'n', 'Ꮓ': 'z',
	0x13B7: 'm', // LU, the M in the classic "ᏚᏟᎪᎷ"
	// Armenian
	'ո': 'n', 'օ': 'o', 'ս': 'u', 'ա': 'a', 'ե': 'e', 'ի': 'i', 'լ': 'l',
	'ց': 'g', 'ք': 'f', 'ղ': 'q',
	0x0576: 'u', 0x0582: 'w', // NOW and YIWN; found by probing, not by reading
	// Digit and symbol swaps, the cheapest evasion of all
	'0': 'o', '1': 'l', '3': 'e', '4': 'a', '5': 's', '7': 't',
	'@': 'a', '$': 's', '!': 'i',
}

// fold maps a rune through the confusable table, trying the case the table
// happens to be keyed on so a caller need not know which that is.
func fold(r rune) rune {
	if c, ok := confusables[r]; ok {
		return c
	}
	if c, ok := confusables[unicode.ToLower(r)]; ok {
		return c
	}
	if c, ok := confusables[unicode.ToUpper(r)]; ok {
		return c
	}
	return r
}

// Skeleton reduces a message to a form fit for COMPARING it with another message
// or with a pattern. Lossy on purpose; never shown to anybody and never stored as
// a body.
//
// What it defeats, which Sanitize deliberately does not: whole-script
// confusables, combining-mark noise, spacing and punctuation tricks, digit
// substitution, and case. "ᏚᏟᎪᎷ", "s͡c͡a͡m", "S C A M" and "5cam" all reduce to
// "scam", so a rule written once matches every spelling of it.
func Skeleton(s string) string {
	// NOT lowercased first. Folding has to happen before case does, because the
	// table is keyed on the case each script actually uses — Cherokee's
	// lookalikes are its UPPERCASE letters and Cyrillic's are its lowercase
	// ones. Lowercasing first turned "ᏚᏟᎪᎷ" into lowercase Cherokee that matched
	// nothing.
	s = norm.NFKD.String(s)
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		if unicode.Is(unicode.Mn, r) || unicode.Is(unicode.Me, r) || unicode.Is(unicode.Cf, r) {
			continue // marks and invisibles mean nothing to a comparison
		}
		r = fold(r)
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(unicode.ToLower(r))
		}
	}
	return b.String()
}
