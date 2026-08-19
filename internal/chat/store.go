package chat

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/netip"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

// EVERY TIMESTAMP IN THIS PACKAGE IS UNIX SECONDS. Stated once, here, because the
// whole enforcement model is durations and a seconds-vs-milliseconds slip turns a
// one-hour timeout into either 3.6 seconds or 1000 hours.

const (
	// Throttle. Deterministic, and deliberately independent of the scanner — none
	// of this waits on a model.
	MinInterval  = 2 * time.Second
	PerIPWindow  = time.Minute
	PerIPMax     = 10
	CourtWindow  = time.Minute
	CourtSoftCap = 30 // a court's messages per window before fair-share bites
	FairShare    = 3  // one address's slice of a CONTENDED court
	GlobalWindow = time.Minute
	GlobalMax    = 300 // shed new addresses past this, never established ones

	// The enforcer's clamp. An automated consequence cannot outlive this however
	// it was written, so a scanner bug or a future edit cannot manufacture a
	// permanent ban out of a very long kick.
	MaxAutoKick = 7 * 24 * time.Hour

	// The escalation ladder, and the lookback over which repeats count.
	LadderLookback = 30 * 24 * time.Hour
)

// Ladder is the sequence of automated timeouts. "Kicked for an hour, or more if
// repeat offender" — three rungs, because a ladder cannot be tuned before there
// is traffic to tune it against, and the top rung is MaxAutoKick.
var Ladder = []time.Duration{time.Hour, 24 * time.Hour, 7 * 24 * time.Hour}

const (
	ScanNew     = 0
	ScanDone    = 1
	ScanFailed  = 2
	ScanClaimed = 3
)

const (
	KindKick = "kick"
	KindBan  = "ban"

	ReasonSpam   = "spam"
	ReasonScam   = "scam"
	ReasonHack   = "hack"
	ReasonFlood  = "flood"
	ReasonManual = "manual"
)

var (
	ErrThrottled = errors.New("too many messages")
	ErrKicked    = errors.New("posting is blocked for this address")
	ErrDuplicate = errors.New("the same message was just posted in several courts")
	ErrPurged    = errors.New("this court has been purged")
)

// Store owns the database. Two handles on purpose.
//
// SQLite in WAL mode allows many readers and one writer. A single pooled handle
// capped at one connection would put every read behind every write and behind the
// busy timeout — GETs queued in Go's pool, where WAL's concurrent-reader guarantee
// cannot help them. So reads get a pool and writes get exactly one connection,
// which is also what makes BEGIN IMMEDIATE meaningful.
type Store struct {
	r, w *sql.DB
	Now  func() time.Time // injectable, so durations are testable to the second
}

const schema = `
CREATE TABLE IF NOT EXISTS messages (
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
);
CREATE INDEX IF NOT EXISTS messages_read  ON messages(chain, court, id);
CREATE INDEX IF NOT EXISTS messages_queue ON messages(scan_state, next_try, id);
CREATE INDEX IF NOT EXISTS messages_by_ip ON messages(ip_hash, id);
CREATE INDEX IF NOT EXISTS messages_dup   ON messages(ip_hash, skeleton, created_at);

CREATE TABLE IF NOT EXISTS infractions (
  id          INTEGER PRIMARY KEY,
  ip_hash     TEXT    NOT NULL,
  net_hash    TEXT    NOT NULL DEFAULT '',
  kind        TEXT    NOT NULL,
  reason      TEXT    NOT NULL,
  evidence_id INTEGER,
  evidence    TEXT    NOT NULL DEFAULT '',
  detail      TEXT    NOT NULL DEFAULT '',
  created_at  INTEGER NOT NULL,
  expires_at  INTEGER,
  revoked_at  INTEGER,
  revoked_by  TEXT    NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS infractions_active ON infractions(ip_hash, revoked_at, expires_at);
CREATE INDEX IF NOT EXISTS infractions_net    ON infractions(net_hash, revoked_at, expires_at);
-- Replay of the same evidence is a no-op, which is what makes a crash between
-- "punish" and "mark scanned" harmless. PARTIAL, because SQLite treats NULLs as
-- distinct (so manual rows with no evidence would not be constrained at all) and
-- because without the revoked_at clause a ban -> unban -> ban cycle would fail.
CREATE UNIQUE INDEX IF NOT EXISTS infractions_once
  ON infractions(evidence_id, kind)
  WHERE evidence_id IS NOT NULL AND revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS frozen (chain TEXT, court TEXT, at INTEGER NOT NULL,
  PRIMARY KEY (chain, court));
`

// Open prepares the database. The pragmas are not optional: without busy_timeout
// a concurrent writer gets SQLITE_BUSY instantly rather than waiting, which is the
// difference between "the scanner is writing" and "chat returned an error".
func Open(path string) (*Store, error) {
	dsn := "file:" + path +
		"?_pragma=journal_mode(WAL)" +
		"&_pragma=busy_timeout(5000)" +
		"&_pragma=synchronous(NORMAL)" +
		"&_pragma=wal_autocheckpoint(256)"

	// _txlock=immediate on the WRITE handle, and this is not optional.
	//
	// database/sql's BeginTx issues a plain BEGIN, which is DEFERRED: the
	// transaction starts as a reader and tries to upgrade on its first write. When
	// another connection holds the write lock, that upgrade returns SQLITE_BUSY —
	// and busy_timeout does NOT retry it, deliberately, because waiting could hand
	// the transaction an inconsistent snapshot. The only correct recovery is to roll
	// back and re-run the whole transaction.
	//
	// Measured before the fix, in TestAWriteWaitsForTheLockRatherThanFailing: a post
	// from a second process while the first held a write transaction failed outright
	// with "database is locked (5)". In production that is a user's message refused
	// with a 503 every time the scanner happens to be writing. BEGIN IMMEDIATE takes
	// the write lock up front, where busy_timeout DOES apply, so the post waits and
	// then succeeds.
	w, err := sql.Open("sqlite", dsn+"&_txlock=immediate")
	if err != nil {
		return nil, err
	}
	w.SetMaxOpenConns(1)
	if _, err := w.Exec(schema); err != nil {
		w.Close()
		return nil, fmt.Errorf("schema: %w", err)
	}
	r, err := sql.Open("sqlite", dsn)
	if err != nil {
		w.Close()
		return nil, err
	}
	r.SetMaxOpenConns(4)
	return &Store{r: r, w: w, Now: time.Now}, nil
}

func (s *Store) Close() error {
	err := s.w.Close()
	if err2 := s.r.Close(); err == nil {
		err = err2
	}
	return err
}

// Secret reads the HMAC key, creating it once if absent.
//
// INSERT OR IGNORE rather than "generate on first run": three binaries may start
// together, and a lost race that regenerated the key would silently lift every
// consequence and change everyone's public tag with no log line.
func (s *Store) Secret(gen func() []byte) ([]byte, error) {
	if _, err := s.w.Exec(`INSERT OR IGNORE INTO meta(k,v) VALUES('ip_secret', ?)`,
		fmt.Sprintf("%x", gen())); err != nil {
		return nil, err
	}
	key, ok, err := s.SecretIfSet()
	if err != nil {
		return nil, err
	}
	if !ok {
		// INSERT OR IGNORE then no row back is not a state that should be reachable;
		// saying so beats returning a nil key that hashes everything identically.
		return nil, errors.New("ip_secret vanished between write and read")
	}
	return key, nil
}

// SecretIfSet reads the key WITHOUT creating one, and reports whether there was one.
//
// The read-only half of Secret, for callers that must not mint. An operator tool that
// silently generated a key would produce hashes matching nothing the server wrote — a
// ban that appears to succeed and blocks nobody.
func (s *Store) SecretIfSet() ([]byte, bool, error) {
	var hexKey string
	err := s.r.QueryRow(`SELECT v FROM meta WHERE k='ip_secret'`).Scan(&hexKey)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	key := make([]byte, len(hexKey)/2)
	for i := range key {
		var b int
		if _, err := fmt.Sscanf(hexKey[i*2:i*2+2], "%02x", &b); err != nil {
			return nil, false, fmt.Errorf("ip_secret is not hex: %w", err)
		}
		key[i] = byte(b)
	}
	return key, true, nil
}

// Message is a row as the world sees it. There is deliberately no verdict field:
// a model's opinion about a person is not a public surface.
type Message struct {
	ID        int64  `json:"id"`
	Moniker   string `json:"moniker"`
	Body      string `json:"body"`
	Country   string `json:"country"`
	Suffix    string `json:"suffix"`
	CreatedAt int64  `json:"created_at"`
}

// Post is the whole admission decision plus the insert, in one transaction.
//
// BEGIN IMMEDIATE, and everything inside it, because the checks are reads that
// gate a write: run outside a transaction, two simultaneous posts from one address
// both pass the interval check and both land.
func (s *Store) Post(ctx context.Context, in PostInput) (int64, error) {
	now := s.Now()
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	var frozen int
	if err := tx.QueryRowContext(ctx,
		`SELECT count(*) FROM frozen WHERE chain=? AND court=?`, in.Chain, in.Court).
		Scan(&frozen); err != nil {
		return 0, err
	}
	if frozen > 0 {
		return 0, ErrPurged
	}

	if st, err := statusTx(ctx, tx, in.IPHash, in.NetHash, now); err != nil {
		return 0, err
	} else if st.Blocked() {
		return 0, fmt.Errorf("%w: %s", ErrKicked, st.State)
	}

	if err := throttleTx(ctx, tx, in, now); err != nil {
		return 0, err
	}

	res, err := tx.ExecContext(ctx, `INSERT INTO messages
	  (chain,court,moniker,body,skeleton,ip_hash,net_hash,country,suffix,created_at)
	  VALUES (?,?,?,?,?,?,?,?,?,?)`,
		in.Chain, in.Court, in.Moniker, in.Body, Skeleton(in.Body),
		in.IPHash, in.NetHash, in.Country, in.Suffix, now.Unix())
	if err != nil {
		return 0, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, err
	}
	return id, tx.Commit()
}

// PostInput carries what the HTTP layer has already sanitised and hashed. The
// store does not sanitise: doing it once, at ingest, is what keeps the scanner and
// the renderer looking at identical bytes.
type PostInput struct {
	Chain, Court    string
	Moniker, Body   string
	IPHash, NetHash string
	Country, Suffix string
}

func throttleTx(ctx context.Context, tx *sql.Tx, in PostInput, now time.Time) error {
	var last sql.NullInt64
	if err := tx.QueryRowContext(ctx,
		`SELECT max(created_at) FROM messages WHERE ip_hash=?`, in.IPHash).Scan(&last); err != nil {
		return err
	}
	if last.Valid && now.Unix()-last.Int64 < int64(MinInterval.Seconds()) {
		return fmt.Errorf("%w: one message every %s", ErrThrottled, MinInterval)
	}

	var mine int
	if err := tx.QueryRowContext(ctx,
		`SELECT count(*) FROM messages WHERE ip_hash=? AND created_at > ?`,
		in.IPHash, now.Add(-PerIPWindow).Unix()).Scan(&mine); err != nil {
		return err
	}
	if mine >= PerIPMax {
		return fmt.Errorf("%w: %d per %s", ErrThrottled, PerIPMax, PerIPWindow)
	}

	// Fair share, and it binds ONLY under contention. A flat per-address quota
	// would throttle two people talking while most of the court's budget sat
	// idle; a court-wide cap with no per-address share lets three addresses mute
	// the room for everybody.
	var courtTotal, courtMine int
	if err := tx.QueryRowContext(ctx, `SELECT count(*),
	    coalesce(sum(CASE WHEN ip_hash=? THEN 1 ELSE 0 END),0)
	  FROM messages WHERE chain=? AND court=? AND created_at > ?`,
		in.IPHash, in.Chain, in.Court, now.Add(-CourtWindow).Unix()).
		Scan(&courtTotal, &courtMine); err != nil {
		return err
	}
	if courtTotal >= CourtSoftCap && courtMine >= FairShare {
		return fmt.Errorf("%w: this court is busy, and this address has had its share",
			ErrThrottled)
	}

	// Global budget. It SHEDS rather than denies: past the cap, an address that
	// has already posted in the window keeps going and a new one waits. A flat
	// global 429 would let one attacker mute the entire product.
	var globalTotal int
	if err := tx.QueryRowContext(ctx,
		`SELECT count(*) FROM messages WHERE created_at > ?`,
		now.Add(-GlobalWindow).Unix()).Scan(&globalTotal); err != nil {
		return err
	}
	if globalTotal >= GlobalMax && mine == 0 {
		return fmt.Errorf("%w: the service is saturated", ErrThrottled)
	}

	// Cross-court duplicate posting is a RATE LIMIT, not a punishment: it refuses
	// this message and writes no infraction. As a punishment it was a mass-harm
	// primitive — on a shared address an attacker types one sentence in three
	// courts and a stranger is kicked — and it fires on the honest announcement.
	if sk := Skeleton(in.Body); len(sk) >= 12 {
		// OTHER courts, excluding this one: two already plus this one is the
		// third, which is where the rule was described as biting. Repeating
		// yourself in a court you have already used is the per-address
		// throttle's business, not this rule's.
		var others int
		if err := tx.QueryRowContext(ctx,
			`SELECT count(DISTINCT court) FROM messages
			 WHERE ip_hash=? AND skeleton=? AND court <> ? AND created_at > ?`,
			in.IPHash, sk, in.Court, now.Add(-10*time.Minute).Unix()).Scan(&others); err != nil {
			return err
		}
		if others >= 2 {
			return ErrDuplicate
		}
	}
	return nil
}

// Status is what a caller is told about themselves, so the composer can be
// disabled before anyone types into a box that will refuse them.
type Status struct {
	State string `json:"state"` // ok | kick | ban
	Until int64  `json:"until,omitempty"`
	Ref   int64  `json:"ref,omitempty"` // opaque, so an appeal can quote something
}

func (s Status) Blocked() bool { return s.State != "" && s.State != "ok" }

func (s *Store) Status(ctx context.Context, ipHash, netHash string) (Status, error) {
	return statusTx(ctx, s.r, ipHash, netHash, s.Now())
}

type querier interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

// statusTx is the enforcement read, and it is where the automated ceiling is
// APPLIED rather than merely promised.
//
// Whatever the scanner wrote, this clamps a non-manual consequence to
// MaxAutoKick from its creation and refuses to honour a non-manual ban at all. The
// guarantee therefore lives in the process whose behaviour *is* the punishment,
// and survives any future edit to the scanner.
func statusTx(ctx context.Context, q querier, ipHash, netHash string, now time.Time) (Status, error) {
	var (
		id           int64
		kind, reason string
		createdAt    int64
		expiresAt    sql.NullInt64
	)
	err := q.QueryRowContext(ctx, `SELECT id, kind, reason, created_at, expires_at
	  FROM infractions
	  WHERE revoked_at IS NULL
	    -- The network only matches for a MANUAL consequence. An automated kick
	    -- applies to one address and nothing else.
	    --
	    -- Without that clause every scanner kick silently punished the whole /24:
	    -- found by posting one scam from 203.0.113.50 and watching an untouched
	    -- 203.0.113.99 get a 403. net_hash exists so an OPERATOR facing a rotation
	    -- campaign can act on a range in one command — a range is a decision a
	    -- human makes, never a side effect of a model's opinion.
	    AND (ip_hash = ?
	         OR (reason = 'manual' AND net_hash <> '' AND net_hash = ?))
	    AND (expires_at IS NULL OR expires_at > ?)
	  ORDER BY (expires_at IS NULL) DESC, expires_at DESC LIMIT 1`,
		ipHash, netHash, now.Unix()).Scan(&id, &kind, &reason, &createdAt, &expiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Status{State: "ok"}, nil
	}
	if err != nil {
		return Status{}, err
	}

	if reason != ReasonManual {
		ceiling := createdAt + int64(MaxAutoKick.Seconds())
		if kind == KindBan {
			// An automated ban is not honoured. It is capped to a kick, so a
			// scanner that wrote one has still only bought MaxAutoKick.
			kind = KindKick
			if !expiresAt.Valid {
				expiresAt = sql.NullInt64{Int64: ceiling, Valid: true}
			}
		}
		if !expiresAt.Valid || expiresAt.Int64 > ceiling {
			expiresAt = sql.NullInt64{Int64: ceiling, Valid: true}
		}
		if expiresAt.Int64 <= now.Unix() {
			return Status{State: "ok"}, nil
		}
	}
	st := Status{State: kind, Ref: id}
	if expiresAt.Valid {
		st.Until = expiresAt.Int64
	}
	return st, nil
}

// Recent reads a court's visible history. hidden rows are filtered here, so a
// consequence removes a scam from view rather than only stopping the next one.
func (s *Store) Recent(ctx context.Context, chain, court string, since int64, limit int) ([]Message, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	if since < 0 {
		since = 0
	}
	rows, err := s.r.QueryContext(ctx, `SELECT id, moniker, body, country, suffix, created_at
	  FROM messages WHERE chain=? AND court=? AND id > ? AND hidden=0
	  ORDER BY id LIMIT ?`, chain, court, since, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Message
	for rows.Next() {
		var m Message
		if err := rows.Scan(&m.ID, &m.Moniker, &m.Body, &m.Country, &m.Suffix, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// Consequence records a kick or ban and hides the offender's recent messages.
//
// hidden is scoped to the SAME MESSAGE plus that address's last few minutes,
// rather than everything it ever posted: on a shared address a wider sweep would
// retroactively delete strangers' messages, and every routine timeout would carry
// that collateral.
func (s *Store) Consequence(ctx context.Context, c Infraction) (int64, error) {
	now := s.Now()
	if c.Kind == KindBan && c.Reason != ReasonManual {
		return 0, errors.New("only a manual consequence may be a ban")
	}
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()

	var expires any
	if c.Kind == KindKick {
		d := c.Duration
		if c.Reason != ReasonManual && (d <= 0 || d > MaxAutoKick) {
			d = MaxAutoKick
		}
		expires = now.Add(d).Unix()
	}
	var evID any
	if c.EvidenceID > 0 {
		evID = c.EvidenceID
	}
	res, err := tx.ExecContext(ctx, `INSERT INTO infractions
	  (ip_hash,net_hash,kind,reason,evidence_id,evidence,detail,created_at,expires_at)
	  VALUES (?,?,?,?,?,?,?,?,?)`,
		c.IPHash, c.NetHash, c.Kind, c.Reason, evID, c.Evidence, c.Detail,
		now.Unix(), expires)
	if err != nil {
		// The partial unique index makes a replay of the same evidence a no-op,
		// which is what stops a crash between punish and mark-scanned from
		// walking the ladder.
		if strings.Contains(err.Error(), "UNIQUE") {
			return 0, nil
		}
		return 0, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, err
	}
	if _, err := tx.ExecContext(ctx,
		`UPDATE messages SET hidden=1 WHERE ip_hash=? AND created_at > ?`,
		c.IPHash, now.Add(-10*time.Minute).Unix()); err != nil {
		return 0, err
	}
	return id, tx.Commit()
}

// Infraction is a consequence to record.
type Infraction struct {
	IPHash, NetHash string
	Kind, Reason    string
	Duration        time.Duration // kicks only
	EvidenceID      int64
	Evidence        string // a COPY of the body, so an appeal survives pruning
	Detail          string
}

// Escalate returns the next rung for an address: "an hour, or more if repeat
// offender". Only unrevoked infractions count, or an upheld appeal would unmute
// somebody and leave them one rung higher — reversible-looking rather than
// reversible.
func (s *Store) Escalate(ctx context.Context, ipHash string) (time.Duration, error) {
	var n int
	err := s.r.QueryRowContext(ctx, `SELECT count(*) FROM infractions
	  WHERE ip_hash=? AND revoked_at IS NULL AND reason <> ? AND created_at > ?`,
		ipHash, ReasonManual, s.Now().Add(-LadderLookback).Unix()).Scan(&n)
	if err != nil {
		return 0, err
	}
	if n >= len(Ladder) {
		n = len(Ladder) - 1
	}
	return Ladder[n], nil
}

// Revoke reverses a consequence and un-hides what it hid. The row is kept, not
// deleted: deleting it would erase the audit trail the appeal path depends on.
func (s *Store) Revoke(ctx context.Context, id int64, by string) error {
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var ipHash string
	if err := tx.QueryRowContext(ctx,
		`SELECT ip_hash FROM infractions WHERE id=?`, id).Scan(&ipHash); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx,
		`UPDATE infractions SET revoked_at=?, revoked_by=? WHERE id=? AND revoked_at IS NULL`,
		s.Now().Unix(), by, id); err != nil {
		return err
	}
	// An appeal that restored posting and left the messages hidden would be half
	// an apology.
	if _, err := tx.ExecContext(ctx,
		`UPDATE messages SET hidden=0 WHERE ip_hash=?`, ipHash); err != nil {
		return err
	}
	return tx.Commit()
}

// Freeze marks a court unservable, for a purge on chain. Latched in a store we
// own rather than re-derived from the chain on every request, because the chain
// read cannot distinguish "purged" from "node unreachable".
func (s *Store) Freeze(ctx context.Context, chain, court string) error {
	_, err := s.w.ExecContext(ctx,
		`INSERT OR IGNORE INTO frozen(chain,court,at) VALUES (?,?,?)`,
		chain, court, s.Now().Unix())
	return err
}

// Heartbeat records that the scanner is alive, and whether it is enforcing.
// Reported as-is so the panel cannot claim moderation that is not happening.
func (s *Store) Heartbeat(ctx context.Context, enforcing bool) error {
	_, err := s.w.ExecContext(ctx,
		`INSERT INTO meta(k,v) VALUES('scanner_seen', ?)
		 ON CONFLICT(k) DO UPDATE SET v=excluded.v`,
		fmt.Sprintf("%d,%t", s.Now().Unix(), enforcing))
	return err
}

// Health is what /api/chat/health answers.
type Health struct {
	OK          bool  `json:"ok"`
	ScannerSeen int64 `json:"scanner_seen_at,omitempty"`
	Enforcing   bool  `json:"enforcing"`
	Backlog     int   `json:"backlog"`
}

func (s *Store) Health(ctx context.Context) (Health, error) {
	h := Health{OK: true}
	var v string
	switch err := s.r.QueryRowContext(ctx,
		`SELECT v FROM meta WHERE k='scanner_seen'`).Scan(&v); {
	case errors.Is(err, sql.ErrNoRows): // never started: fail-open, and say so
	case err != nil:
		return h, err
	default:
		fmt.Sscanf(v, "%d,%t", &h.ScannerSeen, &h.Enforcing)
	}
	if err := s.r.QueryRowContext(ctx,
		`SELECT count(*) FROM messages WHERE scan_state IN (?,?)`,
		ScanNew, ScanFailed).Scan(&h.Backlog); err != nil {
		return h, err
	}
	return h, nil
}

// Pending is a message for the scanner, with the window it should be judged
// against.
type Pending struct {
	ID              int64
	Chain, Court    string
	Body            string
	IPHash, NetHash string
	Prior           []string
}

// Claim takes up to n messages for scanning and marks them claimed, so a second
// daemon or an overlapping restart cannot punish the same row twice.
//
// Newest first for anything recent: draining oldest-first means that after an
// outage the currently-harmful messages are scanned last, exactly during the burst
// that matters.
func (s *Store) Claim(ctx context.Context, n int) ([]Pending, error) {
	now := s.Now().Unix()
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	// Reclaim anything a dead daemon left claimed.
	if _, err := tx.ExecContext(ctx,
		`UPDATE messages SET scan_state=? WHERE scan_state=? AND claimed_at < ?`,
		ScanNew, ScanClaimed, now-300); err != nil {
		return nil, err
	}

	rows, err := tx.QueryContext(ctx, `SELECT id, chain, court, body, ip_hash, net_hash
	  FROM messages
	  WHERE scan_state IN (?,?) AND next_try <= ? AND hidden=0
	  ORDER BY (created_at > ?) DESC, id DESC LIMIT ?`,
		ScanNew, ScanFailed, now, now-600, n)
	if err != nil {
		return nil, err
	}
	var out []Pending
	for rows.Next() {
		var p Pending
		if err := rows.Scan(&p.ID, &p.Chain, &p.Court, &p.Body, &p.IPHash, &p.NetHash); err != nil {
			rows.Close()
			return nil, err
		}
		out = append(out, p)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	for i, p := range out {
		if _, err := tx.ExecContext(ctx,
			`UPDATE messages SET scan_state=?, claimed_at=? WHERE id=?`,
			ScanClaimed, now, p.ID); err != nil {
			return nil, err
		}
		prior, err := priorTx(ctx, tx, p, now)
		if err != nil {
			return nil, err
		}
		out[i].Prior = prior
	}
	return out, tx.Commit()
}

// priorTx is the window: the same address's recent messages in the same court.
//
// Bounded three ways, and each bound closes a real hole. After the LAST
// CONSEQUENCE, or an expired timeout's own evidence keeps being re-judged and
// "hello" three times walks the ladder. Within THIRTY MINUTES, so context does not
// accumulate forever. And hidden=0, so punished content stops driving verdicts.
func priorTx(ctx context.Context, tx *sql.Tx, p Pending, now int64) ([]string, error) {
	var since int64
	if err := tx.QueryRowContext(ctx,
		`SELECT coalesce(max(created_at),0) FROM infractions WHERE ip_hash=?`,
		p.IPHash).Scan(&since); err != nil {
		return nil, err
	}
	if w := now - int64((30 * time.Minute).Seconds()); w > since {
		since = w
	}
	rows, err := tx.QueryContext(ctx, `SELECT body FROM messages
	  WHERE ip_hash=? AND court=? AND chain=? AND id < ? AND created_at > ? AND hidden=0
	  ORDER BY id DESC LIMIT 5`, p.IPHash, p.Court, p.Chain, p.ID, since)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var b string
		if err := rows.Scan(&b); err != nil {
			return nil, err
		}
		out = append([]string{b}, out...) // oldest first, as they were said
	}
	return out, rows.Err()
}

// RecordVerdict stores a scan result. Called in one short transaction AFTER the
// model has answered — never with an inference in flight, which would hold the
// write lock for seconds and make chat return errors.
func (s *Store) RecordVerdict(ctx context.Context, id int64, verdict string) error {
	_, err := s.w.ExecContext(ctx,
		`UPDATE messages SET scan_state=?, verdict=?, claimed_at=0 WHERE id=?`,
		ScanDone, verdict, id)
	return err
}

// RecordFailure schedules a retry with backoff, and gives up after enough tries
// so a permanently malformed row cannot be retried forever.
func (s *Store) RecordFailure(ctx context.Context, id int64) error {
	const maxAttempts = 5
	var attempts int
	if err := s.r.QueryRowContext(ctx,
		`SELECT attempts FROM messages WHERE id=?`, id).Scan(&attempts); err != nil {
		return err
	}
	attempts++
	state := ScanFailed
	if attempts >= maxAttempts {
		state = ScanDone // terminal: unscannable, and never punished
	}
	backoff := time.Duration(1<<uint(attempts)) * time.Second
	_, err := s.w.ExecContext(ctx,
		`UPDATE messages SET scan_state=?, attempts=?, next_try=?, claimed_at=0 WHERE id=?`,
		state, attempts, s.Now().Add(backoff).Unix(), id)
	return err
}

// HashPair is the two keys a consequence can apply to: the address, and the
// network it sits in. The second exists so an operator facing a rotation campaign
// has one action available instead of forty.
func HashPair(h *Hasher, a netip.Addr) (ipHash, netHash string) {
	return h.Hash(a), h.HashNet(a)
}

// InfractionRow is a consequence as an operator sees it — including the evidence,
// because an appeal that cannot be examined is not an appeal.
type InfractionRow struct {
	ID         int64
	IPHash     string
	NetHash    string
	Kind       string
	Reason     string
	EvidenceID int64
	Evidence   string
	Detail     string
	CreatedAt  int64
	ExpiresAt  int64 // 0 = never
	RevokedAt  int64 // 0 = in force
	RevokedBy  string
}

// ListInfractions reads consequences, newest first. An empty ipHash lists all of
// them; revoked rows are included only on request, because the default question is
// "what is in force".
func (s *Store) ListInfractions(ctx context.Context, ipHash string, withRevoked bool, limit int) ([]InfractionRow, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	q := `SELECT id, ip_hash, net_hash, kind, reason,
	        coalesce(evidence_id,0), evidence, detail, created_at,
	        coalesce(expires_at,0), coalesce(revoked_at,0), revoked_by
	      FROM infractions WHERE 1=1`
	var args []any
	if ipHash != "" {
		q += ` AND (ip_hash = ? OR net_hash = ?)`
		args = append(args, ipHash, ipHash)
	}
	if !withRevoked {
		q += ` AND revoked_at IS NULL`
	}
	q += ` ORDER BY id DESC LIMIT ?`
	args = append(args, limit)

	rows, err := s.r.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []InfractionRow
	for rows.Next() {
		var r InfractionRow
		if err := rows.Scan(&r.ID, &r.IPHash, &r.NetHash, &r.Kind, &r.Reason,
			&r.EvidenceID, &r.Evidence, &r.Detail, &r.CreatedAt,
			&r.ExpiresAt, &r.RevokedAt, &r.RevokedBy); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// MessageVerdict reports what the scanner concluded about one message, for the
// operator. It is deliberately not on any public read path.
func (s *Store) MessageVerdict(ctx context.Context, id int64) (verdict string, body string, err error) {
	err = s.r.QueryRowContext(ctx,
		`SELECT verdict, body FROM messages WHERE id=?`, id).Scan(&verdict, &body)
	return verdict, body, err
}

// CountInfractions is the cheap form of ListInfractions, for health and tests.
func (s *Store) CountInfractions(ctx context.Context, withRevoked bool) (int, error) {
	q := `SELECT count(*) FROM infractions`
	if !withRevoked {
		q += ` WHERE revoked_at IS NULL`
	}
	var n int
	err := s.r.QueryRowContext(ctx, q).Scan(&n)
	return n, err
}
