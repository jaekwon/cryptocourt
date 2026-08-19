package scan

import (
	"regexp"
	"strings"

	"github.com/jaekwon/kourt/internal/chat"
)

// Deterministic detectors, run before the model and immune to being argued with.
//
// WHAT THEY MAY AND MAY NOT CONCLUDE is the whole design here, because this is a
// crypto court: `g1…` addresses and `0x…` hashes are the application's VOCABULARY.
// The page validates a g1 address as configuration, /me is keyed on one, and the
// product exists to adjudicate claims about on-chain events. "Did g1abc… actually
// stake on claim 7?" is the modal legitimate message. So an address on its own is
// never a finding — it only raises a flag the model is told about.
//
// What these do earn on their own is the off-platform lure, which has no innocent
// reading in a court's chat.
var (
	// Split in two, because the two halves need different normalisation and sharing one
	// pattern across both produced a false positive on ordinary English — see foldDots.
	reOffURL  = regexp.MustCompile(`(?i)\b(t\.me/|wa\.me/|discord\.gg/)`)
	reOffWord = regexp.MustCompile(`(?i)(telegram|whatsapp|discordgg)`)
	// "words" and "seed" alongside "phrase": "send me your recovery words" is the same request
	// and was not matched, measured.
	reSecretAsk = regexp.MustCompile(`(?i)((seed|secret|recovery)\s*(phrase|words|seed)|private\s*key|mnemonic)`)
	reEVMAddr   = regexp.MustCompile(`0x[0-9a-fA-F]{40}\b`)
	reGnoAddr   = regexp.MustCompile(`\bg1[0-9a-z]{38}\b`)
)

// Hint is what the prefilter concluded: a floor on the verdict, plus notes for the
// model.
type Hint struct {
	Floor string   // Clean unless something has no innocent reading
	Notes []string // logged, and available to a future prompt
	// Reporting means the message looks like somebody WARNING about abuse rather
	// than committing it. See Reporting.
	Reporting bool

	// Secret means the message CONTAINS a disclosed secret, not a request for one — today,
	// a BIP-39 phrase whose checksum validates.
	//
	// It exists because the reporting carve-out withholds the whole consequence, and that
	// conflates two decisions. Withholding the TIMEOUT from a possible reporter is the point:
	// kicking somebody for warning the room is the perverse outcome §7 describes. Withholding
	// the HIDE is different, and measured: "fyi here are my words: <a real phrase>" was
	// recorded as scam and left on screen indefinitely, because the message opened with three
	// letters.
	//
	// A recovery phrase quoted by a well-meaning reporter is still a recovery phrase in a
	// public room. The harm is the disclosure, not the intent, so the message goes out of
	// sight whoever posted it — and nobody is punished for it.
	//
	// Deliberately NOT set for the off-platform floor. A warning that quotes a scam link
	// ("careful, that t.me/x is fake") is useful, and the panel never renders a URL as an
	// anchor, so quoting one is not itself the harm. A secret is different in kind: quoting it
	// IS the harm.
	Secret bool
}

// reReporting matches the shapes a person uses when they are raising an alarm
// rather than sounding one.
var reReporting = regexp.MustCompile(`(?i)(is (this|it) (a )?(scam|legit|real|phishing)|` +
	`do ?n[o']?t click|don't fall for|be ?ware|beware|warning|heads up|` +
	`careful|scam alert|i (just )?(got|received|was sent)|someone (just )?(sent|messaged|dm)|` +
	`mods,? (please )?(look|check|see)|reporting this|fyi)`)

// Reporting reports whether a message reads as a warning about abuse rather than an
// instance of it.
//
// WHY THIS EXISTS, measured rather than assumed: gemma3:4b cannot tell the two apart.
// Asked about "someone just messaged me this, is it a scam? <lure>" it answers scam
// 0.98; asked about "heads up, there is a fake GNOT airdrop going around in DMs" —
// which contains no lure at all — it answers scam 0.95. It is classifying the SUBJECT
// of the message, not the ACT. Every reporting variant tested came back flagged.
//
// Left alone, the consequence is perverse: a user warning the court gets a 24h
// timeout AND their warning hidden, which is the exact opposite of what a scam
// detector is for.
//
// So a message that looks like a report is not punished automatically. It is
// classified, recorded, and left for a person — the same treatment `unknown` gets,
// for the same reason: the model has been shown not to be able to answer.
//
// THE COST, stated plainly: a scammer who appends "is this a scam?" to their lure
// buys immunity from the automated timeout, and their message stays visible. That is
// a real weakening. The alternative is kicking people for warning each other, and
// between an attacker who has to add six words and a bystander who gets punished for
// helping, this is the better failure.
func Reporting(body string) bool {
	return reReporting.MatchString(body)
}

// foldDots maps the characters people substitute for a dot back to a dot.
//
// URL evasion is separator substitution — "t·me/x", "t(dot)me/x" — so that is what gets folded,
// and only that. The previous approach searched the SKELETON for "tme", and a skeleton has no
// spaces or punctuation, so it matched ordinary English: measured, "the planning department
// rejected it" earned a floor of spam, as did "apartment", "compartment" and "postmen". In a
// court that adjudicates property filings those are words people use, and a floor of spam is an
// hour of silence for saying one.
//
// Folding a targeted set cannot do that: "department" contains no dot substitute, and the
// pattern it is matched against still requires "t.me/" with its slash.
func foldDots(s string) string {
	r := strings.NewReplacer(
		"·", ".", "․", ".", "‧", ".", "•", ".",
		"(dot)", ".", "[dot]", ".", "{dot}", ".", " dot ", ".", "-dot-", ".",
	)
	return r.Replace(s)
}

// Prefilter inspects a message. It runs on the SKELETON as well as the raw text,
// so "te1egram" and "5eed phrase" are caught along with the plain spellings — that is
// what chat.Skeleton is for. URL forms are matched on dot-folded raw text instead, because
// a skeleton is one long word and "tme" lives inside "department".
func Prefilter(body string) Hint {
	h := Hint{Floor: Clean}
	sk := chat.Skeleton(body)
	// The URL forms are checked against dot-folded raw text, the word forms against raw and
	// skeleton. Which normalisation belongs to which is the whole lesson of foldDots.
	switch {
	case reSecretAsk.MatchString(body), reSecretAsk.MatchString(sk):
		// Asking a stranger for their recovery words has one meaning.
		h.Floor = Scam
		h.Notes = append(h.Notes, "asks for a secret phrase or key")
	case reOffURL.MatchString(foldDots(body)), reOffWord.MatchString(body), reOffWord.MatchString(sk):
		// Not a finding on its own — plenty of people mention Telegram — but a
		// floor of spam is fair for an unsolicited off-platform pull.
		h.Floor = Spam
		h.Notes = append(h.Notes, "points off-platform")
	}
	if reEVMAddr.MatchString(body) {
		h.Notes = append(h.Notes, "contains an EVM address")
	}
	if reGnoAddr.MatchString(body) {
		h.Notes = append(h.Notes, "contains a gno address")
	}
	if Reporting(body) {
		h.Reporting = true
		h.Notes = append(h.Notes, "reads as a report or warning, not an act")
	}
	// A VALID CHECKSUM, not a run of words. The floor here sets `scam`, which costs somebody
	// 24 hours, so it has to mean what it says.
	//
	// The rule was "eight consecutive wordlist words", against a 136-word subset. Measured, it
	// caught one published test vector — the all-`abandon` one, the only phrase built from
	// words starting with A — and a realistic phrase scored a run of 1. With the full 2048-word
	// list the runs are right but the rule is not: BIP-39 is drawn from short common English
	// nouns, so "list apple orange lemon cherry olive garlic onion potato tomato pepper salt
	// sugar" runs 13 and a list of materials runs 12. The shortest real phrase is 12 words, so
	// no threshold separates them and raising the bar only stops catching phrases.
	//
	// SeedPhrase checks the checksum instead, which is the thing that makes a phrase a phrase.
	// A 12-word noun list passes by luck one time in 16, and must also be exactly a phrase
	// length. Measured: six published vectors caught, including comma-separated and buried in a
	// plea; five noun lists rejected, including twelve genuine BIP-39 words in an order I made
	// up — which is correct, because an invented sequence cannot restore anybody's wallet.
	if SeedPhrase(body) {
		h.Floor = Scam
		h.Secret = true
		h.Notes = append(h.Notes, "contains a valid BIP-39 recovery phrase")
	} else if n := WordlistRun(body); n >= 12 {
		// A near miss gets a note and NO floor. It may be a mistyped real phrase, which is a
		// disclosure worth a person's eyes, and it may equally be somebody listing fruit — and
		// the one thing this must not do is hand a timeout to the second.
		h.Notes = append(h.Notes, "a long run of wordlist words, but no valid checksum")
	}
	return h
}

// WordlistRun counts the longest run of consecutive wordlist words.
//
// It runs on the RAW text, not the skeleton: a skeleton has no spaces, so
// strings.Fields on one returns a single token and the run is always 0 or 1. An
// earlier version of this file called it with the skeleton and therefore counted
// nothing at all — the kind of bug that leaves a detector permanently silent while
// looking implemented.
func WordlistRun(body string) int {
	best, run := 0, 0
	for _, w := range strings.Fields(strings.ToLower(body)) {
		w = strings.Trim(w, ".,;:!?\"'()[]")
		if _, ok := bip39Index[w]; ok {
			if run++; run > best {
				best = run
			}
		} else {
			run = 0
		}
	}
	return best
}
