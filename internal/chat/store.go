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

	// The cross-court duplicate rule. DupWindow is how long a copy is remembered
	// and DupCourts is how many OTHER courts must already hold it.
	//
	// DupMinSkeleton WAS 12, and 12 refuses ordinary speech. Measured over 29
	// phrases people genuinely repeat between rooms and 13 lures a broadcaster
	// would send:
	//
	//	  >=12   ordinary refused 13/29    lures exempt from THIS rule  3/13
	//	  >=16   ordinary refused  4/29    lures exempt  4/13
	//	  >=17   ordinary refused  1/29    lures exempt  6/13
	//	  >=23   ordinary refused  1/29    lures exempt  7/13
	//	  >=24   ordinary refused  0/29    lures exempt  7/13
	//	  >=26   ordinary refused  0/29    lures exempt 10/13
	//
	// LENGTH DOES NOT SEPARATE THE TWO CLASSES. Ordinary phrases run up to 23
	// skeleton runes ("congratulations everyone") and lures start at 7 ("dm me
	// now"), so the bands overlap and no threshold avoids both errors. 16 was
	// tried first and still refused "same question here", "that worked, thanks"
	// and "following this one".
	//
	// So the threshold is placed ABOVE the ordinary band rather than inside it,
	// because the two errors are not symmetric. A false positive refuses an
	// innocent person for saying thanks in a third room, with no other line of
	// defence and nothing to tell them but this rule's own message. A false
	// negative lets one broadcast past a COARSE RATE LIMIT while the scanner
	// still reads every copy — and a bare DM-ask is the shape it was measured
	// catching at 0.85. Of the seven lures exempt at 24, TWO never needed this
	// rule at all — "send me your seed phrase" earns a deterministic SCAM floor
	// and "t.me/support" a spam one, both of which are consequences rather than
	// refusals — and the other five are short DM-asks with no destination, which
	// is the scanner's shape.
	//
	// 24 is the first threshold with no ordinary refusals, and 26 gives up three
	// more lures to buy nothing, so it is a knee rather than a preference.
	DupMinSkeleton = 24
	DupCourts      = 2
	DupWindow      = 10 * time.Minute

	// The enforcer's clamp. An automated consequence cannot outlive this however
	// it was written, so a scanner bug or a future edit cannot manufacture a
	// permanent ban out of a very long kick.
	MaxAutoKick = 7 * 24 * time.Hour

	// HideWindow is how far back a consequence reaches when hiding the offender's OTHER
	// messages. Narrow on purpose: on a shared address a wider sweep would retroactively
	// remove strangers' messages, and every routine timeout would carry that collateral.
	// The message a consequence CITES is hidden regardless of its age — see Consequence.
	HideWindow = 10 * time.Minute

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
	ErrDuplicate = errors.New("the same message was just posted in several courts; post something different, or wait")
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
  -- hidden: 0 visible, 1 hidden by a consequence, 2 hidden as a disclosed secret.
  --
  -- Every read tests hidden=0, so any non-zero value hides. The distinction matters to Revoke
  -- alone: it RECOMPUTES 1 from the consequences still standing, and must leave 2 exactly where
  -- it is. A secret was never a punishment, so an appeal about something else cannot be a reason
  -- to republish it -- measured, reversing an unrelated kick did.
  hidden     INTEGER NOT NULL DEFAULT 0,
  scan_state INTEGER NOT NULL DEFAULT 0,
  attempts   INTEGER NOT NULL DEFAULT 0,
  next_try   INTEGER NOT NULL DEFAULT 0,
  claimed_at INTEGER NOT NULL DEFAULT 0,
  verdict    TEXT    NOT NULL DEFAULT '',
  reviewed_at INTEGER NOT NULL DEFAULT 0
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
	if err := migrate(w); err != nil {
		w.Close()
		return nil, fmt.Errorf("migrating: %w", err)
	}
	r, err := sql.Open("sqlite", dsn)
	if err != nil {
		w.Close()
		return nil, err
	}
	r.SetMaxOpenConns(4)
	return &Store{r: r, w: w, Now: time.Now}, nil
}

// migrate brings an EXISTING database up to the current schema.
//
// Everything above is CREATE TABLE IF NOT EXISTS, which is exactly the right thing for
// a database that does not exist yet and does nothing whatsoever for one that does. A
// column added to `schema` therefore appears on fresh installs and silently never
// appears on the machine that has been running for a month — and the failure does not
// arrive at startup where it would be noticed, but later, as "no such column" from
// whatever query needed it first. That is a deployment trap rather than a bug in any one
// change, so it is closed once here.
//
// Column additions only, because that is the alteration SQLite makes cheap and safe.
// Anything else — renaming, retyping, dropping, backfilling — needs a real versioned
// path with PRAGMA user_version, and should not be smuggled in through this function.
func migrate(w *sql.DB) error {
	// Idempotent by inspection rather than by version counter, so it does not matter
	// whether this database was created before or after the column existed. A fresh
	// install already has it from `schema` and this is a no-op; a month-old one gets it.
	return ensureColumn(w, "messages", "reviewed_at", "INTEGER NOT NULL DEFAULT 0")
}

func ensureColumn(w *sql.DB, table, col, decl string) error {
	var n int
	if err := w.QueryRow(
		`SELECT COUNT(*) FROM pragma_table_info(?) WHERE name=?`, table, col).
		Scan(&n); err != nil {
		return err
	}
	if n > 0 {
		return nil
	}
	// Not parameterised, and it cannot be: SQLite takes no placeholders in DDL. Every
	// caller is a literal in this file, which is the only reason that is acceptable.
	_, err := w.Exec("ALTER TABLE " + table + " ADD COLUMN " + col + " " + decl)
	return err
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

// throttleTx deliberately ignores `hidden` and `frozen`, unlike almost everything else here.
//
// Every other read excludes them because they mean "nobody can see this, so it should not drive
// a decision". The throttle is not that kind of decision: it asks what this address SENT, and
// hiding a message afterwards does not un-send it. Counting only visible messages would let an
// author whose messages were hidden — or whose court was withdrawn — burst freely, and would
// let a kick that was later revoked hand back a fresh quota.
//
// Stated because an audit of this file's guard clauses flags these five queries as the ones
// missing the filters, and the answer is that they are missing them on purpose.
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
	if sk := Skeleton(in.Body); len(sk) >= DupMinSkeleton {
		// OTHER courts, excluding this one: two already plus this one is the
		// third, which is where the rule was described as biting. Repeating
		// yourself in a court you have already used is the per-address
		// throttle's business, not this rule's.
		var others int
		if err := tx.QueryRowContext(ctx,
			`SELECT count(DISTINCT court) FROM messages
			 WHERE ip_hash=? AND skeleton=? AND court <> ? AND created_at > ?`,
			in.IPHash, sk, in.Court, now.Add(-DupWindow).Unix()).Scan(&others); err != nil {
			return err
		}
		if others >= DupCourts {
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
	  WHERE `+sqlInForce+`
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
	  ORDER BY (expires_at IS NULL) DESC, expires_at DESC LIMIT 1`,
		now.Unix(), ipHash, netHash).Scan(&id, &kind, &reason, &createdAt, &expiresAt)
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
//
// A FROZEN COURT IS NOT READ EITHER, and it took measuring to notice that it was. Freeze
// gated only Post, so a purged court refused new messages with "this court is no longer
// served" while serving its entire transcript to anybody who asked — and
// `kourtchatctl freeze` printed "its history is no longer served", which was simply untrue.
// A compliance control that stops accepting and keeps publishing has not stopped serving.
//
// The rows are still in the table: freeze stops serving, it does not erase. An operator who
// needs the content gone runs the pruner afterwards, and §9 says so — the two are separate
// acts on purpose, because "stop showing this" and "destroy the evidence" are different
// decisions and one of them is irreversible.
func (s *Store) Recent(ctx context.Context, chain, court string, since int64, limit int) ([]Message, error) {
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	if since < 0 {
		since = 0
	}
	frozen, err := s.IsFrozen(ctx, chain, court)
	if err != nil {
		return nil, err
	}
	if frozen {
		return nil, ErrPurged
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
// hidden is scoped to the SAME MESSAGE plus that address's last few minutes, rather than
// everything it ever posted: on a shared address a wider sweep would retroactively delete
// strangers' messages, and every routine timeout would carry that collateral.
//
// "THE SAME MESSAGE" was in this comment before it was in the query. The UPDATE had only the
// ten-minute window, so the cited message was hidden when it happened to fall inside it and
// not otherwise. Measured:
//
//	scanner 1 minute behind    author kicked, the scam HIDDEN
//	scanner 11 minutes behind  author kicked, the scam STILL VISIBLE
//	scanner 2 hours behind     author kicked, the scam STILL VISIBLE
//
// A backlog is not an edge case here — Claim scans newest-first precisely because "after an
// outage the currently-harmful messages are scanned last" — so the fix failed in exactly the
// condition that motivated it. §7 exists because "a ban stops new posts; the scam link stays
// pinned in the court forever", and that is what a slow scanner was still producing.
//
// The id clause is scoped to the same author as well, so a mis-set evidence_id can never hide
// a stranger's message. That is not a live risk today — the scanner cites the message it just
// judged, and `kick -msg` derives the hash FROM the message — but the whole reason the window
// is narrow is collateral, and a second way in deserves the same guard.
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
	if _, err := tx.ExecContext(ctx, `UPDATE messages SET hidden=1
	   WHERE (ip_hash = ? AND created_at > ?)
	      OR (id = ? AND ip_hash = ?)`,
		c.IPHash, now.Add(-HideWindow).Unix(), evID, c.IPHash); err != nil {
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
	// RECOMPUTED, not un-hidden. §7 says `hidden` is "filtered at read, recomputed on
	// revocation" and the code did a blanket `hidden=0` for the whole address, which is a
	// different thing whenever an address has more than one consequence.
	//
	// Measured: an address with a manual kick and a scam kick, both live. Reversing the manual
	// one — the operator doing exactly the right thing about a wrong call — put "send me your
	// seed phrase now" back in the room, because it belonged to the same address. The author
	// stayed kicked by the scam consequence, and their scam was readable again. That is §7's
	// own failure mode ("a ban stops new posts; the scam link stays pinned") reached from the
	// one direction nobody would look: an operator granting an appeal.
	//
	// So a message is hidden if ANY unrevoked consequence would hide it — the one that cites
	// it, or one whose recent-window covers it.
	//
	// THE WINDOW IS BOUNDED AT BOTH ENDS, and it took a live run to see why. Consequence writes
	// `created_at > now - HideWindow` with no upper bound, which is exact at the instant it
	// runs because nothing can be newer than now. A recompute evaluated later has no such
	// luxury: without `<= i.created_at` an old unrevoked consequence hides everything posted
	// after it, forever. Measured — an expired kick from the previous day kept a fresh message
	// hidden after the operator reversed the only consequence that concerned it. Revocation is the only thing that says a
	// decision was wrong; expiry says it is served, which is why an expired kick keeps its
	// evidence out of sight and only `unban` brings it back.
	if _, err := tx.ExecContext(ctx, `
	  UPDATE messages SET hidden = CASE WHEN hidden = 2 THEN 2 WHEN EXISTS (
	      SELECT 1 FROM infractions i
	       WHERE i.revoked_at IS NULL
	         AND i.ip_hash = messages.ip_hash
	         AND ((messages.created_at > i.created_at - ?
	               AND messages.created_at <= i.created_at)
	              OR i.evidence_id = messages.id)
	    ) THEN 1 ELSE 0 END
	   WHERE ip_hash = ?`, // scoped as an optimisation, not for correctness: the CASE is a
		//                     function of each row's own consequences, so widening it computes
		//                     the same answer everywhere. Verified by mutation.
		int64(HideWindow.Seconds()), ipHash); err != nil {
		return err
	}
	return tx.Commit()
}

// Freeze marks a court unservable, for a purge on chain. Latched in a store we
// own rather than re-derived from the chain on every request, because the chain
// read cannot distinguish "purged" from "node unreachable".
// HideMessage takes one message out of view and punishes nobody, durably.
//
// Marked 2 rather than 1 so Revoke's recompute leaves it alone. Reversing an unrelated
// consequence used to republish it: the recompute derives `hidden` from the consequences that
// still stand, and a hide that never had a consequence behind it looked like one that should be
// undone. A disclosed secret is not a punishment, so no appeal about anything else is a reason
// to put it back.
//
// KNOWN LIMITATION, stated rather than left to be discovered: nothing un-hides a 2. If the
// deterministic detector were ever wrong — a noun list of exactly phrase length whose checksum
// passes by luck, one chance in sixteen at twelve words — the message stays out of sight and
// `dismiss` will not bring it back, because dismiss records that a person looked and does not
// touch visibility. Restoring one is a deliberate act nobody has needed yet.
//
// The two halves of moderation are separable and this is the seam. §7's `hidden` normally
// arrives with a consequence, but a message can need to be out of sight while its author needs
// nothing done to them at all — a recovery phrase quoted by somebody warning the room is the
// case that forced this. Scoped to a single id, so it cannot become a sweep.
func (s *Store) HideMessage(ctx context.Context, id int64) error {
	res, err := s.w.ExecContext(ctx,
		`UPDATE messages SET hidden=2 WHERE id=? AND hidden=0`, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("no visible message %d", id)
	}
	return nil
}

// IsFrozen reports whether a court has been withdrawn from service.
//
// Read through the read handle so it costs nothing on the serving path, and consulted by
// BOTH verbs — Post has always checked it inside its transaction; Recent had not.
func (s *Store) IsFrozen(ctx context.Context, chain, court string) (bool, error) {
	var n int
	if err := s.r.QueryRowContext(ctx,
		`SELECT count(*) FROM frozen WHERE chain=? AND court=?`, chain, court).Scan(&n); err != nil {
		return false, err
	}
	return n > 0, nil
}

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

	// Unscannable counts messages that gave up: five failed attempts, terminal, and
	// never classified.
	//
	// It exists because without it an outage reads as perfect health. §1 predicts the
	// outage — "a 7B model against an 8GB budget will OOM" — and the isolation works,
	// chat keeps serving. But RecordFailure marks an exhausted row ScanDone, Backlog
	// counts only ScanNew and ScanFailed, PendingReview needs a non-clean verdict, and
	// Run heartbeats every cycle whether it classified anything or not. Each of those is
	// right on its own and together they say "all well" while nothing is being read.
	//
	// Measured, in internal/scan's outage fixture: after ollama went away, backlog 0,
	// heartbeat fresh, enforcing true, review queue empty, and a seed-phrase lure sitting
	// in the court unclassified.
	Unscannable int `json:"unscannable"`
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
	// hidden=0 to match Claim EXACTLY. Claim skips hidden rows — punished content must
	// stop driving verdicts — so counting them as backlog reports work that will never be
	// done. Measured before the fix: four messages, a consequence hiding all of them, two
	// still unscanned; Backlog said 2 and Claim offered 0, and the difference never
	// drained. An operator is told to watch this number, and after any consequence at all
	// it stopped returning to zero.
	//
	// Distinct from Unscannable below, which is the opposite failure: rows that WERE tried
	// and gave up. A hidden row was never tried and does not need to be. If its consequence
	// is later revoked, Revoke clears hidden and it becomes claimable and counted again,
	// which is the correct direction.
	if err := s.r.QueryRowContext(ctx,
		`SELECT count(*) FROM messages WHERE scan_state IN (?,?) AND hidden=0
		   AND `+sqlNotFrozen, ScanNew, ScanFailed).Scan(&h.Backlog); err != nil {
		return h, err
	}
	// Terminal AND never classified. scan_state alone is not enough: ScanDone is also
	// where every successfully scanned message ends up, so the empty verdict is what
	// distinguishes "read and found clean" from "never read at all".
	// Same exclusions as the backlog above, for the same reason: this line tells an operator
	// that something needs attention, so it must not count rows where no attention is
	// possible. A hidden message was punished; a withdrawn court's messages are unreadable.
	// Measured before the fix: freezing a court left its unscannable rows warning forever,
	// with no available action.
	if err := s.r.QueryRowContext(ctx,
		`SELECT count(*) FROM messages WHERE scan_state=? AND verdict='' AND hidden=0
		   AND `+sqlNotFrozen, ScanDone).Scan(&h.Unscannable); err != nil {
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
	    AND `+sqlNotFrozen+`
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
	// UNREVOKED consequences only. Escalate already filters these out, with the reason
	// written next to it — "an upheld appeal would unmute somebody and leave them one rung
	// higher, reversible-looking rather than reversible" — and the same reasoning applies
	// here: a reversed consequence is deemed not to have happened, so it must not keep
	// cutting off the author's context either.
	//
	// Measured before the fix: after an upheld appeal, the message posted next arrived at
	// the scanner with ZERO lines of prior context, still truncated by the consequence that
	// had just been reversed. Less context is not the safe direction — the window exists so
	// a scam split across individually-innocent lines is visible.
	//
	// The `revoked_at` half is what showed a measurable difference. The consequence bound
	// ITSELF turns out to be largely subsumed by `hidden = 0` below: Consequence hides the
	// author's recent window, so the messages the bound would exclude are usually already
	// excluded for being hidden, and deleting the bound entirely changed no test. It is kept
	// because the two cover different ground at the edges — hiding reaches only the recent
	// slice, while an author with a longer history has unhidden messages before it — but that
	// is reasoning, not a measurement, and it is recorded as such rather than dressed up.
	var since int64
	if err := tx.QueryRowContext(ctx,
		`SELECT coalesce(max(created_at),0) FROM infractions
		  WHERE ip_hash=? AND revoked_at IS NULL`,
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
//
// Returns whether this was the LAST attempt, because giving up is the interesting event
// and it used to look identical to the four failures before it. That moment is when
// moderation silently stops for a message: the row goes terminal, leaves the backlog,
// never gets a verdict, and so never reaches the review queue either. Health.Unscannable
// counts them after the fact; the caller logs the moment.
func (s *Store) RecordFailure(ctx context.Context, id int64) (gaveUp bool, err error) {
	const maxAttempts = 5
	var attempts int
	if err := s.r.QueryRowContext(ctx,
		`SELECT attempts FROM messages WHERE id=?`, id).Scan(&attempts); err != nil {
		return false, err
	}
	attempts++
	state := ScanFailed
	if attempts >= maxAttempts {
		state = ScanDone // terminal: unscannable, and never punished
		gaveUp = true
	}
	backoff := time.Duration(1<<uint(attempts)) * time.Second
	if _, err := s.w.ExecContext(ctx,
		`UPDATE messages SET scan_state=?, attempts=?, next_try=?, claimed_at=0 WHERE id=?`,
		state, attempts, s.Now().Add(backoff).Unix(), id); err != nil {
		return false, err
	}
	return gaveUp, nil
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

// sqlInForce is what "in force" MEANS for a consequence: not reversed, and not expired.
//
// Takes one placeholder, the current time. Written once because it was the fourth predicate in
// this file to exist in several copies, and the copies had already disagreed: statusTx and the
// pruner checked both halves, while CountInfractions and ListInfractions checked only
// `revoked_at IS NULL` — so both answered "what is in force" with "what was never reversed".
//
// Measured before the fix, with one hour-long kick, one permanent ban and one revoked kick:
//
//	fresh              status said 2 in force, enforcer blocked 2   agreed
//	two hours later    status said 2 in force, enforcer blocked 1   diverged
//	two months later   status said 2 in force, enforcer blocked 1   never recovered
//
// An operator-facing count that only ever grows, in a design whose whole claim about automated
// moderation is that its consequences expire.
const sqlInForce = `revoked_at IS NULL AND (expires_at IS NULL OR expires_at > ?)`

// sqlNotFrozen excludes messages in a court that has been withdrawn from service.
//
// Written once for the same reason as sqlAwaitingReview below: the last two bugs in this file
// were both a predicate honoured on some paths and not others, and the second was seven copies
// of one idea that had already drifted.
//
// WHY THE SCANNER SKIPS A FROZEN COURT. Claim already skips `hidden` because punished content
// must stop driving verdicts. Withdrawn content is in the same position and the reasoning
// carries over unchanged: nobody can read it, so there is no harm left to prevent, and
// spending an inference on it — or asking a person to judge it — is work with no beneficiary.
// A court that is still being scanned and still filling a moderator's queue has not been
// withdrawn in any sense an operator would recognise; it has only been hidden from readers.
//
// The counter-argument, which is real: a scam is a scam, and its author should be stopped
// elsewhere too. That is what the live courts are for — they are where the author is still
// able to do harm, and where the scanner is still looking. Freezing is a deliberate act taken
// after the fact, so a court's history has almost always been scanned already.
const sqlNotFrozen = `NOT EXISTS (SELECT 1 FROM frozen f
	                    WHERE f.chain = messages.chain AND f.court = messages.court)`

// sqlAwaitingReview is THE definition of §7's deferred queue, and it is one string because
// it was seven.
//
// The same idea was written out in four different indentations across Prune, PruneDryRun,
// PendingReview, ReviewGroups and MarkReviewedFrom, and they had already drifted: three of
// the seven copies were missing `hidden = 0`, so the queue asked a human to judge messages
// that had already been hidden and whose author was already kicked. That is the same failure
// as freeze being consulted in Post and not in Recent — a predicate that exists in more than
// one place eventually disagrees with itself.
//
// The three clauses, and why each is part of "awaiting review":
//
//	hidden = 0        a hidden message HAS been acted on. Consequence hides the author's
//	                  whole recent window, not only the message it names, so the neighbours
//	                  are hidden-but-uncited and would otherwise look unactioned.
//	verdict flagged   clean and unknown are not accusations; '' was never scanned.
//	no citing row     an infraction naming this message means a consequence already followed.
//
// `reviewed_at = 0` is deliberately NOT here: whether to include already-dismissed rows is
// the caller's question, and `review -all` exists to answer it either way.
//
// The subquery correlates on `messages.id`, so every use must have `messages` as its outer
// table.
const sqlAwaitingReview = `hidden = 0
	     AND verdict NOT IN ('', 'clean', 'unknown')
	     AND NOT EXISTS (SELECT 1 FROM infractions WHERE evidence_id = messages.id)
	     AND ` + sqlNotFrozen

// PruneResult reports what a prune did AND what it refused to do.
//
// The refusals are the interesting half. A pruner that silently declines to delete looks
// broken from the outside — "I asked it to prune and the file did not shrink" — and the
// reasons it declines are exactly the ones an operator needs to see, because each of them
// means a message is still doing a job.
type PruneResult struct {
	Deleted       int   `json:"deleted"`
	KeptUnscanned int   `json:"kept_unscanned"`
	KeptQueued    int   `json:"kept_queued"`
	KeptCited     int   `json:"kept_cited"`
	Oldest        int64 `json:"oldest_remaining"`
	Remaining     int   `json:"remaining"`
}

// Prune deletes messages older than a cutoff, and refuses three kinds outright.
//
// §7 cut the pruner from v1 — "worse half-done than absent" — and it was right to: the
// groundwork was not there. `evidence` now copies a body into its infraction at punish
// time precisely so deleting the message cannot destroy what an appeal reads, and the
// review queue has since added a constraint that did not exist when this was deferred.
//
// WHAT IT WILL NOT DELETE, whatever the cutoff says:
//
//   - UNSCANNED messages. The scanner has not looked yet, and deleting one is not
//     retention policy, it is silently skipping moderation. This covers the outage case:
//     if the model has been unreachable for a month, a 30-day prune must not quietly
//     erase the backlog instead of classifying it.
//   - Messages AWAITING REVIEW — flagged, no consequence citing them, not dismissed.
//     §7's carve-out defers exactly these to a person; deleting them empties that
//     person's queue without anyone deciding anything.
//   - Messages cited by a consequence still IN FORCE. The appeal text survives in
//     `evidence`, so the record is safe either way, but `Revoke` restores a punished
//     author's hidden messages, and it cannot restore rows that are gone. Once the
//     consequence has expired or been reversed there is nothing left to restore.
//
// Bounded by `limit` in one statement, because a single unbounded DELETE over a year of
// history holds the write lock for as long as it takes, and §1's whole argument for one
// database file is that nothing holds that lock for long. Call it repeatedly.
func (s *Store) Prune(ctx context.Context, olderThan time.Duration, limit int) (PruneResult, error) {
	var out PruneResult
	if olderThan <= 0 {
		return out, errors.New("prune needs a positive age; refusing to delete everything")
	}
	if limit <= 0 || limit > 100_000 {
		limit = 5_000
	}
	cutoff := s.Now().Add(-olderThan).Unix()

	// The three refusals, counted before the delete so the numbers describe the same
	// population the delete considered.
	countOld := func(extra string, args ...any) (int, error) {
		var n int
		q := `SELECT count(*) FROM messages WHERE created_at < ? AND ` + extra
		err := s.r.QueryRowContext(ctx, q, append([]any{cutoff}, args...)...).Scan(&n)
		return n, err
	}
	var err error
	if out.KeptUnscanned, err = countOld(`scan_state <> ?`, ScanDone); err != nil {
		return out, err
	}
	if out.KeptQueued, err = countOld(
		`scan_state = ? AND reviewed_at = 0 AND `+sqlAwaitingReview, ScanDone); err != nil {
		return out, err
	}
	if out.KeptCited, err = countOld(
		`EXISTS (SELECT 1 FROM infractions i WHERE i.evidence_id = messages.id
		         AND i.revoked_at IS NULL
		         AND (i.expires_at IS NULL OR i.expires_at > ?))`, s.Now().Unix()); err != nil {
		return out, err
	}

	res, err := s.w.ExecContext(ctx, `
	  DELETE FROM messages WHERE id IN (
	    SELECT id FROM messages
	     WHERE created_at < ?
	       AND scan_state = ?
	       AND NOT (reviewed_at = 0 AND `+sqlAwaitingReview+`)
	       AND NOT EXISTS (SELECT 1 FROM infractions i
	                        WHERE i.evidence_id = messages.id
	                          AND i.revoked_at IS NULL
	                          AND (i.expires_at IS NULL OR i.expires_at > ?))
	     ORDER BY id LIMIT ?)`,
		cutoff, ScanDone, s.Now().Unix(), limit)
	if err != nil {
		return out, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return out, err
	}
	out.Deleted = int(n)

	// What is left, so an operator can tell "nothing to do" from "nothing happened".
	if err := s.r.QueryRowContext(ctx,
		`SELECT count(*), COALESCE(MIN(created_at), 0) FROM messages`).
		Scan(&out.Remaining, &out.Oldest); err != nil {
		return out, err
	}
	return out, nil
}

// PruneDryRun reports what a prune WOULD do, changing nothing.
func (s *Store) PruneDryRun(ctx context.Context, olderThan time.Duration, limit int) (PruneResult, error) {
	var out PruneResult
	if olderThan <= 0 {
		return out, errors.New("prune needs a positive age; refusing to delete everything")
	}
	if limit <= 0 || limit > 100_000 {
		limit = 5_000
	}
	cutoff := s.Now().Add(-olderThan).Unix()
	// Same predicate as Prune's DELETE, as a count. Duplicated deliberately rather than
	// shared through a string constant: a dry run whose query has drifted from the real
	// one is worse than no dry run, so the two are side by side where a reader can
	// compare them, and a test posts the same fixture through both.
	if err := s.r.QueryRowContext(ctx, `
	  SELECT count(*) FROM messages
	   WHERE created_at < ?
	     AND scan_state = ?
	     AND NOT (reviewed_at = 0 AND `+sqlAwaitingReview+`)
	     AND NOT EXISTS (SELECT 1 FROM infractions i
	                      WHERE i.evidence_id = messages.id
	                        AND i.revoked_at IS NULL
	                        AND (i.expires_at IS NULL OR i.expires_at > ?))
	   LIMIT ?`, cutoff, ScanDone, s.Now().Unix(), limit).Scan(&out.Deleted); err != nil {
		return out, err
	}
	var err error
	if out.KeptUnscanned, err = func() (int, error) {
		var n int
		e := s.r.QueryRowContext(ctx,
			`SELECT count(*) FROM messages WHERE created_at < ? AND scan_state <> ?`,
			cutoff, ScanDone).Scan(&n)
		return n, e
	}(); err != nil {
		return out, err
	}
	if err := s.r.QueryRowContext(ctx, `
	  SELECT count(*) FROM messages
	   WHERE created_at < ? AND scan_state = ? AND reviewed_at = 0
	     AND `+sqlAwaitingReview+``,
		cutoff, ScanDone).Scan(&out.KeptQueued); err != nil {
		return out, err
	}
	if err := s.r.QueryRowContext(ctx, `
	  SELECT count(*) FROM messages
	   WHERE created_at < ?
	     AND EXISTS (SELECT 1 FROM infractions i WHERE i.evidence_id = messages.id
	                  AND i.revoked_at IS NULL
	                  AND (i.expires_at IS NULL OR i.expires_at > ?))`,
		cutoff, s.Now().Unix()).Scan(&out.KeptCited); err != nil {
		return out, err
	}
	if err := s.r.QueryRowContext(ctx,
		`SELECT count(*), COALESCE(MIN(created_at), 0) FROM messages`).
		Scan(&out.Remaining, &out.Oldest); err != nil {
		return out, err
	}
	return out, nil
}

// Review is one message the scanner flagged and did not punish.
type Review struct {
	ID        int64  `json:"id"`
	Chain     string `json:"chain"`
	Court     string `json:"court"`
	Moniker   string `json:"moniker"`
	Body      string `json:"body"`
	Verdict   string `json:"verdict"`
	IPHash    string `json:"ip_hash"`
	NetHash   string `json:"net_hash"`
	Hidden    bool   `json:"hidden"`
	CreatedAt int64  `json:"created_at"`
}

// PendingReview returns the messages a person is supposed to look at.
//
// THE HOLE THIS FILLS. §7's reporting carve-out is a deliberate decision to record a
// verdict and take no action, because gemma3:4b cannot tell reporting a scam from
// sending one — measured, not assumed — and punishing the difference means kicking
// somebody for warning the room. The scanner therefore logs "no action taken" and moves
// on, which left the most interesting messages in the system visible only as a line on a
// daemon's stdout: not queryable, not durable, and gone with the next log rotation.
//
// Verified before this existed: a message reading "careful everyone, someone just DMed
// me asking for my seed phrase" was stored with verdict='scam' and no consequence, and
// `kourtchatctl list` did not mention it at all. A design that defers its hardest cases
// to a human owes the human a way to see them.
//
// The query is "flagged, and nothing came of it": a non-clean verdict, no infraction
// citing this message as evidence, and not already dismissed. Messages whose consequence
// was later REVOKED stay out — that decision has been made, and `list -all` is where
// reversals are read.
func (s *Store) PendingReview(ctx context.Context, includeDone bool, limit int) ([]Review, error) {
	if limit <= 0 || limit > 500 {
		limit = 50
	}
	// hidden=0: a hidden message HAS been acted on, even when no infraction cites it by id.
	// Consequence hides the author's whole recent window, not just the message it names, so
	// the neighbours end up hidden-but-uncited — and the queue was surfacing those, asking a
	// human to judge something already removed from the room whose author was already
	// kicked. §7's carve-out is about messages deliberately left ALONE; this queue must hold
	// only those.
	q := `
	  SELECT id, chain, court, moniker, body, verdict, ip_hash, net_hash, hidden, created_at
	    FROM messages
	   WHERE ` + sqlAwaitingReview
	if !includeDone {
		q += ` AND reviewed_at = 0`
	}
	q += ` ORDER BY id DESC LIMIT ?`
	rows, err := s.r.QueryContext(ctx, q, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Review{}
	for rows.Next() {
		var r Review
		var hidden int
		if err := rows.Scan(&r.ID, &r.Chain, &r.Court, &r.Moniker, &r.Body, &r.Verdict,
			&r.IPHash, &r.NetHash, &hidden, &r.CreatedAt); err != nil {
			return nil, err
		}
		r.Hidden = hidden != 0
		out = append(out, r)
	}
	return out, rows.Err()
}

// ReviewGroup is one AUTHOR's worth of deferred messages.
type ReviewGroup struct {
	IPHash   string `json:"ip_hash"`
	NetHash  string `json:"net_hash"`
	Monikers int    `json:"monikers"` // how many names one address used
	Moniker  string `json:"moniker"`  // the most recent
	Count    int    `json:"count"`
	Courts   int    `json:"courts"`
	Court    string `json:"court"`
	Chain    string `json:"chain"`
	FirstAt  int64  `json:"first_at"`
	LastAt   int64  `json:"last_at"`
	LatestID int64  `json:"latest_id"`
	Latest   string `json:"latest"`
}

// ReviewGroups is the review queue collapsed by author, and it exists because the
// flat one is a denial-of-attention surface.
//
// MEASURED, against the flat queue: one address, staying inside the existing throttle,
// got 70 reporting-shaped messages accepted in about twenty minutes of simulated time.
// The queue held 71 rows, all twenty of the first rows an operator reads were the
// attacker's, and the single genuine report sat at position 71 of 71. Near-duplicates
// evade the skeleton dedup — "incident 1", "incident 2" — so nothing upstream stopped it.
//
// That defeats §7's carve-out at its weakest point. The carve-out's whole answer to "the
// model cannot tell reporting from sending" is that a PERSON will look, and burying the
// person under seventy decoys is cheaper than evading the classifier.
//
// The fix is deliberately not a new punishment. Flooding is indistinguishable from
// diligent reporting to the same classifier that could not tell reporting from sending in
// the first place, so acting automatically on the pattern would just move the false
// positive. Instead the VIEW becomes flood-resistant: seventy messages from one address
// are one row saying seventy, which is also the clearest possible signal to the operator
// that it is not a reporter — nobody files seventy incidents in twenty minutes.
func (s *Store) ReviewGroups(ctx context.Context, includeDone bool, limit int) ([]ReviewGroup, error) {
	if limit <= 0 || limit > 500 {
		limit = 50
	}
	where := sqlAwaitingReview
	if !includeDone {
		where += ` AND reviewed_at = 0`
	}
	// The latest message per author comes from a correlated subquery rather than a
	// window function: the point of the row is to be READ, so it has to be the one the
	// operator would judge, not whichever row the aggregate happened to keep.
	q := `
	  SELECT ip_hash,
	         MAX(net_hash),
	         COUNT(DISTINCT moniker),
	         COUNT(*),
	         COUNT(DISTINCT court),
	         MIN(created_at),
	         MAX(created_at),
	         MAX(id)
	    FROM messages
	   WHERE ` + where + `
	GROUP BY ip_hash
	ORDER BY MAX(id) DESC
	   LIMIT ?`
	rows, err := s.r.QueryContext(ctx, q, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []ReviewGroup{}
	for rows.Next() {
		var g ReviewGroup
		if err := rows.Scan(&g.IPHash, &g.NetHash, &g.Monikers, &g.Count, &g.Courts,
			&g.FirstAt, &g.LastAt, &g.LatestID); err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i := range out {
		if err := s.r.QueryRowContext(ctx,
			`SELECT moniker, body, court, chain FROM messages WHERE id=?`, out[i].LatestID).
			Scan(&out[i].Moniker, &out[i].Latest, &out[i].Court, &out[i].Chain); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// MarkReviewedFrom dismisses every queued message from one author at once.
//
// Without this, grouping the view would have moved the problem rather than solved it: an
// operator who can SEE that seventy messages are one flood in one row still needs seventy
// commands to clear it, and the flood wins at the dismissal step instead of the reading
// step. Scoped to the queue — already-actioned and already-dismissed rows are untouched,
// so this cannot quietly bulk-clear history.
func (s *Store) MarkReviewedFrom(ctx context.Context, ipHash string) (int64, error) {
	// Redundant today and kept anyway: with the predicate below intact, an empty hash
	// matches nothing and the zero-rows check already refuses. Deleting this guard was
	// tried and no test noticed, which is the honest reason it is documented rather than
	// asserted. It is here for the edit that widens the WHERE clause one day, where an
	// empty author would otherwise mean every author.
	if ipHash == "" {
		return 0, errors.New("no author given")
	}
	res, err := s.w.ExecContext(ctx, `
	  UPDATE messages SET reviewed_at=?
	   WHERE ip_hash=? AND reviewed_at=0
	     AND `+sqlAwaitingReview+``,
		s.Now().Unix(), ipHash)
	if err != nil {
		return 0, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, err
	}
	if n == 0 {
		return 0, fmt.Errorf("nothing queued from %s", ipHash)
	}
	return n, nil
}

// MarkReviewed records that a person looked and chose to do nothing.
//
// Separate from doing nothing at all, which is what an unreviewed row already means. The
// distinction is the only thing that lets the queue empty: without it every deferred
// message is permanently new, and a queue that never shrinks stops being read.
func (s *Store) MarkReviewed(ctx context.Context, id int64) error {
	res, err := s.w.ExecContext(ctx,
		`UPDATE messages SET reviewed_at=? WHERE id=? AND reviewed_at=0`, s.Now().Unix(), id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("no unreviewed message %d", id)
	}
	return nil
}

// MessageAuthor is who to hold responsible for a message, and what they said.
//
// So that an operator acting on something they just read in `review` does not have to
// copy a hash by hand out of one command into another. Transcription is where an
// operator bans the wrong person.
//
// The body comes back too, and that is not a convenience. A consequence carries a COPY
// of its evidence so an appeal survives the message being pruned, and the first version
// of the -msg path recorded neither the id nor the text: `why` on a manual kick showed
// the operator's own note and no trace of what was actually said. The automated half got
// this right and the human half did not, which is backwards — a person's decision is the
// one that can be permanent.
func (s *Store) MessageAuthor(ctx context.Context, id int64) (ipHash, netHash, body string, err error) {
	err = s.r.QueryRowContext(ctx,
		`SELECT ip_hash, net_hash, body FROM messages WHERE id=?`, id).
		Scan(&ipHash, &netHash, &body)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", "", fmt.Errorf("no message %d", id)
	}
	return ipHash, netHash, body, err
}

// ListInfractions reads consequences, newest first. An empty ipHash lists all of them.
//
// `all` false means IN FORCE: neither reversed nor expired. It previously excluded only the
// reversed, so the default listing — under a heading promising "consequences in force" —
// included hour-long kicks from weeks earlier, each row dutifully labelled "expired". `all`
// is where history lives, and the CLI's -all flag is exactly that question.
func (s *Store) ListInfractions(ctx context.Context, ipHash string, all bool, limit int) ([]InfractionRow, error) {
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
	if !all {
		q += ` AND ` + sqlInForce
		args = append(args, s.Now().Unix())
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
//
// `all` false means IN FORCE — see sqlInForce — not merely "not reversed", which is what it
// used to mean while `kourtchatctl status` printed the number as "in force".
func (s *Store) CountInfractions(ctx context.Context, all bool) (int, error) {
	q := `SELECT count(*) FROM infractions`
	var args []any
	if !all {
		q += ` WHERE ` + sqlInForce
		args = append(args, s.Now().Unix())
	}
	var n int
	err := s.r.QueryRowContext(ctx, q, args...).Scan(&n)
	return n, err
}
