package chat

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func newStore(t *testing.T) (*Store, *time.Time) {
	t.Helper()
	// A real file, not :memory:, because WAL needs one — and WAL is the thing
	// being relied on for two processes to share this database.
	s, err := Open(filepath.Join(t.TempDir(), "chat.db"))
	if err != nil {
		t.Fatal(err)
	}
	clock := time.Unix(1_700_000_000, 0)
	s.Now = func() time.Time { return clock }
	t.Cleanup(func() { s.Close() })
	return s, &clock
}

func post(t *testing.T, s *Store, court, ip, body string) (int64, error) {
	t.Helper()
	return s.Post(context.Background(), PostInput{
		Chain: "dev", Court: court, Moniker: "alice", Body: body,
		IPHash: ip, NetHash: "net-" + ip,
	})
}

func TestPostAndRead(t *testing.T) {
	s, _ := newStore(t)
	ctx := context.Background()
	if _, err := post(t, s, "orem", "ip1", "first message here"); err != nil {
		t.Fatal(err)
	}
	msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 1 || msgs[0].Body != "first message here" {
		t.Fatalf("got %+v", msgs)
	}
	// A different chain is a different room: one court slug exists on many chains.
	other, err := s.Recent(ctx, "test5", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(other) != 0 {
		t.Fatal("courts must not be shared across chains")
	}
}

func TestThrottleInterval(t *testing.T) {
	s, clock := newStore(t)
	if _, err := post(t, s, "orem", "ip1", "one message here"); err != nil {
		t.Fatal(err)
	}
	if _, err := post(t, s, "orem", "ip1", "immediately after"); !errors.Is(err, ErrThrottled) {
		t.Fatalf("a second message in the same instant must be refused, got %v", err)
	}
	// Paired positive: after the interval it must go through, or this is just a
	// test that posting fails.
	*clock = clock.Add(MinInterval)
	if _, err := post(t, s, "orem", "ip1", "after the interval"); err != nil {
		t.Fatalf("after the interval it must be accepted: %v", err)
	}
}

func TestThrottlePerIPWindow(t *testing.T) {
	s, clock := newStore(t)
	for i := 0; i < PerIPMax; i++ {
		if _, err := post(t, s, "orem", "ip1", "message number here"); err != nil {
			t.Fatalf("message %d of the allowance was refused: %v", i, err)
		}
		*clock = clock.Add(MinInterval)
	}
	if _, err := post(t, s, "orem", "ip1", "one too many now"); !errors.Is(err, ErrThrottled) {
		t.Fatalf("past the window allowance must be refused, got %v", err)
	}
	// And the window must actually expire.
	*clock = clock.Add(PerIPWindow)
	if _, err := post(t, s, "orem", "ip1", "after the window"); err != nil {
		t.Fatalf("the window must expire: %v", err)
	}
}

// Fair share must bind ONLY under contention. Two people talking in a quiet court
// have to be able to hold a conversation; the earlier design throttled them to one
// message every twenty seconds with most of the court's budget idle.
func TestFairShareOnlyBitesUnderContention(t *testing.T) {
	s, clock := newStore(t)
	// A quiet court: one address well past FairShare must still be fine.
	for i := 0; i < FairShare+3; i++ {
		if _, err := post(t, s, "quiet", "ip1", "chatting away here"); err != nil {
			t.Fatalf("a quiet court must not enforce a share: %v", err)
		}
		*clock = clock.Add(MinInterval)
	}

	// Now make the court contended by other addresses, and the share bites.
	// Enough DISTINCT addresses that the court fills before any one of them hits
	// its own per-address allowance — otherwise the per-address rule fires first
	// and this proves nothing about the share.
	// Ten addresses, three rounds. The minimum interval is per ADDRESS, so
	// distinct addresses post back to back and all thirty messages land inside
	// the court's window — advancing the clock per message instead pushed the
	// earliest ones out of it, and the court never looked contended.
	s2, clock2 := newStore(t)
	for round := 0; round < FairShare; round++ {
		for i := 0; i < CourtSoftCap/FairShare; i++ {
			if _, err := post(t, s2, "busy", fmt.Sprintf("ip%02d", i), "filling the court up"); err != nil {
				t.Fatalf("filling round %d addr %d: %v", round, i, err)
			}
		}
		*clock2 = clock2.Add(MinInterval)
	}
	// ip00 has posted three of the thirty, which is its share of a contended court.
	if _, err := post(t, s2, "busy", "ip00", "one more from ip00"); !errors.Is(err, ErrThrottled) {
		t.Fatalf("a contended court must enforce the share, got %v", err)
	}
	// A newcomer with no share used yet still gets in — the cap sheds the greedy,
	// it does not close the room.
	if _, err := post(t, s2, "busy", "ipNew", "a newcomer speaks up"); err != nil {
		t.Fatalf("a contended court must still admit a newcomer: %v", err)
	}
}

// THE LOAD-BEARING SECURITY PROPERTY. Whatever the scanner writes, the enforcer
// refuses to honour a permanent ban that no human authorised, and clamps any
// automated timeout to MaxAutoKick.
func TestEnforcerClampsAutomatedConsequences(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()

	// A scanner writing a ban directly is refused at the door...
	if _, err := s.Consequence(ctx, Infraction{
		IPHash: "ip1", Kind: KindBan, Reason: ReasonScam,
	}); err == nil {
		t.Fatal("an automated ban must be refused when written")
	}

	// ...and even if one is somehow in the table, the ENFORCER does not honour it
	// as a ban. This is the half that survives a future edit to the scanner.
	if _, err := s.w.Exec(`INSERT INTO infractions(ip_hash,net_hash,kind,reason,created_at)
	  VALUES ('ip2','net2',?,?,?)`, KindBan, ReasonScam, clock.Unix()); err != nil {
		t.Fatal(err)
	}
	st, err := s.Status(ctx, "ip2", "net2")
	if err != nil {
		t.Fatal(err)
	}
	if st.State == KindBan {
		t.Fatal("a ban with a non-manual reason must not be honoured as a ban")
	}
	if st.State != KindKick {
		t.Fatalf("it should degrade to a kick, got %q", st.State)
	}
	// And it expires: MaxAutoKick after it was created, not never.
	*clock = clock.Add(MaxAutoKick + time.Second)
	if st, err = s.Status(ctx, "ip2", "net2"); err != nil {
		t.Fatal(err)
	}
	if st.Blocked() {
		t.Fatal("an automated consequence must expire at the ceiling")
	}

	// A MANUAL ban is honoured, and forever — otherwise the operator has no tool.
	if _, err := s.Consequence(ctx, Infraction{
		IPHash: "ip3", Kind: KindBan, Reason: ReasonManual,
	}); err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(10 * 365 * 24 * time.Hour)
	if st, err = s.Status(ctx, "ip3", ""); err != nil {
		t.Fatal(err)
	}
	if st.State != KindBan {
		t.Fatalf("a manual ban must persist, got %q", st.State)
	}
}

// An over-long automated kick is clamped too, or a very long kick would be a
// permanent ban wearing a different word.
func TestOverlongAutomatedKickIsClamped(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	if _, err := s.w.Exec(`INSERT INTO infractions(ip_hash,kind,reason,created_at,expires_at)
	  VALUES ('ip1',?,?,?,?)`, KindKick, ReasonSpam,
		clock.Unix(), clock.Add(100*365*24*time.Hour).Unix()); err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(MaxAutoKick + time.Minute)
	st, err := s.Status(ctx, "ip1", "")
	if err != nil {
		t.Fatal(err)
	}
	if st.Blocked() {
		t.Fatalf("a hundred-year kick must be clamped to the ceiling, got %+v", st)
	}
}

func TestKickBlocksPostingThenExpires(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	if _, err := s.Consequence(ctx, Infraction{
		IPHash: "ip1", NetHash: "net-ip1", Kind: KindKick,
		Reason: ReasonSpam, Duration: time.Hour,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := post(t, s, "orem", "ip1", "trying to post now"); !errors.Is(err, ErrKicked) {
		t.Fatalf("a kicked address must be refused, got %v", err)
	}
	*clock = clock.Add(time.Hour + time.Second)
	if _, err := post(t, s, "orem", "ip1", "the kick has expired"); err != nil {
		t.Fatalf("the kick must expire: %v", err)
	}
}

// "Kicked for an hour, or more if repeat offender."
func TestEscalationLadder(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	for i, want := range Ladder {
		got, err := s.Escalate(ctx, "ip1")
		if err != nil {
			t.Fatal(err)
		}
		if got != want {
			t.Fatalf("rung %d: want %s, got %s", i, want, got)
		}
		if _, err := s.Consequence(ctx, Infraction{
			IPHash: "ip1", Kind: KindKick, Reason: ReasonSpam,
			Duration: got, EvidenceID: int64(i + 1),
		}); err != nil {
			t.Fatal(err)
		}
		*clock = clock.Add(time.Minute)
	}
	// The top rung holds rather than growing without bound.
	got, err := s.Escalate(ctx, "ip1")
	if err != nil {
		t.Fatal(err)
	}
	if got != Ladder[len(Ladder)-1] {
		t.Fatalf("the ladder must stop at its top rung, got %s", got)
	}
}

// A revoked consequence must not count toward the ladder, or an upheld appeal
// unmutes somebody and quietly leaves them one rung higher.
func TestRevokedInfractionsDoNotEscalate(t *testing.T) {
	s, _ := newStore(t)
	ctx := context.Background()
	id, err := s.Consequence(ctx, Infraction{
		IPHash: "ip1", Kind: KindKick, Reason: ReasonSpam,
		Duration: time.Hour, EvidenceID: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	if d, _ := s.Escalate(ctx, "ip1"); d != Ladder[1] {
		t.Fatalf("before revoking, the next rung is %s", d)
	}
	if err := s.Revoke(ctx, id, "operator"); err != nil {
		t.Fatal(err)
	}
	if d, _ := s.Escalate(ctx, "ip1"); d != Ladder[0] {
		t.Fatalf("after revoking, the ladder must reset to %s, got %s", Ladder[0], d)
	}
	// And the address can post again.
	if _, err := post(t, s, "orem", "ip1", "after the appeal"); err != nil {
		t.Fatalf("a revoked kick must stop blocking: %v", err)
	}
}

// A crash between "punish" and "mark scanned" replays the punish. The partial
// unique index makes that a no-op, which is what stops one message walking the
// ladder.
func TestReplayIsIdempotent(t *testing.T) {
	s, _ := newStore(t)
	ctx := context.Background()
	in := Infraction{IPHash: "ip1", Kind: KindKick, Reason: ReasonSpam,
		Duration: time.Hour, EvidenceID: 42}
	if _, err := s.Consequence(ctx, in); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Consequence(ctx, in); err != nil {
		t.Fatalf("a replay must be a no-op, not an error: %v", err)
	}
	var n int
	if err := s.r.QueryRow(`SELECT count(*) FROM infractions WHERE evidence_id=42`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("want one infraction for one message, got %d", n)
	}
}

// Ban, unban, ban again — the first thing anybody does after testing unban. An
// unconditional unique index would have failed the third step.
func TestBanUnbanBanAgain(t *testing.T) {
	s, _ := newStore(t)
	ctx := context.Background()
	mk := func() (int64, error) {
		return s.Consequence(ctx, Infraction{IPHash: "ip1", Kind: KindBan,
			Reason: ReasonManual, EvidenceID: 7})
	}
	id, err := mk()
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Revoke(ctx, id, "op"); err != nil {
		t.Fatal(err)
	}
	if _, err := mk(); err != nil {
		t.Fatalf("re-banning after an unban must work: %v", err)
	}
}

// A consequence hides the offender's recent messages: stopping the next post while
// leaving the scam link pinned in the court would invert the priority.
func TestConsequenceHidesRecentMessages(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	id, err := post(t, s, "orem", "ip1", "claim your free airdrop")
	if err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(MinInterval)
	if _, err := post(t, s, "orem", "ip2", "an innocent bystander"); err != nil {
		t.Fatal(err)
	}
	inf, err := s.Consequence(ctx, Infraction{IPHash: "ip1", Kind: KindKick,
		Reason: ReasonSpam, Duration: time.Hour, EvidenceID: id})
	if err != nil {
		t.Fatal(err)
	}
	msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 1 || msgs[0].Body != "an innocent bystander" {
		t.Fatalf("only the offender's message should be hidden, got %+v", msgs)
	}
	// Revoking restores them, or the appeal is half an apology.
	if err := s.Revoke(ctx, inf, "op"); err != nil {
		t.Fatal(err)
	}
	if msgs, _ = s.Recent(ctx, "dev", "orem", 0, 50); len(msgs) != 2 {
		t.Fatalf("revoking must un-hide, got %d messages", len(msgs))
	}
}

func TestFrozenCourtRefusesPosts(t *testing.T) {
	s, _ := newStore(t)
	ctx := context.Background()
	if _, err := post(t, s, "orem", "ip1", "before the purge"); err != nil {
		t.Fatal(err)
	}
	if err := s.Freeze(ctx, "dev", "orem"); err != nil {
		t.Fatal(err)
	}
	if _, err := post(t, s, "orem", "ip2", "after the purge"); !errors.Is(err, ErrPurged) {
		t.Fatalf("a frozen court must refuse posts, got %v", err)
	}
	// Another court is unaffected — freezing is per court, not a kill switch.
	if _, err := post(t, s, "ipsum", "ip2", "a different court"); err != nil {
		t.Fatalf("freezing one court must not affect another: %v", err)
	}
}

// The requirement, as a test: with no scanner ever having run, chat works and
// health says plainly that nothing is being enforced.
func TestChatWorksWithNoScanner(t *testing.T) {
	s, _ := newStore(t)
	ctx := context.Background()
	if _, err := post(t, s, "orem", "ip1", "nobody is scanning this"); err != nil {
		t.Fatalf("chat must work with no scanner: %v", err)
	}
	h, err := s.Health(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !h.OK {
		t.Fatal("health must be ok with no scanner")
	}
	if h.Enforcing {
		t.Fatal("nothing may claim to be enforcing when no scanner has run")
	}
	if h.ScannerSeen != 0 {
		t.Fatal("an unseen scanner must not report a heartbeat")
	}
	if h.Backlog != 1 {
		t.Fatalf("the unscanned message should show as backlog, got %d", h.Backlog)
	}
	// And once it runs in dry-run, enforcing stays false: the label derives from
	// this, so it cannot imply moderation that is not happening.
	if err := s.Heartbeat(ctx, false); err != nil {
		t.Fatal(err)
	}
	if h, _ = s.Health(ctx); h.Enforcing || h.ScannerSeen == 0 {
		t.Fatalf("dry-run must report seen-but-not-enforcing, got %+v", h)
	}
}

// Cross-court duplicate posting is a RATE LIMIT: it refuses the message and
// records nothing, so being wrong costs a 429 rather than a punishment.
func TestCrossCourtDuplicateIsRefusedNotPunished(t *testing.T) {
	s, clock := newStore(t)
	const body = "claim your free airdrop at example dot com"
	for _, court := range []string{"a", "b"} {
		if _, err := post(t, s, court, "ip1", body); err != nil {
			t.Fatalf("court %s: %v", court, err)
		}
		*clock = clock.Add(MinInterval)
	}
	if _, err := post(t, s, "c", "ip1", body); !errors.Is(err, ErrDuplicate) {
		t.Fatalf("the third court must be refused, got %v", err)
	}
	var n int
	if err := s.r.QueryRow(`SELECT count(*) FROM infractions`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("a rate limit must not write an infraction, got %d", n)
	}
	// Paired positive: a DIFFERENT message in that third court is fine, so this
	// is not simply a cap on courts.
	if _, err := post(t, s, "c", "ip1", "something else entirely here"); err != nil {
		t.Fatalf("a different message must be accepted: %v", err)
	}
}

// The scanner's window is bounded by the last consequence, or an expired kick's
// own evidence keeps being re-judged and "hello" three times walks the ladder.
func TestWindowStopsAtTheLastConsequence(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	for _, b := range []string{"setup line one", "setup line two"} {
		if _, err := post(t, s, "orem", "ip1", b); err != nil {
			t.Fatal(err)
		}
		*clock = clock.Add(MinInterval)
	}
	if _, err := s.Consequence(ctx, Infraction{IPHash: "ip1", Kind: KindKick,
		Reason: ReasonSpam, Duration: time.Second}); err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(2 * time.Second)
	if _, err := post(t, s, "orem", "ip1", "hello again everyone"); err != nil {
		t.Fatal(err)
	}
	pend, err := s.Claim(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range pend {
		if p.Body != "hello again everyone" {
			continue
		}
		if len(p.Prior) != 0 {
			t.Fatalf("the window must not reach past a consequence, got %q", p.Prior)
		}
	}
}

func TestClaimMarksAndReclaims(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	if _, err := post(t, s, "orem", "ip1", "a message to scan"); err != nil {
		t.Fatal(err)
	}
	first, err := s.Claim(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(first) != 1 {
		t.Fatalf("want one claimed, got %d", len(first))
	}
	// A second daemon must not get the same row, or both would punish it.
	if again, err := s.Claim(ctx, 10); err != nil {
		t.Fatal(err)
	} else if len(again) != 0 {
		t.Fatal("a claimed row must not be handed out twice")
	}
	// But a dead daemon's claim must not strand the row forever.
	*clock = clock.Add(10 * time.Minute)
	if again, err := s.Claim(ctx, 10); err != nil {
		t.Fatal(err)
	} else if len(again) != 1 {
		t.Fatal("a stale claim must be reclaimed")
	}
}

func TestRecordFailureBacksOffAndGivesUp(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	id, err := post(t, s, "orem", "ip1", "this will fail to scan")
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		gaveUp, err := s.RecordFailure(ctx, id)
		if err != nil {
			t.Fatal(err)
		}
		// Both directions: only the LAST attempt reports giving up. The caller logs on
		// that signal, and a signal that fires every time is a signal nobody reads.
		if want := i == 4; gaveUp != want {
			t.Fatalf("attempt %d: gaveUp=%v, want %v", i+1, gaveUp, want)
		}
		*clock = clock.Add(time.Hour)
	}
	// Terminal: unscannable, and — the direction that matters — never punished.
	pend, err := s.Claim(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(pend) != 0 {
		t.Fatal("a row that keeps failing must stop being retried")
	}
	var n int
	if err := s.r.QueryRow(`SELECT count(*) FROM infractions`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatal("a failed scan must never punish anybody")
	}
}

func TestSecretIsStableAcrossCalls(t *testing.T) {
	s, _ := newStore(t)
	calls := 0
	gen := func() []byte {
		calls++
		b := make([]byte, 32)
		b[0] = byte(calls) // a different key each call, if it were ever called twice
		return b
	}
	a, err := s.Secret(gen)
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.Secret(gen)
	if err != nil {
		t.Fatal(err)
	}
	if string(a) != string(b) {
		t.Fatal("the secret must not change between calls: every consequence and " +
			"every public tag is keyed on it")
	}
	if len(a) != 32 {
		t.Fatalf("want a 32-byte key, got %d", len(a))
	}
}

// An automated consequence applies to ONE address. It must not reach the network,
// or one scam message from a shared connection punishes everybody behind it — which
// is precisely the mass-collateral this design exists to avoid. Found live: an
// untouched neighbour in the same /24 got a 403.
func TestAutomatedConsequenceDoesNotReachTheNetwork(t *testing.T) {
	s, _ := newStore(t)
	ctx := context.Background()
	const net = "shared-net"
	if _, err := s.Consequence(ctx, Infraction{
		IPHash: "offender", NetHash: net, Kind: KindKick,
		Reason: ReasonScam, Duration: time.Hour,
	}); err != nil {
		t.Fatal(err)
	}
	if st, err := s.Status(ctx, "offender", net); err != nil {
		t.Fatal(err)
	} else if !st.Blocked() {
		t.Fatal("the offender must be blocked")
	}
	if st, err := s.Status(ctx, "neighbour", net); err != nil {
		t.Fatal(err)
	} else if st.Blocked() {
		t.Fatalf("a neighbour sharing the network must NOT be blocked, got %+v", st)
	}

	// A MANUAL range ban is the one thing that does reach the network, because an
	// operator chose it deliberately.
	if _, err := s.Consequence(ctx, Infraction{
		IPHash: "irrelevant", NetHash: net, Kind: KindBan, Reason: ReasonManual,
	}); err != nil {
		t.Fatal(err)
	}
	if st, err := s.Status(ctx, "neighbour", net); err != nil {
		t.Fatal(err)
	} else if st.State != KindBan {
		t.Fatalf("a manual range ban must reach the network, got %+v", st)
	}
}

// THE LADDER DECAYS, and a patient offender starts again at an hour.
//
// LadderLookback is thirty days and nothing tested it, which left the whole escalation
// story resting on an untested constant. Both directions matter and they pull opposite
// ways: without a decay an address carries a scam forever, and addresses are reassigned
// constantly — DHCP, CGNAT, a café's NAT — so "forever" eventually punishes a stranger who
// inherited the address rather than the person who earned it. With too short a decay a
// repeat offender is never more than an hour from posting again.
func TestTheLadderForgetsAfterTheLookback(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()

	// Two automated kicks put this address on the third rung.
	for i := 0; i < 2; i++ {
		if _, err := s.Consequence(ctx, Infraction{
			IPHash: "ip1", Kind: KindKick, Reason: ReasonSpam, Duration: time.Hour,
		}); err != nil {
			t.Fatal(err)
		}
	}
	if d, _ := s.Escalate(ctx, "ip1"); d != Ladder[2] {
		t.Fatalf("two prior kicks must reach the third rung, got %s", d)
	}

	// Just INSIDE the window: still remembered. Checked before the decay, or a passing
	// decay test could be passing because the count was broken all along.
	*clock = clock.Add(LadderLookback - time.Hour)
	if d, _ := s.Escalate(ctx, "ip1"); d != Ladder[2] {
		t.Fatalf("inside the lookback the history must still count, got %s", d)
	}

	// Just OUTSIDE: forgotten, back to an hour.
	*clock = clock.Add(2 * time.Hour)
	if d, _ := s.Escalate(ctx, "ip1"); d != Ladder[0] {
		t.Fatalf("past the lookback the ladder must reset to the first rung, got %s", d)
	}

	// And a fresh offence starts the climb again rather than resuming at the top.
	if _, err := s.Consequence(ctx, Infraction{
		IPHash: "ip1", Kind: KindKick, Reason: ReasonSpam, Duration: time.Hour,
	}); err != nil {
		t.Fatal(err)
	}
	if d, _ := s.Escalate(ctx, "ip1"); d != Ladder[1] {
		t.Fatalf("one offence after the reset is the second rung, got %s", d)
	}
}

// A HUMAN'S DECISION DOES NOT INFLATE THE MACHINE'S LADDER.
//
// Escalate counts only `reason <> manual`, so an operator's kick — however justified —
// leaves the next automated timeout at whatever rung the SCANNER had reached on its own.
// Pinned because it is a deliberate asymmetry and reads like an oversight: the ladder is
// the scanner's own record with an address, and letting a manual action raise it would
// mean a human intervening once quietly made every later automated verdict harsher, in a
// system whose entire safety argument is that automation cannot reach for the severe end.
func TestAManualConsequenceDoesNotRaiseTheAutomatedLadder(t *testing.T) {
	s, _ := newStore(t)
	ctx := context.Background()

	for i := 0; i < 3; i++ {
		if _, err := s.Consequence(ctx, Infraction{
			IPHash: "ip1", Kind: KindKick, Reason: ReasonManual, Duration: time.Hour,
			Detail: "an operator's judgement",
		}); err != nil {
			t.Fatal(err)
		}
	}
	if d, _ := s.Escalate(ctx, "ip1"); d != Ladder[0] {
		t.Fatalf("three manual kicks must leave the automated ladder at the first rung, got %s", d)
	}
	// PAIRED POSITIVE: the same three, automated, do climb it — otherwise the assertion
	// above would pass on a ladder that never moved at all.
	if _, err := s.Consequence(ctx, Infraction{
		IPHash: "ip2", Kind: KindKick, Reason: ReasonSpam, Duration: time.Hour,
	}); err != nil {
		t.Fatal(err)
	}
	if d, _ := s.Escalate(ctx, "ip2"); d != Ladder[1] {
		t.Fatalf("an automated kick must climb the ladder, got %s", d)
	}
}

// "IN FORCE" MUST MEAN IN FORCE — not "never reversed".
//
// Fourth predicate in this file found living in several copies, and the copies had already
// disagreed: statusTx and the pruner checked reversal AND expiry, while CountInfractions and
// ListInfractions checked only reversal. `kourtchatctl status` printed the count as "in force"
// and `list` listed under a heading promising the same, so both answered a different question.
//
// Measured before the fix, with one hour-long kick, one permanent ban and one revoked kick:
// fresh, status said 2 and the enforcer blocked 2; two hours later status still said 2 while
// the enforcer blocked 1; two months later, unchanged. An operator-facing count that only
// grows, in a design whose entire claim about automated moderation is that it expires.
//
// The enforcer is the authority here, so it is what the count is compared against — not a
// number this test computes for itself.
func TestInForceMeansInForce(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()

	// One that will expire, one permanent, one reversed.
	if _, err := s.Consequence(ctx, Infraction{IPHash: "ip-a", Kind: KindKick,
		Reason: ReasonSpam, Duration: time.Hour}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Consequence(ctx, Infraction{IPHash: "ip-b", Kind: KindBan,
		Reason: ReasonManual, Detail: "by hand"}); err != nil {
		t.Fatal(err)
	}
	revoked, err := s.Consequence(ctx, Infraction{IPHash: "ip-c", Kind: KindKick,
		Reason: ReasonSpam, Duration: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Revoke(ctx, revoked, "appeal upheld"); err != nil {
		t.Fatal(err)
	}

	// blocked asks the ENFORCER, which is the only authority on what is in force.
	blocked := func() int {
		n := 0
		for _, ip := range []string{"ip-a", "ip-b", "ip-c"} {
			st, err := s.Status(ctx, ip, "net-"+ip)
			if err != nil {
				t.Fatal(err)
			}
			if st.State != "ok" {
				n++
			}
		}
		return n
	}
	agree := func(when string) {
		t.Helper()
		count, err := s.CountInfractions(ctx, false)
		if err != nil {
			t.Fatal(err)
		}
		rows, err := s.ListInfractions(ctx, "", false, 50)
		if err != nil {
			t.Fatal(err)
		}
		want := blocked()
		if count != want {
			t.Errorf("%s: status would say %d in force, the enforcer blocks %d", when, count, want)
		}
		if len(rows) != want {
			t.Errorf("%s: list shows %d in force, the enforcer blocks %d", when, len(rows), want)
		}
		for _, r := range rows {
			if r.RevokedAt != 0 {
				t.Errorf("%s: a reversed consequence is not in force: id=%d", when, r.ID)
			}
			if r.ExpiresAt != 0 && r.ExpiresAt <= clock.Unix() {
				t.Errorf("%s: an expired consequence is not in force: id=%d", when, r.ID)
			}
		}
	}

	// FRESH: two live, one reversed. This is the arm that was already correct, and it is here
	// so the fix cannot be "return zero".
	agree("fresh")
	if blocked() != 2 {
		t.Fatalf("precondition: two should be blocking, got %d", blocked())
	}

	// EXPIRED: the kick lapses, the ban does not.
	*clock = clock.Add(2 * time.Hour)
	agree("two hours later")
	if blocked() != 1 {
		t.Fatalf("only the permanent ban should remain, got %d", blocked())
	}
	*clock = clock.Add(60 * 24 * time.Hour)
	agree("two months later")

	// AND HISTORY IS STILL THERE, which is what -all is for. A fix that simply stopped
	// counting things would pass everything above.
	all, err := s.CountInfractions(ctx, true)
	if err != nil {
		t.Fatal(err)
	}
	if all != 3 {
		t.Errorf("every consequence ever must still be countable, got %d", all)
	}
	rows, err := s.ListInfractions(ctx, "", true, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 3 {
		t.Errorf("and listable, got %d", len(rows))
	}
	// Including the expired one, which is the row an operator goes looking for after an
	// appeal about something that has already lapsed.
	found := false
	for _, r := range rows {
		if r.IPHash == "ip-a" {
			found = true
		}
	}
	if !found {
		t.Error("an expired consequence must remain readable under -all")
	}
}

// A CONSEQUENCE MUST HIDE THE MESSAGE IT CITES, however late it arrives.
//
// The hide was a ten-minute window and nothing else, so the cited message was removed from view
// only when it happened to fall inside it. §7 exists because "a ban stops new posts; the scam
// link stays pinned in the court forever" — and a slow scanner reproduced exactly that:
//
//	scanner 1 minute behind    author kicked, the scam hidden
//	scanner 11 minutes behind  author kicked, the scam STILL VISIBLE
//
// A backlog is not an edge case: Claim scans newest-first precisely because after an outage the
// currently-harmful messages are scanned last. The fix failed in the condition that motivated it.
func TestALateConsequenceStillHidesItsEvidence(t *testing.T) {
	for _, lag := range []time.Duration{time.Minute, HideWindow + time.Minute, 2 * time.Hour} {
		t.Run(lag.String(), func(t *testing.T) {
			s, clock := newStore(t)
			ctx := context.Background()

			id, err := post(t, s, "orem", "ip-crook", "send me your seed phrase")
			if err != nil {
				t.Fatal(err)
			}
			*clock = clock.Add(lag)
			if _, err := s.Consequence(ctx, Infraction{
				IPHash: "ip-crook", NetHash: "net-crook", Kind: KindKick, Reason: ReasonScam,
				Duration: time.Hour, EvidenceID: id, Evidence: "send me your seed phrase",
			}); err != nil {
				t.Fatal(err)
			}
			msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
			if err != nil {
				t.Fatal(err)
			}
			if len(msgs) != 0 {
				t.Fatalf("the cited message must be hidden whatever the lag; still showing %q",
					msgs[0].Body)
			}
			// And the author is kicked, so the fixture is not passing because nothing happened.
			st, err := s.Status(ctx, "ip-crook", "net-crook")
			if err != nil {
				t.Fatal(err)
			}
			if st.State == "ok" {
				t.Fatal("the author must be kicked too")
			}
		})
	}
}

// THE BYSTANDER, for the new path into hiding. The id clause is a second way a consequence can
// reach a message, and the narrow window exists precisely because of collateral on shared
// addresses — so the new clause is scoped to the same author, and a mis-set evidence_id must not
// be able to hide a stranger.
func TestHidingByCitationCannotReachAnotherAuthor(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()

	// A neighbour on the SAME network, different address, who said something long ago and
	// something just now — plus something the OFFENDER said long ago, which must also
	// survive: a timeout removes the recent burst, not an author's whole history.
	old, err := post(t, s, "orem", "ip-neighbour", "an old remark from the neighbour")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := post(t, s, "orem", "ip-crook", "something the offender said long ago"); err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(2 * time.Hour)
	if _, err := post(t, s, "orem", "ip-neighbour", "and a recent one too"); err != nil {
		t.Fatal(err)
	}
	if _, err := post(t, s, "orem", "ip-crook", "send me your seed phrase"); err != nil {
		t.Fatal(err)
	}

	// A consequence against the crook that WRONGLY cites the neighbour's old message.
	if _, err := s.Consequence(ctx, Infraction{
		IPHash: "ip-crook", NetHash: "net-crook", Kind: KindKick, Reason: ReasonScam,
		Duration: time.Hour, EvidenceID: old, Evidence: "an old remark from the neighbour",
	}); err != nil {
		t.Fatal(err)
	}

	msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	var left []string
	for _, m := range msgs {
		left = append(left, m.Body)
	}
	// The neighbour's OLD message must survive: it is not theirs to hide.
	found := false
	for _, b := range left {
		if b == "an old remark from the neighbour" {
			found = true
		}
	}
	if !found {
		t.Errorf("a citation must not reach another author's message; left %v", left)
	}
	// The neighbour's recent message must survive too — the window is per address.
	recent := false
	for _, b := range left {
		if b == "and a recent one too" {
			recent = true
		}
	}
	if !recent {
		t.Errorf("the window is per address; the neighbour's recent message must survive: %v", left)
	}
	// PAIRED POSITIVE: the crook's own recent message IS hidden, so the fixture is not
	// passing because hiding stopped working altogether.
	for _, b := range left {
		if b == "send me your seed phrase" {
			t.Error("the offender's own recent message must still be hidden")
		}
	}
	// AND THE OTHER EDGE OF THE WINDOW: the offender's own OLD message survives. The window
	// is narrow on purpose — a timeout removes a burst, not a history — and widening it to
	// everything passed every other assertion here, because the bystander is a different
	// address and nothing spoke for the offender's own past.
	ownOld := false
	for _, b := range left {
		if b == "something the offender said long ago" {
			ownOld = true
		}
	}
	if !ownOld {
		t.Errorf("a timeout must not retroactively hide the offender's whole history: %v", left)
	}
	st, err := s.Status(ctx, "ip-neighbour", "net-crook")
	if err != nil {
		t.Fatal(err)
	}
	if st.State != "ok" {
		t.Errorf("and the neighbour must not be punished, got %q", st.State)
	}
}

// REVERSING ONE CONSEQUENCE MUST NOT REPUBLISH ANOTHER'S EVIDENCE.
//
// Revoke did a blanket `hidden=0` for the whole address, while §7 says `hidden` is "recomputed
// on revocation" — a different thing as soon as an address has two consequences. Measured: with a
// manual kick and a scam kick both live, reversing the manual one put "send me your seed phrase
// now" back in the room. The author stayed kicked by the scam consequence and their scam was
// readable again.
//
// That is §7's own failure mode — "a ban stops new posts; the scam link stays pinned" — reached
// from the one direction nobody would think to look: an operator granting an appeal.
func TestReversingOneConsequenceKeepsTheOthersHides(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()

	// Both messages first: after the first consequence the address cannot post, so a fixture
	// that posts between them measures the throttle instead of this.
	wrong, err := post(t, s, "orem", "ip-x", "a wrong call by the operator")
	if err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(MinInterval + time.Second)
	scam, err := post(t, s, "orem", "ip-x", "send me your seed phrase now")
	if err != nil {
		t.Fatal(err)
	}

	manual, err := s.Consequence(ctx, Infraction{IPHash: "ip-x", NetHash: "net-x",
		Kind: KindKick, Reason: ReasonManual, Duration: time.Hour,
		EvidenceID: wrong, Evidence: "a wrong call by the operator"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Consequence(ctx, Infraction{IPHash: "ip-x", NetHash: "net-x",
		Kind: KindKick, Reason: ReasonScam, Duration: 24 * time.Hour,
		EvidenceID: scam, Evidence: "send me your seed phrase now"}); err != nil {
		t.Fatal(err)
	}

	visible := func() []string {
		t.Helper()
		msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
		if err != nil {
			t.Fatal(err)
		}
		var out []string
		for _, m := range msgs {
			out = append(out, m.Body)
		}
		return out
	}
	if len(visible()) != 0 {
		t.Fatalf("precondition: both consequences should have hidden everything, got %v", visible())
	}

	// The operator grants the appeal about the manual call. The scam consequence stands.
	if err := s.Revoke(ctx, manual, "appeal upheld on the manual one"); err != nil {
		t.Fatal(err)
	}
	for _, body := range visible() {
		if strings.Contains(body, "seed phrase") {
			t.Error("reversing one consequence must not republish evidence for another that " +
				"is still in force")
		}
	}
	st, err := s.Status(ctx, "ip-x", "net-x")
	if err != nil {
		t.Fatal(err)
	}
	if st.State == "ok" {
		t.Fatal("precondition: the scam consequence should still be in force")
	}

	// PAIRED POSITIVE: reversing the LAST one restores everything, so this is not a fix that
	// simply stopped un-hiding. Without it, "unban" would be half an apology.
	rows, err := s.ListInfractions(ctx, "", true, 10)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rows {
		if r.RevokedAt == 0 {
			if err := s.Revoke(ctx, r.ID, "appeal upheld on the rest"); err != nil {
				t.Fatal(err)
			}
		}
	}
	if got := visible(); len(got) != 2 {
		t.Fatalf("with every consequence reversed, all messages come back: got %v", got)
	}
}

// The recompute must honour a CITATION as well as a window, which took a late consequence to
// show. Every earlier fixture had the cited message inside the surviving consequence's window,
// so the window clause covered it and dropping the citation clause changed nothing.
//
// A consequence issued long after the message it cites is not exotic — Claim scans newest-first
// precisely because a backlog means the harmful messages are reached last — so this is the same
// case as a late kick hiding its own evidence, now met during an appeal about something else.
func TestTheRecomputeHonoursACitationOutsideTheWindow(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()

	old, err := post(t, s, "orem", "ip-z", "the old message a late consequence will cite")
	if err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(HideWindow + time.Hour) // far outside any window
	recent, err := post(t, s, "orem", "ip-z", "a recent message about the docket")
	if err != nil {
		t.Fatal(err)
	}

	// One consequence about the recent message, issued while it is fresh.
	appealed, err := s.Consequence(ctx, Infraction{IPHash: "ip-z", NetHash: "net-z",
		Kind: KindKick, Reason: ReasonManual, Duration: time.Hour,
		EvidenceID: recent, Evidence: "a recent message about the docket"})
	if err != nil {
		t.Fatal(err)
	}
	// Then time passes, and a LATE consequence cites the old message. Its window reaches
	// NEITHER message, which is what makes the citation clause the only thing hiding the old
	// one — and the first version of this fixture issued both at the same instant, so the
	// surviving window covered everything and the test proved nothing about citations.
	*clock = clock.Add(HideWindow + time.Hour)
	if _, err := s.Consequence(ctx, Infraction{IPHash: "ip-z", NetHash: "net-z",
		Kind: KindKick, Reason: ReasonScam, Duration: 24 * time.Hour,
		EvidenceID: old, Evidence: "the old message a late consequence will cite"}); err != nil {
		t.Fatal(err)
	}
	msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 0 {
		t.Fatalf("precondition: both should be hidden, got %v", msgs)
	}

	// Reverse the one about the recent message. The late consequence still stands and still
	// cites the old one, which the window does not reach.
	if err := s.Revoke(ctx, appealed, "appeal upheld"); err != nil {
		t.Fatal(err)
	}
	var bodies []string
	msgs, err = s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range msgs {
		bodies = append(bodies, m.Body)
	}
	for _, b := range bodies {
		if strings.Contains(b, "the old message") {
			t.Error("a message cited by a consequence still in force must stay hidden, even " +
				"when no window reaches it")
		}
	}
	// PAIRED: the appealed message is back.
	if len(bodies) != 1 || !strings.Contains(bodies[0], "a recent message") {
		t.Errorf("the appealed message must be restored and only it: %v", bodies)
	}
}

// And expiry is NOT revocation: a kick that simply ran its course leaves its evidence out of
// sight, because §7 exists to stop a scam being pinned in a court and a lapsed timeout is not
// somebody saying the decision was wrong. Only `unban` says that.
func TestAnExpiredConsequenceKeepsItsEvidenceHidden(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()

	id, err := post(t, s, "orem", "ip-y", "send me your seed phrase now")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Consequence(ctx, Infraction{IPHash: "ip-y", NetHash: "net-y",
		Kind: KindKick, Reason: ReasonScam, Duration: time.Hour,
		EvidenceID: id, Evidence: "send me your seed phrase now"}); err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(2 * time.Hour) // the kick lapses on its own

	st, err := s.Status(ctx, "ip-y", "net-y")
	if err != nil {
		t.Fatal(err)
	}
	if st.State != "ok" {
		t.Fatalf("precondition: the kick should have expired, got %q", st.State)
	}
	msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 0 {
		t.Errorf("an expired consequence keeps its evidence hidden; got %d visible", len(msgs))
	}
}

// A DISCLOSED SECRET SURVIVES SOMEBODY ELSE'S APPEAL.
//
// Revoke recomputes `hidden` from the consequences that still stand, which is right — and it
// treated a hide with no consequence behind it as one to undo. Measured: an address with a
// message hidden as a disclosed secret, plus a later unrelated kick; reversing the kick put the
// recovery phrase back in the room. The secret was never a punishment, so an appeal about
// something else cannot be a reason to republish it.
//
// This one only surfaced from a mutation. Widening the recompute to every address looked
// harmless — the recompute is a function of each row's own consequences — until it met a hide
// that had no consequence behind it at all.
func TestADisclosedSecretSurvivesAnUnrelatedAppeal(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()

	secret, err := post(t, s, "orem", "ip-h", "fyi someone sent me these words: legal winner")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.HideMessage(ctx, secret); err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(time.Hour) // well outside any hide window
	other, err := post(t, s, "orem", "ip-h", "and an unrelated remark later on")
	if err != nil {
		t.Fatal(err)
	}
	id, err := s.Consequence(ctx, Infraction{IPHash: "ip-h", NetHash: "net-h",
		Kind: KindKick, Reason: ReasonManual, Duration: time.Hour,
		EvidenceID: other, Evidence: "and an unrelated remark later on"})
	if err != nil {
		t.Fatal(err)
	}

	if err := s.Revoke(ctx, id, "appeal upheld"); err != nil {
		t.Fatal(err)
	}
	msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	var bodies []string
	for _, m := range msgs {
		bodies = append(bodies, m.Body)
		if strings.Contains(m.Body, "legal winner") {
			t.Error("an appeal about something else must not republish a disclosed secret")
		}
	}
	// PAIRED POSITIVE: the message the appeal WAS about comes back, or unban is half an apology.
	found := false
	for _, b := range bodies {
		if b == "and an unrelated remark later on" {
			found = true
		}
	}
	if !found {
		t.Errorf("the appealed message must be restored: visible=%v", bodies)
	}
}

// A CONSEQUENCE'S WINDOW LOOKS BACKWARD ONLY.
//
// Consequence writes `created_at > now - HideWindow` with no upper bound, which is exact at the
// instant it runs, because nothing can be newer than now. Revoke's recompute evaluates the same
// idea later and has no such luxury: without an upper bound, an old unrevoked consequence hides
// everything posted after it, for as long as it exists.
//
// Found by running it, not by testing it. Every unit fixture posted its messages before any
// consequence, so no message was ever newer than one — and a live walk-through where somebody
// offended, waited out the kick, posted again, and had the second decision reversed left the
// second message hidden by the first consequence's window.
func TestAConsequenceDoesNotHideWhatCameAfterIt(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()

	first, err := post(t, s, "orem", "ip-w", "send me your seed phrase, the first offence")
	if err != nil {
		t.Fatal(err)
	}
	old, err := s.Consequence(ctx, Infraction{IPHash: "ip-w", NetHash: "net-w",
		Kind: KindKick, Reason: ReasonScam, Duration: time.Hour,
		EvidenceID: first, Evidence: "send me your seed phrase, the first offence"})
	if err != nil {
		t.Fatal(err)
	}

	// The kick runs its course. It is never revoked, so its evidence stays out of sight.
	*clock = clock.Add(2 * time.Hour)
	later, err := post(t, s, "orem", "ip-w", "a fresh remark the operator misjudges")
	if err != nil {
		t.Fatal(err)
	}
	wrong, err := s.Consequence(ctx, Infraction{IPHash: "ip-w", NetHash: "net-w",
		Kind: KindKick, Reason: ReasonManual, Duration: time.Hour,
		EvidenceID: later, Evidence: "a fresh remark the operator misjudges"})
	if err != nil {
		t.Fatal(err)
	}

	// The operator grants the appeal about the second decision.
	if err := s.Revoke(ctx, wrong, "appeal upheld"); err != nil {
		t.Fatal(err)
	}
	msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	var bodies []string
	for _, m := range msgs {
		bodies = append(bodies, m.Body)
	}
	// The appealed message comes back: the only consequence that concerned it is reversed, and
	// the older one predates it, so its backward-looking window cannot reach forward.
	if len(bodies) != 1 || !strings.Contains(bodies[0], "a fresh remark") {
		t.Errorf("an older consequence must not hide a message posted after it: visible=%v", bodies)
	}
	// And the first offence stays hidden, because expiry is not revocation.
	for _, b := range bodies {
		if strings.Contains(b, "seed phrase") {
			t.Error("an expired but unreversed consequence keeps its evidence hidden")
		}
	}
	_ = old
}

// THE FAIR SHARE MUST NOT THROTTLE A CONVERSATION.
//
// `courtTotal >= CourtSoftCap && courtMine >= FairShare` is the most conditional rule in this
// file, its comment claims it "binds ONLY under contention", and nothing tested that ordinary
// talking survives it. A rate limiter that quietly taxes real conversation is the failure nobody
// reports — they just stop typing.
//
// Measured: 2, 5 and 12 people talking at a human pace, twelve rounds each, zero refusals. The
// reason is worth writing down because it does not follow from the constants. Twelve people at
// one message per twenty seconds is 36 messages a minute, well past CourtSoftCap — but the
// window holds only three rounds and an author's own pending message is not counted yet, so
// courtMine peaks at 2 and the second clause never fires however many people are present.
//
// Which means the rule keys on how fast ONE address talks, not on how many people are in the
// room. That is the property to pin, and it is not what the constants look like they say.
func TestOrdinaryConversationIsNeverThrottled(t *testing.T) {
	for _, people := range []int{2, 5, 12} {
		t.Run(fmt.Sprintf("%d people", people), func(t *testing.T) {
			s, clock := newStore(t)
			ctx := context.Background()
			sent := 0
			for round := 0; round < 12; round++ {
				for p := 0; p < people; p++ {
					if _, err := s.Post(ctx, PostInput{
						Chain: "dev", Court: "orem", Moniker: fmt.Sprintf("p%d", p),
						Body:   fmt.Sprintf("person %d at round %d, about the docket", p, round),
						IPHash: fmt.Sprintf("ip%d", p), NetHash: "net-shared",
					}); err != nil {
						t.Errorf("round %d, person %d refused: %v", round, p, err)
					} else {
						sent++
					}
				}
				*clock = clock.Add(20 * time.Second)
			}
			if sent != people*12 {
				t.Fatalf("only %d of %d messages were accepted in an ordinary conversation",
					sent, people*12)
			}
		})
	}
}

// AND IT IS A SHARE, NOT A MUTE BUTTON. Under real contention a fast talker is capped — that is
// the point — but somebody who has said nothing can still get a word in. Without that second
// half, whoever types fastest would silence the room, which is what a court-wide cap alone does
// and the reason it is not used alone.
//
// Filling the court needs 15 addresses rather than 10: at 10 the fill itself reaches FairShare on
// its fourth round and gets throttled, which is the rule working correctly and would have made
// this fixture measure its own setup.
func TestUnderContentionAFairShareStillLetsANewcomerSpeak(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	say := func(ip, body string) error {
		_, err := s.Post(ctx, PostInput{Chain: "dev", Court: "orem", Moniker: ip,
			Body: body, IPHash: ip, NetHash: "net-" + ip})
		return err
	}

	// Fill the court to its soft cap, spread widely enough that no single address is near its
	// own share: 15 addresses, two messages each.
	for round := 0; round < 2; round++ {
		for p := 0; p < 15; p++ {
			if err := say(fmt.Sprintf("bg%02d", p),
				fmt.Sprintf("background talk %d from %d", round, p)); err != nil {
				t.Fatalf("the fill must not be throttled or this measures its own setup: %v", err)
			}
		}
		*clock = clock.Add(5 * time.Second)
	}
	var inWindow int
	if err := s.r.QueryRow(`SELECT count(*) FROM messages WHERE created_at > ?`,
		clock.Add(-CourtWindow).Unix()).Scan(&inWindow); err != nil {
		t.Fatal(err)
	}
	if inWindow < CourtSoftCap {
		t.Fatalf("precondition: the court must be contended, %d < %d", inWindow, CourtSoftCap)
	}

	// A fast talker gets exactly their share and is then told why.
	accepted := 0
	var lastErr error
	for i := 0; i < 6; i++ {
		if err := say("fasttalker", fmt.Sprintf("replying quickly, point %d", i)); err != nil {
			lastErr = err
		} else {
			accepted++
		}
		*clock = clock.Add(MinInterval + time.Second)
	}
	if accepted != FairShare {
		t.Errorf("a contended court should allow exactly FairShare=%d, got %d", FairShare, accepted)
	}
	if !errors.Is(lastErr, ErrThrottled) {
		t.Errorf("the refusal must be a throttle, got %v", lastErr)
	}
	if lastErr != nil && !strings.Contains(lastErr.Error(), "had its share") {
		t.Errorf("and it must say why, got %q", lastErr)
	}

	// THE HALF THAT MAKES IT FAIR: somebody who has said nothing is not shut out.
	if err := say("newcomer", "hello, I have a question about claim 7"); err != nil {
		t.Errorf("a newcomer must still be able to speak in a busy court: %v", err)
	}
}

// The global budget SHEDS rather than denies: past GlobalMax an address already talking keeps
// going and a brand-new one waits. `mine` there is the per-address count across ALL courts, so
// "new" means has said nothing anywhere in the window — not nothing in this court.
//
// Saturating the window takes 300 messages inside sixty seconds, which only works if the clock
// advances between ROUNDS rather than between posts: MinInterval is per address, so sixty
// addresses can speak at the same instant. Advancing per post spreads 300 messages over fifteen
// minutes and the window never holds more than twenty — which is how the first version of this
// fixture skipped itself.
func TestTheGlobalBudgetShedsNewAddressesNotEstablishedOnes(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	say := func(ip, court, body string) error {
		_, err := s.Post(ctx, PostInput{Chain: "dev", Court: court, Moniker: ip,
			Body: body, IPHash: ip, NetHash: "net-" + ip})
		return err
	}

	// 60 addresses over 20 courts, five rounds: 300 in the window, 15 per court (under the soft
	// cap) and 5 per address (under PerIPMax), so the GLOBAL rule is what this measures.
	const addrs, rounds, courts = 60, 5, 20
	for round := 0; round < rounds; round++ {
		for p := 0; p < addrs; p++ {
			if err := say(fmt.Sprintf("ip%02d", p), fmt.Sprintf("court%d", p%courts),
				fmt.Sprintf("filler %d from %d in the global window", round, p)); err != nil {
				t.Fatalf("round %d, address %d: the fill must be accepted, or the other limits "+
					"are what this fixture is measuring: %v", round, p, err)
			}
		}
		*clock = clock.Add(MinInterval + time.Second)
	}
	var inWindow int
	if err := s.r.QueryRow(`SELECT count(*) FROM messages WHERE created_at > ?`,
		clock.Add(-GlobalWindow).Unix()).Scan(&inWindow); err != nil {
		t.Fatal(err)
	}
	if inWindow < GlobalMax {
		t.Fatalf("precondition: the global window must be saturated, %d < %d", inWindow, GlobalMax)
	}

	// Established — has posted inside the window. Must keep going.
	if err := say("ip39", "court3", "still talking, already established here"); err != nil {
		t.Errorf("an established address must not be shed: %v", err)
	}
	// New — has said nothing anywhere. Waits, and is told it is the service rather than blamed.
	err := say("stranger", "court3", "hello, first time posting here")
	if !errors.Is(err, ErrThrottled) {
		t.Errorf("a new address must be shed while the service is saturated, got %v", err)
	}
	if err != nil && !strings.Contains(err.Error(), "saturated") {
		t.Errorf("and told it is the service, not them: %q", err)
	}
}

// The other half of "binds ONLY under contention": in a QUIET court a single address is not held
// to FairShare at all — it gets the full per-address allowance, because the court's budget is
// sitting idle and there is nobody to be fair to.
//
// This arm exists because of a mutation: deleting `courtTotal >= CourtSoftCap` turns the rule
// into a flat three-per-minute quota and survives every other fixture in this file, since none of
// them has a fast talker in an empty room. It is also the case the rule's own comment names first
// — "a flat per-address quota would throttle two people talking while most of the court's budget
// sat idle".
func TestAQuietCourtHoldsNobodyToTheFairShare(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	say := func(ip, body string) error {
		_, err := s.Post(ctx, PostInput{Chain: "dev", Court: "orem", Moniker: ip,
			Body: body, IPHash: ip, NetHash: "net-" + ip})
		return err
	}

	// One person, well past FairShare, alone. PerIPMax is the only thing that should stop them.
	for i := 0; i < PerIPMax; i++ {
		if err := say("alone", fmt.Sprintf("thinking out loud, part %d of the argument", i)); err != nil {
			t.Fatalf("message %d of %d in an empty court was refused: %v", i+1, PerIPMax, err)
		}
		*clock = clock.Add(MinInterval + time.Second)
	}
	// And that IS where it stops, so the paragraph above is a measurement rather than a claim
	// that this address is unlimited.
	if err := say("alone", "one more thought before I stop"); !errors.Is(err, ErrThrottled) {
		t.Errorf("the per-address limit must still apply, got %v", err)
	} else if !strings.Contains(err.Error(), "per 1m0s") {
		t.Errorf("and it must be the per-address one, not the fair share: %q", err)
	}

	// Two people going back and forth quickly in a quiet court: the case the comment names.
	*clock = clock.Add(PerIPWindow)
	for i := 0; i < 5; i++ {
		for _, who := range []string{"ann", "bob"} {
			if err := say(who, fmt.Sprintf("%s, turn %d of the back and forth", who, i)); err != nil {
				t.Errorf("a two-person exchange must not be throttled (%s, turn %d): %v",
					who, i, err)
			}
		}
		*clock = clock.Add(MinInterval + time.Second)
	}
}

// THE CROSS-COURT RULE MUST NOT REFUSE ORDINARY SPEECH, which is what DupMinSkeleton = 12 did.
//
// The rule exists to stop one sentence being broadcast into three rooms. Its threshold was a bare
// 12 with no stated reason, and 12 is shorter than the things people genuinely repeat between
// rooms: measured over 29 such phrases, 13 were refused — "thanks everyone", "good morning all",
// "still waiting", "same question here" among them. A rate limit that refuses somebody for saying
// thanks in a third court is the failure the "pair every refusal with the ordinary input it must
// NOT refuse" rule exists to catch, and this table is that pairing.
//
// These are asserted at the RULE's threshold rather than at 16 directly, so raising the constant
// again cannot silently start refusing them.
func TestOrdinaryPhrasesRepeatedBetweenRoomsAreAccepted(t *testing.T) {
	ordinary := []string{
		"thanks everyone", "good morning all", "same question here", "still waiting",
		"I agree with that", "that worked, thanks", "following this one", "welcome aboard",
		"makes sense to me", "see you tomorrow", "fixed it, thanks",
	}
	for _, body := range ordinary {
		t.Run(body, func(t *testing.T) {
			s, clock := newStore(t)
			// Three courts, the same phrase, well inside DupWindow.
			for _, court := range []string{"a", "b", "c"} {
				if _, err := post(t, s, court, "ip1", body); err != nil {
					t.Fatalf("court %s refused %q: %v — ordinary repeated speech must pass; "+
						"its skeleton is %d runes against DupMinSkeleton=%d",
						court, body, err, len([]rune(Skeleton(body))), DupMinSkeleton)
				}
				*clock = clock.Add(MinInterval)
			}
		})
	}
}

// AND IT MUST STILL REFUSE A BROADCAST. The paired negative, starting at the threshold itself, so
// this fixture fails if the constant is raised further rather than passing quietly on a rule that
// no longer does anything.
//
// "send me your seed phrase" was in this list and is NOT any more: at 20 skeleton runes it sits
// below DupMinSkeleton, and it never needed a rate limit — the prefilter gives it a deterministic
// SCAM floor, which is a consequence rather than a refused message. Written down because a lure
// dropped from a table with no reason beside it is how coverage disappears quietly.
func TestABroadcastLureIsStillRefusedInTheThirdCourt(t *testing.T) {
	for _, body := range []string{
		"check my profile for the link",              // 24 skeleton runes: the threshold itself
		"urgent: verify your wallet now",             // 25
		"contact support at t dot me slash help",     // 31
		"claim your free airdrop at example dot com", // 35
	} {
		t.Run(body, func(t *testing.T) {
			s, clock := newStore(t)
			for _, court := range []string{"a", "b"} {
				if _, err := post(t, s, court, "ip1", body); err != nil {
					t.Fatalf("court %s: %v", court, err)
				}
				*clock = clock.Add(MinInterval)
			}
			if _, err := post(t, s, "c", "ip1", body); !errors.Is(err, ErrDuplicate) {
				t.Fatalf("the third court must refuse a broadcast %q (skeleton %d, "+
					"DupMinSkeleton %d), got %v",
					body, len([]rune(Skeleton(body))), DupMinSkeleton, err)
			}
		})
	}
}

// THE REPLAY GUARD, which is what stops two scanners punishing one message twice.
//
// `infractions_once` is UNIQUE(evidence_id, kind) WHERE evidence_id IS NOT NULL AND revoked_at IS
// NULL, and Consequence turns its violation into (0, nil) rather than an error. Its comment says
// that is "what stops a crash between punish and mark-scanned from walking the ladder", and nothing
// tested it — the crash it describes is hard to stage, so the property went unasserted while being
// relied on.
//
// It is not hypothetical. Two kourtmod processes against one database is an ordinary deployment
// state: a restart overlap, or an operator starting a second instance. Measured live with two
// --enforce scanners and three lures, every message was scanned once and earned exactly one
// consequence, with the infraction ids interleaved across the two processes — so they really did
// race. This fixture is the deterministic half of that run.
//
// All four arms of the index are exercised, because three of them are exemptions and an exemption
// that stops working is a duplicate consequence nobody sees.
func TestOneMessageEarnsOneConsequenceHoweverManyScannersSeeIt(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()

	id, err := post(t, s, "orem", "ip-crook", "send me your seed phrase and I will restore it")
	if err != nil {
		t.Fatal(err)
	}
	punish := func() (int64, error) {
		return s.Consequence(ctx, Infraction{
			IPHash: "ip-crook", NetHash: "net-crook", Kind: KindKick, Reason: ReasonScam,
			Duration: time.Hour, EvidenceID: id, Evidence: "…seed phrase…",
		})
	}

	first, err := punish()
	if err != nil {
		t.Fatal(err)
	}
	if first == 0 {
		t.Fatal("the first consequence must be recorded")
	}
	// THE REPLAY. Not an error: the scanner treats an error as a failure and retries, so a
	// duplicate has to look like success-with-nothing-done.
	again, err := punish()
	if err != nil {
		t.Errorf("a replay must not be an error, or the scanner retries it forever: %v", err)
	}
	if again != 0 {
		t.Errorf("a replay must report that it recorded nothing, got id %d", again)
	}
	if n, err := s.CountInfractions(ctx, true); err != nil {
		t.Fatal(err)
	} else if n != 1 {
		t.Fatalf("one message, one consequence, got %d", n)
	}

	// AND THE STATED PURPOSE: the replay must not have moved the ladder. This is the assertion
	// the guard exists for — a double-punish that were merely cosmetic would still leave the
	// author one rung higher for their next message.
	next, err := s.Escalate(ctx, "ip-crook")
	if err != nil {
		t.Fatal(err)
	}
	if next != Ladder[1] {
		t.Errorf("after ONE consequence the next rung is %s, got %s — a replay walked the ladder",
			Ladder[1], next)
	}

	// PAIRED POSITIVE: a DIFFERENT message from the same author still earns its own consequence,
	// or the guard would have turned into an amnesty after the first offence.
	//
	// Past the kick first. A kicked address cannot post, so a fixture that advances by minutes
	// never creates the second message and asserts nothing about the guard — which is how the
	// first version of this failed, and the second time that trap has cost a run here.
	// Escalate counts consequences within LadderLookback regardless of expiry, so letting the
	// kick lapse does not weaken the ladder assertions.
	*clock = clock.Add(2 * time.Hour)
	id2, err := post(t, s, "orem", "ip-crook", "dm me and I will restore your wallet for you")
	if err != nil {
		t.Fatal(err)
	}
	second, err := s.Consequence(ctx, Infraction{
		IPHash: "ip-crook", NetHash: "net-crook", Kind: KindKick, Reason: ReasonScam,
		Duration: time.Hour, EvidenceID: id2, Evidence: "…dm me…",
	})
	if err != nil {
		t.Fatal(err)
	}
	if second == 0 {
		t.Error("a second, different message must earn its own consequence")
	}
	if n, err := s.CountInfractions(ctx, true); err != nil {
		t.Fatal(err)
	} else if n != 2 {
		t.Errorf("two offences, two consequences, got %d", n)
	}
}

// The three EXEMPTIONS in that index, each measured, because an exemption that quietly stops
// working is a consequence that cannot be issued and no error to say why.
func TestTheReplayGuardsExemptions(t *testing.T) {
	ctx := context.Background()

	t.Run("no evidence is unconstrained", func(t *testing.T) {
		// A manual consequence often cites nothing — an operator acting on an address, not a
		// message. Those must not collide with each other, which is why the index is partial.
		//
		// NO MUTATION OF THAT CLAUSE CAN BREAK THIS, and the index's own comment says why:
		// SQLite treats NULLs as distinct, so dropping `evidence_id IS NOT NULL` changes
		// nothing. Deleting the clause survives this fixture, which is documented redundancy
		// rather than a gap — the clause states an assumption about SQLite that the code depends
		// on, and this arm pins the BEHAVIOUR, which is what an operator actually needs.
		s, _ := newStore(t)
		for i := 0; i < 3; i++ {
			got, err := s.Consequence(ctx, Infraction{
				IPHash: "ip-x", Kind: KindKick, Reason: ReasonManual, Duration: time.Hour,
			})
			if err != nil {
				t.Fatalf("consequence %d: %v", i+1, err)
			}
			if got == 0 {
				t.Fatalf("consequence %d was swallowed as a duplicate; a manual action with no "+
					"evidence has nothing to duplicate", i+1)
			}
		}
	})

	t.Run("a different kind on the same evidence is allowed", func(t *testing.T) {
		// An operator escalating a scanner's kick to a ban cites the same message. The index is
		// keyed on (evidence_id, kind) so that path stays open.
		s, _ := newStore(t)
		id, err := post(t, s, "orem", "ip-y", "send me your seed phrase right now please")
		if err != nil {
			t.Fatal(err)
		}
		if _, err := s.Consequence(ctx, Infraction{
			IPHash: "ip-y", Kind: KindKick, Reason: ReasonScam,
			Duration: time.Hour, EvidenceID: id,
		}); err != nil {
			t.Fatal(err)
		}
		got, err := s.Consequence(ctx, Infraction{
			IPHash: "ip-y", Kind: KindBan, Reason: ReasonManual, EvidenceID: id,
		})
		if err != nil {
			t.Fatal(err)
		}
		if got == 0 {
			t.Error("an operator must be able to ban on the same evidence a kick cited, or a " +
				"scanner's kick would block the escalation it exists to surface")
		}
	})

	t.Run("after revocation the same evidence may be used again", func(t *testing.T) {
		// Without the revoked_at clause a ban -> unban -> ban cycle would fail on the second ban,
		// so an operator who reversed a call could never reinstate it.
		s, _ := newStore(t)
		id, err := post(t, s, "orem", "ip-z", "send me your seed phrase right now please")
		if err != nil {
			t.Fatal(err)
		}
		first, err := s.Consequence(ctx, Infraction{
			IPHash: "ip-z", Kind: KindBan, Reason: ReasonManual, EvidenceID: id,
		})
		if err != nil {
			t.Fatal(err)
		}
		if err := s.Revoke(ctx, first, "operator"); err != nil {
			t.Fatal(err)
		}
		again, err := s.Consequence(ctx, Infraction{
			IPHash: "ip-z", Kind: KindBan, Reason: ReasonManual, EvidenceID: id,
		})
		if err != nil {
			t.Fatal(err)
		}
		if again == 0 {
			t.Error("a reversed consequence must not block reinstating it on the same evidence")
		}
	})
}
