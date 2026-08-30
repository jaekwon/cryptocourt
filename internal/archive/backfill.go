package archive

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// BACKFILL EXISTS BECAUSE THE CLIENT CANNOT BE THE ONLY WITNESS.
//
// Promotion used to happen one way: the composer called /m/claimed once its
// transaction was broadcast. Every path that skips that call loses the bytes an
// hour later even though a perfectly valid claim references them — the tab
// closed, the network dropped, the browser was killed, or the claim was filed
// from the CLI or from gnoweb, which never touch the composer at all.
//
// Losing evidence quietly is worse than any missing feature, so the archive
// asks the chain itself rather than waiting to be told.
//
// It cannot walk every claim on chain: there is no court enumeration, and an
// unbounded scan would grow without limit. So an upload records WHICH COURT it
// was composed for, and backfill walks only courts that actually have staged
// bytes — a set bounded by this database, usually one or two courts, often
// none. A blob uploaded with no court hint still relies on /m/claimed; that is
// the honest cost of the hint being optional.

// backfillBatch bounds one pass per court, so a first run against a busy court
// cannot hold the loop for minutes. The cursor makes the remainder the next
// pass's problem.
const backfillBatch = 256

const backfillSchema = `
CREATE TABLE IF NOT EXISTS blob_cursor (
  court   TEXT PRIMARY KEY,
  scanned INTEGER NOT NULL
);
`

// ensureColumn adds a column to an EXISTING database. The schema above is
// CREATE TABLE IF NOT EXISTS, which is right for a fresh install and silently
// does nothing for an old one, so anything added later needs this.
func ensureColumn(db *sql.DB, table, col, decl string) error {
	var n int
	if err := db.QueryRow(
		`SELECT COUNT(*) FROM pragma_table_info(?) WHERE name=?`, table, col).Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return nil
	}
	// Not parameterised, and it cannot be: SQLite takes no placeholders in DDL.
	// Every caller is a literal in this file, which is the only reason that is
	// acceptable.
	_, err := db.Exec("ALTER TABLE " + table + " ADD COLUMN " + col + " " + decl)
	return err
}

// ClaimCounter is what backfill needs from a chain, named as an interface so the
// sweep is testable without a node.
type ClaimCounter interface {
	ClaimCount(ctx context.Context, court string) (uint64, error)
	ClaimHashes(ctx context.Context, court string, claimID uint64) ([]string, error)
}

// StagedCourts lists the courts that have unpromoted bytes waiting. Empty is the
// normal steady state and costs one indexed query.
func (s *Store) StagedCourts(ctx context.Context) ([]string, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT DISTINCT court FROM blobs
		 WHERE promoted = 0 AND court IS NOT NULL AND court != ''`)
	if err != nil {
		return nil, fmt.Errorf("archive staged courts: %w", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (s *Store) cursor(ctx context.Context, court string) (uint64, error) {
	var n uint64
	err := s.db.QueryRowContext(ctx,
		`SELECT scanned FROM blob_cursor WHERE court = ?`, court).Scan(&n)
	if err == sql.ErrNoRows {
		return 0, nil
	}
	return n, err
}

func (s *Store) setCursor(ctx context.Context, court string, n uint64) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO blob_cursor (court, scanned) VALUES (?, ?)
		 ON CONFLICT(court) DO UPDATE SET scanned = excluded.scanned`, court, n)
	return err
}

// Backfill promotes the bytes any recent claim references, and reports how many
// blobs it kept.
//
// It runs BEFORE the sweep, so a claim filed fifty-nine minutes ago is seen
// before the bytes it points at would be deleted.
func (s *Store) Backfill(ctx context.Context, chain ClaimCounter) (int, error) {
	courts, err := s.StagedCourts(ctx)
	if err != nil {
		return 0, err
	}
	kept := 0
	for _, court := range courts {
		from, err := s.cursor(ctx, court)
		if err != nil {
			return kept, fmt.Errorf("archive cursor %s: %w", court, err)
		}
		total, err := chain.ClaimCount(ctx, court)
		if err == nil {
			// THE NODE ANSWERED. Stamped separately from the pass, because a pass
			// with nothing staged completes without asking anything — so a fresh
			// backfilled_at proves the loop is alive and says NOTHING about
			// whether the chain is reachable. Observed on a live service: an
			// unreachable node still showed a recent backfill, which is a false
			// reassurance in exactly the place an operator would look.
			if serr := s.Stamp(ctx, "chain", time.Now()); serr != nil {
				return kept, serr
			}
		}
		if err != nil {
			// A node that will not answer is a reason to try again later, never a
			// reason to advance the cursor past claims nobody has read.
			return kept, fmt.Errorf("archive backfill %s: %w", court, err)
		}
		last := total
		if last > from+backfillBatch {
			last = from + backfillBatch
		}
		for id := from + 1; id <= last; id++ {
			hashes, err := chain.ClaimHashes(ctx, court, id)
			if err != nil {
				// One unreadable claim — purged, or never existed — must not stop
				// the others behind it.
				continue
			}
			for _, h := range hashes {
				if err := s.Promote(ctx, h); err == nil {
					kept++
				}
			}
		}
		if err := s.setCursor(ctx, court, last); err != nil {
			return kept, err
		}
	}
	// Stamped only on a COMPLETE pass. Every early return above is an error, and
	// stamping those would make a backfill that fails every time look like one
	// that runs every time — which is the exact confusion this stamp exists to
	// prevent.
	if err := s.Stamp(ctx, "backfill", time.Now()); err != nil {
		return kept, err
	}
	return kept, nil
}
