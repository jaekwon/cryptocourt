package chat

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// THE BACKUP PROCEDURE §9 RECOMMENDS, PINNED — because a wrong backup is silent until a
// restore, which is the worst moment to discover anything.
//
// §9 records the measurement that motivates it: on a server holding three messages, `chat.db`
// was 4,096 bytes of header while `chat.db-wal` held the schema AND every row, so `cp chat.db`
// produced a file that opens cleanly and answers `no such table: messages`. Nothing tested
// either half of that — not the trap, and not the `VACUUM INTO` the document tells an operator
// to use instead. The consequence of the second going quietly wrong is worse than the first:
// an operator who follows the advice would believe they had backups.
//
// The two arms are paired on purpose. A test that only asserted "VACUUM INTO copies the rows"
// would also pass if the main file were self-sufficient, in which case it would be measuring
// nothing about the WAL at all. The naive copy failing is what makes the good copy meaningful.
func TestTheDocumentedBackupProcedureCopiesALiveDatabase(t *testing.T) {
	dir := t.TempDir()
	live := filepath.Join(dir, "chat.db")
	s, err := Open(live)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	clock := time.Unix(1_700_000_000, 0)
	s.Now = func() time.Time { return clock }
	ctx := context.Background()

	const want = 6
	for i := 0; i < want; i++ {
		if _, err := s.Post(ctx, PostInput{
			Chain: "dev", Court: "orem", Moniker: "alice",
			Body:   fmt.Sprintf("message %d about the settle window and the docket order", i),
			IPHash: "ip-a", NetHash: "net-a",
		}); err != nil {
			t.Fatal(err)
		}
		clock = clock.Add(MinInterval)
	}

	// The database stays OPEN throughout, which is the whole point: this is the backup of a
	// running server, not of a stopped one.
	raw, err := sql.Open("sqlite", live)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()
	snap := filepath.Join(dir, "snapshot.db")
	if _, err := raw.Exec(`VACUUM INTO ?`, snap); err != nil {
		t.Fatalf("VACUUM INTO is what §9 tells an operator to run; it must work against a "+
			"live database on this driver: %v", err)
	}

	integ, n, err := backupState(snap)
	if err != nil {
		t.Fatalf("the snapshot must be a usable database: %v", err)
	}
	if integ != "ok" {
		t.Errorf("PRAGMA integrity_check on the snapshot says %q, want ok", integ)
	}
	if n != want {
		t.Errorf("the snapshot holds %d messages, want all %d — a backup short of the live "+
			"database is the failure this procedure exists to avoid", n, want)
	}

	// THE CONTROL, and the reason the assertion above is not vacuous: the main file alone is
	// not the database. If this ever starts succeeding, the WAL is being checkpointed
	// differently and §9's measurement needs retaking rather than this test deleting.
	alone := filepath.Join(dir, "alone.db")
	b, err := os.ReadFile(live)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(alone, b, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, n2, err := backupState(alone); err == nil && n2 == want {
		t.Errorf("copying %s alone produced a complete database with %d messages. That "+
			"contradicts §9's measurement, and it means this test's other half proves "+
			"nothing about the WAL — re-measure both before trusting either", "chat.db", n2)
	} else {
		t.Logf("control: the main file alone is not the database (%v, %d rows), which is what "+
			"makes the snapshot assertion meaningful", err, n2)
	}
}

// backupState opens a candidate backup the way a restoring operator would: read it, check it,
// and count what survived.
func backupState(path string) (string, int, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return "", 0, err
	}
	defer db.Close()
	var integ string
	if err := db.QueryRow(`PRAGMA integrity_check`).Scan(&integ); err != nil {
		return "", 0, err
	}
	var n int
	if err := db.QueryRow(`SELECT count(*) FROM messages`).Scan(&n); err != nil {
		return integ, 0, err
	}
	return integ, n, nil
}
