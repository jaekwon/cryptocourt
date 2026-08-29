package archive

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// THE CLASSIFIER IS AN AID TO A MODERATOR, NOT A GATE ON EVIDENCE.
//
// This archive holds the exhibits filed with claims in a court, and it is the
// one place that has both the bytes and the legal obligation — so the checking
// belongs here rather than on chain (docs/CLAIM_MEDIA.md §3.2). What it must not
// become is a model with the power to remove evidence from a court on its own
// say-so.
//
// So the shape follows internal/scan's, which already settled this for text: an
// unreadable verdict carries no more weight than a clean one. A model that times
// out, answers nonsense, or is not running at all leaves the image SERVING and
// puts it in front of a person. Fail-closed would mean an Ollama outage silently
// withdrawing every exhibit in every court, which is a worse failure than the
// one it protects against — and the chain-side purge, which is authoritative and
// human, is unaffected either way.
//
// Auto-blocking exists, but only where being wrong is cheaper than being slow:
// the most serious label, at high confidence, and nothing else. Everything else
// is queued.

// ImageVerdict is what a model said about one image.
type ImageVerdict struct {
	// Label is free-form so a different backend can use its own vocabulary; only
	// AutoBlockLabel is ever acted on without a person.
	Label string
	// Confidence is 0..1.
	Confidence float64
	// Why is the model's prose, stored for an operator to read and NEVER parsed
	// for instructions — the same rule internal/scan states about its own.
	Why string
}

// AutoBlockLabel is the one label this service will act on by itself, and it is
// deliberately the only one. Anything else a model dislikes is a queue entry.
const AutoBlockLabel = "illegal"

// AutoBlockConfidence is where "probably" stops being enough. Set high because
// the cost of a false positive here is a court losing a piece of evidence with
// nobody told, and the cost of a false negative is an image waiting a few hours
// for a person who was going to look anyway.
const AutoBlockConfidence = 0.90

// ImageClassifier judges image bytes. An interface so the archive is testable
// without a GPU, and so a backend can be replaced without touching this file.
type ImageClassifier interface {
	ClassifyImage(ctx context.Context, mime string, body []byte) (ImageVerdict, error)
}

const classifySchema = `
CREATE TABLE IF NOT EXISTS blob_review (
  sha256     TEXT PRIMARY KEY,
  label      TEXT NOT NULL,
  confidence REAL NOT NULL,
  why        TEXT NOT NULL,
  checked_at INTEGER NOT NULL,
  cleared_at INTEGER
);
CREATE INDEX IF NOT EXISTS blob_review_queue ON blob_review (cleared_at, confidence);
`

// whyMax bounds stored prose, for internal/scan's reason: it is written to a
// screen an operator reads, and a model that runs away must not fill it.
const whyMax = 400

func clipWhy(s string) string {
	if len(s) <= whyMax {
		return s
	}
	return s[:whyMax] + "…"
}

// Review records a verdict and blocks the blob if — and only if — the model was
// both sure and serious. Returns whether it blocked.
func (s *Store) Review(ctx context.Context, sum string, v ImageVerdict) (bool, error) {
	block := v.Label == AutoBlockLabel && v.Confidence >= AutoBlockConfidence
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO blob_review (sha256, label, confidence, why, checked_at)
		 VALUES (?, ?, ?, ?, ?)
		 ON CONFLICT(sha256) DO UPDATE SET
		   label = excluded.label, confidence = excluded.confidence,
		   why = excluded.why, checked_at = excluded.checked_at`,
		sum, v.Label, v.Confidence, clipWhy(v.Why), time.Now().Unix())
	if err != nil {
		return false, fmt.Errorf("archive review: %w", err)
	}
	if !block {
		return false, nil
	}
	if err := s.Block(ctx, sum); err != nil {
		return false, err
	}
	return true, nil
}

// Clear is a person overruling the model, and it is the reason auto-blocking is
// survivable: every automatic refusal has a human undo that leaves a record of
// having been used.
func (s *Store) Clear(ctx context.Context, sum string) error {
	if _, err := s.db.ExecContext(ctx,
		`UPDATE blob_review SET cleared_at = ? WHERE sha256 = ?`,
		time.Now().Unix(), sum); err != nil {
		return fmt.Errorf("archive clear review: %w", err)
	}
	_, err := s.db.ExecContext(ctx, `UPDATE blobs SET blocked = 0 WHERE sha256 = ?`, sum)
	if err != nil {
		return fmt.Errorf("archive unblock: %w", err)
	}
	return nil
}

// PendingReview is what an operator has not looked at yet, worst first.
func (s *Store) PendingReview(ctx context.Context, limit int) ([]string, error) {
	if limit < 1 {
		limit = 50
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT sha256 FROM blob_review
		 WHERE cleared_at IS NULL AND label != 'clean'
		 ORDER BY confidence DESC LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("archive pending: %w", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var sum string
		if err := rows.Scan(&sum); err != nil {
			return nil, err
		}
		out = append(out, sum)
	}
	return out, rows.Err()
}

// Unreviewed lists promoted blobs no model has judged. Promotion is when this
// runs, because classifying bytes that are about to expire is work spent on
// something nobody claimed.
func (s *Store) Unreviewed(ctx context.Context, limit int) ([]string, error) {
	if limit < 1 {
		limit = 20
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT b.sha256 FROM blobs b
		 LEFT JOIN blob_review r ON r.sha256 = b.sha256
		 WHERE b.promoted = 1 AND b.blocked = 0 AND r.sha256 IS NULL
		 LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("archive unreviewed: %w", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var sum string
		if err := rows.Scan(&sum); err != nil {
			return nil, err
		}
		out = append(out, sum)
	}
	return out, rows.Err()
}

// ReviewPass classifies what has not been looked at and reports how many it
// blocked.
//
// A CLASSIFIER THAT FAILS LEAVES THE IMAGE SERVING. It records nothing, so the
// blob stays unreviewed and is picked up on the next pass — the outage delays a
// judgement rather than making one. This is the same choice internal/scan makes
// about text, and for the same reason: a scanner nobody can understand must be
// harmless rather than harmful.
func (s *Store) ReviewPass(ctx context.Context, c ImageClassifier, limit int) (int, error) {
	if c == nil {
		return 0, nil
	}
	sums, err := s.Unreviewed(ctx, limit)
	if err != nil {
		return 0, err
	}
	blocked := 0
	for _, sum := range sums {
		mime, body, err := s.Get(ctx, sum)
		if err != nil {
			continue // gone or already blocked between the query and here
		}
		v, err := c.ClassifyImage(ctx, mime, body)
		if err != nil {
			continue // an outage is not a verdict
		}
		did, err := s.Review(ctx, sum, v)
		if err != nil {
			return blocked, err
		}
		if did {
			blocked++
		}
	}
	return blocked, nil
}

func ensureClassifySchema(db *sql.DB) error {
	_, err := db.Exec(classifySchema)
	return err
}
