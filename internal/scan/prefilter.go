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
	reOffPlatform = regexp.MustCompile(`(?i)\b(t\.me/|wa\.me/|telegram|whatsapp|discord\.gg/)`)
	reSecretAsk   = regexp.MustCompile(`(?i)(seed\s*phrase|secret\s*phrase|recovery\s*phrase|private\s*key|mnemonic)`)
	reEVMAddr     = regexp.MustCompile(`0x[0-9a-fA-F]{40}\b`)
	reGnoAddr     = regexp.MustCompile(`\bg1[0-9a-z]{38}\b`)
)

// Hint is what the prefilter concluded: a floor on the verdict, plus notes for the
// model.
type Hint struct {
	Floor string   // Clean unless something has no innocent reading
	Notes []string // passed to nothing yet; logged, and available to a future prompt
}

// Prefilter inspects a message. It runs on the SKELETON as well as the raw text,
// so "t·me/" and "5eed phrase" are caught along with the plain spellings — that is
// what chat.Skeleton is for.
func Prefilter(body string) Hint {
	h := Hint{Floor: Clean}
	sk := chat.Skeleton(body)
	// Skeleton drops punctuation, so the URL forms are checked against the raw
	// text and the word forms against both.
	switch {
	case reSecretAsk.MatchString(body), reSecretAsk.MatchString(sk):
		// Asking a stranger for their recovery words has one meaning.
		h.Floor = Scam
		h.Notes = append(h.Notes, "asks for a secret phrase or key")
	case reOffPlatform.MatchString(body), strings.Contains(sk, "tme"), strings.Contains(sk, "wame"):
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
	if n := WordlistRun(body); n >= 8 {
		// EIGHT, not four. BIP-39 is 2048 ordinary English words: at four, real
		// sentences match ("would allow any actor above…"), and a rule that fires
		// on prose is a rule somebody switches off.
		h.Floor = Scam
		h.Notes = append(h.Notes, "contains a long run of wordlist words")
	}
	return h
}

// bip39Run returns the longest run of consecutive wordlist words.
//
// A short embedded list rather than the full 2048: the point is to catch someone
// pasting or soliciting a recovery phrase, and a run of eight from this subset is
// already vanishingly unlikely in prose. Kept short deliberately — a partial list
// under-fires, which is the safe direction, where a full list plus a low threshold
// over-fires on ordinary English.
var bip39Subset = map[string]bool{}

func init() {
	for _, w := range strings.Fields(`abandon ability able about above absent absorb abstract
		absurd abuse access accident account accuse achieve acid acoustic acquire across act
		action actor actress actual adapt add addict address adjust admit adult advance advice
		aerobic affair afford afraid again age agent agree ahead aim air airport aisle alarm
		album alcohol alert alien all alley allow almost alone alpha already also alter always
		amateur amazing among amount amused analyst anchor ancient anger angle angry animal
		ankle announce annual another answer antenna antique anxiety any apart apology appear
		apple approve april arch arctic area arena argue arm armed armor army around arrange
		arrest arrive arrow art artefact artist artwork ask aspect assault asset assist assume
		asthma athlete atom attack attend attitude attract auction audit august aunt author
		auto autumn average avocado avoid awake aware away awesome awful awkward axis`) {
		bip39Subset[w] = true
	}
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
		if bip39Subset[w] {
			if run++; run > best {
				best = run
			}
		} else {
			run = 0
		}
	}
	return best
}
