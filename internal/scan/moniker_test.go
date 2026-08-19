package scan

import (
	"context"
	"testing"

	"github.com/jaekwon/kourt/internal/chat"
)

// THE MONIKER IS NOT MODERATED. MEASUREMENT SAYS LEAVE IT THAT WAY — AND SHOWS WHAT THAT COSTS.
//
// §8 says the moniker is "unowned and impersonatable by design". What it does not say, and what
// matters operationally, is that the scanner never SEES it: `Claim` selects id, chain, court,
// body, ip_hash and net_hash. A scam has two halves, a credibility claim and an ask, and only one
// of them is ever in the classifier's input.
//
// THE ASK IS THE HALF THAT MATTERS, mostly. What gets classified is the move-to-a-private-channel,
// which cannot be smuggled into a 24-rune name. Measured on the body alone:
//
//	"happy to help — message me privately and I will resolve your dispute"   spam 0.85  acted on
//	"DM me for help with your claim, I can look it up on my end"            scam 0.85  acted on
//	"I can restore your account access, contact me directly"                scam 0.25  DROPPED
//
// THE THIRD ONE IS THE HOLE, and it is worth being exact about where it goes rather than calling
// it caught. 0.25 is under MinConfidence, so the label becomes Unknown — and `sqlAwaitingReview`
// excludes `unknown`, so it earns no consequence AND no human look. It is the most
// authority-flavoured of the three and the one that disappears.
//
// FEEDING THE MONIKER IN WOULD MAKE THAT WORSE, WHICH IS THE REASON NOT TO. Same third body,
// twice, with a name prepended:
//
//	"[dave] I can restore your account access…"              scam 0.25 -> 0.85   acted on
//	"[kourt-moderator] I can restore your account access…"   scam 0.25 -> 0.25   still dropped
//
// gemma3:4b reads a claimed moderator restoring accounts as legitimate and "dave" doing the same
// thing as a scam. So the name is not merely uninformative to the model, it is a DISCOUNT on
// exactly the message an impersonator sends. Including it would hand that discount over.
//
// The false-positive arm was clean throughout, including "Kourt Support" asking an ordinary
// question and "sysadmin_jane" mentioning work, but that is not what decided it. The discount is.
//
// ASSERTED: the floor, and the paired positive. Model judgement is logged, not asserted — a
// fixture that fails because a 4B model said spam instead of scam teaches nothing, and the
// confidence numbers above are a measurement of one model, not a contract.
func TestLiveTheAskIsCaughtWithoutTheName(t *testing.T) {
	o := liveClassifier(t)
	ctx := context.Background()

	// Bodies an impersonator needs, with the name stripped off. The scanner sees exactly this.
	dropped := 0
	for _, body := range []string{
		"happy to help — message me privately and I will resolve your dispute",
		"DM me for help with your claim, I can look it up on my end",
		"I can restore your account access, contact me directly",
	} {
		v, err := o.Classify(ctx, body, nil)
		if err != nil {
			t.Fatal(err)
		}
		acted := "acted on"
		if Severity(v.Label) == 0 {
			acted = "CLEAN"
		} else if v.Confidence < MinConfidence {
			acted = "dropped to unknown: no consequence, no review"
			dropped++
		}
		t.Logf("%-8s %.2f  %-28s %q", v.Label, v.Confidence, acted, body)

		// THE FLOOR: not clean. A clean verdict here would mean the ask itself is invisible,
		// and then the unscanned moniker really would be the gap it looks like.
		if Severity(v.Label) == 0 {
			t.Errorf("an authority-claiming ask must not read clean from the body alone: "+
				"got %s %.2f for %q", v.Label, v.Confidence, body)
		}
	}
	// Not an error — a measurement of what the design costs, logged loudly because the header
	// above depends on it and because a sub-threshold verdict is the one nobody sees.
	if dropped > 0 {
		t.Logf("NOTE: %d of 3 fell under the confidence bar and reach neither a consequence nor "+
			"the review queue. That is the cost of not reading the moniker, stated rather than "+
			"rounded up to 'caught'.", dropped)
	}

	// THE PAIRED POSITIVE, which has to be here or the floor above passes for a scanner that
	// flags everything — including the word "admin" in an ordinary question.
	for _, body := range []string{
		"I had the same problem last week — the settle window has to close first, then it shows up",
		"is there an admin here who can explain how the appeal path works",
		"does anyone know whether the trailing week ratio is over blocks or wall clock",
	} {
		v, err := o.Classify(ctx, body, nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("%-8s %.2f  %-28s %q", v.Label, v.Confidence, "clean is required", body)
		if Severity(v.Label) > 0 && v.Confidence >= MinConfidence {
			t.Errorf("ordinary help and ordinary questions must stay clean: got %s %.2f for %q",
				v.Label, v.Confidence, body)
		}
	}
}

// WHERE A HEDGED VERDICT GOES: nowhere. Read from the rows rather than from the SQL, because the
// route is assembled from three separate decisions and none of them mentions the others.
//
//	scanner.go   a label under MinConfidence is rewritten to Unknown  ("a hedged verdict
//	             punishes nobody" — correct on its own)
//	store.go     sqlAwaitingReview excludes '', 'clean' AND 'unknown'  (correct on its own:
//	             a clean message is not a review item)
//	together     a suspicion the model half-believes is recorded, punishes nobody, and is
//	             shown to nobody
//
// This is the same composition shape as the outage in outage_test.go — two defensible rules whose
// product is a silence — and it is worth pinning as CURRENT behaviour rather than fixed on sight.
// Raising the bar's floor into the review queue would put every 0.25 hunch about a stranger in
// front of an operator, and §7's queue exists precisely so a person only sees what is worth their
// time. The right size of that trade-off is an operator's call, not a test's.
//
// So: asserted as it stands, and documented in §6. If somebody later decides hedged verdicts
// should reach a human, this fixture is the thing that has to change, and its comment says why.
func TestAHedgedVerdictReachesNeitherAConsequenceNorAReviewer(t *testing.T) {
	s, _ := outageStore(t)
	ctx := context.Background()

	id, err := s.Post(ctx, chat.PostInput{
		Chain: "dev", Court: "orem", Moniker: "kourt-moderator",
		Body:   "I can restore your account access, contact me directly",
		IPHash: "ip-imposter", NetHash: "net-imposter",
	})
	if err != nil {
		t.Fatal(err)
	}

	// The measured verdict for that exact body: scam, and hedged.
	sc := &Scanner{Store: s, Enforce: true, Batch: 8,
		Cls: &fakeCls{bare: Verdict{Label: Scam, Confidence: 0.25, Why: "might be impersonation"}}}
	if _, err := sc.Tick(ctx); err != nil {
		t.Fatal(err)
	}

	if n, err := s.CountInfractions(ctx, true); err != nil {
		t.Fatal(err)
	} else if n != 0 {
		t.Errorf("a hedged verdict must punish nobody, got %d consequences", n)
	}
	queued, err := s.PendingReview(ctx, false, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(queued) != 0 {
		t.Errorf("CURRENT behaviour is that it does not reach a reviewer either; %d queued means "+
			"somebody changed that deliberately, which is fine — update this fixture and §6",
			len(queued))
	}
	// And it is still on screen, which is the part that matters to a reader: fail-open plus a
	// hedged verdict is a message nobody has decided about.
	msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 1 || msgs[0].ID != id {
		t.Fatalf("the message stays visible: got %d messages", len(msgs))
	}

	// THE PAIRED POSITIVE: the same label ABOVE the bar does reach both surfaces, so the zeros
	// above are about the confidence gate and not about a scanner that does nothing.
	id2, err := s.Post(ctx, chat.PostInput{
		Chain: "dev", Court: "orem", Moniker: "crook",
		Body:   "send me your seed phrase and I will restore your funds",
		IPHash: "ip-crook", NetHash: "net-crook",
	})
	if err != nil {
		t.Fatal(err)
	}
	sc.Cls = &fakeCls{bare: Verdict{Label: Scam, Confidence: 0.95, Why: "a lure"}}
	if _, err := sc.Tick(ctx); err != nil {
		t.Fatal(err)
	}
	if n, err := s.CountInfractions(ctx, true); err != nil {
		t.Fatal(err)
	} else if n != 1 {
		t.Errorf("a confident verdict must act: got %d consequences", n)
	}
	if msgs, err := s.Recent(ctx, "dev", "orem", 0, 50); err != nil {
		t.Fatal(err)
	} else {
		for _, m := range msgs {
			if m.ID == id2 {
				t.Error("and the message it cited must be hidden")
			}
		}
	}
}
