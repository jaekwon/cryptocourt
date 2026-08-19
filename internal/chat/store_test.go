package chat

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
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
		if err := s.RecordFailure(ctx, id); err != nil {
			t.Fatal(err)
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
