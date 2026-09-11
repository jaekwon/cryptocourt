package chat

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/jaekwon/kourt/internal/geo"
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
// "FROM WHERE" NOW HAS ONE CARVE-OUT, WRITTEN DOWN RATHER THAN LEFT IMPLICIT.
// HereByCountry publishes counts per country for the connections being held. It
// is a location, so the rule above had to either forbid it or say what it
// permits, and a rule that is quietly contradicted by the struct beneath it is
// worse than either.
//
// What makes it permissible is not that it is coarse — it is that it is
// DETACHED. Nothing here joins a country to a moniker, a message, a hash or a
// room: the payload says three connections are in Germany and cannot say which
// three, or what any of them said. That is weaker than what the site already
// discloses of its own accord, because a posted message carries its country as a
// flag beside the name that wrote it — a location attached to an author, which
// this deliberately is not.
//
// AND A SINGLE HOLDER IS NOT NAMED. A country appears only once at least
// hereFloor connections are in it; the rest are summed into HereElsewhere, which
// is a count with no location on it at all. With seven readers online that folds
// most of the world into one row, and that is the intended trade: the row that
// would be interesting is exactly the row that would place somebody.
//
// Still NOT allowed, and none of these got easier: the network hashes (only how
// MANY there are), which rooms are being held (only how many), and any join
// between a location and a person, a name or a message.
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

	// HereNetworks is how many DISTINCT networks those connections come from,
	// and it is the number that makes Holding readable. Holding counts
	// connections, so one person with four tabs open is four; this counts the
	// networks behind them, so that same person is one. Neither is the truth on
	// its own, but "7 here from 3 networks" says something "7 here" cannot.
	//
	// A NETWORK IS THE /24 OR /48, not the address — the same unit NetPrefix
	// defines for a range consequence, deliberately reused rather than redefined
	// here. So it is coarser than it first sounds: two readers in one office, one
	// household or one small ISP block are ONE network, and this number is a
	// floor under "how many people", never a count of them.
	//
	// A COUNT OF KEYS, NEVER THE KEYS. The keys are the same hashed network
	// identifiers a consequence is recorded against, and they do not appear in
	// this payload in any form.
	HereNetworks int `json:"here_networks"`

	// HereRooms is how many distinct rooms are being held. Seven connections in
	// one court and seven spread across seven are different rooms to walk into,
	// and Holding cannot tell them apart. Which courts they are is not published.
	HereRooms int `json:"here_rooms"`

	// HereByCountry is the connections being held, per country, largest first —
	// the carve-out described at the top of this file. Countries below the floor
	// are not listed; see HereElsewhere.
	HereByCountry []countryCount `json:"here_by_country"`

	// HereElsewhere is every held connection not accounted for in the list
	// above: the ones in countries under the floor, and the ones with no country
	// at all. Two reasons, deliberately summed into one number — separating them
	// would publish "one connection from a country we know and will not name",
	// which is most of the way back to naming it.
	HereElsewhere int `json:"here_elsewhere"`

	// GeoKnown says whether a country file is loaded at all. Without it every
	// connection lands in HereElsewhere, which is indistinguishable from a room
	// full of readers in countries below the floor — the same "healthy and idle
	// looks like broken" trap the bot's Failures field exists for.
	GeoKnown bool `json:"geo_known"`

	// Rooms with a message in the last hour, and how many messages that was.
	// A count of rooms and a count of rows; neither says who or what.
	CourtsActive     int `json:"courts_active"`
	MessagesLastHour int `json:"messages_last_hour"`

	BotKeySet bool     `json:"bot_key_set"`
	Bot       botStats `json:"bot"`
}

// countryCount is one row of the location tally: a two-letter code and how many
// held connections are in it. No hash, no room, no name.
type countryCount struct {
	CC string `json:"cc"`
	N  int    `json:"n"`
}

// hereFloor is how many connections a country needs before it is named.
//
// ONE, WHICH IS THE OWNER'S CALL AND A REAL TRADE. It was two, and the argument
// for two is still true: at one, a country with a single reader in it is a
// public statement that one particular person is in that country, and on a
// quiet site that is often the only reader there. At two the smallest thing the
// page could say was "two connections are in Norway", which places neither.
//
// It was changed on the instruction "i want everyone to see the same thing",
// after the alternative was put and declined — the reader's own country sent
// only to that reader, which would have shown each person their own position
// and nobody else's. The point of this page is now that everyone sees the same
// map, and a map that hides the only reader in a country is not that.
//
// SO THE RETICENCE IS GONE AND THE PAGE SAYS SO. What is still true: nothing
// joins a country to a name, a message, or a room, and the count is of held
// connections rather than of people. What is no longer true is that a lone
// reader is unplaced — see the prose on the page, which was corrected with
// this line rather than left promising it.
const hereFloor = 1

// cellCount is one cell's dot: where to draw it and how many are in it.
type cellCount struct {
	Lat float64 `json:"lat"`
	Lon float64 `json:"lon"`
	N   int     `json:"n"`
}

// hereCells applies the floor to the cell tally and turns what survives into
// coordinates. Sorted by count then position, so the page does not reshuffle
// between two polls that saw the same room.
//
// NO ELSEWHERE OF ITS OWN. A connection that cannot be placed, or whose cell is
// under the floor, is already counted in the country table's elsewhere; a second
// number for the same people would invite adding them up. The map showing fewer
// than the table is the honest consequence of the map being the finer view.
func hereCells(byCell map[uint16]int) []cellCount {
	out := make([]cellCount, 0, len(byCell))
	for cell, n := range byCell {
		if n < hereFloor {
			continue
		}
		lat, lon, ok := geo.CellCentre(cell)
		if !ok {
			continue
		}
		out = append(out, cellCount{Lat: lat, Lon: lon, N: n})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].N != out[j].N {
			return out[i].N > out[j].N
		}
		if out[i].Lat != out[j].Lat {
			return out[i].Lat > out[j].Lat
		}
		return out[i].Lon < out[j].Lon
	})
	return out
}

// hereRows turns the live tally into the published list plus the elsewhere
// count, applying the floor. Sorted by count descending, then by code, so the
// page does not reshuffle between two polls that saw the same room.
func hereRows(byCC map[string]int) ([]countryCount, int) {
	rows := make([]countryCount, 0, len(byCC))
	elsewhere := 0
	for cc, n := range byCC {
		if cc == "" || n < hereFloor {
			elsewhere += n
			continue
		}
		rows = append(rows, countryCount{CC: cc, N: n})
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].N != rows[j].N {
			return rows[i].N > rows[j].N
		}
		return rows[i].CC < rows[j].CC
	})
	return rows, elsewhere
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
	// FailKind is a fixed word from this file's own vocabulary — "refused",
	// "unreachable" or "internal" — and NEVER the vendor's message, nor a panic's. A 401 body can echo request
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
	BotFailInternal    = "internal"    // this code broke, not the vendor
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
	if kind != BotFailRefused && kind != BotFailUnreachable && kind != BotFailInternal {
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
/* SpendSince is what the helper has cost since an instant, in micros.

WINDOWED, BECAUSE BotStats IS NOT. That one sums the whole table, which is the
right number for a page reporting what the helper has ever cost and the wrong
one for a ceiling: a lifetime total crosses any cap eventually and then stays
crossed, so the clerk would go quiet for ever on the strength of a year of
ordinary use.

EVERY KIND COUNTS. A pass and a withheld reply are billed exactly like an answer
— the input was sent and charged — so a cap that counted only answers would be
a cap an attacker walks straight through by asking things that get refused.
*/
func (s *Store) SpendSince(ctx context.Context, since int64) (int64, error) {
	var n sql.NullInt64
	if err := s.r.QueryRowContext(ctx,
		`SELECT sum(cost_micros) FROM bot_replies WHERE created_at >= ?`,
		since).Scan(&n); err != nil {
		return 0, err
	}
	return n.Int64, nil
}

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

// BotLastCallAt is the throttle's only question: when did we last SPEND A CALL,
// whatever became of it.
//
// A CALL AND NOT A REPLY, and that distinction is the whole point. It used to
// read bot_replies alone, which holds the calls that produced something — so a
// call the vendor REFUSED left no trace the throttle could see and did not count
// against it. MEASURED with a broken key: ten messages arriving in a room
// produced ten calls to the vendor over thirty seconds, and the one-per-minute
// throttle held back none of them. Every message posted anywhere wakes this bot,
// so a revoked key turned it into an unthrottled loop against somebody else's
// API.
//
// The throttle exists so that tokens are not burned. A refused call burns a
// round trip rather than tokens, but it is still a call this process chose to
// make, and "one a minute" is a promise about calls or it is not a promise.
//
// READ FROM THE DATABASE, both halves, so a restart cannot hand the bot a fresh
// allowance — a crash loop against a failing vendor is exactly the shape that
// would otherwise call on every start.
func (s *Store) BotLastCallAt(ctx context.Context) (time.Time, error) {
	var at sql.NullInt64
	if err := s.r.QueryRowContext(ctx,
		`SELECT max(created_at) FROM bot_replies`).Scan(&at); err != nil {
		return time.Time{}, err
	}
	failedAt, err := s.metaInt(ctx, botFailAtK)
	if err != nil {
		return time.Time{}, err
	}
	last := at.Int64
	if failedAt > last {
		last = failedAt
	}
	if last == 0 {
		return time.Time{}, nil
	}
	return time.Unix(last, 0), nil
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

// holdGauge counts long-poll requests in flight, remembers the high water mark,
// and keeps a tally of what those connections have in common.
//
// THE TWO NUMBERS THAT MATTER STAY LOCK-FREE. now and peak are atomics, as they
// always were: this is instrumentation, and instrumentation that can block the
// thing it measures is worse than no instrumentation.
//
// THE TALLIES DO TAKE A LOCK, and the earlier version of this comment said that
// was disqualifying. It is not, and the reason is arithmetic rather than taste:
// the lock is held for one map increment, and it is taken twice per LONG POLL —
// once entering the wait and once leaving it, so once per reader per MaxWait,
// which is twenty seconds. Seven readers is seven hundredths of a lock
// acquisition per second.
//
// AND IT IS NOW ON THE PATH THAT SERVES A REPLY, which this comment used to say
// could not be afforded. That was true of the design it described and is no
// longer true of this one: here() reports the windowed count, so building a poll
// reply takes the lock once and sweeps the three maps. The bound is what makes
// it affordable — the maps are the size of the recently-connected, not of the
// log, so a sweep is a walk over a few tens of keys with no allocation. What is
// still refused is anything unbounded on that path, and a lock whose hold time
// grows with history would be exactly that. If this site ever holds thousands of
// connections at once, the windowed total wants caching behind an atomic; at
// this scale that would be a cache with nothing to gain.
//
// KEYED, NOT LISTED. Each map holds a count per key and the key is forgotten
// once nothing is in flight for it and its window has passed, so the maps are
// bounded by recent connections rather than by history — nothing here
// accumulates, and a restart is the only reset the peak has.
//
// The peak is monotonic for the life of the process and says so on the page. A
// decaying peak would need a window, a timer and a decision about what "recent"
// means, none of which a diagnostics line is worth.
//
// ---- THE WINDOW, WHICH IS THE ONE THING THIS DOES BEYOND COUNTING ----
//
// REPORTED: "i'm on the chat but i don't see myself in the map". Two causes,
// and this is the second of them. A long poll is not held continuously — it
// returns, the client works, and it re-polls — so a gauge that counts requests
// IN FLIGHT reports a reader who is plainly sitting there as absent for part of
// every cycle. MEASURED against the live site with one reader on it, sampling
// every 1.5s for 36s: present in 14 of 24 samples, a clean ~6s-on/~4s-off
// beat. The page intermittently said nobody was holding the chat open.
//
// THAT IS NOT COSMETIC. A country is named only once hereFloor connections are
// in it, so two readers in one country clear the floor only in the instants
// their polls happen to overlap — a genuinely populated map would drop dots
// between beats.
//
// A WINDOWED MAXIMUM, NOT A LINGER COUNT, and the difference is the whole bug
// this could have shipped. "Keep counting a connection for W after it leaves"
// double-counts the reader who re-polls four seconds later: they are one live
// connection plus one lingering ghost, and the page says two. So each key
// remembers the MOST that were in flight at once (peak) and WHEN that was last
// achieved, and reports that for W afterwards. One reader polling forever holds
// a steady 1; two readers hold 2; a reader who closes the tab decays to 0 once
// W has passed with nothing in flight.
//
// WHAT THE WINDOW COSTS, said plainly. The number becomes "held just now"
// rather than "held this instant", so somebody who closes the tab is counted
// for up to W afterwards. That is the trade being made deliberately: a steady
// number that is a few seconds stale is more honest to a reader than a correct
// number that flickers to nothing while they watch.
//
// IT DOES NOT WEAKEN THE FLOOR. Naming a country still requires hereFloor
// connections to have been in flight AT ONCE — the peak is a maximum of
// simultaneous holds, never a sum over time — so no country is ever named on
// the strength of one reader polling repeatedly.
//
// /diag's Holding IS DELIBERATELY NOT WINDOWED. That line is an operator fact
// about this process — how many requests are parked in it right now — and the
// atomics above answer it exactly. The window belongs to the reader-facing
// number, which is answering a different question.
const holdLinger = 45 * time.Second

// keyState is one tally key's recent history: what is in flight now, and the
// most that were in flight at once within the window.
type keyState struct {
	live   int
	peak   int
	peakAt time.Time
}

type holdGauge struct {
	now  atomic.Int64
	peak atomic.Int64

	mu sync.Mutex
	// clock is injectable so the window can be tested without sleeping. nil
	// means time.Now.
	clock func() time.Time
	// byCC is connections per two-letter country, "" for the ones with no
	// country — an address the file does not cover, or no file at all.
	byCC map[string]*keyState
	// byNet is connections per network hash. THE HASHES NEVER LEAVE THIS MAP:
	// only its SIZE is published, which answers the one question the raw count
	// cannot — whether "7 here" is seven readers or one reader with seven tabs.
	byNet map[string]*keyState
	// byRoom is connections per room, keyed by pulseKey. Only its size is
	// published, for the same reason.
	byRoom map[string]*keyState

	// byCell is connections per coarse grid cell — the map's own tally.
	//
	// KEYED BY CELL, NOT BY COORDINATE, which is the point: the finest thing
	// this process holds about where a reader is, is which ~550km square they
	// are in. It goes through exactly the same window and the same floor as
	// byCC, so a cell is named on the same terms a country is.
	byCell map[uint16]*keyState
}

// holder is what a held connection has in common with others. Not a person and
// not an identity: three keys that are only ever counted.
//
// STABLE ACROSS A READER'S POLLS, which is what makes the window above possible
// at all: the same reader re-polling produces the same three keys, so their next
// poll updates a tally rather than adding a second one.
type holder struct {
	cc, net, room string
	// cell is the coarse grid cell, 0 when this build cannot place the address.
	// A NUMBER, NOT A NAME: see internal/geo/cell.go for why the coordinate it
	// came from is not kept anywhere, including here.
	cell uint16
}

func (g *holdGauge) tick() time.Time {
	if g.clock != nil {
		return g.clock()
	}
	return time.Now()
}

func (g *holdGauge) enter(h holder) {
	n := g.now.Add(1)
	for {
		p := g.peak.Load()
		if n <= p || g.peak.CompareAndSwap(p, n) {
			break
		}
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.byCC == nil {
		g.byCC = map[string]*keyState{}
		g.byNet = map[string]*keyState{}
		g.byRoom = map[string]*keyState{}
	}
	if g.byCell == nil {
		g.byCell = map[uint16]*keyState{}
	}
	t := g.tick()
	bump(g.byCC, h.cc, t)
	if h.net != "" {
		bump(g.byNet, h.net, t)
	}
	if h.room != "" {
		bump(g.byRoom, h.room, t)
	}
	// Cell 0 is "could not place", which is not a place and must not become one.
	if h.cell != 0 {
		bump(g.byCell, h.cell, t)
	}
}

func (g *holdGauge) leave(h holder) {
	g.now.Add(-1)
	g.mu.Lock()
	defer g.mu.Unlock()
	drop(g.byCC, h.cc)
	drop(g.byNet, h.net)
	drop(g.byRoom, h.room)
	if h.cell != 0 {
		drop(g.byCell, h.cell)
	}
}

// bump records one more in-flight poll for a key, and re-stamps the peak when
// this is the most that have been in flight at once.
//
// GREATER-OR-EQUAL RATHER THAN GREATER, and it is NOT load-bearing — measured,
// after the comment here first claimed it was. The claim was that re-achieving
// the same peak must refresh the clock or a steady poller would expire after one
// window; changing it to `>` fails no test, because sweep re-stamps an expired
// key that still has something in flight and that is what actually keeps a
// steady poller in the room. The `>=` is kept for saying plainly what a bump
// means, not because anything depends on it.
func bump[K comparable](m map[K]*keyState, k K, t time.Time) {
	s := m[k]
	if s == nil {
		s = &keyState{}
		m[k] = s
	}
	s.live++
	if s.live >= s.peak {
		s.peak = s.live
		s.peakAt = t
	}
}

// drop decrements what is in flight for a key. It does NOT forget the key —
// that is the window's job, in present() — but it never lets live go negative,
// because a leave without a matching enter would otherwise poison the tally for
// the life of the process.
func drop[K comparable](m map[K]*keyState, k K) {
	if m == nil {
		return
	}
	if s := m[k]; s != nil && s.live > 0 {
		s.live--
	}
}

// present is what a key counts for right now: its recent peak while the window
// holds, and only what is actually in flight once it has passed.
func (s *keyState) present(t time.Time) int {
	if t.Sub(s.peakAt) <= holdLinger {
		return s.peak
	}
	return s.live
}

// sweep forgets keys with nothing in flight and an expired window, and resets a
// stale peak back to what is really there. Called under the lock from snapshot,
// so the maps stay the size of the room without needing a timer.
func (g *holdGauge) sweep(t time.Time) {
	for _, m := range []map[string]*keyState{g.byCC, g.byNet, g.byRoom} {
		sweepMap(m, t)
	}
	sweepMap(g.byCell, t)
}

// sweepMap is sweep for one tally. Split out only because byCell is keyed by a
// number and the other three by a string; the rule is identical and must stay
// that way — a cell that expired on different terms from a country would make
// the map and the table disagree about who is in the room.
func sweepMap[K comparable](m map[K]*keyState, t time.Time) {
	for k, s := range m {
		if t.Sub(s.peakAt) <= holdLinger {
			continue
		}
		if s.live == 0 {
			delete(m, k)
			continue
		}
		s.peak = s.live
		s.peakAt = t
	}
}

// snapshot copies the tallies out under the lock. Copied rather than returned by
// reference: the caller marshals JSON, and a map still being written to while
// encoding is a data race and a torn payload.
func (g *holdGauge) snapshot() (byCC map[string]int, nets, rooms int) {
	byCC, nets, rooms, _ = g.snapshotAll()
	return byCC, nets, rooms
}

// snapshotAll is snapshot plus the cell tally. Two entry points rather than one
// with a discarded return, because every existing caller wants three things and
// only the presence page wants the fourth.
func (g *holdGauge) snapshotAll() (byCC map[string]int, nets, rooms int, byCell map[uint16]int) {
	g.mu.Lock()
	defer g.mu.Unlock()
	t := g.tick()
	g.sweep(t)
	byCC = make(map[string]int, len(g.byCC))
	for k, v := range g.byCC {
		if n := v.present(t); n > 0 {
			byCC[k] = n
		}
	}
	// len IS SAFE HERE, and only because sweep ran first. An earlier version of
	// this counted present() > 0 per key, with a comment about keys that survive
	// a sweep while counting nothing. There are none: an unexpired key has
	// peak >= 1 by construction, and an expired one is either deleted or has its
	// peak reset to a live count above zero. The loop was guarding a state that
	// cannot occur, which is worse than no guard — it invites the reader to
	// believe in it.
	byCell = make(map[uint16]int, len(g.byCell))
	for k, v := range g.byCell {
		if n := v.present(t); n > 0 {
			byCell[k] = n
		}
	}
	return byCC, len(g.byNet), len(g.byRoom), byCell
}

// presentTotal is every held connection the window can see, country known or
// not. This is the reader-facing count — the one the chat panel prints — and it
// is a sum over byCC because byCC keys every connection, using "" for the ones
// with no country.
func (g *holdGauge) presentTotal() int64 {
	byCC, _, _ := g.snapshot()
	var n int64
	for _, v := range byCC {
		n += int64(v)
	}
	return n
}

// ---------------------------------------------------------------- handlers ---

/*
WHO IS IN THE ROOM, FOR THE PEOPLE IN IT — the reader-facing half of the

	presence tally, and a separate endpoint from /diag on purpose.
	WHY NOT JUST LINK READERS AT /diag. That payload also carries what the site's
	own answerer has been doing: whether it is enabled, how often it has spoken,
	what it has cost. This deployment's standing requirement is that nobody is
	told there is an answerer at all, and a link from the chat panel to a payload
	that names it is that requirement undone by one devtools tab. So the panel
	points here, and here carries presence and nothing else.
	IT PUBLISHES NO GRAND TOTAL, deliberately. The chat line counts the reader
	asking, and the country tally counts placed connections; a total on this page
	would visibly disagree with the number the reader clicked on, and explaining
	the difference is not something this endpoint can honestly do. So it reports
	the distribution and lets the panel keep the count.
	THE PRIVACY RULES ARE hereRows' AND NOT RESTATED HERE: a country appears only
	once at least hereFloor connections are in it, everything else — including
	every connection with no country at all — is one number with no location on
	it. Nothing joins a country to a moniker, a message, a hash or a room.
*/
type herePayload struct {
	// Placed is the connections a country could be named for; Elsewhere is all
	// the rest, whether under the floor or simply unknown.
	ByCountry []countryCount `json:"by_country"`
	Elsewhere int            `json:"elsewhere"`

	// Networks and Rooms are shape without location: seven readers behind one
	// network in one room is a different room to walk into than seven spread
	// across seven, and neither says which networks or which rooms.
	Networks int `json:"networks"`
	Rooms    int `json:"rooms"`

	// GeoKnown distinguishes "everybody is under the floor" from "this server
	// has no country file at all", which are the same empty list otherwise —
	// the healthy-looks-like-broken trap the bot's Failures field exists for.
	GeoKnown bool `json:"geo_known"`

	// ByCell is where the map draws its dots: one row per coarse grid cell that
	// has at least hereFloor connections in it, at the CENTRE of the cell.
	//
	// COORDINATES, NOT A CELL NUMBER AND NOT A PLACE NAME. The page needs a
	// position to draw and nothing else, so the grid arithmetic stays on this
	// side and the wire carries the answer. There is no city here, no region,
	// and no way back from the number to either — see internal/geo/cell.go.
	//
	// THE SAME FLOOR AS A COUNTRY, and that is a judgement worth stating: a cell
	// is ~550km on a side, which is coarser than a good many countries, so
	// naming one on the same terms is not a relaxation of hereFloor. What it
	// buys is a map with several dots across a populous country instead of one
	// dot in the middle of it.
	ByCell []cellCount `json:"by_cell"`

	// CellsKnown distinguishes "nobody cleared the floor in any cell" from "this
	// build has only a country file and cannot place anybody" — the same
	// healthy-looks-like-broken distinction GeoKnown exists for, one level down.
	CellsKnown bool `json:"cells_known"`

	// Events is the change sequence number — see pulse.changes. The page shows
	// a flash when it moves, so a reader can see the site is alive.
	//
	// A NUMBER AND NOTHING ELSE, which is what makes it publishable here. It
	// says how many things have happened, never what or where or by whom, and
	// it cannot be joined to the country tally beside it: the tally is a census
	// of held connections and this is a count of events, with no key in common.
	Events int64 `json:"events"`
}

// herePresence answers it. GET only, and never cached: it is a live count.
//
// NOT called here(): that name is already the TOTAL the poll reply carries, and
// the two are deliberately different numbers — see herePayload on why this one
// publishes no total.
func (s *Server) herePresence(w http.ResponseWriter, r *http.Request) {
	if s.cors(w, r) {
		return
	}
	if r.Method != http.MethodGet {
		writeErr(w, http.StatusMethodNotAllowed, "GET only")
		return
	}
	/* HOLDING OPEN UNTIL SOMETHING HAPPENS, so the page can show a change as it
	   lands rather than up to one interval later. Same shape as the messages
	   poll: `since` is what the client last saw, `wait` is how long it will
	   hold, both optional — a client that sends neither is answered at once,
	   which is what keeps this safe to deploy in either order.

	   NOT COUNTED IN THE GAUGE, and this is the one thing that would quietly
	   undo the number it is reporting. The tally means "people with a chat
	   open"; somebody reading THIS page has no chat open, and entering them
	   here would make the presence figure include its own audience — a page
	   that reports a bigger room the longer you look at it. The messages
	   handler enters the gauge; this one deliberately never does. */
	since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
	if wait := waitFor(r.URL.Query().Get("wait")); wait > 0 {
		// Watched BEFORE the count is re-read, for the reason in pulse.watch: a
		// change landing between the two would close a channel nobody held.
		ch := s.pulse().watchAny()
		if since == s.pulse().changeCount() {
			timer := time.NewTimer(wait)
			defer timer.Stop()
			select {
			case <-ch:
			case <-r.Context().Done():
				return // the client hung up; there is nobody to answer
			case <-timer.C:
			}
		}
	}
	byCC, nets, rooms, byCell := s.hold.snapshotAll()
	out := herePayload{Networks: nets, Rooms: rooms, GeoKnown: s.Geo != nil,
		CellsKnown: s.CellsKnown(), Events: s.pulse().changeCount()}
	out.ByCountry, out.Elsewhere = hereRows(byCC)
	out.ByCell = hereCells(byCell)
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, out)
}

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
	byCC, nets, rooms := s.hold.snapshot()
	out.HereByCountry, out.HereElsewhere = hereRows(byCC)
	out.HereNetworks, out.HereRooms = nets, rooms
	// A country FILE, not a country header: the header answers per request and
	// cannot be reported on without one in hand, and a deployment with neither is
	// the case this flag exists to make visible.
	out.GeoKnown = s.Geo != nil
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
