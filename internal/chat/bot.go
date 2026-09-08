package chat

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// A HELPER IN THE ROOM, and everything below is about spending as little as
// possible to be one.
//
// THE SHAPE. Every tick it looks at the rooms that have said anything lately,
// finds messages it has not considered, decides LOCALLY whether any of them is
// plausibly a question about the site, and only then spends one API call — which
// is itself allowed to answer "nothing useful to add". A room full of argument
// costs nothing at all, because the local filter never fires.
//
// THE THREE THINGS THAT KEEP IT FROM BURNING MONEY, in the order they bite:
//
//  1. a watermark per room, so a restart does not re-answer the backlog
//  2. a local filter, so most traffic never reaches the model
//  3. one reply per BotMinGap ACROSS ALL ROOMS, read from the database rather
//     than from memory, so a crash loop cannot hand it a fresh allowance
//
// IT POSTS AS anon, like everybody else in the room — asked for, and the reason
// it cannot know itself by name. It records the id of every message it writes,
// so "was this mine" is a lookup and not a guess. See Store.BotReplyIDs.
//
// AND IT NEVER ANSWERS A REPLY OF ITS OWN, which the id table makes exact. The
// failure that costs real money is a bot that answers itself: a reply becomes a
// new message, which triggers a reply. Two independent things stop it here — the
// id check, and a local filter that requires a question mark or an interrogative
// opening, which the bot's own declarative answers do not have.
type Bot struct {
	Store *Store
	HTTP  *http.Client

	// Key is the API key. Read once at start by the caller; the bot does not go
	// looking for it, so a key set after this process started takes effect at the
	// next restart rather than mid-loop.
	Key   string
	Model string

	// Chains limits which chains' rooms it will speak in. Empty means all of
	// them, which is right for a single-chain deployment and wrong for a box that
	// also serves a dev chain — hence the field.
	Chains map[string]bool

	// Tick is how often it looks. MinGap is the floor between two replies across
	// every room together.
	Tick   time.Duration
	MinGap time.Duration

	// MaxAge is how stale a message may be and still be worth answering. A
	// question from an hour ago has either been answered by a person or been
	// abandoned, and answering it announces that nobody was listening at the time.
	MaxAge time.Duration

	// Site, Repo and Chain go into the system prompt so the bot can point at real
	// places instead of inventing them.
	Site, Repo, ChainDocs string

	// Prices in micro-dollars per million tokens. OPERATOR CONFIGURATION AND NOT
	// A FACT: they are whatever the vendor charges this account today, and this
	// process has no way to ask. Wrong numbers here make the money column wrong
	// and nothing else; the token counts beside it come from the API response.
	InPerMTok, OutPerMTok int64

	// Log receives one line per interesting event. Optional.
	Log func(string, ...any)

	// Wake tells the waiting readers that something was said. Server.Wake is the
	// implementation.
	//
	// WITHOUT IT THE HELPER IS INVISIBLE FOR UP TO MaxWait, which is twenty
	// seconds on the live site. MEASURED: the bot posted in 3ms and a reader
	// holding a long poll did not see it until the poll expired 4 seconds later —
	// the whole four, not a fraction of it. Every other writer here goes through
	// the HTTP handler, which fires the pulse itself; the bot writes through the
	// store, so nothing fired.
	//
	// That made the reply latency work pointless: a helper tuned to answer in
	// 1.2s that a reader sees twenty seconds later has not answered in 1.2s.
	//
	// Optional like Subscribe, so a test can run the bot with no server attached.
	Wake func(chain, court string)

	// Subscribe, when set, hands back a channel that closes when anything is
	// posted anywhere. Server.Subscribe is the implementation.
	//
	// WITHOUT IT THIS IS A POLLER and the fastest it can answer is one Tick. With
	// it a greeting in an empty room is answered about a second after it lands,
	// which is what makes the room feel occupied rather than monitored. Optional,
	// because a test wants determinism and a poller is still correct.
	Subscribe func() <-chan struct{}

	// TypeCPS is how fast the helper appears to type, in characters per second.
	//
	// A REPLY THAT ARRIVES INSTANTLY READS AS A MACHINE, whatever it says. Nobody
	// composes three sentences in 40ms, and a room where one participant always
	// answers before you have finished reading your own message is a room where
	// everybody knows what that participant is. So the reply is held back by
	// roughly the time it would have taken to write: a short line lands in a
	// couple of seconds, a full paragraph takes the better part of twenty.
	//
	// FAST, NOT AVERAGE. 18 c/s is about 215 words a minute — a quick typist
	// having a good day, not a median one, because the alternative is a helper
	// that takes a minute to answer "click the map".
	TypeCPS float64

	// TypeMax caps that wait however long the reply is. Past it the delay stops
	// buying plausibility and starts being a slow site.
	TypeMax time.Duration

	// GreetAfter is how long a room must have been silent for a bare greeting to
	// be worth answering.
	//
	// THE POINT IS TO ANSWER AN EMPTY ROOM, not to interject. "hello" said into a
	// live conversation is aimed at the people in it and needs nothing from the
	// site; the same word into a room where nothing has happened for an hour is
	// somebody checking whether anyone is there, and leaving it unanswered is the
	// worst version of this feature.
	GreetAfter time.Duration

	// Endpoint is overridable so tests can point at a local server. Empty means
	// the real one.
	Endpoint string
}

const (
	// BotTick, BotMinGap and BotMaxAge are the defaults the command uses.
	BotTick   = 15 * time.Second
	BotMinGap = time.Minute
	BotMaxAge = 10 * time.Minute

	// botMaxBody is the reply cap. Under MaxBodyRunes, so a long answer is cut
	// here — where it can be cut at a sentence — rather than refused by Post.
	botMaxBody = 360

	// botLookback bounds the rows one tick reads per room.
	botLookback = 25

	// BotTypeCPS, BotTypeMax and BotGreetAfter are the defaults. See the fields.
	BotTypeCPS    = 18.0
	BotTypeMax    = 20 * time.Second
	BotGreetAfter = 30 * time.Minute

	// botReadPause is the beat before the typing starts — the time a person
	// spends reading the message before answering it. Asked for as "immediately
	// + 1s", and it is also what keeps a one-word greeting from being answered in
	// the same instant it is posted.
	botReadPause = time.Second

	// A GREETING IS NOT COMPOSED, so it is not timed as though it were.
	//
	// MEASURED against the instruction the model was given — "one short line,
	// under 100 characters" — a greeting reply came out 60 to 64 characters and
	// so took 4.3 to 4.4 seconds to arrive under the typing model, against the
	// ~1s that was asked for. The length was the whole problem: a bare "hey" took
	// 1.17s already.
	//
	// So the reply is held to what a greeting actually is. Forty characters is
	// "hey — what would you like to know?", which is muscle memory rather than
	// composition, and at that length arriving inside a second and a bit is the
	// plausible speed rather than an exception to the model. Substantive answers
	// keep the full rate: that is the other half of what was asked for, and a
	// paragraph appearing instantly is what gives a helper away.
	botGreetWithin   = 1200 * time.Millisecond
	botGreetMaxChars = 40
)

// botIPHash is the ip_hash the bot's own rows carry.
//
// A CONSTANT AND NOT A REAL HASH, so operator tooling that groups by address
// shows the bot as one identifiable participant rather than as a mystery peer,
// and so a ban aimed at a person can never land on it by collision. It still
// goes through throttleTx like anybody else: at one reply a minute it is an
// order of magnitude under PerIPMax, and that is deliberate — the bot should be
// inside the room's rules, not exempt from them.
const botIPHash = "bot:site-helper"

// BotRunnable is whether a helper will actually run, and it exists so that the
// answer is given ONCE.
//
// The command had two answers to this and they disagreed: Server.BotEnabled came
// straight from the --bot flag, while the goroutine started only inside the
// branch where a key had also been found. So a deployment with --bot and no key
// reported enabled=true on the diagnostics page and added one to the count of
// people in every room — a participant that was never going to speak. Neither
// line was wrong on its own; there were simply two of them.
//
// A FLAG IS AN INTENTION AND A KEY IS A CAPABILITY, and it takes both. Trivial
// enough to inline, which is exactly why it was inlined twice; it is a function
// so that there is one place to be right and a truth table can be pinned to it.
func BotRunnable(flagOn, keySet bool) bool { return flagOn && keySet }

// BotOptions is everything a deployment chooses about the helper. Nothing in it
// is a hook: the hooks are the point of NewBot.
type BotOptions struct {
	Enabled                      bool
	Model, Site, Repo, ChainDocs string
	MinGap                       time.Duration
	InPerMTok, OutPerMTok        int64
	Chains                       map[string]bool
	Log                          func(string, ...any)
}

// NewBot builds the helper AND CONNECTS IT to the server it will speak through,
// returning nil when it must not run.
//
// WHY A CONSTRUCTOR RATHER THAN A STRUCT LITERAL AT THE CALL SITE. Wake and
// Subscribe are optional fields — deliberately, so a test can drive the bot with
// no server attached — and an optional field that the one real caller forgets is
// a fault that nothing fails on. That is not hypothetical: Wake was missing for
// a while, and the cost was a reply the bot wrote in 3ms that readers did not see
// for up to twenty seconds. The bot's own tests passed throughout, because they
// set the field themselves.
//
// The command has no seam a test can call, so that omission was guarded by a
// check that read main.go's TEXT — which could only ever show the line was
// written, not that the hook worked. Here the wiring is inside a function a test
// can call, and the test drives the hooks rather than reading them.
//
// nil MEANS DO NOT RUN, and it is the same answer Server.BotEnabled should
// report, so a caller sets that from this result instead of deciding twice.
func NewBot(store *Store, srv *Server, key string, o BotOptions) *Bot {
	if !BotRunnable(o.Enabled, key != "") {
		return nil
	}
	return &Bot{
		Store: store, Key: key, Model: o.Model,
		Chains: o.Chains, MinGap: o.MinGap,
		Site: o.Site, Repo: o.Repo, ChainDocs: o.ChainDocs,
		InPerMTok: o.InPerMTok, OutPerMTok: o.OutPerMTok,
		Log: o.Log,
		// THE TWO HOOKS, and the whole reason this function exists.
		Subscribe: srv.Subscribe,
		Wake:      srv.Wake,
	}
}

func (b *Bot) logf(f string, a ...any) {
	if b.Log != nil {
		b.Log(f, a...)
	}
}

func (b *Bot) now() time.Time {
	if b.Store != nil {
		return b.Store.Now()
	}
	return time.Now()
}

// Run loops until the context ends.
func (b *Bot) Run(ctx context.Context) {
	tick := b.Tick
	if tick <= 0 {
		tick = BotTick
	}
	t := time.NewTicker(tick)
	defer t.Stop()
	b.logf("chat bot: watching, model=%s gap=%s", b.Model, b.gap())
	for {
		// RE-SUBSCRIBED EVERY ITERATION, and taken BEFORE the pass rather than
		// after it. The channel is replaced on each fire, so a handle kept across
		// iterations is a handle to a signal that has already gone; and a post
		// landing during the pass must wake the NEXT one rather than being
		// swallowed by a subscription taken afterwards. Same discipline the long
		// poll follows — see pulse.watch.
		var woke <-chan struct{}
		if b.Subscribe != nil {
			woke = b.Subscribe()
		}
		if err := b.once(ctx); err != nil && !errors.Is(err, context.Canceled) {
			b.logf("chat bot: %v", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-woke:
			// Something was said. Look now rather than at the next tick.
		case <-t.C:
		}
	}
}

func (b *Bot) gap() time.Duration {
	if b.MinGap > 0 {
		return b.MinGap
	}
	return BotMinGap
}

// once is a single pass: catch up the watermarks, find one thing worth
// answering, answer it if the throttle allows.
//
// AT MOST ONE REPLY PER PASS, which together with the ticker is the second half
// of the throttle. Even if ten rooms each hold a question, this speaks once and
// the rest wait — a bot that empties a backlog in one pass is the thing that
// makes a bill.
func (b *Bot) once(ctx context.Context) error {
	if b.Key == "" {
		return nil
	}
	now := b.now()
	rooms, err := b.Store.ActiveRooms(ctx, now.Add(-b.age()).Unix())
	if err != nil {
		return err
	}

	// THE THROTTLE IS CHECKED BEFORE THE MODEL AND AFTER THE SCAN, deliberately.
	// Before the model, so a throttled pass costs nothing at all.
	// The scan is what advances the watermarks, and it must run every pass: if it
	// were skipped while throttled, the questions that arrived during the wait
	// would still be waiting when the gap expired and the bot would answer the
	// oldest of them, which is the behaviour MaxAge exists to prevent.
	last, err := b.Store.BotLastCallAt(ctx)
	if err != nil {
		return err
	}
	// A CALL, NOT A REPLY. See Store.BotLastCallAt: a refused call left no trace
	// the throttle could see, so a broken key called once per incoming message.
	maySpeak := last.IsZero() || now.Sub(last) >= b.gap()

	var pick *botCandidate
	for _, room := range rooms {
		chain, court := room[0], room[1]
		if len(b.Chains) > 0 && !b.Chains[chain] {
			continue
		}
		c, err := b.scan(ctx, chain, court, now)
		if err != nil {
			b.logf("chat bot: scanning %s/%s: %v", chain, court, err)
			continue
		}
		// The newest candidate across all rooms wins. A question asked thirty
		// seconds ago is worth more than one asked nine minutes ago, and the
		// watermark has already moved past both either way.
		if c != nil && (pick == nil || c.at.After(pick.at)) {
			pick = c
		}
	}
	if pick == nil || !maySpeak {
		return nil
	}
	return b.answer(ctx, *pick)
}

func (b *Bot) age() time.Duration {
	if b.MaxAge > 0 {
		return b.MaxAge
	}
	return BotMaxAge
}

type botCandidate struct {
	chain, court string
	body         string
	at           time.Time
	// greeting is true when this is a bare hello into a room that had gone quiet,
	// which is answered on different terms: no site vocabulary is required of it,
	// and the answer is a short line rather than an explanation.
	greeting bool
	// transcript is the recent room, oldest first, for context.
	transcript []string
}

// scan advances one room's watermark and returns the best thing in it to answer,
// or nil.
//
// THE WATERMARK MOVES WHETHER OR NOT WE SPEAK. That is what makes this safe to
// run every tick: a message is considered exactly once, so a question the filter
// rejected is not re-examined forever, and a restart resumes rather than
// re-reading. It is persisted per room in meta.
func (b *Bot) scan(ctx context.Context, chain, court string, now time.Time) (*botCandidate, error) {
	mark, err := b.Store.botMark(ctx, chain, court, now.Add(-b.age()).Unix())
	if err != nil {
		return nil, err
	}
	msgs, err := b.Store.Recent(ctx, chain, court, mark, botLookback)
	if err != nil {
		if errors.Is(err, ErrWithdrawn) {
			return nil, nil // a frozen room is not a failure, it is just closed
		}
		return nil, err
	}
	if len(msgs) == 0 {
		return nil, nil
	}
	mine, err := b.Store.BotReplyIDs(ctx, chain, court, mark)
	if err != nil {
		return nil, err
	}

	var (
		best    *botCandidate
		highest int64
		lines   []string
	)
	for _, m := range msgs {
		if m.ID > highest {
			highest = m.ID
		}
		lines = append(lines, m.Moniker+": "+m.Body)
		if mine[m.ID] {
			continue // our own voice
		}
		at := time.Unix(m.CreatedAt, 0)
		if now.Sub(at) > b.age() {
			continue
		}
		switch {
		case botWorthAsking(m.Body):
			best = &botCandidate{chain: chain, court: court, body: m.Body, at: at}
		case botGreeting(m.Body):
			// A GREETING ONLY COUNTS IN A ROOM THAT HAD GONE QUIET, and the
			// question is asked of the store rather than of the transcript: the
			// rows this pass happens to have read start at the watermark, which
			// says nothing about what came before it.
			quiet, err := b.Store.roomQuietBefore(ctx, chain, court, m.ID,
				at.Add(-b.greetAfter()).Unix())
			if err != nil {
				return nil, err
			}
			if quiet {
				best = &botCandidate{chain: chain, court: court, body: m.Body,
					at: at, greeting: true}
			}
		default:
			continue
		}
	}
	if highest > mark {
		if err := b.Store.setBotMark(ctx, chain, court, highest); err != nil {
			return nil, err
		}
	}
	if best != nil {
		if len(lines) > 8 {
			lines = lines[len(lines)-8:]
		}
		best.transcript = lines
	}
	return best, nil
}

// botWorthAsking is the LOCAL filter, and it is the difference between a bill
// and a rounding error.
//
// It is deliberately narrow: a question mark, or an opening that is plainly
// interrogative, plus a hint that the subject is this site rather than the world.
// A room arguing about virology never trips it. It will also miss real questions
// phrased as statements — that is the trade, and the cheap direction to be wrong
// in, because the cost of a miss is silence and the cost of a false positive is
// money and noise.
//
// IT ALSO CLOSES THE LOOP BY SHAPE. The bot's own replies are declarative
// answers with no question mark and no interrogative opening, so even if the id
// check were somehow bypassed a reply could not satisfy this.
func botWorthAsking(body string) bool {
	s := strings.ToLower(strings.TrimSpace(body))
	if s == "" || len(s) > 600 {
		return false
	}
	// A mark is what most questions have; the openings catch the ones that do not.
	asks := strings.Contains(s, "?")
	if !asks {
		for _, p := range []string{
			"how do i", "how does", "how can i", "what is", "what are", "what does",
			"where do i", "where is", "why does", "can someone", "anyone know",
			"is there a way", "help with", "i don't understand", "i dont understand",
		} {
			if strings.HasPrefix(s, p) || strings.Contains(s, " "+p) {
				asks = true
				break
			}
		}
	}
	if !asks {
		return false
	}
	// ...AND IT HAS TO BE ABOUT THIS PLACE. Without this the bot answers general
	// knowledge questions in a court about virology, which is both off-topic and
	// the most expensive thing it could choose to do.
	for _, w := range []string{
		"kourt", "court", "claim", "stake", "staking", "vote", "voting", "verdict",
		"settle", "settled", "dispute", "folder", "set", "docket", "comment",
		"gno", "gnot", "wallet", "keplr", "adena", "chain", "realm", "map",
		"cc", "coin", "token", "moderator", "mod", "appeal", "site", "page",
		"how it works", "sign in", "log in", "connect",
	} {
		if strings.Contains(s, w) {
			return true
		}
	}
	return false
}

// botGreeting is a bare hello and not much else.
//
// SHORT AND WHOLLY A GREETING, which is what keeps it from firing on "hello, is
// there a way to unstake" — that is a question and botWorthAsking already has
// it. The length bound is the real filter: a greeting is a handful of
// characters, so anything longer is a message that happens to open politely.
func botGreeting(body string) bool {
	s := strings.ToLower(strings.TrimSpace(body))
	s = strings.Trim(s, ".!?,;:\u2026 ")
	if s == "" || len(s) > 24 {
		return false
	}
	for _, g := range []string{
		"hi", "hii", "hey", "heya", "hello", "hallo", "yo", "sup", "gm",
		"good morning", "good evening", "good afternoon", "greetings",
		"anyone here", "anybody here", "anyone around", "is anyone here",
		"anyone", "hello there", "hey there", "hi there", "howdy",
	} {
		if s == g {
			return true
		}
	}
	return false
}

// roomQuietBefore reports whether nothing was said in this room in the window
// before a given message.
//
// EXCLUDES THE HELPER'S OWN ROWS. A room the bot itself last spoke in is still a
// quiet room from a reader's point of view — otherwise one greeting answered
// would make the next hour of greetings ineligible, which is the opposite of
// what an empty room needs.
func (s *Store) roomQuietBefore(ctx context.Context, chain, court string, id, since int64) (bool, error) {
	var n int
	err := s.r.QueryRowContext(ctx,
		`SELECT count(*) FROM messages
		  WHERE chain=? AND court=? AND id<>? AND created_at>=? AND hidden=0
		    AND ip_hash<>?`,
		chain, court, id, since, botIPHash).Scan(&n)
	return n == 0, err
}

// ---------------------------------------------------------------- watermark --

func (s *Store) botMark(ctx context.Context, chain, court string, staleBefore int64) (int64, error) {
	var v int64
	err := s.r.QueryRowContext(ctx, `SELECT v FROM meta WHERE k=?`,
		botMarkKey(chain, court)).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		// NO MARK MEANS SKIP WHAT IS ALREADY STALE, and nothing else.
		//
		// This used to start at max(id) — "the present" — and that was wrong in a
		// way only a test showed: the newest message in a room the bot has never
		// seen IS the message it was started for, so the first thing anybody said
		// in a new room was marked as considered and never answered. On a live
		// site that is every room's first question, forever.
		//
		// The intent was only ever to avoid answering a BACKLOG: a question from
		// an hour ago has been answered by a person or abandoned, and replying to
		// it announces that nobody was listening. So the floor is the newest
		// message that is already too old to answer, which leaves everything
		// fresh in view and is the same rule MaxAge applies message by message.
		var top sql.NullInt64
		if err := s.r.QueryRowContext(ctx,
			`SELECT max(id) FROM messages WHERE chain=? AND court=? AND created_at < ?`,
			chain, court, staleBefore).Scan(&top); err != nil {
			return 0, err
		}
		if err := s.setBotMark(ctx, chain, court, top.Int64); err != nil {
			return 0, err
		}
		return top.Int64, nil
	}
	return v, err
}

func (s *Store) setBotMark(ctx context.Context, chain, court string, id int64) error {
	_, err := s.w.ExecContext(ctx,
		`INSERT INTO meta(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v`,
		botMarkKey(chain, court), id)
	return err
}

func botMarkKey(chain, court string) string { return "bot_mark:" + chain + "\x00" + court }

// ------------------------------------------------------------------- model ---

const botSystem = `You are a helper in the public chat of a Kourt court.

Kourt is a site where people stake coin on CLAIMS OF FACT and a court settles
each one YES or NO. A claim is filed, anyone may stake on either side, an
answerer posts a bond to answer it, and after a settling window the answer
stands or is disputed and voted on. Headings ("sets") are themselves claims the
court votes into existence. It runs on gno.land, a proof-of-stake chain whose
smart contracts are written in Gno, a Go-derived language, and the site's own
state lives in a realm on that chain.

Answer ONLY questions about how this site or this system works. In one short
paragraph, under 300 characters, plain and concrete. No greeting, no sign-off,
no emoji, no markdown headings.

If the message is not a question about the site — if it is argument about the
subject matter, small talk, abuse, or something you would have to guess at —
reply with exactly: PASS

Do not invent features, URLs, fees or numbers. If you do not know, say which
page would say, or reply PASS.`

type botAPIReq struct {
	Model     string      `json:"model"`
	MaxTokens int         `json:"max_tokens"`
	System    string      `json:"system"`
	Messages  []botAPIMsg `json:"messages"`
}

type botAPIMsg struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type botAPIResp struct {
	Content []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	} `json:"content"`
	Usage struct {
		InputTokens  int64 `json:"input_tokens"`
		OutputTokens int64 `json:"output_tokens"`
	} `json:"usage"`
}

// answer asks the model, and posts if it had something to say.
func (b *Bot) answer(ctx context.Context, c botCandidate) error {
	prompt := "The court is \"" + c.court + "\" on " + b.Site + ".\n" +
		"Recent messages, oldest first:\n" + strings.Join(c.transcript, "\n") +
		"\n\nThe message to consider is the last one from a reader: " + c.body
	if c.greeting {
		// A DIFFERENT ERRAND, said explicitly, because the standing instruction is
		// to PASS on anything that is not a question about the site — and a bare
		// hello is not one. Without this line the model correctly refuses to
		// answer the very thing it was woken for.
		// UNDER FORTY, not under a hundred: at a hundred the reply took four and a
		// half seconds to arrive and a greeting that takes that long has missed
		// the moment it was answering. The cap is enforced after the fact too, so
		// a model that overruns does not get answered implausibly fast.
		prompt += "\n\nThis is a greeting into a room that has been silent for a " +
			"while. Greet them back in ONE very short line, UNDER 40 CHARACTERS, " +
			"and invite a question about the site. Do not explain anything yet " +
			"and do not reply PASS."
	} else {
		prompt += "\n\nAnswer it, or reply PASS."
	}
	body, in, out, err := b.ask(ctx, prompt)
	if err != nil {
		/* COUNTED, because a helper that fails every call looked exactly like one
		   nobody had asked anything: MEASURED with a wrong key, five rejected
		   calls in a row left the page reading replies=0 passes=0 cost=0, which
		   is what a healthy idle helper reads. The count is what tells them
		   apart. Recorded before the error is returned, so a failure to record
		   cannot swallow the failure itself. */
		var bf botFail
		kind := BotFailUnreachable
		if errors.As(err, &bf) {
			kind = bf.Kind
		}
		actx, done := acctCtx(ctx)
		defer done()
		if rerr := b.Store.RecordBotFailure(actx, kind); rerr != nil {
			b.logf("chat bot: could not record a failed call: %v", rerr)
		}
		return err
	}
	text := strings.TrimSpace(body)
	// PASS is the model's way of spending almost nothing. It is still charged for
	// the input, so it is recorded — a page that showed only successful replies
	// would understate the bill.
	if text == "" || strings.HasPrefix(strings.ToUpper(text), "PASS") {
		b.logf("chat bot: passed on %s/%s (in=%d out=%d)", c.chain, c.court, in, out)
		actx, done := acctCtx(ctx)
		defer done()
		return b.Store.recordBotSpend(actx, b.Model, botKindPass, in, out, b.costMicros(in, out))
	}
	/* A GREETING IS CAPPED SHORT AND ANSWERED FAST; an answer gets the room's
	   full limit and the full typing rate. Both halves were asked for, and it is
	   the LENGTH that reconciles them: hold a greeting to what a greeting is and
	   the ~1s follows from the same model that makes a paragraph take twenty. */
	if c.greeting {
		text = botTrimTo(text, botGreetMaxChars)
	} else {
		text = botTrim(text)
	}
	if text == "" {
		return nil
	}
	// HELD BACK FOR AS LONG AS IT WOULD HAVE TAKEN TO WRITE. See Bot.TypeCPS —
	// the delay is the whole difference between a participant and a service. It
	// happens HERE, after the model has answered and before the message lands, so
	// the wait is real time on the wall and not a queue somewhere.
	if !b.pause(ctx, botWaitFor(text, c.greeting, b.cps(), b.typeMax())) {
		// The context ended mid-pause. The spend already happened and is recorded;
		// the message is simply never said, which is better than saying it into a
		// process that is shutting down. UNDELIVERED, for the same reason a
		// refusal is: it was written and billed and nobody read it.
		//
		// THE DETACHED CONTEXT IS LOAD-BEARING HERE ABOVE ALL: this branch exists
		// because ctx was cancelled, so writing through it recorded nothing.
		actx, done := acctCtx(ctx)
		defer done()
		return b.Store.recordBotSpend(actx, b.Model, botKindUndelivered, in, out,
			b.costMicros(in, out))
	}
	id, err := b.Store.Post(ctx, PostInput{
		Chain: c.chain, Court: c.court,
		Moniker: "anon", Body: text,
		IPHash: botIPHash,
	})
	if err != nil {
		// A refused post is not an error worth stopping for: the room may have been
		// frozen between the scan and now, or the phrase may have tripped the
		// duplicate window. The spend still happened and is still recorded.
		/* UNDELIVERED AND NOT A PASS. The model answered, we were billed, and the
		   room refused the message — a court frozen between the scan and the
		   post, or the duplicate rule. Reporting that as "nothing to add" hides
		   the one outcome an operator can actually act on. */
		b.logf("chat bot: post refused in %s/%s: %v", c.chain, c.court, err)
		actx, done := acctCtx(ctx)
		defer done()
		return b.Store.recordBotSpend(actx, b.Model, botKindUndelivered, in, out,
			b.costMicros(in, out))
	}
	/* TELL THE ROOM. Ordered after the post and before the accounting: the
	   readers are what the message is for, and a slow write to bot_replies must
	   not sit between the message landing and anybody seeing it. */
	if b.Wake != nil {
		b.Wake(c.chain, c.court)
	}
	b.logf("chat bot: answered %s/%s as anon (in=%d out=%d)", c.chain, c.court, in, out)
	actx, done := acctCtx(ctx)
	defer done()
	return b.Store.RecordBotReply(actx, c.chain, c.court, id, b.Model,
		in, out, b.costMicros(in, out))
}

// botTrim caps the reply at the room's limit and takes any leading markdown off.
func botTrim(s string) string { return botTrimTo(s, botMaxBody) }

// botTrimTo is the same with the cap named, because a greeting is held to a
// shorter one than an answer — see botGreetMaxChars.
func botTrimTo(s string, limit int) string {
	s = strings.TrimSpace(strings.TrimLeft(s, "#>*- \t"))
	s = strings.Join(strings.Fields(s), " ")
	if len(s) <= limit {
		return s
	}
	// Cut at the last sentence end inside the limit, so a truncated reply reads
	// as finished rather than as having been interrupted.
	cut := s[:limit]
	if i := strings.LastIndexAny(cut, ".!?"); i > limit/2 {
		return cut[:i+1]
	}
	if i := strings.LastIndex(cut, " "); i > 0 {
		return cut[:i]
	}
	return cut
}

// botWaitFor is how long to hold a reply back before sending it, and it is a
// pure function of the reply so that the two halves of what was asked for can be
// checked against each other without a clock.
//
// A GREETING GOES AT A FIXED BEAT and an answer is timed by its length. That is
// not two rules fighting: a greeting is capped to what a greeting is — see
// botGreetMaxChars — so the fixed beat IS the plausible typing time for it,
// while a paragraph still takes the seconds a paragraph takes.
func botWaitFor(text string, greeting bool, cps float64, max time.Duration) time.Duration {
	if greeting {
		return botGreetWithin
	}
	return botDelay(text, cps, max)
}

// botDelay is the read-then-type wait for a reply of this length.
//
// A CONSTANT BEAT PLUS A RATE. The beat is the reading; the rate is the typing.
// Kept as a pure function of the text so it can be checked without a clock.
func botDelay(text string, cps float64, max time.Duration) time.Duration {
	if cps <= 0 {
		cps = BotTypeCPS
	}
	d := botReadPause + time.Duration(float64(len([]rune(text)))/cps*float64(time.Second))
	if max > 0 && d > max {
		return max
	}
	return d
}

// pause sleeps, reporting false if the context ended first.
func (b *Bot) pause(ctx context.Context, d time.Duration) bool {
	if d <= 0 {
		return true
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}

func (b *Bot) cps() float64 {
	if b.TypeCPS > 0 {
		return b.TypeCPS
	}
	return BotTypeCPS
}

func (b *Bot) typeMax() time.Duration {
	if b.TypeMax > 0 {
		return b.TypeMax
	}
	return BotTypeMax
}

func (b *Bot) greetAfter() time.Duration {
	if b.GreetAfter > 0 {
		return b.GreetAfter
	}
	return BotGreetAfter
}

func (b *Bot) costMicros(in, out int64) int64 {
	return (in*b.InPerMTok + out*b.OutPerMTok) / 1_000_000
}

// recordBotSpend files a call that was billed but put no message in a room, and
// the KIND says which of the two that was.
//
// IT USED TO TAKE NEITHER, and both callers therefore landed in the same bucket:
// a PASS and a post the store REFUSED were both reported as "had nothing to
// add". MEASURED — the cross-court duplicate rule refused the third room's
// greeting, and the page called it a pass. See botKindUndelivered.
func (s *Store) recordBotSpend(ctx context.Context, model, kind string, in, out, cost int64) error {
	// NEGATIVE IDS, descending, so these rows cannot collide with a message id and
	// cannot be mistaken for one. BotReplyIDs only ever asks about ids above a
	// watermark, which is never negative, so these are invisible to it — which is
	// right: nothing was said, so there is nothing for the bot to recognise later.
	var low sql.NullInt64
	if err := s.r.QueryRowContext(ctx,
		`SELECT min(msg_id) FROM bot_replies`).Scan(&low); err != nil {
		return err
	}
	id := int64(-1)
	if low.Valid && low.Int64 < 0 {
		id = low.Int64 - 1
	}
	_, err := s.w.ExecContext(ctx,
		`INSERT INTO bot_replies
		   (msg_id, chain, court, model, in_tokens, out_tokens, cost_micros, kind, created_at)
		 VALUES (?,'','',?,?,?,?,?,?)`,
		id, model, in, out, cost, kind, s.Now().Unix())
	return err
}

/*
botFail carries WHICH KIND of nothing came back, so the diagnostics page can

	say something an operator can act on without ever carrying the vendor's own
	words to a public page. The wrapped error is for the log, which is private;
	only Kind reaches the payload.
*/
/* ACCOUNTING OUTLIVES THE THING IT IS ACCOUNTING FOR.
   Every write below records money that has ALREADY been spent, and several of
   them are reached BECAUSE the context was cancelled — a shutdown during the
   typing pause, a cancelled request. Handing that same cancelled context to the
   INSERT meant the write failed and the spend was LOST: MEASURED, a reply
   interrupted at shutdown left in_tokens at 0 for a call that had been billed
   for 80. Silent, and in the direction that understates a bill.
   WithoutCancel keeps the values and drops the cancellation; the timeout is so a
   process that is stopping cannot be held open by a database that is not
   answering. */
func acctCtx(ctx context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
}

type botFail struct {
	Kind string
	Err  error
}

func (e botFail) Error() string { return e.Kind + ": " + e.Err.Error() }
func (e botFail) Unwrap() error { return e.Err }

// ask makes the one call.
func (b *Bot) ask(ctx context.Context, prompt string) (text string, in, out int64, err error) {
	ep := b.Endpoint
	if ep == "" {
		ep = "https://api.anthropic.com/v1/messages"
	}
	payload, err := json.Marshal(botAPIReq{
		Model: b.Model, MaxTokens: 300, System: b.system(),
		Messages: []botAPIMsg{{Role: "user", Content: prompt}},
	})
	if err != nil {
		return "", 0, 0, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, ep, bytes.NewReader(payload))
	if err != nil {
		return "", 0, 0, err
	}
	req.Header.Set("content-type", "application/json")
	req.Header.Set("x-api-key", b.Key)
	req.Header.Set("anthropic-version", "2023-06-01")
	cl := b.HTTP
	if cl == nil {
		cl = &http.Client{Timeout: 45 * time.Second}
	}
	res, err := cl.Do(req)
	if err != nil {
		// No answer at all: a network, a DNS or a timeout. Distinct from a refusal
		// because they send an operator to different places to look.
		return "", 0, 0, botFail{BotFailUnreachable, err}
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return "", 0, 0, botFail{BotFailUnreachable, err}
	}
	if res.StatusCode != http.StatusOK {
		// THE KEY IS NEVER IN AN ERROR. The body may echo request detail, so only
		// the status travels; a log line is a place operators paste from.
		return "", 0, 0, botFail{BotFailRefused,
			fmt.Errorf("model returned %d", res.StatusCode)}
	}
	var parsed botAPIResp
	if err := json.Unmarshal(raw, &parsed); err != nil {
		// An answer that is not the shape we asked for is a refusal in effect:
		// something at the other end is not the API we think it is.
		return "", 0, 0, botFail{BotFailRefused, err}
	}
	var sb strings.Builder
	for _, c := range parsed.Content {
		if c.Type == "text" {
			sb.WriteString(c.Text)
		}
	}
	return sb.String(), parsed.Usage.InputTokens, parsed.Usage.OutputTokens, nil
}

// system builds the prompt, appending the real places this deployment lives.
func (b *Bot) system() string {
	var sb strings.Builder
	sb.WriteString(botSystem)
	if b.Site != "" {
		sb.WriteString("\n\nThis site is " + b.Site + ".")
	}
	if b.Repo != "" {
		sb.WriteString(" Its source is at " + b.Repo + ".")
	}
	if b.ChainDocs != "" {
		sb.WriteString(" gno.land documentation is at " + b.ChainDocs + ".")
	}
	return sb.String()
}
