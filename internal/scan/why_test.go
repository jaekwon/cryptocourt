package scan

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"unicode/utf8"
)

// whyServer is a fake Ollama that returns one chosen explanation, so the truncation can be
// driven with text no real model would reliably produce on demand.
func whyServer(t *testing.T, why string) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		inner, err := json.Marshal(map[string]any{
			"verdict": "scam", "confidence": 0.9, "why": why,
		})
		if err != nil {
			t.Error(err)
			return
		}
		out, err := json.Marshal(map[string]any{
			"message": map[string]any{"role": "assistant", "content": string(inner)},
		})
		if err != nil {
			t.Error(err)
			return
		}
		_, _ = w.Write(out)
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

// THE MODEL'S EXPLANATION IS CUT ON A RUNE BOUNDARY, AND EVERY LANGUAGE GETS THE SAME ROOM.
//
// The cap was `v.Why[:200]`, a byte slice of a UTF-8 string. Measured before the fix, with a
// `why` of 199 ASCII characters then "é": the stored value was 200 bytes, utf8.ValidString false,
// ending in a dangling 0xc3.
//
// The invalid byte is the smaller half of it. A byte cap rations characters by how expensive
// they are to encode, and gemma3:4b answers in the language it was addressed in. Both arms below
// were run against the old implementation: the rune-boundary one reported 200 bytes ending
// 61 61 c3, and the script one reported a 200-character Japanese explanation cut to 68 — 66
// readable characters and two trailing bytes that count as one rune each.
func TestTheModelsExplanationIsCutOnARuneBoundary(t *testing.T) {
	// 199 ASCII then a two-byte rune, so byte 200 is that rune's continuation byte and a byte
	// slice keeps the lead without it.
	why := strings.Repeat("a", 199) + "é" + strings.Repeat("b", 60)
	v, err := NewOllama(whyServer(t, why), "gemma3:4b").Classify(context.Background(), "x", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !utf8.ValidString(v.Why) {
		t.Errorf("the stored explanation is not valid UTF-8: %d bytes ending % x",
			len(v.Why), v.Why[max(0, len(v.Why)-3):])
	}
	if n := utf8.RuneCountInString(v.Why); n != WhyMaxRunes {
		t.Errorf("got %d runes, want exactly %d — the cap counts characters now", n, WhyMaxRunes)
	}
	// The fixture must actually have exercised the truncation, or the assertions above are
	// about a string that was never cut.
	if utf8.RuneCountInString(why) <= WhyMaxRunes {
		t.Fatalf("the fixture's why is only %d runes and would not be truncated at all",
			utf8.RuneCountInString(why))
	}
}

// THE EQUAL-ROOM PROPERTY, which is the half a byte cap got wrong. The same NUMBER of
// characters in a three-byte-per-character script must survive intact.
func TestAnExplanationInAnotherScriptKeepsAsManyCharacters(t *testing.T) {
	// 200 characters of Japanese: 600 bytes, three times over the old byte cap, and not one
	// character too long for the real one.
	why := strings.Repeat("説", WhyMaxRunes)
	if len(why) <= 200 {
		t.Fatalf("fixture is not over the old byte cap (%d bytes), so it proves nothing", len(why))
	}
	v, err := NewOllama(whyServer(t, why), "gemma3:4b").Classify(context.Background(), "x", nil)
	if err != nil {
		t.Fatal(err)
	}
	if v.Why != why {
		t.Errorf("a %d-character explanation was cut to %d characters because its script "+
			"encodes to %d bytes; the cap must ration characters, not bytes",
			WhyMaxRunes, utf8.RuneCountInString(v.Why), len(why))
	}
}

// And the ordinary explanation the cap must not touch at all — the overwhelmingly common case,
// and the one that would make a passing table of truncations meaningless on its own.
func TestAnOrdinaryExplanationIsPassedThroughUnchanged(t *testing.T) {
	for _, why := range []string{
		"asks for a seed phrase and a DM",
		"",
		strings.Repeat("x", WhyMaxRunes), // exactly at the limit: kept whole
	} {
		v, err := NewOllama(whyServer(t, why), "gemma3:4b").Classify(context.Background(), "x", nil)
		if err != nil {
			t.Fatal(err)
		}
		if v.Why != why {
			t.Errorf("an explanation of %d runes was altered: %q -> %q",
				utf8.RuneCountInString(why), why, v.Why)
		}
	}
}
