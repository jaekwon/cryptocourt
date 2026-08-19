package chat

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
)

// Can a database that already has messages in it survive a schema change?
//
// This is the question CREATE TABLE IF NOT EXISTS cannot answer. A new column added to
// `schema` appears on every fresh install and on no existing one, and nothing complains
// at startup — the first sign is "no such column" out of whatever query needed it, on
// the one machine that has been running long enough to have data worth keeping.
//
// So the fixture is an OLD database: built with the pre-reviewed_at shape, filled with
// rows, and then opened by the current code. Two things must hold, and the second is the
// one a version counter alone would not give — the column arrives AND the rows are still
// there. A migration that silently recreated the table would pass an "is the column
// present" check on its own.
const oldMessagesSchema = `
CREATE TABLE messages (
  id         INTEGER PRIMARY KEY,
  chain      TEXT    NOT NULL,
  court      TEXT    NOT NULL,
  moniker    TEXT    NOT NULL,
  body       TEXT    NOT NULL,
  skeleton   TEXT    NOT NULL DEFAULT '',
  ip_hash    TEXT    NOT NULL,
  net_hash   TEXT    NOT NULL DEFAULT '',
  country    TEXT    NOT NULL DEFAULT '',
  suffix     TEXT    NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  hidden     INTEGER NOT NULL DEFAULT 0,
  scan_state INTEGER NOT NULL DEFAULT 0,
  attempts   INTEGER NOT NULL DEFAULT 0,
  next_try   INTEGER NOT NULL DEFAULT 0,
  claimed_at INTEGER NOT NULL DEFAULT 0,
  verdict    TEXT    NOT NULL DEFAULT ''
);`

func hasColumn(t *testing.T, db *sql.DB, table, col string) bool {
	t.Helper()
	var n int
	if err := db.QueryRow(
		`SELECT COUNT(*) FROM pragma_table_info(?) WHERE name=?`, table, col).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n > 0
}

func TestAnExistingDatabaseGainsTheColumnAndKeepsItsRows(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.db")

	// An installation from before the column existed, with history in it.
	raw, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec(oldMessagesSchema); err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec(
		`INSERT INTO messages(id,chain,court,moniker,body,ip_hash,created_at,verdict,hidden)
		 VALUES (1,'dev','orem','alice','a message worth keeping','ip1',1700000000,'clean',0),
		        (2,'dev','orem','crook','a scam that was hidden','ip2',1700000001,'scam',1)`); err != nil {
		t.Fatal(err)
	}
	// The precondition, asserted rather than assumed: if the fixture already had the
	// column, this test would prove nothing and still pass.
	if hasColumn(t, raw, "messages", "reviewed_at") {
		t.Fatal("the fixture is supposed to predate reviewed_at")
	}
	if err := raw.Close(); err != nil {
		t.Fatal(err)
	}

	// Now the current code opens it.
	s, err := Open(path)
	if err != nil {
		t.Fatalf("opening an older database must migrate it, not fail: %v", err)
	}
	defer s.Close()

	if !hasColumn(t, s.w, "messages", "reviewed_at") {
		t.Fatal("reviewed_at was not added to an existing database")
	}

	// THE HALF A VERSION COUNTER WOULD NOT CATCH: the rows are still there, with their
	// values, and the hidden flag still hides.
	ctx := context.Background()
	msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 1 {
		t.Fatalf("want the one visible message after migrating, got %d", len(msgs))
	}
	if msgs[0].Body != "a message worth keeping" {
		t.Fatalf("the surviving row is wrong: %q", msgs[0].Body)
	}
	var total, hidden int
	if err := s.r.QueryRow(
		`SELECT COUNT(*), COALESCE(SUM(hidden),0) FROM messages`).Scan(&total, &hidden); err != nil {
		t.Fatal(err)
	}
	if total != 2 || hidden != 1 {
		t.Fatalf("history was not preserved: %d rows, %d hidden", total, hidden)
	}
	// The new column has to be usable, not merely present.
	if _, err := s.w.Exec(`UPDATE messages SET reviewed_at=? WHERE id=1`, 1700000002); err != nil {
		t.Fatalf("the migrated column must be writable: %v", err)
	}
}

// Opening twice must not try to add the column twice. ALTER TABLE ADD COLUMN is an
// error when the column is already there, so a migration that is not idempotent turns
// every restart after the first into a failure to start.
func TestMigratingIsIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "twice.db")
	for i := 0; i < 3; i++ {
		s, err := Open(path)
		if err != nil {
			t.Fatalf("open %d failed: %v", i+1, err)
		}
		if !hasColumn(t, s.w, "messages", "reviewed_at") {
			t.Fatalf("open %d: column missing", i+1)
		}
		if err := s.Close(); err != nil {
			t.Fatal(err)
		}
	}
}

// A brand-new database has a usable column, by whichever route.
//
// It is named in two places — `schema`, so a reader can see the current shape in one
// piece, and `migrate`, for databases that already exist. That redundancy is deliberate
// and it is also why this test does NOT discriminate between the two: deleting the
// column from `schema` was tried, and nothing failed, because migrate() runs on a fresh
// database as well and adds it there too. So the duplication cannot drift into a broken
// install; the worst it can do is one wasted ALTER TABLE on first open. What this pins
// is only the thing that matters to an operator — a new install has the column.
func TestAFreshDatabaseAlreadyHasIt(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "new.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if !hasColumn(t, s.w, "messages", "reviewed_at") {
		t.Fatal("a fresh database must have reviewed_at from the schema")
	}
}
