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
//
// RUNES, NOT BYTES, and this file had it wrong. internal/scan spells out why at
// length: a byte cap rations characters by how expensive they are to encode, so
// a Japanese explanation gets a third of the room an English one does — silently,
// in the one field whose entire purpose is telling a person why. It can also cut
// a character in half and store invalid UTF-8. That comment says this repository
// had already made the same unit mistake twice, in the moniker's limit and the
// body's. This was the third.
const whyMaxRunes = 400

// clipWhy bounds the model's prose and strips what a terminal would obey.
//
// THE PROSE IS ATTACKER-INFLUENCED. A model is asked to describe a picture, and
// the picture may contain text; the prompt says that text is not an instruction,
// but a model is not a parser and this is not a promise. The output then lands
// in an operator's terminal via `kourtchatctl images`, where a C0 escape can
// clear the screen, move the cursor, or overwrite the line above — which is the
// line describing a different image. Nothing here needs a control character, so
// none survives.
func clipWhy(s string) string {
	cleaned := make([]rune, 0, len(s))
	for _, r := range s {
		switch {
		case r == '\n' || r == '\t':
			cleaned = append(cleaned, ' ') // one line, always
		case r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f):
			// C0, DEL and C1: dropped rather than replaced, so a run of them
			// cannot pad the field out of shape either.
		default:
			cleaned = append(cleaned, r)
		}
		if len(cleaned) >= whyMaxRunes {
			return string(cleaned) + "…"
		}
	}
	return string(cleaned)
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

// OperatorLabel marks a row a person judged rather than a model. It is not in
// any enum a model can emit, so the two can never be confused in the queue.
const OperatorLabel = "operator"

// BlockByOperator is a person acting on what a model MISSED.
//
// WITHOUT THIS THE HUMAN IS STRICTLY WEAKER THAN THE MODEL. An operator could
// undo an automatic block and could do nothing about an image the classifier had
// waved through — which inverts the whole arrangement, since the classifier is
// meant to sort a queue for a person rather than to be the only thing with a
// veto. The undo existed from the start; this is the other half of it, and it
// was missing.
//
// It records a review row so the act is visible in the same queue, labelled as
// a person's judgement rather than a model's, at full confidence because a
// person is not guessing.
func (s *Store) BlockByOperator(ctx context.Context, sum, why string) error {
	if why == "" {
		why = "removed by an operator"
	}
	if _, err := s.Review(ctx, sum, ImageVerdict{
		Label: OperatorLabel, Confidence: 1, Why: why,
	}); err != nil {
		return err
	}
	// Review only blocks at AutoBlockLabel, and a person's label is deliberately
	// not that one — so the block is made here, explicitly.
	return s.Block(ctx, sum)
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

// Pending is one row of the queue, as an operator needs to see it.
//
// The whole point of storing a label, a confidence and the model's prose is that
// somebody reads them. This used to return bare hashes: a list of 64-character
// hex strings, with the reason each was flagged stored one table over and
// reachable only by a query the caller had to know to write. A queue that cannot
// say why is a queue nobody works through.
type Pending struct {
	SHA256     string
	Label      string
	Confidence float64
	Why        string
	CheckedAt  int64
	Blocked    bool
	// Where it came from. A claim carries up to seven exhibits, so seven flagged
	// images may be one filing or seven — and a list that cannot say which lets
	// a flood bury the entry that matters. internal/chat states the rule about
	// its own queue: the answer to flooding is a VIEW that resists it, not a new
	// punishment.
	Court string
	Claim uint64
}

// PendingReview is what an operator has not looked at yet, worst first.
func (s *Store) PendingReview(ctx context.Context, limit int) ([]Pending, error) {
	if limit < 1 {
		limit = 50
	}
	// ORDERED BY ORIGIN FIRST, then by how sure the model was. A flat
	// worst-first list interleaves one filing's seven exhibits with everything
	// else, so the operator reads seven separate incidents instead of one — and
	// deciding about the source is the action that actually ends it.
	rows, err := s.db.QueryContext(ctx,
		`SELECT r.sha256, r.label, r.confidence, r.why, r.checked_at,
		        COALESCE(b.blocked, 0), COALESCE(b.filed_court, ''),
		        COALESCE(b.filed_claim, 0)
		 FROM blob_review r
		 LEFT JOIN blobs b ON b.sha256 = r.sha256
		 WHERE r.cleared_at IS NULL AND r.label != 'clean'
		 ORDER BY COALESCE(b.filed_court, '') , COALESCE(b.filed_claim, 0),
		          r.confidence DESC LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("archive pending: %w", err)
	}
	defer rows.Close()
	var out []Pending
	for rows.Next() {
		var p Pending
		var blocked int
		if err := rows.Scan(&p.SHA256, &p.Label, &p.Confidence, &p.Why,
			&p.CheckedAt, &blocked, &p.Court, &p.Claim); err != nil {
			return nil, err
		}
		// Whether the image is ALREADY off the site is the first thing an
		// operator needs: one of these rows is an emergency and the rest are
		// reading. Without it every entry looks equally urgent.
		p.Blocked = blocked != 0
		out = append(out, p)
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
	if err := s.Stamp(ctx, "review", time.Now()); err != nil {
		return blocked, err
	}
	return blocked, nil
}

func ensureClassifySchema(db *sql.DB) error {
	_, err := db.Exec(classifySchema)
	return err
}
