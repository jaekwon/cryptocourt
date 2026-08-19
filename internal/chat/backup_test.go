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

// A NEW DATABASE IS CREATED 0600, AND THE WAL INHERITS IT.
//
// Measured against the real server before this: the key file was 0600 while chat.db,
// chat.db-wal and chat.db-shm were all -rw-r--r--, because SQLite creates a database 0644
// masked by the umask and 022 is the usual umask. In the default configuration there is no
// --secret-file, so the hashing key is a row in that same file and any local user could read
// both the address hashes and the key that reverses them.
//
// THE WAL ARM IS THE ONE THAT MATTERS. §9's own measurement shows the main file can be 4,096
// bytes of header while every row lives in the -wal, so a 0600 main file beside a 0644 WAL
// would protect nothing. SQLite copies the database file's permissions onto the WAL when it
// creates it, which is why Open sets the mode BEFORE its first write rather than after.
func TestANewDatabaseIsNotReadableByOtherUsers(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "chat.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	// A write, so the WAL certainly exists and certainly holds rows.
	s.Now = func() time.Time { return time.Unix(1_700_000_000, 0) }
	if _, err := s.Post(context.Background(), PostInput{
		Chain: "dev", Court: "orem", Moniker: "alice",
		Body:   "a message, so the WAL exists and has something in it",
		IPHash: "ip-a", NetHash: "net-a",
	}); err != nil {
		t.Fatal(err)
	}

	checked := 0
	for _, suffix := range []string{"", "-wal", "-shm"} {
		fi, err := os.Stat(path + suffix)
		if err != nil {
			continue // -shm in particular need not exist on every platform
		}
		checked++
		if perm := fi.Mode().Perm(); perm&0o077 != 0 {
			t.Errorf("%s is mode %04o: other users on this host can read it. In the default "+
				"configuration that file also holds the IP hashing key, so this is the "+
				"difference between hashed addresses and reversible ones",
				filepath.Base(path+suffix), perm)
		}
	}
	if checked < 2 {
		t.Fatalf("only %d of the database's files existed, so the WAL arm — the one that "+
			"matters, since the rows live there — did not run", checked)
	}
}

// AND AN EXISTING DATABASE IS LEFT ALONE. Open documents this: silently tightening a file an
// operator may have deliberately shared is not its decision, and cmd/kourtchat warns instead.
// Without this arm the pre-create could grow into an unconditional chmod and nothing would say.
func TestOpeningAnExistingDatabaseDoesNotChangeItsMode(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "chat.db")
	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}

	s2, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s2.Close()
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if perm := fi.Mode().Perm(); perm != 0o644 {
		t.Errorf("Open changed an existing database's mode from 0644 to %04o. That may be an "+
			"improvement, but it is a decision this function documents leaving to the operator "+
			"— change the comment and cmd/kourtchat's warning together if it should now act",
			perm)
	}
}
