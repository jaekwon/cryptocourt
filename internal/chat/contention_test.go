package chat

import (
	"context"
	"fmt"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// Does the scanner stall chat?
//
// CHAT.md §1 chooses ONE database file for two processes, over the alternative of
// splitting them so isolation is enforced by file permissions. The argument for one
// file was that SQLite in WAL mode allows many readers alongside one writer, that
// reads and writes get separate handles, and that the scanner never holds a
// transaction across an inference. All three are claims about runtime behaviour, and
// a source-level check cannot see any of them — so they are measured here.
//
// What is NOT claimed: that a POST is instant while another writer holds the lock.
// SQLite has one writer, so it cannot be. What must hold is that a held write
// transaction does not break chat — reads stay fast, and a write waits and then
// succeeds rather than failing.

func openAt(t *testing.T, path string) *Store {
	t.Helper()
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

// READS MUST NOT WAIT FOR WRITES. This is the whole reason for two handles: a single
// pooled handle capped at one connection would queue every GET behind every write in
// Go's pool, where WAL's concurrent-reader guarantee never gets a chance to apply.
func TestReadsAreNotBlockedByAWriter(t *testing.T) {
	s := openAt(t, filepath.Join(t.TempDir(), "chat.db"))
	ctx := context.Background()

	if _, err := s.Post(ctx, PostInput{
		Chain: "dev", Court: "orem", Moniker: "alice", Body: "a message to read",
		IPHash: "ip1", NetHash: "net1",
	}); err != nil {
		t.Fatal(err)
	}

	// A writer holding a transaction open, standing in for the scanner writing a
	// batch of verdicts.
	held := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		tx, err := s.w.BeginTx(ctx, nil)
		if err != nil {
			t.Error(err)
			return
		}
		if _, err := tx.ExecContext(ctx,
			`UPDATE messages SET verdict='clean' WHERE id=1`); err != nil {
			t.Error(err)
		}
		close(held)
		time.Sleep(700 * time.Millisecond)
		_ = tx.Commit()
	}()
	<-held

	start := time.Now()
	msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("a read failed while a writer held the lock: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("want the message, got %d", len(msgs))
	}
	// Generous, because this is CI-hostile territory; the failure it catches is a
	// read waiting out the whole write, which would be ~700ms.
	if elapsed > 250*time.Millisecond {
		t.Fatalf("a read waited %s for a writer; reads and writes must not share a "+
			"connection", elapsed)
	}
	t.Logf("read completed in %s while a write transaction was open", elapsed)
	<-done
}

// A WRITE WAITS AND THEN SUCCEEDS. busy_timeout is what turns "the scanner is
// writing" into a short wait instead of an error — without it SQLite returns
// SQLITE_BUSY immediately and a user's message is simply refused.
func TestAWriteWaitsForTheLockRatherThanFailing(t *testing.T) {
	s := openAt(t, filepath.Join(t.TempDir(), "chat.db"))
	ctx := context.Background()

	// A second Store on the same file: two PROCESSES, which is the real deployment.
	// SetMaxOpenConns(1) serialises within one process and does nothing across two,
	// so this is the case the pragmas have to carry.
	other := openAt(t, filepath.Join(filepath.Dir(dbPath(t, s)), "chat.db"))

	held := make(chan struct{})
	go func() {
		tx, err := other.w.BeginTx(ctx, nil)
		if err != nil {
			t.Error(err)
			return
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO meta(k,v) VALUES('probe','1')
			 ON CONFLICT(k) DO UPDATE SET v='1'`); err != nil {
			t.Error(err)
		}
		close(held)
		time.Sleep(400 * time.Millisecond)
		_ = tx.Commit()
	}()
	<-held

	start := time.Now()
	id, err := s.Post(ctx, PostInput{
		Chain: "dev", Court: "orem", Moniker: "alice", Body: "posted during a write",
		IPHash: "ip1", NetHash: "net1",
	})
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("a post failed while another process held the write lock — "+
			"busy_timeout is what should have made this a wait: %v", err)
	}
	if id == 0 {
		t.Fatal("no id")
	}
	t.Logf("post waited %s for another process's write transaction, then succeeded", elapsed)
}

// THE FAIL-OPEN PROPERTY, as a runtime test rather than an import-graph check.
//
// An earlier plan proposed a script asserting that the HTTP package never imports the
// scanner. That checks a different thing: the HTTP path MUST read the infractions
// table, which the scanner writes, so the coupling that could actually break
// fail-open is the one such a check is designed to permit. This exercises the real
// property — chat serves while a scanner-shaped writer is busy.
func TestChatServesWhileTheScannerWrites(t *testing.T) {
	s := openAt(t, filepath.Join(t.TempDir(), "chat.db"))
	ctx := context.Background()

	for i := 0; i < 5; i++ {
		if _, err := s.Post(ctx, PostInput{
			Chain: "dev", Court: "orem", Moniker: "alice",
			Body:   fmt.Sprintf("message number %d here", i),
			IPHash: fmt.Sprintf("ip%02d", i), NetHash: "net1",
		}); err != nil {
			t.Fatal(err)
		}
	}

	stop := make(chan struct{})
	var stopOnce sync.Once
	halt := func() { stopOnce.Do(func() { close(stop) }) }
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { // a scanner, writing verdicts as fast as it can
		defer wg.Done()
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			_ = s.RecordVerdict(ctx, int64(i%5+1), "clean")
		}
	}()

	// Reads and status checks are what a page does every few seconds. Every one must
	// answer; a single failure here is chat going down because moderation is busy.
	deadline := time.Now().Add(600 * time.Millisecond)
	reads, worst := 0, time.Duration(0)
	for time.Now().Before(deadline) {
		start := time.Now()
		if _, err := s.Recent(ctx, "dev", "orem", 0, 50); err != nil {
			halt()
			wg.Wait()
			t.Fatalf("a read failed while the scanner was writing: %v", err)
		}
		if _, err := s.Status(ctx, "ip01", "net1"); err != nil {
			halt()
			wg.Wait()
			t.Fatalf("a status check failed while the scanner was writing: %v", err)
		}
		if d := time.Since(start); d > worst {
			worst = d
		}
		reads++
	}
	halt()
	wg.Wait()

	if reads < 10 {
		t.Fatalf("only %d reads completed in 600ms; chat is being starved", reads)
	}
	if worst > 250*time.Millisecond {
		t.Fatalf("worst read+status took %s while the scanner wrote", worst)
	}
	t.Logf("%d read+status pairs while the scanner wrote continuously, worst %s",
		reads, worst)
}

// dbPath recovers the directory a store was opened in, so a second store can be
// opened on the same file.
func dbPath(t *testing.T, s *Store) string {
	t.Helper()
	var name string
	if err := s.r.QueryRow(`SELECT file FROM pragma_database_list WHERE name='main'`).
		Scan(&name); err != nil {
		t.Fatal(err)
	}
	return name
}
