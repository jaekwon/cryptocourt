// Package archive keeps kourt.xyz's own copy of the images filed with a claim.
//
// WHY THIS EXISTS. A claim's evidence used to be a bare third-party URL, and the
// hosts people reach for delete exactly the controversial images. A court whose
// evidence a third party can remove is not a court of record. The chain now
// stores a sha256 and a list of mirrors instead, and this service is the mirror
// the project itself operates: content-addressed, so the address is derivable
// from the hash and nothing has to be stored on chain to find it.
//
// IT IS A MIRROR, NEVER AN AUTHORITY. It cannot forge — the hash is on chain and
// every client checks — so the only question it must answer honestly is
// availability. Being wrong here loses pixels, never proof.
//
// See docs/CLAIM_MEDIA.md; §3 is this package.
package archive

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"time"
)

// MaxBytes bounds one blob. It matches the realm's own cap, and the composer
// downscales to fit without ever telling anyone about it — so this is a backstop
// against a hostile uploader, not a rule an honest person meets.
const MaxBytes = 256 * 1024

// StageTTL is how long unreferenced bytes live.
//
// THIS IS THE ANTI-ABUSE MECHANISM, not a housekeeping detail. Without it POST
// /m is an unauthenticated, unmetered, anonymous place to put arbitrary bytes on
// someone else's disk forever — free hosting for content with no connection to
// any court. Bytes are promoted to permanent only when an on-chain claim
// references their hash, which ties archive cost to the one thing an attacker
// cannot fake or get for free: filing a claim costs a deposit the court already
// charges.
//
// An hour is ample. The composer uploads seconds before it asks for a signature,
// and a draft abandoned mid-compose is exactly what should expire.
const StageTTL = time.Hour

// ErrNotFound is returned for a blob this archive does not hold, or holds and
// has been told not to serve. The two are deliberately indistinguishable to a
// caller: a takedown that announced itself would be a lookup oracle for what has
// been taken down.
var ErrNotFound = errors.New("archive: no such blob")

// servableMIMEs is what may be stored AND served, and it is raster only.
//
// SVG IS EXCLUDED ON PURPOSE AND MUST STAY EXCLUDED. These bytes are served from
// kourt.xyz's own origin. Inside an <img> an SVG is inert, but a person who
// follows the link directly gets a document — and an SVG document can carry
// script, which would then run as kourt.xyz. There is no version of "user
// uploads run script on our origin" that ends well, and no image an author needs
// that cannot be a PNG.
var servableMIMEs = map[string]string{
	"image/png":  ".png",
	"image/jpeg": ".jpg",
	"image/webp": ".webp",
	"image/gif":  ".gif",
	"image/avif": ".avif",
}

// MIMEServable reports whether the archive will accept and serve this type.
func MIMEServable(mime string) bool {
	_, ok := servableMIMEs[mime]
	return ok
}

// SniffMIME reads the type out of the BYTES, and it exists because the type on
// the way in is whatever the caller's Content-Type header claimed.
//
// nosniff keeps a browser from acting on a lie, but "a browser will not execute
// it" is a smaller promise than "this archive holds images". Without this, POST
// /m is a way to park arbitrary bytes on our disk, at our address, under a label
// that says picture — and the thing serving them is a court.
//
// Returns "" for anything it does not recognise, which is refused.
func SniffMIME(body []byte) string {
	switch {
	case len(body) >= 8 && string(body[:8]) == "\x89PNG\r\n\x1a\n":
		return "image/png"
	case len(body) >= 3 && body[0] == 0xff && body[1] == 0xd8 && body[2] == 0xff:
		return "image/jpeg"
	case len(body) >= 12 && string(body[:4]) == "RIFF" && string(body[8:12]) == "WEBP":
		return "image/webp"
	case len(body) >= 6 && (string(body[:6]) == "GIF87a" || string(body[:6]) == "GIF89a"):
		return "image/gif"
	// AVIF is an ISO-BMFF box: the major brand sits at bytes 8..12 after "ftyp".
	case len(body) >= 12 && string(body[4:8]) == "ftyp" &&
		(string(body[8:12]) == "avif" || string(body[8:12]) == "avis"):
		return "image/avif"
	}
	return ""
}

const schema = `
CREATE TABLE IF NOT EXISTS blobs (
  sha256    TEXT PRIMARY KEY,
  mime      TEXT NOT NULL,
  body      BLOB NOT NULL,
  size      INTEGER NOT NULL,
  staged_at INTEGER NOT NULL,
  promoted  INTEGER NOT NULL DEFAULT 0,
  blocked   INTEGER NOT NULL DEFAULT 0,
  court     TEXT
);
CREATE INDEX IF NOT EXISTS blobs_sweep ON blobs (promoted, staged_at);
`

// Store holds the bytes. It shares the service's database because that database
// is documented as the service's whole memory and the one thing to back up —
// a second store beside it would quietly make that false.
type Store struct {
	db *sql.DB
}

func NewStore(db *sql.DB) (*Store, error) {
	if _, err := db.Exec(schema); err != nil {
		return nil, fmt.Errorf("archive schema: %w", err)
	}
	if _, err := db.Exec(backfillSchema); err != nil {
		return nil, fmt.Errorf("archive backfill schema: %w", err)
	}
	// Added after the first release, so an existing database needs it explicitly.
	if err := ensureColumn(db, "blobs", "court", "TEXT"); err != nil {
		return nil, fmt.Errorf("archive court column: %w", err)
	}
	if err := ensureClassifySchema(db); err != nil {
		return nil, fmt.Errorf("archive review schema: %w", err)
	}
	return &Store{db: db}, nil
}

// Digest is the address of these bytes, and the only name the archive knows them
// by. Callers never choose it.
func Digest(body []byte) string {
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}

// Put stages bytes and returns their digest.
//
// The archive computes the hash ITSELF and never accepts one from the caller.
// Trusting a submitted digest would let anyone park bytes at an address that
// does not describe them — which is the single thing content addressing exists
// to prevent, and the reason a client can believe any mirror.
// court is the slug the upload was composed for, or "" when the caller did not
// say. It is a HINT for backfill and nothing else: it grants no access, and a
// wrong one only means the bytes rely on /m/claimed instead.
func (s *Store) Put(ctx context.Context, mime string, body []byte, court string) (string, error) {
	if len(body) == 0 {
		return "", errors.New("archive: empty body")
	}
	if len(body) > MaxBytes {
		return "", fmt.Errorf("archive: %d bytes exceeds the %d cap", len(body), MaxBytes)
	}
	if !MIMEServable(mime) {
		return "", fmt.Errorf("archive: %q is not a servable image type", mime)
	}
	// THE BYTES DECIDE, NOT THE HEADER. A caller may label anything image/png;
	// only something that actually starts like a PNG is stored as one.
	if got := SniffMIME(body); got != mime {
		if got == "" {
			return "", fmt.Errorf("archive: those bytes are not an image this archive stores")
		}
		return "", fmt.Errorf("archive: sent as %q but the bytes are %q", mime, got)
	}
	sum := Digest(body)
	// Idempotent, and deliberately does NOT reset staged_at or clear promoted:
	// re-uploading a blob must not extend the life of something already expiring,
	// and must not un-promote something already permanent.
	_, err := s.db.ExecContext(ctx,
		`INSERT INTO blobs (sha256, mime, body, size, staged_at, court)
		 VALUES (?, ?, ?, ?, ?, ?)
		 ON CONFLICT(sha256) DO NOTHING`,
		sum, mime, body, len(body), time.Now().Unix(), court)
	if err != nil {
		return "", fmt.Errorf("archive put: %w", err)
	}
	return sum, nil
}

// Get returns the bytes for a digest. A blocked blob answers ErrNotFound.
func (s *Store) Get(ctx context.Context, sum string) (mime string, body []byte, err error) {
	row := s.db.QueryRowContext(ctx,
		`SELECT mime, body FROM blobs WHERE sha256 = ? AND blocked = 0`, sum)
	switch err := row.Scan(&mime, &body); {
	case errors.Is(err, sql.ErrNoRows):
		return "", nil, ErrNotFound
	case err != nil:
		return "", nil, fmt.Errorf("archive get: %w", err)
	}
	// Belt and braces against a row written by an older, laxer version of this
	// package: what is not servable now is not served now, whatever put it there.
	if !MIMEServable(mime) {
		return "", nil, ErrNotFound
	}
	return mime, body, nil
}

// Promote makes a staged blob permanent. Called when an on-chain claim is seen
// to reference the digest — that reference is what buys the storage.
func (s *Store) Promote(ctx context.Context, sum string) error {
	_, err := s.db.ExecContext(ctx,
		`UPDATE blobs SET promoted = 1 WHERE sha256 = ?`, sum)
	if err != nil {
		return fmt.Errorf("archive promote: %w", err)
	}
	return nil
}

// Block stops the archive serving a blob without forgetting it.
//
// THIS DOES NOT AND CANNOT UNFILE ANYTHING. The chain still holds the hash, the
// claim still says evidence was filed, and another mirror may still serve the
// bytes. Chain-side purge and archive-side refusal are independent on purpose:
// either alone takes an image off kourt.xyz, and neither can rewrite the record
// of what was filed.
func (s *Store) Block(ctx context.Context, sum string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE blobs SET blocked = 1 WHERE sha256 = ?`, sum)
	if err != nil {
		return fmt.Errorf("archive block: %w", err)
	}
	return nil
}

// SweepStaged deletes unpromoted bytes older than StageTTL and reports how many
// went. This is what keeps the endpoint from being free permanent hosting.
func (s *Store) SweepStaged(ctx context.Context, now time.Time) (int64, error) {
	res, err := s.db.ExecContext(ctx,
		`DELETE FROM blobs WHERE promoted = 0 AND staged_at < ?`,
		now.Add(-StageTTL).Unix())
	if err != nil {
		return 0, fmt.Errorf("archive sweep: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("archive sweep count: %w", err)
	}
	return n, nil
}

// StagedBytesSince is how much unpromoted data has arrived since a moment, used
// to cap a single uploader before the sweep would catch up with them.
func (s *Store) StagedBytesSince(ctx context.Context, since time.Time) (int64, error) {
	var total sql.NullInt64
	err := s.db.QueryRowContext(ctx,
		`SELECT SUM(size) FROM blobs WHERE promoted = 0 AND staged_at >= ?`,
		since.Unix()).Scan(&total)
	if err != nil {
		return 0, fmt.Errorf("archive staged total: %w", err)
	}
	return total.Int64, nil
}
