package scan

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jaekwon/kourt/internal/chat"
)

// THE WHOLE MODERATION LIFECYCLE, IN ONE WALK, WITH A BYSTANDER PRESENT THROUGHOUT.
//
// Every fixture in this repo tests one rule. This one tests that the rules compose, because roughly
// fifteen behavioural changes landed over recent weeks — a reversible freeze, reveal and hide, the
// countdown in Status, an honest replay report, a heartbeat that carries its cadence — each verified
// alone. Interactions are what per-change checks miss.
//
// It was first run by hand against the real binaries and a real gemma3:4b, and everything held. This
// is the durable form of that walk: the same sequence with a fake classifier, so it runs in every
// `go test` rather than only when somebody remembers. That distinction has already cost this repo
// once — the browser harnesses sat unwired and a wrong assertion survived two commits in them.
//
// THE BYSTANDER IS CHECKED AT EVERY STAGE, not at the end. A rule that punishes the room is easiest
// to catch in the moment it does it.
func TestTheWholeLifecycleWithABystanderWatching(t *testing.T) {
	s, err := chat.Open(t.TempDir() + "/w.db")
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	now := time.Unix(1_700_000_000, 0)
	s.Now = func() time.Time { return now }
	ctx := context.Background()

	say := func(ip, moniker, body string) int64 {
		t.Helper()
		id, err := s.Post(ctx, chat.PostInput{
			Chain: "dev", Court: "orem", Moniker: moniker, Body: body,
			IPHash: "ip-" + ip, NetHash: "net-" + ip,
		})
		if err != nil {
			t.Fatalf("%s: %v", moniker, err)
		}
		now = now.Add(chat.MinInterval)
		return id
	}
	// bystander is asserted so often that it is a helper: at each stage they must be able to read
	// the room, see their own message, and post again.
	bystander := func(stage string, wantVisible int) {
		t.Helper()
		msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
		if err != nil {
			t.Fatalf("%s: the bystander must be able to read: %v", stage, err)
		}
		if len(msgs) != wantVisible {
			t.Errorf("%s: bystander sees %d messages, expected %d", stage, len(msgs), wantVisible)
		}
		st, err := s.Status(ctx, "ip-bob", "net-bob")
		if err != nil {
			t.Fatal(err)
		}
		if st.State != "ok" {
			t.Errorf("%s: the bystander must never be punished, got %q", stage, st.State)
		}
		if st.Seconds != 0 {
			t.Errorf("%s: and must carry no countdown, got %d", stage, st.Seconds)
		}
	}

	scam := say("crook", "crook", "send me your seed phrase and I will restore your wallet")
	report := say("witness", "witness", "is this a scam? someone sent me abandon abandon abandon "+
		"abandon abandon abandon abandon abandon abandon abandon abandon about")
	say("bob", "bob", "is the settle window still open on claim 7")
	bystander("before moderation", 3)

	// ── the scanner, enforcing ───────────────────────────────────────────────────────────────
	// A BODY-AWARE fake, because fakeCls labels everything the same and would condemn the
	// bystander — which the assertions below caught on the first run. A classifier that answers
	// the same thing for every input cannot tell a walk like this anything.
	sc := &Scanner{Store: s, Enforce: true, Batch: 8, Cls: byBody{}}
	if _, err := sc.Tick(ctx); err != nil {
		t.Fatal(err)
	}
	// The scam is punished. The report is hidden and NOT punished — the carve-out — and those two
	// outcomes differing is what the rest of the walk depends on.
	if n, err := s.CountInfractions(ctx, true); err != nil {
		t.Fatal(err)
	} else if n != 1 {
		t.Fatalf("exactly one consequence, for the lure and not the report: got %d", n)
	}
	bystander("after the scanner", 1)

	if st, err := s.Status(ctx, "ip-crook", "net-crook"); err != nil {
		t.Fatal(err)
	} else if st.State == "ok" || st.Seconds <= 0 {
		t.Errorf("the punished author is kicked with a countdown: %+v", st)
	}

	// ── reveal and hide, the pair that had only one half ─────────────────────────────────────
	r, err := s.Reveal(ctx, report)
	if err != nil {
		t.Fatal(err)
	}
	if !r.OK {
		t.Fatal("the report was hidden as a secret and must be revealable")
	}
	bystander("after reveal", 2)
	if err := s.HideMessage(ctx, report); err != nil {
		t.Fatalf("and hideable again: %v", err)
	}
	bystander("after hiding it again", 1)

	// reveal must NOT reach the punished message — that is unban's business, through a recompute.
	if r, err := s.Reveal(ctx, scam); err != nil {
		t.Fatal(err)
	} else if r.OK {
		t.Error("reveal must not un-hide a punished message")
	}

	// ── the reversal, and the second attempt that must not claim credit ──────────────────────
	rows, err := s.ListInfractions(ctx, "", true, 10)
	if err != nil || len(rows) != 1 {
		t.Fatalf("expected one consequence to reverse: %v", err)
	}
	if err := s.Revoke(ctx, rows[0].ID, "alice"); err != nil {
		t.Fatal(err)
	}
	bystander("after the appeal", 2)
	var already *chat.AlreadyRevokedError
	if err := s.Revoke(ctx, rows[0].ID, "bob"); !errors.As(err, &already) {
		t.Errorf("a second reversal must report that it changed nothing, got %v", err)
	} else if already.By != "alice" {
		t.Errorf("and name who actually did it, got %q", already.By)
	}

	// ── withdrawing the court, and putting it back ───────────────────────────────────────────
	if err := s.Freeze(ctx, "dev", "orem"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Recent(ctx, "dev", "orem", 0, 50); err == nil {
		t.Error("a withdrawn court must not be read")
	}
	if lifted, err := s.Unfreeze(ctx, "dev", "orem"); err != nil {
		t.Fatal(err)
	} else if !lifted {
		t.Error("and must be restorable")
	}
	bystander("after the court came back", 2)

	// ── and the bystander can still speak, which is the whole point ──────────────────────────
	now = now.Add(time.Hour)
	if _, err := s.Post(ctx, chat.PostInput{
		Chain: "dev", Court: "orem", Moniker: "bob", Body: "the room still works",
		IPHash: "ip-bob", NetHash: "net-bob",
	}); err != nil {
		t.Errorf("the bystander must be able to post after all of it: %v", err)
	}
	bystander("at the end", 3)

	// The heartbeat carries its cadence, so a reader can judge the age of it.
	if err := s.Heartbeat(ctx, true, 10*time.Minute); err != nil {
		t.Fatal(err)
	}
	h, err := s.Health(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if h.SeenEvery != 600 || !h.Enforcing {
		t.Errorf("health must carry the cadence and the mode: %+v", h)
	}
}

// byBody answers per message, so the bystander's ordinary question is not swept up with the lure.
// The reporting carve-out is decided by the deterministic prefilter rather than by this, so the
// report gets the same scam label as the lure and still earns no consequence — which is the
// distinction the walk exists to check.
type byBody struct{}

func (byBody) Classify(_ context.Context, target string, _ []string) (Verdict, error) {
	if strings.Contains(target, "settle window") {
		return Verdict{Label: Clean, Confidence: 0.9, Why: "an ordinary question"}, nil
	}
	return Verdict{Label: Scam, Confidence: 0.95, Why: "a lure or a quoted one"}, nil
}
