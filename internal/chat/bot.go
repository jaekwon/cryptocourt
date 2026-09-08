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
	"regexp"
	"runtime/debug"
	"strings"
	"time"
	"unicode"
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
// IT POSTS AS THE CLERK, and it used to post as anon like everybody else. Both
// were the owner's call: anon first, and then, when three readers in a row asked
// the room who they were talking to and got silence, a name — "what do you want
// your name to be? one name" -> clerk. A court's clerk answers procedural
// questions, judges nothing and takes no side, and it reads as a role rather
// than as a person, so nobody has to wonder whether they are talking to one.
// THE NAME IS RESERVED, in the HTTP handler that every human post goes through
// and this one does not: see IsReservedName. It records the id of every message
// it writes, so "was this mine" is a lookup and not a guess — see
// Store.BotReplyIDs.
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
	//
	// NOW TEN SECONDS RATHER THAN THIRTY MINUTES, on the owner's call, and the
	// reasoning above is what changed rather than being abandoned: "an empty
	// room" turned out to be the wrong test for the case that actually matters.
	// The report was somebody typing "is anybody here?" ten seconds after their
	// own previous line — a person alone in a room, talking to themselves,
	// getting silence — and a half-hour window calls that a live conversation.
	// A greeting still cannot interject into one, because ten seconds is about
	// how long a reply that is aimed at somebody takes to arrive.
	// THE BILL IS BOUNDED ELSEWHERE, which is what makes this safe: MinGap still
	// holds the helper to one reply per gap across every room, so a shorter
	// window changes WHICH message gets answered, not how many.
	GreetAfter time.Duration

	// Facts, when set, is how the clerk learns what the room it is in actually
	// contains. Optional: without it the clerk explains mechanics and knows no
	// numbers, which is what it did until now.
	Facts CourtFacts

	// facts caches what Facts answered, per room. Read and written only from the
	// single goroutine that runs the passes, so it needs no lock — see Run.
	facts map[string]botFact

	// Endpoint is overridable so tests can point at a local server. Empty means
	// the real one.
	Endpoint string
}

/*
CourtFacts is the live state the clerk may quote about the room it is in.

	REPORTED TWICE, in the same words: "the clerk doesn't answer anything related
	to the court, like 'how many claims are there in the court?'". Measured, the
	filter ACCEPTED that question — it names the site — so it reached the model,
	which has no data and could only hedge or refuse. The gap was never the
	filter.
	AN INTERFACE DECLARED HERE AND IMPLEMENTED ELSEWHERE. *archive.Chain already
	has this exact method, for backfill, so kourtchat is what puts the two
	together and this package imports nothing new. Declaring the dependency where
	it is USED, rather than importing the media archive from the chat helper, is
	what keeps that edge from existing at all.
	ONE NUMBER, AND THE ONE THAT WAS ASKED FOR. It is also the number the
	directory shows a reader, so the clerk cannot disagree with the page beside
	it. More facts mean more reads on every reply; each should earn its place the
	way this one did.
*/
type CourtFacts interface {
	ClaimCount(ctx context.Context, court string) (uint64, error)
}

type botFact struct {
	n  uint64
	at time.Time
	ok bool
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
	/* HOW FAST IT APPEARS TO TYPE, and it used to be 18 c/s capped at twenty
	   seconds. Reported: "the clerk is a bit too slow" — measured at 14 to 19
	   seconds for a paragraph, which is a long time to watch a chat panel do
	   nothing when you have asked a simple question.
	   35 c/s IS STILL A PERSON, about 420 words a minute: a very fast typist
	   rather than an impossible one, and the point of the delay was only ever
	   that an instant reply reads as a machine. The cap does the real work here —
	   at eight seconds a paragraph lands while the reader is still looking at
	   the room, and the same paragraph used to take the better part of twenty.
	   A GREETING IS UNAFFECTED: it has its own fixed beat, botGreetWithin, and
	   was already arriving in about a second. */
	BotTypeCPS    = 35.0
	BotTypeMax    = 8 * time.Second
	BotGreetAfter = 10 * time.Second

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
	/* AND WHAT IS REFUSED IS NOT THE SAME NUMBER AS WHAT IS ASKED FOR. The model
	   is told UNDER 40 CHARACTERS and mostly obeys; when it misses, it misses by
	   a word, and cutting there is worse than printing the word.
	   MEASURED ON THE LIVE SITE: "Hey! Got questions about how Kourt works?" is
	   41 characters against a limit of 40, and botTrimTo turned it into "Hey! Got
	   questions about how Kourt" — a question chopped before its verb, with no
	   punctuation. A greeting that reads as broken is worse than a greeting one
	   character over budget, and this was the FIRST thing a new reader saw.
	   WHY THE TRIMMER IS NOT THE PLACE TO FIX IT. Its fallback prefers a
	   sentence end past the halfway mark and then a word boundary, and that order
	   is right for the 360-character ANSWER path it also serves: preferring any
	   sentence end would turn a long answer opening with "Hi." into a three-
	   character reply. The greeting is the caller that needs the slack, so the
	   greeting is where the slack belongs.
	   DERIVED, NOT A SECOND LITERAL, so the two can never drift: this is the
	   asked-for length plus one short word. It costs nothing in plausibility
	   because a greeting's delay is the fixed botGreetWithin regardless of
	   length — the "a hundred characters took four and a half seconds" reasoning
	   above stopped applying to greetings when that beat became fixed. */
	/* THE TWO THINGS THE CLERK SAYS WITHOUT ASKING A MODEL. Both are questions
	   with exactly one correct answer, so sampling one would only ever be a way
	   to get it wrong: a helper that says "I'm an AI assistant" one time and
	   "I'm the clerk" the next has no identity at all, and a callout that
	   paraphrases itself reads as another impersonator. Fixed text also costs
	   nothing and cannot be talked into anything by whatever else is in the room.
	   THE WORDS ARE THE OWNER'S: "so say, 'i'm the clerk'" and, for a name-wearer
	   who gets through, "that's not me, i'm me!" — with the follow-up "be snarky
	   when calling out so they don't try again", which is what the second half of
	   that line is for. Dry rather than cruel: the room is a court, the clerk is
	   part of the furniture, and a helper that sneers reads worse than one that is
	   simply unimpressed. It says the thing that actually deters a repeat — that
	   it did not work and is not funny — and then stops. */
	botClerkLine         = "I'm the clerk. Ask me anything about how this site works."
	botImpersonationLine = "That's not me, I'm me! Anyone can type a name in a box — " +
		"nobody's fooled, and it won't be funnier the second time."

	// How long a court's facts are reused, and how long the clerk will wait for
	// them. THE TIMEOUT IS THE IMPORTANT ONE: a node that has gone away must
	// cost a reply two seconds, not the reply itself — the fact is dropped and
	// the answer goes out without it.
	botFactsTTL     = 30 * time.Second
	botFactsTimeout = 2 * time.Second

	botGreetGrace   = 12
	botGreetHardMax = botGreetMaxChars + botGreetGrace
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
	// Facts is optional; see Bot.Facts and CourtFacts.
	Facts CourtFacts
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
		Log:   o.Log,
		Facts: o.Facts,
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
		woke := b.pass(ctx)
		select {
		case <-ctx.Done():
			return
		case <-woke:
			// Something was said. Look now rather than at the next tick.
		case <-t.C:
		}
	}
}

/*
ONE ITERATION, AND A PANIC IN IT MUST NOT END THE SERVICE.

	THERE IS NO OTHER recover IN THIS REPOSITORY and that is deliberate almost
	everywhere: a panic is how a bug gets found, and the realm panics on purpose
	to abort a transaction. This is the exception, and the reason is what shares
	the process. Run is a bare goroutine inside kourtchat, so a panic here does
	not fail the helper — it kills the process that is serving chat to everybody
	and the media archive besides. MEASURED: a misbehaving hook took Run down and
	the panic reached the top of its goroutine.
	THE HELPER IS ALSO THE LEAST TRUSTWORTHY CODE IN THAT PROCESS. It is optional,
	it talks to a third party, and it parses what comes back. Optional decoration
	must not be able to end the thing it decorates.
	NOT SWALLOWED, THOUGH. The stack goes to the log and the pass is counted as a
	failure, so the diagnostics page shows something wrong rather than a helper
	that has quietly stopped answering — and because failures feed the throttle, a
	pass that panics every time is held to one a minute rather than spinning.
*/
func (b *Bot) pass(ctx context.Context) (woke <-chan struct{}) {
	defer func() {
		r := recover()
		if r == nil {
			return
		}
		b.logf("chat bot: PANIC, recovered: %v\n%s", r, debug.Stack())
		actx, done := acctCtx(ctx)
		defer done()
		if err := b.Store.RecordBotFailure(actx, BotFailInternal); err != nil {
			b.logf("chat bot: could not record the panic: %v", err)
		}
	}()
	// RE-SUBSCRIBED EVERY ITERATION, and taken BEFORE the pass rather than
	// after it. The channel is replaced on each fire, so a handle kept across
	// iterations is a handle to a signal that has already gone; and a post
	// landing during the pass must wake the NEXT one rather than being
	// swallowed by a subscription taken afterwards. Same discipline the long
	// poll follows — see pulse.watch.
	if b.Subscribe != nil {
		woke = b.Subscribe()
	}
	if err := b.once(ctx); err != nil && !errors.Is(err, context.Canceled) {
		b.logf("chat bot: %v", err)
	}
	return woke
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

	/* THE THROTTLE IS CHECKED FIRST, AND IT RETURNS. It used to be checked after
	   the scan so that a throttled pass still advanced the watermarks, on the
	   reasoning that "the questions that arrived during the wait would still be
	   waiting when the gap expired and the bot would answer the oldest of them,
	   which is the behaviour MaxAge exists to prevent".
	   THAT COST A REAL READER THEIR FIRST MESSAGE. Measured on the live site: a
	   visitor said "hello?" in the covid room four seconds after the helper had
	   answered somewhere else, and the log has no line for it at all — the scan
	   considered it, could not speak, advanced the watermark past it, and it was
	   never looked at again. Reproduced deliberately in two fresh rooms: a
	   greeting 2.5s after a reply was still unanswered 75 seconds later, which is
	   seven ticks and long past the gap.
	   THE OLD REASONING DEFINED "STALE" TWICE AND THE TWO DISAGREE. MaxAge says
	   stale is ten MINUTES; the drop treated anything older than MinGap as spent,
	   and MinGap on the live site is ten SECONDS. A message the code itself calls
	   fresh for another 9m50s was being discarded as too old to answer.
	   IT ALSO ANSWERS THE NEWEST, NOT THE OLDEST. The loop below keeps the newest
	   candidate across every room and scan keeps the newest within one, so the
	   harm the old comment named cannot happen: after the gap this answers the
	   most recent thing anybody asked, and MaxAge still discards a genuine
	   backlog.
	   THE BILL DOES NOT MOVE. The gap still governs how often it may speak, so
	   this changes WHICH message gets answered — one instead of none — and not
	   how many. A throttled pass now costs a single indexed row lookup and
	   returns.
	   A CALL, NOT A REPLY. See Store.BotLastCallAt: a refused call left no trace
	   the throttle could see, so a broken key called once per incoming message. */
	last, err := b.Store.BotLastCallAt(ctx)
	if err != nil {
		return err
	}
	if !last.IsZero() && now.Sub(last) < b.gap() {
		return nil
	}

	rooms, err := b.Store.ActiveRooms(ctx, now.Add(-b.age()).Unix())
	if err != nil {
		return err
	}

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
	if pick == nil {
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
	// addressed is true when the reader used the clerk's name. It changes what
	// the model is told, not whether it is called: somebody who speaks to you by
	// name is owed an answer whatever they asked about.
	addressed bool
	// says, when set, is the exact line to post — and the signal that no model
	// call is needed at all. See botClerkLine and botImpersonationLine.
	says string
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
		/* SOMEBODY IS WEARING THE CLERK'S NAME. The handler refuses the name, so
		   reaching this branch means either a row that predates the refusal or a
		   spelling Skeleton did not recognise — and the owner asked for both
		   halves: "when somebody impersonates the clerk, don't let it... and, if
		   they succeed anyways, the clerk should say, 'that's not me, i'm me!'".
		   THE CLERK CANNOT ACCUSE ITSELF, and that rests on the `mine[m.ID]` skip
		   a few lines above: its own rows never reach this switch, so anything
		   here that wears the name is not it. The body check is the belt for the
		   one gap in that argument — a reply posted but never recorded in
		   bot_replies, which takes a failed write that logs itself — and it stops
		   a callout from being read as a fresh impersonation and answered again.
		   FIRST, ahead of every other branch: what somebody typed matters less
		   than who they are claiming to be while typing it. */
		case IsReservedName(m.Moniker) && m.Body != botImpersonationLine:
			best = &botCandidate{chain: chain, court: court, body: m.Body, at: at,
				says: botImpersonationLine}
		case botWorthAsking(m.Body):
			best = &botCandidate{chain: chain, court: court, body: m.Body, at: at}
		/* "WHO ARE YOU" IS A QUESTION WITH ONE ANSWER, and for three readers in a
		   row it got silence: botWorthAsking wants a site word ("bot" and
		   "person" are not site words) and botGreeting wants a bare hello, so an
		   identity question fell between them and was dropped without a log line.
		   AFTER botWorthAsking, so "who are you staking with?" stays a question
		   about the site rather than being answered with a name. */
		case botAskingWhoTheClerkIs(m.Body):
			best = &botCandidate{chain: chain, court: court, body: m.Body, at: at,
				says: botClerkLine}
		/* ADDRESSED BY NAME — see botAddressed. After the identity and site-question
		   branches, because "clerk, how do i stake?" is both and either answer
		   would do, and before the greeting branch, because "clerk, hi" is
		   somebody starting a conversation with the clerk rather than with the
		   room. */
		case botAddressed(m.Body):
			best = &botCandidate{chain: chain, court: court, body: m.Body, at: at,
				addressed: true}
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
			// Added with the arithmetic path: both are plainly interrogative, and
			// "how much is 17 * 3" was refused for want of an opening rather than
			// for anything about what it asked.
			"how much is", "how many",
		} {
			if strings.HasPrefix(s, p) || strings.Contains(s, " "+p) {
				asks = true
				break
			}
		}
	}
	// A BARE SUM NEEDS NO QUESTION SHAPE — see botPureSum.
	if botPureSum(s) {
		return true
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
	// ...OR BE A SUM. Reported: "i typed 'what is 2+2' and no bot is answering
	// it. i want it to" — followed by "widen it a little bit" when the first
	// attempt at this dropped the list above altogether.
	return botArithmetic(s)
}

// botPureSum is a message that is nothing but a calculation: "2+2", "17 * 3",
// "(4+5)/3". Worth answering without any interrogative shape at all, because
// there is nothing else it could be asking for — and it is the one way to let a
// bare sum through without letting prose that happens to contain a year range
// buy a call.
func botPureSum(s string) bool {
	if s == "" || len(s) > 40 {
		return false
	}
	return botOnlySum.MatchString(s) && botSumShape.MatchString(s)
}

var botOnlySum = regexp.MustCompile(`^[0-9\s+\-*/x×÷^%().=]+$`)

/*
A SELF-CONTAINED CALCULATION IS THE ONE THING WORTH ANSWERING THAT NAMES

	NOTHING, and it is the whole of the widening — deliberately, because "a
	little bit" is what was asked for and because arithmetic is the safest
	possible exception: it has one right answer, it can be checked by the person
	who asked, and answering it takes no side on anything.
	WHY NOT SIMPLY ANSWER EVERY QUESTION. The first version of this removed the
	site-word list, and a room arguing about virology would then have bought a
	call per question to be told PASS. Worse, the questions in such a room are
	exactly the ones the clerk must not answer: "who really funded the lab?" is
	the subject matter of a claim, and an opinion on it from something that looks
	like part of the site would be quoted as if it meant something.
	DIGIT-OPERATOR-DIGIT, AND SHORT. The pattern alone is not enough: "the
	2021-2022 data" reads as 1-2 to any such matcher, so the bound is what keeps a
	year range in a sentence about the subject matter out. 40 characters holds
	"what is 2+2" and "how much is 17 * 3" and excludes the arguments measured in
	the test beside this.
*/
func botArithmetic(s string) bool {
	if len(s) > 40 {
		return false
	}
	return botSumShape.MatchString(s)
}

// A digit, an operator, a digit — with the spaces people actually type.
var botSumShape = regexp.MustCompile(`[0-9]\s*[-+*/x×÷^%]\s*[0-9]`)

// botGreeting is a bare hello and not much else.
//
// SHORT AND WHOLLY A GREETING, which is what keeps it from firing on "hello, is
// there a way to unstake" — that is a question and botWorthAsking already has
// it. The length bound is the real filter: a greeting is a handful of
// characters, so anything longer is a message that happens to open politely.
/* courtFacts is the line about this room that goes into the prompt, or "" when
   there is nothing trustworthy to say.
   FAILURE IS SILENCE, NOT AN ERROR. A node that is slow, down or answering
   nonsense must not cost the reader their answer — the fact is left out, and
   the standing instruction not to invent numbers is what covers the gap.
   THE FAILURE IS CACHED TOO, which is the half that matters when a node is
   down: without it every reply would wait the whole timeout again.
   PER ROOM AND PER CHAIN, because a court on dev and a court of the same name
   on kourt-1 are different rooms with different numbers. */
func (b *Bot) courtFacts(ctx context.Context, chain, court string) string {
	if b.Facts == nil {
		return ""
	}
	if b.facts == nil {
		b.facts = map[string]botFact{}
	}
	key := chain + "/" + court
	f, hit := b.facts[key]
	if !hit || b.now().Sub(f.at) >= botFactsTTL {
		fctx, cancel := context.WithTimeout(ctx, botFactsTimeout)
		n, err := b.Facts.ClaimCount(fctx, court)
		cancel()
		f = botFact{n: n, at: b.now(), ok: err == nil}
		b.facts[key] = f
		if err != nil {
			b.logf("chat bot: no facts for %s/%s: %v", chain, court, err)
		}
	}
	if !f.ok {
		return ""
	}
	claims := "claims"
	if f.n == 1 {
		claims = "claim"
	}
	return fmt.Sprintf("\n\nLive fact about THIS court, read from the chain just now: "+
		"it has %d %s. That is the same number the court's own page shows, so it is "+
		"not a guess and not something you are inventing: if the reader asked how "+
		"many claims there are, this is the answer. Do not derive any OTHER number "+
		"from it.", f.n, claims)
}

/*
botAddressed is whether a reader used the clerk's name.

	REPORTED: "i asked cleark, why did the chicken cross the road? and it didn't
	say anything". The message was `clerk, why did the chicken cross the road?`
	and the filter refused it — for a reason that reads as a joke once you see it:
	the site-word list has "court", "claim", "docket" and thirty others, and not
	the clerk's own name. Somebody spoke to it directly and it was not listening
	for itself.
	BEING SPOKEN TO IS AN EXPLICIT REQUEST, which is the whole justification for
	answering a question that names nothing about the site. It is also cheap in
	exactly the way "answer everything" was not: a reader has to single the clerk
	out, and MinGap still holds it to one reply per gap across every room.
	ONE SLIPPED LETTER, because the report itself was typed "cleark". Skeleton
	folds lookalikes and would not have caught that — a doubled or missed letter
	is not a homoglyph — so the comparison allows one insertion or deletion, and
	NOT a substitution: see withinOneSlip for why "clark" must not match.
	Tokens under four characters are not considered at all, or "the" and "cle"
	would start conversations.
*/
func botAddressed(body string) bool {
	for _, tok := range strings.FieldsFunc(strings.ToLower(body), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	}) {
		if len(tok) < 4 || len(tok) > len(ClerkName)+2 {
			continue
		}
		if nameSkeleton(tok) == nameSkeleton(ClerkName) || withinOneSlip(tok, ClerkName) {
			return true
		}
	}
	return false
}

/*
withinOneSlip is one INSERTION or one DELETION — and deliberately not a

	substitution, which is the difference between a typo and a different word.
	FOUND BY ITS OWN TEST. The first version allowed any single edit, and "clark
	kent is here" then read as somebody addressing the clerk: Clark is a name
	people have, one substitution from this one. A slipped or doubled letter
	("cleark", "clerkk", "clrk") is a hand missing a key; a swapped vowel is
	usually a different word entirely, and answering it would put the clerk into
	conversations that are not about it.
	Written out rather than imported because it is only ever asked about a
	five-letter word: no matrix, no allocation.
*/
func withinOneSlip(a, b string) bool {
	switch {
	case a == b:
		return true
	case len(a)+1 == len(b):
		return oneInsertion(a, b)
	case len(b)+1 == len(a):
		return oneInsertion(b, a)
	}
	return false
}

// oneInsertion is whether `short` becomes `long` by inserting one byte.
func oneInsertion(short, long string) bool {
	for i := 0; i < len(short); i++ {
		if short[i] != long[i] {
			return short[i:] == long[i+1:]
		}
	}
	return true
}

// botAskingWhoTheClerkIs is somebody asking the room who they are talking to.
//
// THE GAP IT FILLS. botWorthAsking requires a site word, and "bot", "person" and
// "human" are not site words; botGreeting requires a bare hello. So every way of
// asking "are you a bot?" fell between the two and was dropped with no log line
// at all. Measured on the live site: "who are you" and "are you a real person?
// or are you a bot?" both got silence for 45 seconds while "what is kourt?" was
// answered in 17 — and three real readers had already asked.
//
// DELIBERATELY NARROW, like the filters either side of it: a bounded length and
// a list of shapes people actually type, so a paragraph that happens to contain
// "who are you" does not buy a reply. It costs no API call either way — the
// answer is fixed — but a room where the clerk introduces itself every few
// messages would be its own kind of noise.
func botAskingWhoTheClerkIs(body string) bool {
	/* A QUESTION ABOUT THE SITE IS NOT A QUESTION ABOUT ME, and this line is
	   what keeps the predicate honest on its own rather than only in the branch
	   order below. "who are you staking with?" contains the shape "who are you"
	   and is plainly a question about the room — the scan would send it to the
	   model anyway, because botWorthAsking is checked first, but a predicate that
	   claims it is a trap for the next caller. Found by its own test. */
	if botWorthAsking(body) {
		return false
	}
	s := strings.ToLower(strings.TrimSpace(body))
	s = strings.Trim(s, ".!?,;:\u2026 ")
	if s == "" || len(s) > 80 {
		return false
	}
	s = strings.Join(strings.Fields(s), " ")
	for _, shape := range []string{
		"who are you", "who r u", "who is this", "who am i talking to",
		"who are we talking to", "what are you",
		"are you a bot", "are you a robot", "are you an ai", "are you ai",
		"are you human", "are you a human", "are you a person",
		"are you a real person", "are you real", "are you alive",
		"is this a bot", "is this a person", "is this a real person",
		"am i talking to a bot", "am i talking to a person", "bot or human",
		/* "WHAT IS YOUR ROLE" IS THE SAME QUESTION IN POLITE FORM, and the live
		   room is what added these: a reader asked "what is your role in this?"
		   and got nothing, because the shapes above all ask WHAT the clerk is and
		   none of them asks what it is FOR. Measured at the same time: "what do
		   you do here?" and "what is your job?" were refused by every path, while
		   "what are you for?" already matched — the list had one member of the
		   family and not the family.
		   THE APOSTROPHE FORMS ARE SPELLED OUT because normalising does not strip
		   one: "what's your role" and "whats your role" are what people type, and
		   a Contains test sees exactly what it is given. */
		"what is your role", "what's your role", "whats your role",
		"what is your job", "what's your job", "whats your job",
		"what do you do", "what are you here for", "what is your purpose",
		"what's your purpose", "whats your purpose",
	} {
		if strings.Contains(s, shape) {
			return true
		}
	}
	return false
}

// say posts a line the clerk did not have to ask anybody for.
//
// EVERYTHING EXCEPT THE MODEL CALL IS THE SAME as answering a question: the
// typing pause, so it reads as a participant rather than a reflex; the room's
// own Post, so the duplicate rule and a frozen court still apply; the wake, so
// readers see it now; and the reply id, so the clerk never answers itself.
// ZERO TOKENS AND ZERO COST, recorded as such. The row in bot_replies is what
// the throttle reads, so a fixed line still spends the allowance — otherwise
// "who are you" typed ten times would be ten replies — and the accounting stays
// honest about a reply that cost nothing because nothing was bought.
func (b *Bot) say(ctx context.Context, c botCandidate, line string) error {
	if !b.pause(ctx, botWaitFor(line, true, b.cps(), b.typeMax())) {
		return nil // shutting down; better unsaid than said into a dying process
	}
	id, err := b.Store.Post(ctx, PostInput{
		Chain: c.chain, Court: c.court,
		Moniker: ClerkName, Body: line,
		Country: ClerkCountry,
		IPHash:  botIPHash,
	})
	if err != nil {
		b.logf("chat bot: fixed line refused in %s/%s: %v", c.chain, c.court, err)
		return nil
	}
	if b.Wake != nil {
		b.Wake(c.chain, c.court)
	}
	b.logf("chat bot: said a fixed line in %s/%s as %s", c.chain, c.court, ClerkName)
	actx, done := acctCtx(ctx)
	defer done()
	return b.Store.RecordBotReply(actx, c.chain, c.court, id, b.Model, 0, 0, 0)
}

func botGreeting(body string) bool {
	s := strings.ToLower(strings.TrimSpace(body))
	s = strings.Trim(s, ".!?,;:\u2026 ")
	if s == "" || len(s) > 24 {
		return false
	}
	/* A PRESENCE CHECK IS ONE PHRASE WITH EIGHT SPELLINGS, and this list held
	   three of them. Reported by the owner: "i asked 'is anybody here' but no
	   bot responded." The message was `is anybody here?`, and the helper never
	   even considered it \u2014 botWorthAsking refuses it correctly, since a presence
	   check names nothing about this site and must not buy an API call, which
	   left this function as the only path. It matched on equality against a
	   hand-written list carrying "anybody here", "anyone here" and "is anyone
	   here": every combination of {is, ""} x {anyone, anybody} except the one
	   somebody typed. A message both filters refuse is dropped SILENTLY \u2014 the
	   watermark advances and nothing is logged \u2014 so the room simply looked dead.
	   NORMALISED RATHER THAN ENUMERATED. Four more literals would close these
	   four spellings and leave "is there anybody here" open, and the report after
	   that would be another word order. Dropping a leading "is"/"is there" and
	   folding the anybody/anyone synonym collapses the whole family onto the two
	   entries that were already here, which is why "is anyone here" is no longer
	   in the list: it is now the same string as "anyone here".
	   SAFE ONLY BECAUSE A GREETING IS SHORT. "is the docket down" opens
	   identically and is a question, not a greeting \u2014 the 24-character bound
	   above is what separates them, and it is checked before any of this. */
	s = strings.TrimPrefix(s, "is there ")
	s = strings.TrimPrefix(s, "is ")
	s = strings.ReplaceAll(s, "anybody", "anyone")
	for _, g := range []string{
		"hi", "hii", "hey", "heya", "hello", "hallo", "yo", "sup", "gm",
		"good morning", "good evening", "good afternoon", "greetings",
		"anyone here", "anyone around",
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
//
// THE WINDOW IS HALF-OPEN, `> since` rather than `>= since`, and with
// BotGreetAfter down to ten seconds that stopped being a hair-split. A message
// AT the boundary is where the silence starts, not activity inside it: if
// somebody speaks at t and greets at t+10, the room has been silent for ten
// seconds by any reading a person would give the sentence. created_at is stored
// in whole SECONDS, so with a ten-second window "exactly at the edge" is a
// common case rather than a measure-zero one — the reported timeline was
// precisely 10s apart, and under `>=` the change of window would not have
// covered the very report that prompted it.
func (s *Store) roomQuietBefore(ctx context.Context, chain, court string, id, since int64) (bool, error) {
	var n int
	err := s.r.QueryRowContext(ctx,
		`SELECT count(*) FROM messages
		  WHERE chain=? AND court=? AND id<>? AND created_at>? AND hidden=0
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

STAKING HERE IS NO-LOSS, and this is the one thing readers assume wrongly. A
staker on the side that loses withdraws their stake IN FULL — one times what
they put in. Winners are paid in newly minted court coin, weighted by conviction
(stake multiplied by the time it was held) and by an adjudicated quality tier.
Nobody is paid out of the other side's stake and no value moves between the two
sides at all. Real money (GNOT) enters once, when buying a court's coin, and is
burned; it never leaves. If somebody asks whether being wrong costs them their
stake, the answer is no.

Answer the question you are given. Questions about how this site or this system
works matter most and are why you are here, but a plain question with a plain
answer gets one too, even when it has nothing to do with courts: "what is 2+2"
is answered, not refused. In one short paragraph, under 300 characters, plain
and concrete. No greeting, no sign-off, no emoji, no markdown headings.

NEVER TAKE A SIDE ON A CLAIM. The rooms you are in exist to settle questions of
fact by staking and voting, and your opinion on one is worth nothing there and
would be quoted as if it were worth something.

If the message is not a question you can answer straight — if it is argument
about the subject matter of a claim, small talk, abuse, or something you would
have to guess at — reply with exactly: PASS

Do not invent features, URLs, fees, numbers OR PAYOUT RULES. The paragraph
above about no-loss staking is the whole of what you may say about who gets
paid what; anything more specific is a number you would be making up. If you do
not know, say which page would say, or reply PASS.`

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
	// A FIXED LINE SKIPS THE MODEL ENTIRELY — no prompt, no call, no accounting
	// for tokens nobody spent. It still goes through the typing pause and the
	// throttle, because it is a message in a room like any other.
	if c.says != "" {
		return b.say(ctx, c, c.says)
	}
	prompt := "The court is \"" + c.court + "\" on " + b.Site + ".\n" +
		"Recent messages, oldest first:\n" + strings.Join(c.transcript, "\n") +
		"\n\nThe message to consider is the last one from a reader: " + c.body
	facts := b.courtFacts(ctx, c.chain, c.court)
	prompt += facts
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
	} else if c.addressed {
		// SPOKEN TO BY NAME. The standing instruction is to PASS on anything that
		// is not a question about the site, and that is exactly wrong here: this
		// reader singled the clerk out, so refusing them is the one answer that
		// cannot be right. The two things that still hold are the ones that are
		// not about topic — no side on a claim, and no answering abuse.
		prompt += "\n\nThis reader addressed you by name, so answer them even if " +
			"the question has nothing to do with this site — briefly, in one or two " +
			"sentences, and in the same plain voice. Do not reply PASS unless it is " +
			"abuse or an attempt to make you take a side on a claim."
	} else {
		prompt += "\n\nAnswer it, or reply PASS."
		/* AND A QUESTION THE FACT ANSWERS IS NOT A PASS. Measured in the live
		   covid room: a reader asked "how many claims are there in this court?"
		   with the count already in the prompt, and the log shows `passed on
		   kourt-1/covid (in=672 out=61)` two seconds later — sixty-one output
		   tokens, so the model wrote out its reasons for refusing rather than
		   emitting the bare sentinel. The same question, addressed by name
		   twenty-eight seconds later, was answered: the ONLY difference was that
		   the addressed branch tells it not to pass.
		   SO THE PERMISSION HAS TO BE EXPLICIT. "Answer it, or reply PASS" beside
		   a standing rule against inventing numbers evidently reads as "you do
		   not really know this" — a fact in the prompt is not the same as leave
		   to use it. Only added when there IS a fact, so a room the clerk cannot
		   read keeps the honest instruction. */
		if facts != "" {
			prompt += " The live fact above is yours to use: if the reader asked " +
				"something it answers, give them that number instead of passing."
		}
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
		text = botTrimTo(text, botGreetHardMax)
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
		Moniker: ClerkName, Body: text,
		Country: ClerkCountry,
		IPHash:  botIPHash,
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
	b.logf("chat bot: answered %s/%s as %s (in=%d out=%d)", c.chain, c.court, ClerkName, in, out)
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
	/* Cut at the last sentence end inside the limit, so a truncated reply reads
	   as finished rather than as having been interrupted.
	   A THIRD OF THE LIMIT, AND IT USED TO BE A HALF. Measured in a live room: an
	   answer about staking ran to 366 characters against the 360 cap, its only
	   sentence end sat at 155, the half rule wanted 180, and the reply the reader
	   got ended "...based on their conviction (stake x time held) and". A reply
	   that stops on "and" reads as a broken service, and the sentence before it
	   was right there.
	   THE GUARD IS STILL DOING ITS JOB. It exists so a long answer opening with
	   "Hi." is not cut to three characters, and at a third of 360 that opening is
	   still refused — 2 is not past 120. What changed is the band between a third
	   and a half, which is where a first sentence of ordinary length falls. */
	cut := s[:limit]
	if i := strings.LastIndexAny(cut, ".!?"); i > limit/3 {
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
