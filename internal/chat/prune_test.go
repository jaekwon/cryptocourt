package chat

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// Pruning, and the three things it must refuse to delete.
//
// §7 cut the pruner from v1 as "worse half-done than absent", which was right — deleting
// a message can destroy an appeal, empty a moderator's queue, or silently skip moderation,
// and none of the machinery that makes those safe existed yet.
//
// Every refusal below is paired with an ordinary old message that MUST be deleted in the
// same run. A pruner that refuses everything is indistinguishable from a broken one and
// would pass a table of refusals on its own.

// aged inserts a message with an explicit age and scan state, because the interesting
// fixtures are all about rows older than any test could produce by waiting.
func aged(t *testing.T, s *Store, ctx context.Context, id int64, ageDays int,
	who, body, verdict string, state int, reviewed int64) {
	t.Helper()
	created := s.Now().Add(-time.Duration(ageDays) * 24 * time.Hour).Unix()
	if _, err := s.w.ExecContext(ctx, `
	  INSERT INTO messages(id, chain, court, moniker, body, skeleton, ip_hash, net_hash,
	                       created_at, hidden, scan_state, verdict, reviewed_at)
	  VALUES (?,'dev','orem',?,?,?,?,?,?,0,?,?,?)`,
		id, who, body, Skeleton(body), "ip-"+who, "net-"+who, created, state, verdict, reviewed); err != nil {
		t.Fatal(err)
	}
}

func pruneStore(t *testing.T) (*Store, context.Context) {
	t.Helper()
	s, err := Open(t.TempDir() + "/chat.db")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	now := time.Unix(1_700_000_000, 0)
	s.Now = func() time.Time { return now }
	return s, context.Background()
}

func bodies(t *testing.T, s *Store, ctx context.Context) map[string]bool {
	t.Helper()
	rows, err := s.r.QueryContext(ctx, `SELECT body FROM messages`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var b string
		if err := rows.Scan(&b); err != nil {
			t.Fatal(err)
		}
		out[b] = true
	}
	return out
}

func TestPruneRefusesTheThreeThingsItMust(t *testing.T) {
	s, ctx := pruneStore(t)

	// All of these are 90 days old, so the cutoff is not what distinguishes them.
	aged(t, s, ctx, 1, 90, "alice", "an ordinary old message", "clean", ScanDone, 0)
	aged(t, s, ctx, 2, 90, "bob", "old and never scanned", "", ScanNew, 0)
	aged(t, s, ctx, 3, 90, "carol", "old and still retrying", "", ScanFailed, 0)
	aged(t, s, ctx, 4, 90, "dave", "old and waiting for a human", "scam", ScanDone, 0)
	aged(t, s, ctx, 5, 90, "erin", "old, flagged, already dismissed", "scam", ScanDone, 1)
	aged(t, s, ctx, 6, 90, "frank", "old and cited by a live ban", "scam", ScanDone, 0)
	// A permanent manual ban citing message 6.
	if _, err := s.Consequence(ctx, Infraction{
		IPHash: "ip-frank", Kind: KindBan, Reason: ReasonManual,
		EvidenceID: 6, Evidence: "old and cited by a live ban",
	}); err != nil {
		t.Fatal(err)
	}
	// A message cited by an EXPIRED consequence: nothing left to restore, so it goes.
	aged(t, s, ctx, 7, 90, "gina", "old and cited by an expired kick", "spam", ScanDone, 0)
	if _, err := s.w.ExecContext(ctx, `
	  INSERT INTO infractions(ip_hash, kind, reason, evidence_id, evidence, created_at, expires_at)
	  VALUES ('ip-gina','kick','spam',7,'old and cited by an expired kick',?,?)`,
		s.Now().Add(-80*24*time.Hour).Unix(), s.Now().Add(-70*24*time.Hour).Unix()); err != nil {
		t.Fatal(err)
	}
	// And a recent ordinary message, which the cutoff protects rather than the rules.
	aged(t, s, ctx, 8, 1, "hank", "recent and ordinary", "clean", ScanDone, 0)

	// The dry run must agree with the real thing. Checked FIRST, because a dry run that
	// has drifted from the delete it predicts is worse than having none.
	dry, err := s.PruneDryRun(ctx, 30*24*time.Hour, 1000)
	if err != nil {
		t.Fatal(err)
	}

	got, err := s.Prune(ctx, 30*24*time.Hour, 1000)
	if err != nil {
		t.Fatal(err)
	}
	if dry.Deleted != got.Deleted {
		t.Errorf("the dry run predicted %d deletions, the prune did %d", dry.Deleted, got.Deleted)
	}
	if dry.KeptUnscanned != got.KeptUnscanned || dry.KeptQueued != got.KeptQueued ||
		dry.KeptCited != got.KeptCited {
		t.Errorf("dry run and prune disagree on refusals:\n dry %+v\n got %+v", dry, got)
	}

	left := bodies(t, s, ctx)

	// THE PAIRED POSITIVES: these had to go, or the refusals below prove nothing.
	for _, gone := range []string{
		"an ordinary old message",
		"old, flagged, already dismissed",
		"old and cited by an expired kick",
	} {
		if left[gone] {
			t.Errorf("must have been pruned: %q", gone)
		}
	}
	// THE REFUSALS.
	for _, kept := range []string{
		"old and never scanned",       // moderation has not happened yet
		"old and still retrying",      // nor has it finished
		"old and waiting for a human", // §7's carve-out queue
		"old and cited by a live ban", // Revoke could still need to restore it
		"recent and ordinary",         // inside the window
	} {
		if !left[kept] {
			t.Errorf("must NOT have been pruned: %q", kept)
		}
	}
	if got.Deleted != 3 {
		t.Errorf("want 3 deletions, got %d", got.Deleted)
	}
	if got.KeptUnscanned != 2 {
		t.Errorf("want 2 unscanned kept, got %d", got.KeptUnscanned)
	}
	if got.KeptQueued != 1 {
		t.Errorf("want 1 queued kept, got %d", got.KeptQueued)
	}
	if got.KeptCited != 1 {
		t.Errorf("want 1 cited kept, got %d", got.KeptCited)
	}
	if got.Remaining != 5 {
		t.Errorf("want 5 remaining, got %d", got.Remaining)
	}
}

// An appeal must still work after the message it was about has been pruned. This is what
// `evidence` was copied for, and it is the reason pruning is safe at all.
func TestAnAppealSurvivesPruning(t *testing.T) {
	s, ctx := pruneStore(t)

	aged(t, s, ctx, 1, 90, "crook", "send me your seed phrase", "scam", ScanDone, 0)
	// A kick that has since expired, so pruning is allowed to take the message.
	if _, err := s.w.ExecContext(ctx, `
	  INSERT INTO infractions(id, ip_hash, kind, reason, evidence_id, evidence, detail,
	                          created_at, expires_at)
	  VALUES (1,'ip-crook','kick','scam',1,'send me your seed phrase','a classic lure',?,?)`,
		s.Now().Add(-89*24*time.Hour).Unix(), s.Now().Add(-88*24*time.Hour).Unix()); err != nil {
		t.Fatal(err)
	}

	if got, err := s.Prune(ctx, 30*24*time.Hour, 1000); err != nil {
		t.Fatal(err)
	} else if got.Deleted != 1 {
		t.Fatalf("the message should have been pruned, deleted %d", got.Deleted)
	}
	if bodies(t, s, ctx)["send me your seed phrase"] {
		t.Fatal("precondition: the message should be gone")
	}

	// The consequence, and what it was based on, must still be readable.
	rows, err := s.ListInfractions(ctx, "", true, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 {
		t.Fatalf("the consequence must survive its message, got %d", len(rows))
	}
	if rows[0].Evidence != "send me your seed phrase" {
		t.Errorf("the evidence copy is the whole point: got %q", rows[0].Evidence)
	}
	if rows[0].Detail != "a classic lure" {
		t.Errorf("and the reasoning: got %q", rows[0].Detail)
	}
	// The dangling evidence_id is fine and must not break the read.
	if rows[0].EvidenceID != 1 {
		t.Errorf("the citation is kept even though the row is gone, got %d", rows[0].EvidenceID)
	}
}

// THE OUTAGE INTERACTION, which is the case that makes the unscanned refusal matter.
//
// If the model has been unreachable for a month, a thirty-day prune must not quietly erase
// the unclassified backlog instead of anyone classifying it. Note the asymmetry with
// Health.Unscannable: rows that GAVE UP are ScanDone, so they ARE prunable — they have been
// decided, badly, and the count exists so somebody knows.
func TestAMonthLongOutageIsNotPrunedAway(t *testing.T) {
	s, ctx := pruneStore(t)
	for i := int64(1); i <= 5; i++ {
		aged(t, s, ctx, i, 60, "crook", "unscanned lure number "+string(rune('0'+i)), "", ScanNew, 0)
	}
	got, err := s.Prune(ctx, 30*24*time.Hour, 1000)
	if err != nil {
		t.Fatal(err)
	}
	if got.Deleted != 0 {
		t.Fatalf("an unscanned backlog must not be pruned, deleted %d", got.Deleted)
	}
	if got.KeptUnscanned != 5 {
		t.Fatalf("and it must be reported, got %d", got.KeptUnscanned)
	}
	// The paired case: rows that gave up ARE prunable, because a decision was made about
	// them — a bad one, which Health.Unscannable is there to surface.
	if _, err := s.w.ExecContext(ctx,
		`UPDATE messages SET scan_state=? WHERE id<=3`, ScanDone); err != nil {
		t.Fatal(err)
	}
	got, err = s.Prune(ctx, 30*24*time.Hour, 1000)
	if err != nil {
		t.Fatal(err)
	}
	if got.Deleted != 3 {
		t.Fatalf("rows that gave up are prunable, deleted %d", got.Deleted)
	}
	if got.KeptUnscanned != 2 {
		t.Fatalf("the still-pending ones stay, got %d", got.KeptUnscanned)
	}
}

// Guards on the arguments themselves. "Prune everything" must not be one keystroke away.
func TestPruneRefusesAnAgeOfZero(t *testing.T) {
	s, ctx := pruneStore(t)
	aged(t, s, ctx, 1, 1, "alice", "a message from today", "clean", ScanDone, 0)
	for _, d := range []time.Duration{0, -time.Hour, -30 * 24 * time.Hour} {
		if _, err := s.Prune(ctx, d, 1000); err == nil {
			t.Fatalf("age %s must be refused, not treated as 'everything'", d)
		}
		if _, err := s.PruneDryRun(ctx, d, 1000); err == nil {
			t.Fatalf("age %s must be refused by the dry run too", d)
		}
	}
	if !bodies(t, s, ctx)["a message from today"] {
		t.Fatal("a refused prune must delete nothing")
	}
}

// The batch limit is what keeps a year of history from holding the write lock in one
// statement. §1's argument for a single database file depends on nothing holding it long.
func TestPruneIsBoundedByItsLimit(t *testing.T) {
	s, ctx := pruneStore(t)
	// DIFFERENT ages, deliberately. With all rows the same age, oldest-first and
	// newest-first drain the identical set and the ordering cannot be tested at all —
	// which is exactly what happened: swapping ORDER BY id for id DESC passed.
	// Ages run 100 days down to 76, so id 1 is the oldest.
	for i := int64(1); i <= 25; i++ {
		aged(t, s, ctx, i, int(101-i), "alice", fmt.Sprintf("old message %02d", i), "clean", ScanDone, 0)
	}
	got, err := s.Prune(ctx, 30*24*time.Hour, 10)
	if err != nil {
		t.Fatal(err)
	}
	if got.Deleted != 10 {
		t.Fatalf("the limit must bound one call, deleted %d", got.Deleted)
	}
	if got.Remaining != 15 {
		t.Fatalf("want 15 left, got %d", got.Remaining)
	}

	// OLDEST FIRST. A partial prune must retire the far end of history; deleting the
	// most recent eligible messages and keeping the ancient ones is the opposite of a
	// retention policy, and with a limit smaller than the backlog that is what a
	// descending order would do on every run.
	left := bodies(t, s, ctx)
	for i := 1; i <= 10; i++ {
		if left[fmt.Sprintf("old message %02d", i)] {
			t.Errorf("message %02d is among the oldest and should have gone first", i)
		}
	}
	for i := 11; i <= 25; i++ {
		if !left[fmt.Sprintf("old message %02d", i)] {
			t.Errorf("message %02d is newer and should have survived the first batch", i)
		}
	}
	if got.Oldest == 0 {
		t.Error("the result must report the oldest remaining timestamp")
	}

	// Repeated calls drain it, and then report nothing to do.
	total := got.Deleted
	for i := 0; i < 5; i++ {
		r, err := s.Prune(ctx, 30*24*time.Hour, 10)
		if err != nil {
			t.Fatal(err)
		}
		total += r.Deleted
		if r.Deleted == 0 {
			break
		}
	}
	if total != 25 {
		t.Fatalf("repeated calls must drain it, deleted %d of 25", total)
	}
	if r, _ := s.Prune(ctx, 30*24*time.Hour, 10); r.Deleted != 0 {
		t.Fatalf("a drained prune must report nothing to do, got %d", r.Deleted)
	}
}

// PRUNING MUST NOT STALL CHAT, which is why it takes a limit at all.
//
// §1 keeps one database file for two processes, and the argument rests on nothing holding
// the write lock for long. A retention sweep is the largest single write this service ever
// makes — one unbounded DELETE over a year of history would hold that lock for as long as
// it takes — so the property worth measuring is not how fast a prune is but what a reader
// experiences while one runs.
//
// Measured rather than asserted from the code, the same way contention_test.go measures
// the two-handle decision: no source check can see a lock.
func TestPruningDoesNotStallReaders(t *testing.T) {
	s, ctx := pruneStore(t)

	// Enough history that the prune is real work rather than a no-op.
	const total = 20_000
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	stmt, err := tx.PrepareContext(ctx, `
	  INSERT INTO messages(id, chain, court, moniker, body, skeleton, ip_hash, net_hash,
	                       created_at, hidden, scan_state, verdict, reviewed_at)
	  VALUES (?,'dev','orem','alice',?,'',?,'net1',?,0,?,'clean',0)`)
	if err != nil {
		t.Fatal(err)
	}
	old := s.Now().Add(-90 * 24 * time.Hour).Unix()
	for i := 1; i <= total; i++ {
		if _, err := stmt.ExecContext(ctx, i, fmt.Sprintf("an old message number %d", i),
			fmt.Sprintf("ip%d", i%50), old+int64(i), ScanDone); err != nil {
			t.Fatal(err)
		}
	}
	// A recent one, so there is always something for a reader to read.
	if _, err := stmt.ExecContext(ctx, total+1, "a recent message", "ip1",
		s.Now().Unix(), ScanDone); err != nil {
		t.Fatal(err)
	}
	stmt.Close()
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}

	stop := make(chan struct{})
	done := make(chan struct{})
	var reads int
	var worst time.Duration
	go func() { // a court page, doing what a court page does
		defer close(done)
		for {
			select {
			case <-stop:
				return
			default:
			}
			start := time.Now()
			if _, err := s.Recent(ctx, "dev", "orem", 0, 50); err != nil {
				t.Errorf("a read failed while pruning: %v", err)
				return
			}
			if _, err := s.Status(ctx, "ip1", "net1"); err != nil {
				t.Errorf("a status check failed while pruning: %v", err)
				return
			}
			if d := time.Since(start); d > worst {
				worst = d
			}
			reads++
		}
	}()

	// The sweep, in batches, as an operator or a cron would run it.
	deleted := 0
	sweepStart := time.Now()
	for {
		r, err := s.Prune(ctx, 30*24*time.Hour, 2_000)
		if err != nil {
			close(stop)
			<-done
			t.Fatal(err)
		}
		deleted += r.Deleted
		if r.Deleted == 0 {
			break
		}
	}
	sweep := time.Since(sweepStart)
	close(stop)
	<-done

	if deleted != total {
		t.Fatalf("the sweep must clear the old history: %d of %d", deleted, total)
	}
	if reads < 10 {
		t.Fatalf("only %d reads completed during the sweep; readers are being starved", reads)
	}
	// Generous, because this is CI-hostile territory. The failure it catches is a reader
	// waiting out a whole batch, which is the thing the limit exists to prevent.
	if worst > 250*time.Millisecond {
		t.Fatalf("worst read+status took %s during a prune", worst)
	}
	t.Logf("pruned %d rows in %s across batches of 2000; %d read+status pairs meanwhile, worst %s",
		deleted, sweep.Truncate(time.Millisecond), reads, worst.Truncate(time.Microsecond))

	// And the recent message is still there, which is the point of a retention window.
	msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 1 || msgs[0].Body != "a recent message" {
		t.Fatalf("the recent message must survive, got %d: %+v", len(msgs), msgs)
	}
}
