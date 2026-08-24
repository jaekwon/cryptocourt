package scan

import (
	"testing"

	"github.com/jaekwon/kourt/internal/chat"
)

// Every dot form a human reads as a dot must reach the same floor, and the reason
// this test exists rather than a comment is that two of them did not.
//
// foldDots handles the visually-similar dots; clean()'s NFKC handles the
// COMPATIBILITY ones before anything reads the body. Between them they covered
// ． U+FF0E, ﹒ U+FE52 and ․ U+2024 — and missed 。 U+3002 and ｡ U+FF61, because an
// ideographic full stop has no NFKC decomposition and ｡ folds to 。 rather than to
// a dot. "join t。me/scamroom" scored Clean, stored verbatim, reading as a link to
// anyone who saw it.
//
// The body is sanitised first because that is what the POST path does: Prefilter
// runs on what the store holds, never on the raw argument, so a test that skips
// SanitizeBody would measure a normalisation the running system never applies.
func TestEveryDotFormReachesTheSameFloor(t *testing.T) {
	for _, c := range []struct{ name, body string }{
		{"plain", "join t.me/scamroom"},
		{"middle dot U+00B7", "join t·me/scamroom"},
		{"one dot leader U+2024", "join t․me/scamroom"},
		{"fullwidth U+FF0E", "join t．me/scamroom"},
		{"small full stop U+FE52", "join t﹒me/scamroom"},
		{"ideographic U+3002", "join t。me/scamroom"},
		{"halfwidth ideographic U+FF61", "join t｡me/scamroom"},
		{"spelled (dot)", "join t(dot)me/scamroom"},
	} {
		clean, err := chat.SanitizeBody(c.body)
		if err != nil {
			t.Fatalf("%s: the body must survive sanitising to be worth filtering: %v", c.name, err)
		}
		if got := Prefilter(clean).Floor; got != Spam {
			t.Errorf("%s: floor %v, want spam — %q points off-platform and reads as a link",
				c.name, got, clean)
		}
	}
}

// AND THE ORDINARY SENTENCE THE FOLD MUST NOT PUNISH. An ideographic full stop is
// ordinary punctuation in Japanese and Chinese; folding it to "." only matters
// where it completes an off-platform host, because reOffURL still requires the
// slash. Without this arm the fix above would be a rule with no stated limit.
func TestAnIdeographicFullStopInOrdinarySpeechIsNotSpam(t *testing.T) {
	for _, body := range []string{
		"この判決は正しいと思います。",
		"同意します。理由は明らかです。",
		"the ruling stands。 nothing points anywhere",
	} {
		clean, err := chat.SanitizeBody(body)
		if err != nil {
			t.Fatalf("sanitise refused ordinary speech: %v", err)
		}
		if got := Prefilter(clean).Floor; got != Clean {
			t.Errorf("floor %v, want clean — %q is a sentence, not a link", got, clean)
		}
	}
}
