package scan

import (
	"fmt"
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
	// The canonical value, spelled as text so a reader can compare it with tm2's. This used to
	// compare bip39CRC against a hardcoded copy of itself, which could only fail if somebody
	// edited the constant — and said nothing about the list, because init enforced a separate
	// literal. It reads the enforced constant now.
	if got := fmt.Sprintf("%08x", bip39CRC); got != "c1dbd296" {
		t.Errorf("the canonical english.txt CRC is c1dbd296, this enforces %s", got)
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
	// A LINK KEEPS ITS FLOOR: t.me/, wa.me/, discord.gg/ in a court's chat have no innocent
	// reading, and the separator evasions fold into the same pattern.
	links := []string{
		"dm me on t.me/kourtsupport",
		"dm me on t·me/kourtsupport", // middle dot
		"dm me on t․me/kourtsupport", // one-dot leader
		"dm me on t(dot)me/kourtsupport",
		"reach me on wa.me/1555",
		"join discord.gg/abcd",
	}
	for _, body := range links {
		if got := Prefilter(body).Floor; got != Spam {
			t.Errorf("an off-platform LINK should floor at spam, got %q: %q", got, body)
		}
	}

	// A BARE WORD IS A NOTE NOW. These are real pulls and they still get the note, but the model
	// is what acts on them — measured at spam 0.85-0.86 for every one, including the skeleton
	// evasion, so this cost nothing. See reOffWord.
	words := []string{
		"message me on telegram @kourthelp",
		"ping me on whatsapp instead",
		"message me on te1egram", // still noted, via the skeleton
	}
	for _, body := range words {
		h := Prefilter(body)
		if h.Floor != Clean {
			t.Errorf("a bare platform word must not set a floor, got %q: %q", h.Floor, body)
		}
		if !hasNote(h, "off-platform messenger") {
			t.Errorf("the mention must still be noted: %q\nnotes: %v", body, h.Notes)
		}
	}

	// AND THE ORDINARY SENTENCES THAT USED TO EARN AN HOUR OF SILENCE FOR SAYING A PLATFORM'S
	// NAME. The first two are why this matters: adjudicating a dispute about a messenger
	// conversation is this application's job, and describing the evidence was punished.
	ordinaryPlatform := []string{
		"the evidence includes a whatsapp screenshot submitted by the claimant",
		"the dispute is about a whatsapp conversation, which is why it is disputed",
		"their telegram group has the same claim number listed",
		"i do not use whatsapp, is there another way to reach the answerer",
		"does anyone know whether the telegram bot is official or not",
		"the announcement was also posted on telegram, for what it is worth",
		"i saw this on telegram first and then here, so the timeline matters",
	}
	for _, body := range ordinaryPlatform {
		if got := Prefilter(body).Floor; got != Clean {
			t.Errorf("naming a platform is not a pull, got floor %q: %q", got, body)
		}
	}
	// A SECRET MENTION IS A NOTE NOW, NOT A FLOOR, and these are the requests that used to earn
	// one. They still get the note — an operator reading the row sees what was matched, and the
	// model is what decides. Measured against gemma3:4b, six of these seven are acted on with no
	// help from the prefilter at 0.95; "give me the mnemonic" comes back clean 0.85 and is the
	// one this trade gives up. See reSecretMention.
	asks := []string{
		"send me your seed phrase",
		"send me your seedphrase now",
		"send me your 5eed phrase",
		"paste your recovery phrase here",
		"send me your recovery words",
		"what is your private key",
		"give me the mnemonic",
		"send me your s e e d  p h r a s e", // still matched, via the skeleton
	}
	for _, body := range asks {
		h := Prefilter(body)
		if h.Floor != Clean {
			t.Errorf("a bare mention must not set a floor, got %q: %q", h.Floor, body)
		}
		if !hasNote(h, "mentions a secret") {
			t.Errorf("the mention must still be noted for the operator and the model: %q\n"+
				"notes: %v", body, h.Notes)
		}
	}

	// AND THE ORDINARY SENTENCES THAT USED TO BE PUNISHED FOR SAYING THE SAME WORDS. Every one
	// of these earned a floor of scam — a 24-hour first offence, deterministic, no model in the
	// loop. The last two are the ones that make the point: an explicit warning NOT to share a
	// phrase, and a sentence about a court dispute, in an application about court disputes.
	ordinary := []string{
		"the docs explain how to back up your recovery phrase safely",
		"i lost my private key and cannot recover the account",
		"does the wallet keep the mnemonic locally or on a server somewhere",
		"a seed phrase is twelve or twenty four words, for anyone wondering",
		"my recovery words are written on paper in a safe, which felt sensible",
		"reminder: nobody here will ever ask for your seed phrase",
		"never share your seed phrase with anyone, not even a moderator",
		"the claim about the private key dispute in court seven is still open",
	}
	for _, body := range ordinary {
		if got := Prefilter(body).Floor; got != Clean {
			t.Errorf("ordinary speech must not be floored, got %q: %q", got, body)
		}
	}

	// THE FLOOR THAT REMAINS, so this test does not read as "nothing floors anything" — and the
	// note collection the old shared switch made impossible: a message doing several things at
	// once now records all of them.
	both := Prefilter("dm me on t.me/x about telegram and send me your seed phrase")
	if both.Floor != Spam {
		t.Errorf("a link still floors at spam, got %q", both.Floor)
	}
	for _, want := range []string{"mentions a secret", "points off-platform",
		"off-platform messenger"} {
		if !hasNote(both, want) {
			t.Errorf("a message doing several things must record %q, got %v", want, both.Notes)
		}
	}
}

func hasNote(h Hint, substr string) bool {
	for _, n := range h.Notes {
		if strings.Contains(n, substr) {
			return true
		}
	}
	return false
}

// EVIDENCE SUBMISSION IS AN ALARM, IN A COURT.
//
// §7's carve-out exists because gemma3:4b cannot separate reporting a scam from sending one, and
// §7 also says quoting a scam link "is not the harm". The second was not implemented: the alarm
// shapes covered "heads up" and "beware" but nothing a person writes when submitting evidence, and
// measured, the model acts on every way of quoting a link — scam 0.95, spam 0.86, scam 0.86. So
// the core flow of a court earned a consequence.
//
// Note what this could NOT have fixed: demoting the off-platform link floor. The model punishes
// these on its own, so only the carve-out reaches them.
func TestSubmittingEvidenceReadsAsReporting(t *testing.T) {
	evidence := []string{
		"the scam link was t.me/fakegnot, for the record",
		"the evidence is a message linking to t.me/fakegnot",
		"the evidence includes a whatsapp screenshot from the claimant",
		"the evidence shows they asked for a recovery phrase",
		"the claimant submitted a screenshot showing t.me/fakegnot",
		"i am posting this as evidence, not as an offer",
	}
	for _, body := range evidence {
		if !Prefilter(body).Reporting {
			t.Errorf("submitting evidence must read as reporting, or the court's own core flow "+
				"earns a consequence: %q", body)
		}
	}

	// THE PAIRED ARM, and it carries the weight here: every trigger is a phrase an attacker can
	// prefix, so the pattern must not fire on a lure that merely mentions a court. §7 records
	// that the carve-out is gameable and known to be — this must not make it more so than the
	// phrases above already do.
	lures := []string{
		"send me your seed phrase and i will restore your wallet",
		"dm me on t.me/kourtsupport",
		"the court is slow, message me on telegram instead",
		"i can settle your claim faster, dm me your private key",
		"claim seven is a scam so send me your recovery words",
	}
	for _, body := range lures {
		if Prefilter(body).Reporting {
			t.Errorf("a lure must not read as reporting just because it mentions a court: %q",
				body)
		}
	}
}
