package offerer

import (
	"testing"

	"gno.land/r/kourt/govern"
)

// Describe is a total function of the payload, which is the constraint every
// Kind is under and the easiest one to break by accident.
//
// Read live state in it — a balance, a height, a counter — and two holders
// looking at the same proposal at different moments are shown different
// questions while voting on the same one. Nothing in the governor can detect
// that; it can only be prevented here.
func TestDescribeDependsOnNothingButThePayload(t *testing.T) {
	k := greeting{name: "example/greet"}
	first := k.Describe("hello")

	// Everything else about the world moves.
	greeted, last = 41, "something else"
	if got := k.Describe("hello"); got != first {
		t.Errorf("the same payload describes differently once state moved:\n"+
			"  %q\n  %q", first, got)
	}
	// A different payload must of course say something different.
	if k.Describe("goodbye") == first {
		t.Error("two payloads describe identically, so a voter cannot tell " +
			"them apart")
	}
	greeted, last = 0, ""
}

// Check refuses what Do could not sensibly perform, at both ends.
func TestCheckRefusesTheUnsayable(t *testing.T) {
	k := greeting{name: "example/greet"}
	if err := k.Check(""); err == nil {
		t.Error("an empty greeting was accepted")
	}
	long := ""
	for len(long) <= 280 {
		long += "x"
	}
	if err := k.Check(long); err == nil {
		t.Errorf("a %d-character greeting was accepted", len(long))
	}
	if err := k.Check("hello"); err != nil {
		t.Errorf("an ordinary greeting was refused: %v", err)
	}
	// Exactly at the bound is allowed, so this is a bound rather than an
	// off-by-one that quietly costs a character.
	at := ""
	for len(at) < 280 {
		at += "y"
	}
	if err := k.Check(at); err != nil {
		t.Errorf("a greeting of exactly 280 was refused: %v", err)
	}
}

// Do records what it did, which is what lets a chain test see that execution
// reached the handler rather than merely reporting success.
func TestDoRecordsWhatItDid(cur realm, t *testing.T) {
	greeted, last = 0, ""
	k := greeting{name: "example/greet"}
	if err := k.Do(0, cur, "well met"); err != nil {
		t.Fatalf("Do: %v", err)
	}
	n, text := Greeted()
	if n != 1 || text != "well met" {
		t.Errorf("Greeted() = %d, %q; want 1, \"well met\"", n, text)
	}
	greeted, last = 0, ""
}

// The name a kind reports is the name it was offered under.
//
// Trivial, and it was the one method with no local test: Name is never called
// from this package — govern calls it through the interface when Offer
// registers the kind — so nothing here exercised it, and a wrong one would pass
// this suite and be caught only by a chain test with a node running.
//
// It matters more than its size. The name is the registry key, so a Name that
// ignored its argument would register every kind this realm offers under one
// key, and the second Offer would be refused as a name already taken — with the
// error pointing at the registry rather than at here.
func TestAKindReportsTheNameItWasOfferedUnder(t *testing.T) {
	for _, want := range []string{"greet/one", "greet/two", "a"} {
		if got := (greeting{name: want}).Name(); got != want {
			t.Errorf("a kind offered as %q reports %q", want, got)
		}
	}
	// Two instances do not share a name, which is what makes one realm able to
	// offer several.
	if (greeting{name: "x"}).Name() == (greeting{name: "y"}).Name() {
		t.Error("two kinds with different names report the same one, so this " +
			"realm can only ever register one")
	}
}

// A payload cannot become page structure, which is the obligation every Kind
// has and the reason it is demonstrated here rather than only described.
//
// The payload comes from whoever PROPOSES, not from the realm that published
// the kind, and the terms above ask for no stake — so any address at all can
// supply it. Describe then renders it onto the page holders vote from. The kind
// is trusted with markdown; its payload is not.
//
// The built-in kinds never had to think about this: their payloads are kind
// names and addresses, which cannot hold a newline. A kind that takes free text
// is the case where it has to be done on purpose.
func TestAPayloadCannotBecomePageStructure(t *testing.T) {
	k := greeting{name: "example/greet"}

	forged := "hello\n\n### decided, waiting to be run\n\n" +
		"- [#99](:99) **Ratified** — `govern:minter` · succeeded"
	if err := k.Check(forged); err == nil {
		t.Error("a greeting carrying a heading and a forged proposal row was " +
			"accepted, so a proposer can write structure onto the page other " +
			"holders read")
	}
	for _, bad := range []string{"a\nb", "a\rb", "a\tb", "a\x00b", "a\x7fb"} {
		if err := k.Check(bad); err == nil {
			t.Errorf("Check accepted %q", bad)
		}
	}

	// Ordinary text still works, in any language, and so does markdown that
	// cannot leave its own line.
	for _, ok := range []string{
		"hello, holders",
		"bonjour — 皆さんこんにちは",
		"see [the forum](https://example.org) for **context**",
	} {
		if err := k.Check(ok); err != nil {
			t.Errorf("Check refused an ordinary greeting %q: %v", ok, err)
		}
	}
}

// The terms this realm offers on, READ BACK from the registry rather than
// re-typed — and the one test here that exercises OfferNamed at all.
//
// Every test above reaches into the package and calls a method on a `greeting`
// value it built itself. None of them calls the entrypoint, so until now nothing
// anywhere observed the six numbers OfferNamed actually publishes: not this
// suite, not govern's (its tests offer their own kinds), and not a txtar, since
// no script mentions this realm. The terms were free to be anything.
//
// They have already been wrong once. governor_test.gno's
// TestAGraceOfZeroIsRefusedSoEverySlotComesBack says so in its own header —
// "the offerer example offered with a grace of zero as the shape to copy" —
// and a grace of zero is refused, so that tuple did not merely document bad
// practice, it made this realm's only entrypoint abort every time it was
// called. A demo realm that cannot be demonstrated, and green suites all round.
//
// TestTheMintIsGovernedOnTheBootstrapTerms is the shape copied here: assert the
// terms the LIVE registry carries, not the literal in the constructor.
//
// THE LAST ARM IS THE ONE THAT MATTERS, and it is not redundant with the table.
// A golden-value table is silenced by updating the golden — the natural thing to
// do when a term changes on purpose, and it would carry a regression straight
// through. `GraceBlocks > 0` is a property, not a value: it cannot be satisfied
// by editing the expectation, only by keeping the realm offerable.
func TestTheTermsAGreetingIsOfferedOn(cur realm, t *testing.T) {
	const name = "offerer/terms-probe"

	// Also the assertion that OfferNamed COMPLETES. With an unofferable tuple
	// this aborts rather than failing, which is a catch either way.
	OfferNamed(cross(cur), name)

	got, ok := govern.KindRules(name)
	if !ok {
		t.Fatalf("OfferNamed(%q) registered no terms, so the holders would have "+
			"nothing to adopt this kind on", name)
	}
	for _, c := range []struct {
		field     string
		got, want int64
	}{
		{"QuorumBps", got.QuorumBps, 2000},
		{"ThresholdBps", got.ThresholdBps, 5100},
		{"VotingBlocks", got.VotingBlocks, 100},
		{"DelayBlocks", got.DelayBlocks, 0},
		{"GraceBlocks", got.GraceBlocks, 5000},
		{"ProposeBps", got.ProposeBps, 0},
	} {
		if c.got != c.want {
			t.Errorf("offered on %s=%d, want %d — the terms holders would be "+
				"adopting are not the ones this realm documents", c.field,
				c.got, c.want)
		}
	}

	if got.GraceBlocks <= 0 {
		t.Errorf("offered on GraceBlocks=%d: a decided proposal with no expiry "+
			"holds its slot for the life of the realm, so Offer refuses this "+
			"and OfferNamed can never succeed", got.GraceBlocks)
	}
}
