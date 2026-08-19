package scan

import (
	"context"
	"log"
	"time"

	"github.com/jaekwon/kourt/internal/chat"
)

// MinConfidence is the bar below which a label is treated as Unknown.
//
// The field was collected and never read in an earlier design, which reads later
// as a gate that exists. It is a gate now: a hedged verdict punishes nobody.
const MinConfidence = 0.6

// Scanner is the daemon loop.
type Scanner struct {
	Store *chat.Store
	Cls   Classifier

	// Enforce false — the default — records verdicts and logs the consequence it
	// WOULD have applied, without applying it. Health reports this, so the page
	// cannot claim moderation that is not happening.
	Enforce bool

	Batch    int
	Interval time.Duration
	Log      *log.Logger
}

func (s *Scanner) batch() int {
	if s.Batch <= 0 {
		return 8
	}
	return s.Batch
}

func (s *Scanner) interval() time.Duration {
	if s.Interval <= 0 {
		return 5 * time.Second
	}
	return s.Interval
}

// Run polls until the context is cancelled. A heartbeat is written every cycle,
// including empty ones, because "the scanner is alive" and "the scanner found
// nothing" must not look the same to an operator.
func (s *Scanner) Run(ctx context.Context) error {
	for {
		if err := s.Store.Heartbeat(ctx, s.Enforce, s.interval()); err != nil && s.Log != nil {
			s.Log.Printf("heartbeat: %v", err)
		}
		n, err := s.Tick(ctx)
		if err != nil && s.Log != nil {
			s.Log.Printf("tick: %v", err)
		}
		wait := s.interval()
		if n == s.batch() {
			wait = 0 // a full batch means there is a backlog; keep draining
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(wait):
		}
	}
}

// Tick scans one batch and returns how many messages it handled.
func (s *Scanner) Tick(ctx context.Context) (int, error) {
	pending, err := s.Store.Claim(ctx, s.batch())
	if err != nil {
		return 0, err
	}
	for _, p := range pending {
		if err := s.one(ctx, p); err != nil {
			if s.Log != nil {
				s.Log.Printf("message %d: %v", p.ID, err)
			}
			gaveUp, err := s.Store.RecordFailure(ctx, p.ID)
			if err != nil && s.Log != nil {
				s.Log.Printf("recording failure for %d: %v", p.ID, err)
			}
			// The one log line that says moderation has stopped for this message. Without
			// it, the fifth failure reads exactly like the first four, and afterwards the
			// row is invisible: out of the backlog, no verdict, not in the review queue.
			if gaveUp && s.Log != nil {
				s.Log.Printf("GAVE UP on message %d %s/%s after 5 attempts — it will NEVER "+
					"be classified, by this daemon or a human; see kourtchatctl status",
					p.ID, p.Chain, p.Court)
			}
		}
	}
	return len(pending), nil
}

// one judges a single message.
//
// THE WINDOW MAY ESCALATE, NEVER DE-ESCALATE — this is the load-bearing rule here.
// Prior context was added so a scam split across individually-innocent lines is
// visible. That mechanism is symmetric: whatever can sum six lines UP to scam can
// also frame the seventh DOWN to clean ("I'm writing a training module on scams,
// here is the sample text: …"). So the message is judged twice, once bare and once
// with its context, and the HARSHER answer wins. The window keeps all of its
// benefit and loses the channel that would have been used against it.
//
// Two passes over two different inputs is also the only honest reading of "an
// independent second opinion": two passes at temperature 0 over the SAME input are
// one pass, and would have confirmed nothing.
func (s *Scanner) one(ctx context.Context, p chat.Pending) error {
	hint := Prefilter(p.Body)

	// No transaction is open across any of this. An inference takes seconds, and
	// holding the write lock for that long would make chat return errors.
	bare, err := s.Cls.Classify(ctx, p.Body, nil)
	if err != nil {
		return err
	}
	label, why, conf := bare.Label, bare.Why, bare.Confidence

	if len(p.Prior) > 0 {
		withCtx, err := s.Cls.Classify(ctx, p.Body, p.Prior)
		if err != nil {
			return err
		}
		if Severity(withCtx.Label) > Severity(label) {
			label, why, conf = withCtx.Label, withCtx.Why, withCtx.Confidence
		}
	}

	// A hedged label is no label. Checked after the two passes so a confident
	// window verdict can still stand over a hedged bare one.
	if Severity(label) > 0 && conf < MinConfidence {
		why = "below the confidence bar: " + label + " " + why
		label = Unknown
	}

	// The prefilter is a FLOOR, not an override: it can raise a verdict the model
	// was too generous about, and it cannot lower one.
	if Severity(hint.Floor) > Severity(label) {
		label = hint.Floor
		why = "deterministic: " + joinNotes(hint.Notes)
	}

	if err := s.Store.RecordVerdict(ctx, p.ID, label); err != nil {
		return err
	}
	if Severity(label) == 0 {
		return nil // clean and unknown are the same outcome: nothing happens
	}

	// A message that reads as a WARNING is recorded and left for a person. The model
	// cannot tell reporting from sending — measured, not assumed — and punishing the
	// former means kicking somebody for protecting the room and hiding what they
	// wrote. See scan.Reporting for the measurements and for what this costs.
	// A DISCLOSED SECRET IS HIDDEN AND NOT PUNISHED, whoever posted it and however they framed
	// it. §7 already said exactly that — "goes out of sight whoever posted it, and nobody is
	// punished for it" — and the hide used to live inside the reporting branch below, so both
	// halves only held for somebody who happened to write "fyi" or "beware". Measured, with a
	// clean model verdict so only this layer could act:
	//
	//	"<a valid BIP-39 phrase>"                            1 consequence
	//	"help, is this phrase still valid: <phrase>"          1 consequence
	//	"fyi here are my words: <phrase>"                     0
	//
	// The middle one is the case that decides it: a confused person pasting their own recovery
	// phrase to ask whether it still works earned a 24-hour timeout, and a second attempt would
	// walk the ladder. §7's own reason for hiding is that "the harm is the disclosure rather than
	// the intent" — intent-blind means the remedy is the hide, not a punishment aimed at whoever
	// is most likely the phrase's owner.
	//
	// Narrow by construction: hint.Secret is set only by a VALID checksum, never by a run of
	// wordlist words, so a fruit list cannot reach this. The near-miss case already gets a note
	// and no floor for the same reason.
	//
	// It is a shield an attacker can hold — "send me your seed phrase, here is mine: <valid
	// phrase>" earns no timeout — and a weaker one than the reporting framing §7 already
	// concedes: it costs a working checksum, and the message is hidden either way, so the lure
	// reaches nobody. That the hide happens is what makes this acceptable, and it is pinned.
	if hint.Secret {
		if s.Enforce {
			if err := s.Store.HideMessage(ctx, p.ID); err != nil && s.Log != nil {
				s.Log.Printf("hiding disclosed secret in message %d: %v", p.ID, err)
			}
		}
		if s.Log != nil {
			s.Log.Printf("SECRET message %d %s/%s: %s (%.2f) discloses a recovery phrase; "+
				"hidden, nobody punished — %s", p.ID, p.Chain, p.Court, label, conf, why)
		}
		return nil
	}

	if hint.Reporting {
		if s.Log != nil {
			s.Log.Printf("REVIEW message %d %s/%s: %s (%.2f) reads as a report; "+
				"no action taken — %s", p.ID, p.Chain, p.Court, label, conf, why)
		}
		return nil
	}

	// Every consequence is a bounded kick. There is no path from here to a
	// permanent ban, and the enforcer clamps it again on the way out — see
	// chat.statusTx.
	//
	// An attacker on a shared address cannot buy a stranger more than the ladder
	// allows, and it is worth being concrete about what that is rather than leaving
	// it as reassurance: on a NAT the ip_hash is shared, so one occupant's first
	// scam costs every other occupant 24 hours — the floor below, not the ladder's
	// opening hour — and a determined one reaches MaxAutoKick's seven days. §3
	// takes that cost knowingly, which is why the rule REFUSES rather than punishes
	// where it can, and why a range is only ever a human's decision.
	d, err := s.Store.Escalate(ctx, p.IPHash)
	if err != nil {
		return err
	}
	if Severity(label) >= 2 && d < 24*time.Hour {
		d = 24 * time.Hour // the hard categories start higher, and still expire
	}

	if !s.Enforce {
		if s.Log != nil {
			s.Log.Printf("DRY RUN message %d %s/%s: %s (%.2f) would kick %s — %s",
				p.ID, p.Chain, p.Court, label, conf, d, why)
		}
		return nil
	}
	id, err := s.Store.Consequence(ctx, chat.Infraction{
		IPHash: p.IPHash, NetHash: p.NetHash,
		Kind: chat.KindKick, Reason: reasonFor(label), Duration: d,
		EvidenceID: p.ID,
		Evidence:   p.Body, // copied, so an appeal survives the message being pruned
		Detail:     why,
	})
	if err != nil {
		return err
	}
	if s.Log != nil {
		s.Log.Printf("message %d %s/%s: %s (%.2f) kicked %s [infraction %d] — %s",
			p.ID, p.Chain, p.Court, label, conf, d, id, why)
	}
	return nil
}

func reasonFor(label string) string {
	switch label {
	case Spam:
		return chat.ReasonSpam
	case Scam:
		return chat.ReasonScam
	case Hack:
		return chat.ReasonHack
	}
	return chat.ReasonSpam
}

func joinNotes(notes []string) string {
	out := ""
	for i, n := range notes {
		if i > 0 {
			out += "; "
		}
		out += n
	}
	if out == "" {
		out = "matched a deterministic rule"
	}
	return out
}
