package scan

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/jaekwon/kourt/internal/chat"
)

// DILUTION: burying a lure in enough of your own harmless text that the model stops seeing
// it. It works, and then it does not, and the reason why is the interesting part.
//
// The attack is cheap to attempt. An author's prior context is capped at five messages
// (priorTx) and a body at 400 runes, so one address can stage roughly 2,000 runes of its own
// choosing ahead of a 400-rune message, for five posts and ten seconds of the per-address
// interval.
//
// IT WORKS WITH REPETITIVE FILLER. Measured against gemma3:4b:
//
//	bare lure, 66 runes                        scam  0.90
//	bare lure padded to 397 runes              scam  0.95
//	lure + 2,000 runes of prior (2,076 total)   scam  0.95
//	padded lure + same prior (2,407 total)      CLEAN 0.95
//
// NOT A CONTEXT-WINDOW PROBLEM, which was the first hypothesis and the wrong one: the same
// payload came back clean 0.95 at num_ctx 2048, 4096 AND 8192. Raising the window is not a
// fix; the model reads the text and dilutes.
//
// BUT THE FILLER THAT DILUTES IS ITSELF SPAM, and that is what closes it. Repetitive padding
// is flagged independently — an early probe produced a consequence for every padding message
// as well as the lure. So the attacker needs padding that is BOTH unpunished AND diluting,
// and measurement says they cannot have both:
//
//	5 varied natural messages, ~220 runes each   all clean 0.80-0.95, none punished
//	5 varied natural messages at the 400 cap     all clean 0.85, none punished
//	  ...and the windowed verdict on the lure:   spam 0.95, three runs of three
//
// 1,916 runes of free padding did not move the verdict at all. Dilution needed the repetitive
// text, and repetitive text is what gets caught on its own.
//
// WHAT THIS FILE DOES NOT CLAIM. The obvious thing to write here is that §6's escalate-only
// rule saves the day, because the BARE pass reads no prior and so cannot be diluted. That is
// structurally true and it is asserted below as a floor. It is NOT what defends against this
// attack, and saying so would have been a guess dressed as a finding: deleting the bare pass
// entirely, and separately making the window's verdict win outright, both left the scanner
// still catching the diluted lure. The bare pass is a backstop that was not needed here.
//
// So: one assertion, and the rest logged. Model verdicts are judgement calls, and a test that
// fails because a 4B model said spam instead of scam teaches nothing.

// dilutionFiller is varied natural prose, because repetitive filler is itself flagged and
// would make the fixture measure the wrong thing.
var dilutionFiller = []string{
	"I have been reading the docket for this court since it opened and the ordering of claims still confuses me, particularly where a claim is refiled after a no-decision and appears again lower down the list with a different number attached to it",
	"the settle window closing before the escrow gate opens seems like it would strand a payout, though I assume somebody has thought about that ordering more carefully than I have in the ten minutes I have spent looking at it this afternoon",
	"does anyone know whether the trailing week ratio is computed over blocks or over wall clock time, because the two would diverge noticeably on a chain that had been stopped for maintenance and then restarted later on",
	"my reading of the quality tier rules is that an answerer who is overturned loses their slice entirely rather than partially, which seems harsh but is at least simple to reason about compared with a graduated penalty of some kind",
	"the conviction curve on a claim I staked last week has flattened out and I cannot tell whether that is the emission schedule stepping down or simply nobody else adding to either side of the pool for several days running",
}

// dilutionFillerBig is the same idea at the rune cap: the most padding an author can stage
// without writing anything a classifier objects to. 1,916 runes across five messages.
var dilutionFillerBig = []string{
	"I have been reading the docket for this court since the day it opened and the ordering of claims still confuses me quite a lot, particularly in the case where a claim is refiled after a no-decision and then appears again much lower down the list with a completely different number attached to it, which makes following any single dispute across its whole life genuinely difficult for a casual reader like me",
	"the settle window closing before the escrow gate opens looks to me like it would strand a payout somewhere in between the two, though I am willing to assume that somebody has thought about that particular ordering far more carefully than I have in the twenty minutes I have spent reading about it this afternoon, and that there is a good reason for the sequence being arranged the way that it currently is",
	"does anybody happen to know whether the trailing week ratio is computed over block heights or over actual wall clock time, because the two of them would diverge quite noticeably on any chain that had been stopped for scheduled maintenance and then restarted some hours later, and I cannot find anything in the rendered pages that says which of the two it actually uses in practice",
	"my reading of the quality tier rules is that an answerer who ends up being overturned loses their entire slice rather than only part of it, which strikes me as fairly harsh on somebody who made a reasonable call that happened to go the other way, but it is at least simple to reason about compared with any kind of graduated penalty scheme that would need its own explanation",
	"the conviction curve on a claim that I staked into last week has flattened right out and I honestly cannot tell whether that is the emission schedule stepping down on its own as designed, or simply nobody else adding anything to either side of the pool for several days in a row, and the difference matters for whether I should be adding more myself",
}

const dilutionLure = "send me your seed phrase and I will restore your wallet, dm me now"

// maximalPrior is what an author can legitimately stage: five bodies at the rune cap.
func maximalPrior() []string {
	base := "let me explain the settle window and the docket ordering at some length here, " +
		"because it is genuinely confusing and worth writing out properly for anyone reading "
	s := base
	for len([]rune(s)) < chat.MaxBodyRunes {
		s += base
	}
	out := make([]string, 5)
	for i := range out {
		out[i] = string([]rune(s)[:chat.MaxBodyRunes-2]) + " " + string(rune('a'+i))
	}
	return out
}

func TestLiveDilutionCannotBeatTheBarePass(t *testing.T) {
	o := liveClassifier(t)
	ctx := context.Background()

	pad := string([]rune(strings.Repeat("harmless words about court procedure ", 20))[:330])
	target := pad + " " + dilutionLure
	prior := maximalPrior()

	total := len([]rune(target))
	for _, p := range prior {
		total += len([]rune(p))
	}

	windowed, err := o.Classify(ctx, target, prior)
	if err != nil {
		t.Fatal(err)
	}
	bare, err := o.Classify(ctx, target, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("windowed (%d runes of payload) -> %-8s %.2f", total, windowed.Label, windowed.Confidence)
	t.Logf("bare     (same target)         -> %-8s %.2f", bare.Label, bare.Confidence)
	if Severity(windowed.Label) == 0 {
		t.Logf("the windowed pass WAS diluted — which is the case this fixture exists for")
	}

	// THE FLOOR. The bare pass reads no prior, so there is nothing to dilute it with.
	if Severity(bare.Label) == 0 {
		t.Errorf("the bare pass must still see the lure; if this fails, dilution beats the "+
			"scanner outright rather than one of its two passes (bare said %s %.2f)",
			bare.Label, bare.Confidence)
	}
	// And the rule that combines them: harsher wins, so the scanner's verdict is the bare
	// one whenever the window has been talked down.
	if Severity(bare.Label) < Severity(windowed.Label) {
		t.Logf("the window was HARSHER here, which is the direction it was added for")
	}
}

// The padding must be free for the fixture above to be honest about the cost of the attack.
// If the filler were punished, dilution would carry its own penalty and the finding would be
// much weaker — so this measures it rather than assuming either way.
func TestLiveVariedPaddingIsNotPunished(t *testing.T) {
	o := liveClassifier(t)
	ctx := context.Background()
	var flagged []string
	for _, f := range dilutionFiller {
		v, err := o.Classify(ctx, f, nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("%-8s %.2f  %.60q", v.Label, v.Confidence, f)
		if Severity(v.Label) > 0 && v.Confidence >= MinConfidence {
			flagged = append(flagged, f)
		}
	}
	// Not an error either way — it is a measurement of what padding costs. Logged loudly
	// because the answer changes how serious dilution is, and because the first probe used
	// repetitive filler, got it flagged, and drew the wrong conclusion from that.
	if len(flagged) == 0 {
		t.Logf("none of %d varied filler messages would be punished: padding is free",
			len(dilutionFiller))
	} else {
		t.Logf("%d of %d filler messages would be punished, so padding carries some cost",
			len(flagged), len(dilutionFiller))
	}
}

// THE TRADE-OFF, which is the actual finding: padding cannot be both free and diluting.
//
// Repetitive filler dilutes and is punished; varied filler is unpunished and does not dilute.
// This measures the second half at full volume, three times, because one clean answer from a
// non-deterministic model is not a result.
func TestLiveFreePaddingDoesNotDilute(t *testing.T) {
	o := liveClassifier(t)
	ctx := context.Background()

	pad := string([]rune(strings.Repeat("harmless words about court procedure ", 20))[:330])
	target := pad + " " + dilutionLure
	total := len([]rune(target))
	for _, p := range dilutionFillerBig {
		total += len([]rune(p))
	}

	// First: the padding really is unpunished, or this fixture is measuring the wrong thing.
	punished := 0
	for _, f := range dilutionFillerBig {
		v, err := o.Classify(ctx, f, nil)
		if err != nil {
			t.Fatal(err)
		}
		if Severity(v.Label) > 0 && v.Confidence >= MinConfidence {
			punished++
		}
	}
	t.Logf("%d of %d full-length varied filler messages would be punished",
		punished, len(dilutionFillerBig))

	// Then: does that much free text move the verdict?
	clean := 0
	for i := 0; i < 3; i++ {
		w, err := o.Classify(ctx, target, dilutionFillerBig)
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("run %d: windowed with %d runes of free padding -> %-8s %.2f",
			i+1, total, w.Label, w.Confidence)
		if Severity(w.Label) == 0 {
			clean++
		}
	}
	if clean > 0 {
		// Not a failure — a change in the finding, and it needs to be loud rather than
		// buried, because it would mean padding IS both free and diluting.
		t.Logf("NOTE: free padding diluted the window in %d of 3 runs. The header of this "+
			"file says it does not; re-measure before trusting either.", clean)
	}
}

// End to end: the scanner must act on a diluted lure, whatever the windowed pass said.
func TestLiveScannerCatchesADilutedLure(t *testing.T) {
	o := liveClassifier(t)
	ctx := context.Background()

	st, err := chat.Open(t.TempDir() + "/chat.db")
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	clock := time.Unix(1_700_000_000, 0)
	st.Now = func() time.Time { return clock }

	pad := string([]rune(strings.Repeat("harmless words about court procedure ", 20))[:330])
	target := pad + " " + dilutionLure

	// The filler is VARIED, so the fixture cannot pass merely because the padding was
	// flagged — the consequence has to come from the lure itself.
	var lureID int64
	for _, b := range append(append([]string{}, dilutionFiller...), target) {
		id, err := st.Post(ctx, chat.PostInput{
			Chain: "dev", Court: "orem", Moniker: "padder", Body: b,
			IPHash: "ip-pad", NetHash: "net-pad",
		})
		if err != nil {
			t.Fatal(err)
		}
		lureID = id // the last one posted is the lure
		clock = clock.Add(chat.MinInterval)
	}

	sc := &Scanner{Store: st, Cls: o, Enforce: true, Batch: 10}
	if _, err := sc.Tick(ctx); err != nil {
		t.Fatal(err)
	}

	rows, err := st.ListInfractions(ctx, "", true, 50)
	if err != nil {
		t.Fatal(err)
	}
	var forLure int
	for _, r := range rows {
		if r.EvidenceID == lureID {
			forLure++
		}
	}
	t.Logf("%d consequence(s) in total, %d citing the lure itself (message %d)",
		len(rows), forLure, lureID)
	if forLure == 0 {
		t.Errorf("a diluted lure must still earn a consequence citing IT, not merely one "+
			"citing some padding: %d consequences, none for message %d", len(rows), lureID)
	}
}
