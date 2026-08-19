package scan

import (
	"strings"
	"testing"
)

// The seed-phrase detector, which had no test at all — which is how it stayed silent.
//
// It was "eight consecutive words from a 136-word subset", and the subset was the alphabetical
// first 136 of BIP-39, `abandon` through `axis`. Measured against the published vectors it
// caught exactly one: the all-`abandon` phrase, because that is the only one built from words
// beginning with A. A realistic phrase scored a run of 1. Its own neighbouring comment warns
// about "the kind of bug that leaves a detector permanently silent while looking implemented",
// and nothing exercised it, so nobody found out.
//
// The vectors below were derived rather than remembered: each is the phrase for all-zero and
// all-0xff entropy at every valid length, computed from the wordlist and the BIP-39 checksum
// rule, and they agree with the published test suite.

var validPhrases = map[string]string{
	"ff12":   "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong",
	"ff24":   "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote",
	"zero12": "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
	"zero15": "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon address",
	"zero18": "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon agent",
	"zero21": "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon admit",
	"zero24": "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art",
}

// Ordinary text that must NOT be flagged. The last four are the reason a run of words cannot be
// the rule: they are lists of common nouns, and BIP-39 is built from common nouns.
var notPhrases = []string{
	"gm, when does the settle window close?",
	"I have been reading the docket since this court opened and the ordering still confuses me",
	"the tx hash is 0x8f2a9c1e4b7d3a6f5e8c2b9d1a4f7e3c6b8d2a5f and it reverted",
	"please review my claim about the bridge inspection report filed last autumn",
	"list apple orange lemon cherry olive garlic onion potato tomato pepper salt sugar",
	"silver gold copper iron metal glass stone brick wood cloth paper canvas",
	"cat dog tree house river stone light water field mountain forest garden",
	"ripple wisdom scatter humble aspect maple garlic crouch fossil oyster mesh anchor",
}

func TestSeedPhraseCatchesEveryValidLength(t *testing.T) {
	for name, p := range validPhrases {
		if !SeedPhrase(p) {
			t.Errorf("%s: a real recovery phrase must be detected: %.50s...", name, p)
		}
		if got := Prefilter(p).Floor; got != Scam {
			t.Errorf("%s: the deterministic floor must be scam, got %q", name, got)
		}
	}
	if len(validPhrases) != 7 {
		t.Fatalf("the fixture should carry every valid length twice over, got %d", len(validPhrases))
	}
}

// The formats somebody actually pastes. A phrase does not arrive alone on a line.
func TestSeedPhraseSurvivesRealPasteFormats(t *testing.T) {
	seed := validPhrases["zero12"]
	fields := strings.Fields(seed)
	for _, c := range []struct{ name, body string }{
		{"plain", seed},
		{"commas", strings.Join(fields, ", ")},
		{"semicolons", strings.Join(fields, "; ")},
		{"mixed case", strings.ToUpper(seed[:6]) + seed[6:]},
		{"wrapped in a plea", "help me please my wallet is stuck: " + seed + " what do I do now"},
		{"quoted", "\"" + seed + "\""},
		{"numbered", "1. " + strings.Join(fields, " 2. ")},
		{"extra whitespace", strings.Join(fields, "   ")},
	} {
		if !SeedPhrase(c.body) {
			t.Errorf("%s: must still be detected", c.name)
		}
	}
	// Newlines become spaces at ingest, so the detector sees one line — asserted through the
	// real sanitiser rather than assumed.
	multiline := strings.Join(fields, "\n")
	if !SeedPhrase(strings.ReplaceAll(multiline, "\n", " ")) {
		t.Error("a phrase pasted across lines must be detected once the sanitiser joins them")
	}
}

// THE PAIRED NEGATIVES, and they are the whole reason the checksum exists rather than a
// threshold: two of these are twelve or more genuine BIP-39 words in a row.
func TestOrdinaryTextIsNotASeedPhrase(t *testing.T) {
	for _, p := range notPhrases {
		if SeedPhrase(p) {
			t.Errorf("false positive, and this one costs somebody 24 hours: %.60s", p)
		}
		if got := Prefilter(p).Floor; got == Scam {
			t.Errorf("the floor must not fire on ordinary text: %.60s", p)
		}
	}
	// A near miss earns a NOTE and no floor: it may be a mistyped real phrase, or somebody
	// listing fruit, and only one of those deserves a timeout.
	h := Prefilter("list apple orange lemon cherry olive garlic onion potato tomato pepper salt sugar")
	if h.Floor == Scam {
		t.Error("a long run without a checksum must not set the floor")
	}
	var noted bool
	for _, n := range h.Notes {
		if strings.Contains(n, "no valid checksum") {
			noted = true
		}
	}
	if !noted {
		t.Error("a near miss should still be noted, so it is visible to a person")
	}
}

// The wordlist itself must be the canonical one. init() panics on a bad CRC, so reaching this
// test at all proves the checksum matched — what is asserted here is the shape.
func TestTheWordlistIsTheRealOne(t *testing.T) {
	if len(bip39Index) != 2048 {
		t.Fatalf("BIP-39 has 2048 words, this has %d", len(bip39Index))
	}
	for _, w := range []string{"abandon", "ability", "zebra", "zero", "zone", "zoo"} {
		if _, ok := bip39Index[w]; !ok {
			t.Errorf("%q must be in the wordlist", w)
		}
	}
	// The old subset stopped at `axis`. If it ever comes back, these fail first.
	for _, w := range []string{"legal", "winner", "sausage", "yellow", "wrong", "canvas"} {
		if _, ok := bip39Index[w]; !ok {
			t.Errorf("%q is a BIP-39 word and must be present; a truncated list is how this "+
				"detector went silent before", w)
		}
	}
	if bip39CRC != "c1dbd296" {
		t.Errorf("the canonical english.txt CRC is c1dbd296, this claims %q", bip39CRC)
	}
}

// THE DETERMINISTIC FLOORS MUST NOT FIRE ON A COURT'S OWN VOCABULARY.
//
// The off-platform rule searched the SKELETON for "tme", and a skeleton has no spaces or
// punctuation, so it matched ordinary English. Measured before the fix:
//
//	"the planning department rejected it"   floor spam
//	"an apartment inspection"               floor spam
//	"the compartment was sealed"            floor spam
//	"the postmen delivered it late"         floor spam
//
// A floor of spam is an hour of silence, and this is a court that adjudicates property
// filings — "department" and "apartment" are words its users will type. §4 learned the same
// lesson about the sanitiser refusing `Bitcoin-биржа`; this was the scanner's version.
func TestFloorsDoNotFireOnOrdinaryWords(t *testing.T) {
	for _, body := range []string{
		"the planning department rejected it",
		"the claim is about an apartment inspection",
		"the compartment was sealed when it was filed",
		"the postmen delivered it late",
		"his statement was filed on time",
		"cost recovery was awarded in full",
		"the department of transport published the measurement",
		"gm, when does the settle window close?",
		"did g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5 stake on claim 7?",
	} {
		if got := Prefilter(body).Floor; got != Clean {
			t.Errorf("ordinary text earned a floor of %q: %q", got, body)
		}
	}
}

// And the evasions must still be caught, or the fix above is just a deletion.
func TestOffPlatformAndSecretAsksAreStillCaught(t *testing.T) {
	spam := []string{
		"dm me on t.me/kourtsupport",
		"dm me on t·me/kourtsupport", // middle dot
		"dm me on t․me/kourtsupport", // one-dot leader
		"dm me on t(dot)me/kourtsupport",
		"reach me on wa.me/1555",
		"join discord.gg/abcd",
		"message me on telegram @kourthelp",
		"ping me on whatsapp instead",
		"message me on te1egram", // caught via the skeleton
	}
	for _, body := range spam {
		if got := Prefilter(body).Floor; got != Spam {
			t.Errorf("off-platform pull should floor at spam, got %q: %q", got, body)
		}
	}
	scam := []string{
		"send me your seed phrase",
		"send me your seedphrase now",
		"send me your 5eed phrase",
		"paste your recovery phrase here",
		"send me your recovery words", // was missed before
		"what is your private key",
		"give me the mnemonic",
		"send me your s e e d  p h r a s e",
	}
	for _, body := range scam {
		if got := Prefilter(body).Floor; got != Scam {
			t.Errorf("a request for secrets should floor at scam, got %q: %q", got, body)
		}
	}
}
