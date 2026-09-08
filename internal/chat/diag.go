package chat

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// WHAT A DIAGNOSTICS PAGE MAY SAY, and the list is short on purpose.
//
// This endpoint is PUBLIC. Everything below is either a count of things or a
// yes/no, and none of it names a person, an address, a hash, a file, a court's
// moderators or the contents of any message. The temptation with a page like
// this is to grow it one useful field at a time until it is an admin console
// with no login, so the rule is written down here rather than left to taste:
//
//	ALLOWED      how many, how often, how much, and whether a thing is on
//	NOT ALLOWED  who, from where, what was said, and any secret or its shape
//
// In particular the bot's API key is never returned in any form — not the key,
// not a prefix, not its length. BotKeySet is a bool, which is all a form needs
// to know whether to offer itself.
//
// The full Health struct is deliberately NOT embedded. It carries scanner
// backlogs, unscannable counts and enforcement internals, which are operator
// facts; publicHealth already exists for exactly this distinction and this
// follows it.
type diagPayload struct {
	OK bool `json:"ok"`

	// Holding is long-poll requests in flight right now — the closest honest
	// answer to "how many people are looking at the site".
	//
	// WHY THIS IS THE METRIC. The panel long-polls: a reader with the chat open
	// holds a GET for up to MaxWait and immediately re-opens it, so one waiter is
	// one live reader, give or take a request boundary. It is not a count of
	// PEOPLE — several tabs are several waiters, and a reader on the map with no
	// chat panel open is invisible here — and it is not a session count, because
	// nothing here has sessions. Reported as what it is.
	Holding     int64 `json:"holding"`
	HoldingPeak int64 `json:"holding_peak"`

	// Rooms with a message in the last hour, and how many messages that was.
	// A count of rooms and a count of rows; neither says who or what.
	CourtsActive     int `json:"courts_active"`
	MessagesLastHour int `json:"messages_last_hour"`

	BotKeySet bool     `json:"bot_key_set"`
	Bot       botStats `json:"bot"`
}

// botStats is what the page shows about the bot: how often it has answered and
// what that cost. Money is reported in micro-dollars as an integer, because a
// float that has been added to a thousand times is a number nobody can check.
type botStats struct {
	Enabled bool   `json:"enabled"`
	Model   string `json:"model,omitempty"`

	// Replies is how many times it SPOKE. Passes is how many times it looked at
	// something, paid for the looking, and had nothing to add.
	//
	// SPLIT BECAUSE THE FIRST VERSION COUNTED THEM TOGETHER, and the page said
	// "3 replies" for a bot that had never once posted — MEASURED: three human
	// messages in the room, three PASSes, three replies reported. bot_replies
	// holds a row per API CALL, because a call that said nothing was still
	// charged and still has to appear in the cost; so "how often has it
	// answered" has to ask for the rows that are attached to a message, which is
	// the rows with a positive msg_id.
	//
	// AND PASSES ARE WORTH SHOWING rather than hiding: together with Replies they
	// say where the spend went, and a bot that is passing on everything is a bot
	// whose filter or prompt is wrong. A count of calls names nobody.
	Replies int64 `json:"replies"`
	Passes  int64 `json:"passes"`

	// LastAt is when it last SPOKE, for the same reason.
	LastAt     int64 `json:"last_at,omitempty"`
	InTokens   int64 `json:"in_tokens"`
	OutTokens  int64 `json:"out_tokens"`
	CostMicros int64 `json:"cost_micros"`

	// Failures is calls the model refused or never answered, and it is here
	// because without it this page could not do the one job it has.
	//
	// MEASURED with a deliberately wrong key: after five consecutive rejected
	// calls the payload read enabled=true, replies=0, passes=0, in_tokens=0,
	// cost_micros=0 — which is byte-for-byte what a perfectly healthy helper that
	// nobody has asked anything looks like. An operator had no way to tell the
	// two apart, on the page whose whole purpose is telling them apart.
	//
	// FailKind is a fixed word from this file's own vocabulary — "refused" or
	// "unreachable" — and NEVER the vendor's message. A 401 body can echo request
	// detail, and this payload is public; a coarse class is what an operator needs
	// anyway, because the two point at different things to go and look at.
	Failures   int64  `json:"failures"`
	LastFailAt int64  `json:"last_fail_at,omitempty"`
	FailKind   string `json:"fail_kind,omitempty"`

	// Undelivered is replies that were written and BILLED and that the room then
	// refused — a court frozen between the scan and the post, or the cross-court
	// duplicate rule. Counted apart from Passes because the two could not be
	// further apart in what they ask of an operator: one is the helper working
	// as designed, the other is the helper paying for words nobody read.
	Undelivered int64 `json:"undelivered"`
}

// The two words FailKind may take. A closed set, so nothing the vendor said can
// reach the page through this field.
const (
	BotFailRefused     = "refused"     // the vendor answered, and said no
	BotFailUnreachable = "unreachable" // no answer at all
)

// ------------------------------------------------------------------ storage --

// botSchema is applied beside the main schema. CREATE TABLE IF NOT EXISTS, so an
// existing database gains it on the next open and an old binary ignores it.
//
// ONE ROW PER REPLY THE BOT SENT, and it is not only an accounting table: it is
// also how the bot knows its own voice. The bot posts as "anon" like everybody
// else — asked for, so that it is a poster in the room rather than a badge — and
// therefore it cannot recognise itself by name. Recording the message id it
// wrote makes the question exact instead of a guess: a row here IS the bot's.
const botSchema = `
CREATE TABLE IF NOT EXISTS bot_replies (
  msg_id     INTEGER PRIMARY KEY,
  chain      TEXT    NOT NULL,
  court      TEXT    NOT NULL,
  model      TEXT    NOT NULL DEFAULT '',
  in_tokens  INTEGER NOT NULL DEFAULT 0,
  out_tokens INTEGER NOT NULL DEFAULT 0,
  -- micro-dollars, integer. See botStats.
  cost_micros INTEGER NOT NULL DEFAULT 0,
  -- WHAT BECAME OF THE CALL, and it is a column rather than a sign on msg_id
  -- because there turned out to be three outcomes and not two. See botKind*.
  kind       TEXT    NOT NULL DEFAULT 'spoke',
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS bot_replies_when ON bot_replies(created_at);
`

// WHAT BECAME OF A CALL THAT WAS BILLED. Three outcomes, not two.
//
// The first version had two and inferred them from the sign of msg_id, which was
// fine while a call either spoke or had nothing to add. It is not fine now:
// MEASURED, a reply the STORE refused — the cross-court duplicate rule, at the
// third court, with the same short greeting — was recorded as a pass. So the
// page reported "had nothing to add" for a reply that had been written, billed
// at 300 micro-dollars, and never delivered to the room. That is the one outcome
// an operator most needs to see, reported as the one that needs no attention.
const (
	botKindSpoke       = "spoke"
	botKindPass        = "pass"        // the model answered PASS: nothing to add
	botKindUndelivered = "undelivered" // written and billed, and the room refused it
)

// botKeyMetaK is the meta row the key lives in.
const botKeyMetaK = "bot_api_key"

// The failure tally lives in meta rather than in a table of its own.
//
// A ROW PER FAILURE WOULD BE UNBOUNDED. A key that has been revoked fails on
// every tick — four times a minute, near six thousand rows a day — for a fault
// that three numbers describe completely. Counters cannot say WHEN each failure
// happened, and nothing here needs that: what an operator does with this is
// compare "failing now" against "last answered", which two timestamps give.
const (
	botFailCountK = "bot_fail_count"
	botFailAtK    = "bot_fail_at"
	botFailKindK  = "bot_fail_kind"
)

// RecordBotFailure counts a call that produced nothing, and remembers which kind.
//
// NO TOKENS AND NO COST, deliberately: a refused call was not billed, and adding
// a zero-cost row to bot_replies would inflate the count of calls that were.
func (s *Store) RecordBotFailure(ctx context.Context, kind string) error {
	if kind != BotFailRefused && kind != BotFailUnreachable {
		// A caller inventing a word is a bug, and letting it through would put
		// arbitrary text on a public page. Recorded as the coarser of the two
		// rather than dropped, because the COUNT still matters.
		kind = BotFailUnreachable
	}
	if _, err := s.w.ExecContext(ctx,
		`INSERT INTO meta(k,v) VALUES(?, '1')
		   ON CONFLICT(k) DO UPDATE SET v = CAST(v AS INTEGER) + 1`,
		botFailCountK); err != nil {
		return err
	}
	for k, v := range map[string]string{
		botFailAtK:   strconv.FormatInt(s.Now().Unix(), 10),
		botFailKindK: kind,
	} {
		if _, err := s.w.ExecContext(ctx,
			`INSERT INTO meta(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v`,
			k, v); err != nil {
			return err
		}
	}
	return nil
}

// metaInt reads a counter, treating absence as zero.
func (s *Store) metaInt(ctx context.Context, k string) (int64, error) {
	var v sql.NullString
	err := s.r.QueryRowContext(ctx, `SELECT v FROM meta WHERE k=?`, k).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	n, _ := strconv.ParseInt(v.String, 10, 64)
	return n, nil
}

func (s *Store) metaStr(ctx context.Context, k string) (string, error) {
	var v sql.NullString
	err := s.r.QueryRowContext(ctx, `SELECT v FROM meta WHERE k=?`, k).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return v.String, err
}

// SetBotKeyOnce stores the bot's API key IF THERE IS NOT ONE ALREADY, and
// reports whether this call was the one that set it.
//
// WRITE-ONCE IS THE WHOLE DESIGN, and it is worth being plain about what it does
// and does not buy. It means a key cannot be silently swapped by a later caller,
// so a public form cannot be used to redirect spending onto somebody else's
// account after the fact. It does NOT mean the first caller is the operator:
// whoever reaches the form first claims the slot, so on a public deployment this
// is trust-on-first-use and the window is "until somebody uses it". An operator
// who wants that window closed should set the key immediately after deploying,
// or run with the bootstrap gate off — see Server.BotKeyBootstrap.
//
// INSERT OR IGNORE rather than a read-then-write, so two requests arriving
// together cannot both believe they were first.
func (s *Store) SetBotKeyOnce(key string) (bool, error) {
	res, err := s.w.Exec(`INSERT OR IGNORE INTO meta(k,v) VALUES(?, ?)`, botKeyMetaK, key)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

// BotKey reads the key, reporting whether there was one. Callers outside this
// package have no reason for it; it is exported for the command that starts the
// bot, which needs the value and nothing else does.
func (s *Store) BotKey() (string, bool, error) {
	var v string
	err := s.r.QueryRow(`SELECT v FROM meta WHERE k=?`, botKeyMetaK).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return v, v != "", nil
}

// BotKeySet answers the only question the public page may ask about the key.
func (s *Store) BotKeySet() (bool, error) {
	_, ok, err := s.BotKey()
	return ok, err
}

// RecordBotReply files what the bot said, what it cost, and — the part the bot
// itself depends on — that this message id is the bot's own.
func (s *Store) RecordBotReply(ctx context.Context, chain, court string, msgID int64,
	model string, inTok, outTok, costMicros int64) error {
	_, err := s.w.ExecContext(ctx,
		`INSERT OR IGNORE INTO bot_replies
		   (msg_id, chain, court, model, in_tokens, out_tokens, cost_micros, kind, created_at)
		 VALUES (?,?,?,?,?,?,?,?,?)`,
		msgID, chain, court, model, inTok, outTok, costMicros, botKindSpoke, s.Now().Unix())
	return err
}

// BotReplyIDs returns the ids the bot wrote in a court, so a scan can skip them.
//
// BY ID AND NOT BY NAME, which is the point. Every human in that transcript is
// "anon" too, so a name check would skip all of them; and a shape check ("does
// it look like something we would write") is a guess that gets worse as the bot
// gets better at sounding like a person. An id either is in this table or is not.
func (s *Store) BotReplyIDs(ctx context.Context, chain, court string, since int64) (map[int64]bool, error) {
	rows, err := s.r.QueryContext(ctx,
		`SELECT msg_id FROM bot_replies WHERE chain=? AND court=? AND msg_id>?`,
		chain, court, since)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64]bool{}
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out[id] = true
	}
	return out, rows.Err()
}

// BotStats totals the table for the diagnostics page.
func (s *Store) BotStats(ctx context.Context) (botStats, error) {
	var (
		st                         botStats
		last, in, out, cost        sql.NullInt64
		spoke, passed, undelivered sql.NullInt64
		model                      sql.NullString
	)
	/* THE TOKENS ARE EVERY ROW AND THE REPLIES ARE NOT, which is the whole point
	   of these three sums being asked for together. A call that answered PASS
	   spent input tokens and posted nothing, so it belongs in the cost and not in
	   the count of answers. msg_id is the discriminator: a real reply carries the
	   id of the message it wrote, and a call that wrote nothing carries a
	   negative placeholder — see recordBotSpend for why negative. */
	err := s.r.QueryRowContext(ctx,
		`SELECT sum(CASE WHEN kind=? THEN 1 ELSE 0 END),
		        sum(CASE WHEN kind=? THEN 1 ELSE 0 END),
		        sum(CASE WHEN kind=? THEN 1 ELSE 0 END),
		        max(CASE WHEN kind=? THEN created_at END),
		        sum(in_tokens), sum(out_tokens), sum(cost_micros)
		   FROM bot_replies`,
		botKindSpoke, botKindPass, botKindUndelivered, botKindSpoke).
		Scan(&spoke, &passed, &undelivered, &last, &in, &out, &cost)
	if err != nil {
		return st, err
	}
	// The model most recently used, so the page reports what is actually running
	// rather than what a flag said at some point.
	if err := s.r.QueryRowContext(ctx,
		`SELECT model FROM bot_replies WHERE kind='spoke'
		   ORDER BY created_at DESC, msg_id DESC LIMIT 1`).
		Scan(&model); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return st, err
	}
	st.Replies, st.Passes, st.LastAt = spoke.Int64, passed.Int64, last.Int64
	st.Undelivered = undelivered.Int64
	if st.Failures, err = s.metaInt(ctx, botFailCountK); err != nil {
		return st, err
	}
	if st.LastFailAt, err = s.metaInt(ctx, botFailAtK); err != nil {
		return st, err
	}
	if st.FailKind, err = s.metaStr(ctx, botFailKindK); err != nil {
		return st, err
	}
	st.InTokens, st.OutTokens, st.CostMicros = in.Int64, out.Int64, cost.Int64
	st.Model = model.String
	return st, nil
}

// BotLastReplyAt is the throttle's only question: when did we last speak, in any
// room. Read from the same table the accounting comes from, so a restart cannot
// hand the bot a fresh allowance — a counter held in memory would.
func (s *Store) BotLastReplyAt(ctx context.Context) (time.Time, error) {
	var at sql.NullInt64
	if err := s.r.QueryRowContext(ctx,
		`SELECT max(created_at) FROM bot_replies`).Scan(&at); err != nil {
		return time.Time{}, err
	}
	if !at.Valid {
		return time.Time{}, nil
	}
	return time.Unix(at.Int64, 0), nil
}

// ActiveRooms lists the rooms with a visible message since a cutoff — the bot's
// work list, and the page's "rooms active" count.
//
// hidden=0, unlike the throttle queries: a room whose only recent message was
// hidden has nothing for the bot to answer and nothing a reader can see.
func (s *Store) ActiveRooms(ctx context.Context, since int64) ([][2]string, error) {
	rows, err := s.r.QueryContext(ctx,
		`SELECT DISTINCT chain, court FROM messages
		  WHERE created_at >= ? AND hidden = 0
		  ORDER BY chain, court`, since)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out [][2]string
	for rows.Next() {
		var c, ct string
		if err := rows.Scan(&c, &ct); err != nil {
			return nil, err
		}
		out = append(out, [2]string{c, ct})
	}
	return out, rows.Err()
}

// CountSince counts visible messages since a cutoff, for the page.
func (s *Store) CountSince(ctx context.Context, since int64) (int, error) {
	var n int
	err := s.r.QueryRowContext(ctx,
		`SELECT count(*) FROM messages WHERE created_at >= ? AND hidden = 0`, since).Scan(&n)
	return n, err
}

// ------------------------------------------------------------------ gauge ----

// holdGauge counts long-poll requests in flight, and remembers the high water
// mark. Two atomics and no lock: this is instrumentation, and instrumentation
// that can block the thing it measures is worse than no instrumentation.
//
// The peak is monotonic for the life of the process and says so on the page. A
// decaying peak would need a window, a timer and a decision about what "recent"
// means, none of which a diagnostics line is worth.
type holdGauge struct {
	now  atomic.Int64
	peak atomic.Int64
}

func (g *holdGauge) enter() {
	n := g.now.Add(1)
	for {
		p := g.peak.Load()
		if n <= p || g.peak.CompareAndSwap(p, n) {
			return
		}
	}
}

func (g *holdGauge) leave() { g.now.Add(-1) }

// ---------------------------------------------------------------- handlers ---

// diag answers the public diagnostics payload. GET only.
func (s *Server) diag(w http.ResponseWriter, r *http.Request) {
	if s.cors(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		writeErr(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	ctx := r.Context()
	hourAgo := s.Store.Now().Add(-time.Hour).Unix()

	out := diagPayload{OK: true, Holding: s.hold.now.Load(), HoldingPeak: s.hold.peak.Load()}
	if h, err := s.Store.Health(ctx); err == nil {
		out.OK = h.OK
	}
	if rooms, err := s.Store.ActiveRooms(ctx, hourAgo); err == nil {
		out.CourtsActive = len(rooms)
	}
	if n, err := s.Store.CountSince(ctx, hourAgo); err == nil {
		out.MessagesLastHour = n
	}
	if set, err := s.Store.BotKeySet(); err == nil {
		out.BotKeySet = set
	}
	if st, err := s.Store.BotStats(ctx); err == nil {
		out.Bot = st
	}
	out.Bot.Enabled = s.BotEnabled
	// NO CACHING. A diagnostics number served from a proxy cache is a lie with a
	// timestamp, and this is the one page whose whole value is being current.
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}

// botkey accepts the key, once.
//
// WRITE-ONCE, WRITE-ONLY. A key already present is refused with 409 and the
// existing one is neither used for comparison nor echoed; there is no response
// in which any part of a key appears. A caller learns exactly one bit — whether
// it was accepted — which is the same bit the diagnostics payload publishes.
func (s *Server) botkey(w http.ResponseWriter, r *http.Request) {
	if s.cors(w, r) {
		return
	}
	if r.Method != http.MethodPost {
		writeErr(w, http.StatusMethodNotAllowed, "POST only")
		return
	}
	// THE SAME WRITE GUARD EVERY OTHER WRITE HERE USES. csrfOK refuses a browser
	// telling on itself cross-site; without it any page on the internet could
	// make a visitor's browser claim this slot.
	if err := csrfOK(r); err != nil {
		code := http.StatusForbidden
		if strings.Contains(err.Error(), "Content-Type") {
			code = http.StatusUnsupportedMediaType
		}
		writeErr(w, code, err.Error())
		return
	}
	if !s.BotKeyBootstrap {
		// THE GATE, OFF BY DEFAULT WOULD BREAK THE FEATURE AS ASKED FOR, so it is
		// ON by default and this branch is the operator's way to shut the window.
		// Said as "not accepting" rather than "disabled", because the honest state
		// is that this deployment does not take a key here at all.
		writeErr(w, http.StatusForbidden, "this deployment does not accept a key here")
		return
	}
	var in struct {
		Key string `json:"key"`
	}
	// A key is a few hundred bytes; 4 kB bounds memory before Decode reads any of
	// it, the same shape the post handler uses for its own cap.
	r.Body = http.MaxBytesReader(w, r.Body, 4<<10)
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "expected a JSON object with a key field")
		return
	}
	key := strings.TrimSpace(in.Key)
	// SHAPE ONLY, and no attempt to validate it against the vendor. A wrong key
	// fails at the first call and the page shows zero replies, which is a legible
	// failure; a key checked here would be a key sent somewhere by an unauthenticated
	// request, which is a way to make this endpoint into a proxy.
	if len(key) < 20 || len(key) > 200 || strings.ContainsAny(key, " \t\r\n") {
		writeErr(w, http.StatusBadRequest, "that does not look like a key")
		return
	}
	first, err := s.Store.SetBotKeyOnce(key)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not store the key")
		return
	}
	if !first {
		writeErr(w, http.StatusConflict, "a key is already set and cannot be replaced here")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, struct {
		OK bool `json:"ok"`
	}{true})
}
