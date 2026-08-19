package scan

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jaekwon/kourt/internal/chat"
)

// What does an operator see when the model goes away mid-run?
//
// This is not a hypothetical failure. §1 justifies two processes rather than one on
// exactly this: "a 7B model against an 8GB budget will OOM, and an OOM in the scanner must
// not take HTTP down." The design predicted the outage and got the isolation right — chat
// keeps serving. What nobody had checked is what the MODERATION side looks like afterwards.
//
// The machinery is sound in isolation. RecordFailure backs off and gives up after five
// attempts, marking the row ScanDone so a permanently malformed message cannot be retried
// forever, and Claim reclaims anything a dead daemon left claimed. Both are right.
//
// Composed, they have a consequence neither one shows: a message that exhausts its
// attempts is ScanDone with an EMPTY verdict. Health.Backlog counts ScanNew and ScanFailed
// only, so the row leaves the backlog; PendingReview requires a non-clean verdict, so it
// never reaches the review queue; and Run writes a heartbeat every cycle whether or not
// anything was classified. Every indicator goes green while nothing is being classified.
//
// clock is a settable now for the store; the scanner itself reads no clock.
func outageStore(t *testing.T) (*chat.Store, func(time.Duration)) {
	t.Helper()
	s, err := chat.Open(t.TempDir() + "/chat.db")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	now := time.Unix(1_700_000_000, 0)
	s.Now = func() time.Time { return now }
	return s, func(d time.Duration) { now = now.Add(d) }
}

// deadCls is ollama after an OOM: reachable at startup, gone by the time it is asked.
type deadCls struct{ calls int }

func (d *deadCls) Classify(_ context.Context, _ string, _ []string) (Verdict, error) {
	d.calls++
	return Verdict{}, errors.New("post http://127.0.0.1:11434: connection refused")
}

func TestAnOutageLeavesEveryIndicatorGreenAndNothingScanned(t *testing.T) {
	s, tick := outageStore(t)
	ctx := context.Background()

	// Ordinary traffic and a scam, so there is something real to miss.
	for _, m := range []struct{ who, body string }{
		{"alice", "is the settle window still open on claim 7"},
		{"crook", "send me your seed phrase and I will restore your funds"},
	} {
		if _, err := s.Post(ctx, chat.PostInput{
			Chain: "dev", Court: "orem", Moniker: m.who, Body: m.body,
			IPHash: "ip-" + m.who, NetHash: "net-" + m.who,
		}); err != nil {
			t.Fatal(err)
		}
		tick(chat.MinInterval)
	}

	dead := &deadCls{}
	sc := &Scanner{Store: s, Cls: dead, Enforce: true, Batch: 8}

	// The backoff doubles, so the clock has to move for the retries to be eligible. Six
	// rounds is enough to exhaust five attempts on both rows.
	for i := 0; i < 6; i++ {
		if err := s.Heartbeat(ctx, true); err != nil {
			t.Fatal(err)
		}
		if _, err := sc.Tick(ctx); err != nil {
			t.Fatal(err)
		}
		tick(2 * time.Minute)
	}
	if dead.calls == 0 {
		t.Fatal("the fixture must actually have tried to classify something")
	}

	h, err := s.Health(ctx)
	if err != nil {
		t.Fatal(err)
	}
	// THE FINDING, asserted as the CURRENT behaviour so the fix has something to change.
	// Each of these is individually defensible and together they say "all well".
	if h.Backlog != 0 {
		t.Fatalf("precondition: the attempts should be exhausted, backlog is %d", h.Backlog)
	}
	if h.ScannerSeen == 0 {
		t.Fatal("precondition: the heartbeat should look fresh")
	}
	if !h.Enforcing {
		t.Fatal("precondition: enforcement should be on")
	}
	// And nothing was classified, nobody was punished, and no human was told.
	n, err := s.CountInfractions(ctx, true)
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("an outage must not punish anybody, got %d consequences", n)
	}
	queued, err := s.PendingReview(ctx, false, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(queued) != 0 {
		t.Fatalf("an unscannable message has no verdict, so it cannot be in the review "+
			"queue; got %d", len(queued))
	}

	// The scam is still on screen, which is correct — fail-open is the design — but it
	// means the ONLY thing standing between the room and that message is an operator
	// noticing, and every number they have says fine.
	msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 2 {
		t.Fatalf("fail-open means the messages stay visible, got %d", len(msgs))
	}

	// So Health must report it. This is the assertion the fix has to satisfy.
	if h.Unscannable != 2 {
		t.Errorf("health must count messages that gave up unscanned: got %d, want 2",
			h.Unscannable)
	}
}

// The paired negative, and it is the important half: a HEALTHY run must not report
// anything unscannable. A counter that is always non-zero is an alarm nobody keeps.
func TestAHealthyRunReportsNothingUnscannable(t *testing.T) {
	s, _ := outageStore(t)
	ctx := context.Background()

	if _, err := s.Post(ctx, chat.PostInput{
		Chain: "dev", Court: "orem", Moniker: "crook",
		Body:   "send me your seed phrase and I will restore your funds",
		IPHash: "ip-crook", NetHash: "net-crook",
	}); err != nil {
		t.Fatal(err)
	}

	sc := &Scanner{Store: s, Enforce: true, Batch: 8,
		Cls: &fakeCls{bare: Verdict{Label: Scam, Confidence: 0.95, Why: "a lure"}}}
	if _, err := sc.Tick(ctx); err != nil {
		t.Fatal(err)
	}
	h, err := s.Health(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if h.Unscannable != 0 {
		t.Errorf("a healthy run must report nothing unscannable, got %d", h.Unscannable)
	}
	if h.Backlog != 0 {
		t.Errorf("and an empty backlog, got %d", h.Backlog)
	}
	// The scam was caught, which is what makes the zero above meaningful rather than
	// vacuous — a scanner that classified nothing would also report nothing unscannable.
	n, err := s.CountInfractions(ctx, true)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("the fixture must actually have worked: %d consequences", n)
	}
}

// A message that recovers before exhausting its attempts must NOT be counted as
// unscannable — the counter is for rows that gave up, not rows that had a bad minute.
func TestATransientOutageThatRecoversCountsForNothing(t *testing.T) {
	s, tick := outageStore(t)
	ctx := context.Background()
	if _, err := s.Post(ctx, chat.PostInput{
		Chain: "dev", Court: "orem", Moniker: "crook",
		Body:   "send me your seed phrase and I will restore your funds",
		IPHash: "ip-crook", NetHash: "net-crook",
	}); err != nil {
		t.Fatal(err)
	}

	// Two failures, well short of the five that give up.
	dead := &deadCls{}
	sc := &Scanner{Store: s, Cls: dead, Enforce: true, Batch: 8}
	for i := 0; i < 2; i++ {
		if _, err := sc.Tick(ctx); err != nil {
			t.Fatal(err)
		}
		tick(2 * time.Minute)
	}
	h, err := s.Health(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if h.Unscannable != 0 {
		t.Errorf("a row still retrying has not given up: got %d unscannable", h.Unscannable)
	}
	if h.Backlog != 1 {
		t.Errorf("it should still be IN the backlog, which is the honest place for it: got %d",
			h.Backlog)
	}

	// Now the model comes back.
	sc.Cls = &fakeCls{bare: Verdict{Label: Scam, Confidence: 0.95, Why: "a lure"}}
	if _, err := sc.Tick(ctx); err != nil {
		t.Fatal(err)
	}
	h, err = s.Health(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if h.Backlog != 0 || h.Unscannable != 0 {
		t.Errorf("after recovery both must be zero: backlog %d, unscannable %d",
			h.Backlog, h.Unscannable)
	}
	n, err := s.CountInfractions(ctx, true)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("the recovered scan must have caught the scam, got %d", n)
	}
}
