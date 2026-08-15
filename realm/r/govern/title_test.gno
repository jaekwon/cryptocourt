package govern

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

// A proposal title is the one piece of free prose an ungated caller puts on a
// page that every other holder reads, and it lands inside a markdown list item.
//
// Without a check on its characters a newline ends that item and starts a row
// of the proposer's own design, with a state and a link they choose. The forged
// row is indistinguishable from a real one; the real one is what looks broken,
// because its formatting runs on past the end of the fake.
func TestATitleCannotForgeARowOnTheFrontPage(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 1_000_000)
	advanceEpochs(1)
	engine.Adopt(setFee{name: "t/k"}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 1_000_000, GraceBlocks: 1_000_000,
	})

	forged := "x\n- [#999](:999) **Ratified** — `govern:minter` · succeeded"
	uassert.AbortsContains(t, cur, "control characters", func() {
		Propose(cross(cur), "t/k", "5", forged)
	})

	// A carriage return alone splits a line in most renderers too, and so does
	// anything else below a space.
	for _, bad := range []string{"a\rb", "a\tb", "a\x00b", "a\x7fb", "\na"} {
		uassert.AbortsContains(t, cur, "control characters", func() {
			Propose(cross(cur), "t/k", "6", bad)
	})
	}

	// Nothing was written by any of that.
	if engine.OpenSlots() != 0 {
		t.Fatalf("%d proposals opened despite every title being refused",
			engine.OpenSlots())
	}

	// Prose still works, in any language, with markdown inside the line — a
	// title is allowed to be styled text and refusing brackets would be
	// refusing ordinary English.
	good := []string{
		"Raise the fee to 2%",
		"Réviser le règlement — 予算の見直し",
		"See [the forum](https://example.org) for **context**",
	}
	// Distinct payloads: the digest is over kind and payload, so reusing one
	// would be refused as a duplicate and prove nothing about the title.
	for i, ok := range good {
		payload := strconv.Itoa(100 + i)
		uassert.NotAborts(t, cur, func() {
			Propose(cross(cur), "t/k", payload, ok)
	})
	}

	// One row per proposal, whatever the titles said. This is the assertion the
	// forged page fails: three proposals rendering four rows means a title
	// wrote a line of its own.
	page := Render("")
	if n := strings.Count(page, "](:"); n != len(good) {
		t.Errorf("the page holds %d rows for %d proposals:\n%s", n, len(good), page)
	}
}

// TextOnly is exported, so its contract is somebody else's to rely on.
//
// Tested directly rather than only through the title, because a realm writing a
// Kind calls this and nothing in this package would notice if the exported
// behaviour changed while mustBeUsableTitle kept working.
func TestTextOnly(t *testing.T) {
	for _, bad := range []string{
		"a\nb",   // the one that matters: a new line is a new row
		"a\rb",   // and this splits a line in most renderers too
		"a\tb",
		"a\x00b",
		"a\x7fb", // DEL
		"\x1b[31m", // an escape sequence
	} {
		if err := TextOnly(bad); err == nil {
			t.Errorf("TextOnly(%q) = nil, want an error", bad)
		}
	}

	// Prose in any language, because every byte of a multi-byte character is
	// >= 0x80 and none of them can be mistaken for a control character.
	//
	// And markdown WITHIN a line, which is allowed on purpose: it cannot leave
	// the row it belongs to, and refusing brackets would refuse ordinary
	// English. A kind wanting to refuse those too can do it on top of this.
	for _, ok := range []string{
		"",
		"hello",
		"Réviser le règlement — 予算の見直し",
		"see [the forum](https://example.org) for **context**",
		"100% of the fee, up to $5",
	} {
		if err := TextOnly(ok); err != nil {
			t.Errorf("TextOnly(%q) = %v, want nil", ok, err)
		}
	}
}
