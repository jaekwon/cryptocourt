package chat

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// ---- the local filter, which is what stands between this and a bill ---------

func TestBotWorthAskingTakesSiteQuestionsAndNothingElse(t *testing.T) {
	yes := []string{
		"how do i stake on a claim?",
		"What does settled YES mean?",
		"how does voting work",
		"where is the docket?",
		"anyone know how to connect a wallet?",
		"is there a way to unstake before it settles?",
		"what is CC and how is it different from gnot?",
		/* AND A SUM, which names nothing about the site. Asked for: "i typed
		   'what is 2+2' and no bot is answering it. i want it to", then "widen it
		   a little bit" — so arithmetic is the whole exception and not a general
		   licence. It is the safest one available: one right answer, checkable by
		   whoever asked, and no side taken on anything. */
		"what is 2+2",
		"what is 2 + 2?",
		"how much is 17 * 3",
		"what is 10/2",
	}
	for _, s := range yes {
		if !botWorthAsking(s) {
			t.Errorf("should have been worth asking: %q", s)
		}
	}
	// THE EXPENSIVE MISTAKE IS THE FALSE POSITIVE. Each of these is a question,
	// or reads like one, and none of them is a question about this site — so a
	// filter that fired on them would spend money to be off-topic in a room
	// about virology.
	no := []string{
		"who really funded the lab?",             // subject matter, not the site
		"why does nobody believe the 2021 data?", // argument
		"what time is it in tokyo?",              // unrelated
		"hello",                                  // greeting, handled elsewhere
		"the map shows seven claims",             // site words, no question
		"staking is a scam",                      // site words, no question
		"",                                       // nothing
		strings.Repeat("how do i stake? ", 60),   // a wall of text
		/* AND THE ARITHMETIC PATH MUST NOT SWALLOW AN ARGUMENT. A year range
		   reads as digit-hyphen-digit to any such matcher, so the length bound is
		   what keeps a sentence about the subject matter out — this is the case
		   that decided the bound, not a round number. */
		"why does nobody believe the 2021-2022 data?",
		"was the 1918 flu worse than the 2009 one?",
	}
	for _, s := range no {
		if botWorthAsking(s) {
			t.Errorf("should NOT have been worth asking: %q", s)
		}
	}
}

// THE LOOP IS CLOSED BY SHAPE AS WELL AS BY ID, and this is the shape half: a
// reply the bot writes must never satisfy the filter that would make it answer
// again. Asserted on the kind of sentence it actually produces — declarative,
// no question mark — because the id table is the belt and this is the brace.
func TestBotDoesNotFindItsOwnAnswersWorthAnswering(t *testing.T) {
	for _, s := range []string{
		"Stake from the claim page: open a claim and use the YES or NO button.",
		"A claim settles when the answer stands through the settling window.",
		"The map is at the top of a court page; each box is a claim.",
		"Sets are headings the court votes into existence.",
	} {
		if botWorthAsking(s) {
			t.Errorf("the bot's own answer would trigger it: %q", s)
		}
		if botGreeting(s) {
			t.Errorf("the bot's own answer read as a greeting: %q", s)
		}
	}
}

// A PRESENCE CHECK IS ONE PHRASE WITH EIGHT SPELLINGS, and the list had three.
// Reported by the owner: "i asked 'is anybody here' but no bot responded." The
// message was `is anybody here?` and the helper never even considered it — no
// log line, because a message the local filters both refuse is dropped
// silently. botWorthAsking refuses it correctly (a presence check names nothing
// about the site, so it must not buy an API call), which leaves botGreeting as
// the only path, and botGreeting matched on `s == g` against a hand-written
// list holding "anybody here", "anyone here" and "is anyone here" — every
// combination of {is, ""} x {anyone, anybody} EXCEPT the one that was typed.
//
// A LIST OF LITERALS CANNOT BE THE FIX. Four more entries would close these
// four spellings and leave "is there anybody here" open, and the next report
// would be another word order. The eight collapse to two by normalising the
// leading "is"/"is there" and the anybody/anyone synonym, so this table is the
// FAMILY rather than a sample of it — and each row below is a spelling a person
// actually types.
func TestBotGreetingCoversEveryPresenceSpelling(t *testing.T) {
	for _, s := range []string{
		"is anybody here?", "is anybody here", "is anyone here?", "anybody here?",
		"anyone here?", "is there anybody here?", "is there anyone here?",
		"anybody around?", "is anyone around?", "IS ANYBODY HERE?", " is anybody here ",
		"is anybody", "is anyone",
	} {
		if !botGreeting(s) {
			t.Errorf("a presence check must read as a greeting: %q", s)
		}
	}
	// AND THE NORMALISING MUST NOT SWALLOW A REAL SENTENCE. Stripping a leading
	// "is" is only safe because a greeting is short; these open the same way and
	// are not greetings, so they check the bound is still doing its job.
	for _, s := range []string{
		"is the docket down?", "is staking live yet?", "is this thing broken",
		"is there a way to unstake",
	} {
		if botGreeting(s) {
			t.Errorf("not a greeting, it asks something: %q", s)
		}
	}
}

func TestBotGreetingIsABareHelloAndNotAnOpening(t *testing.T) {
	for _, s := range []string{"hi", "Hello", "hey!", "HELLO?", "gm", "yo",
		"good morning", "anyone here?", "howdy", " hi "} {
		if !botGreeting(s) {
			t.Errorf("should have been a greeting: %q", s)
		}
	}
	// A MESSAGE THAT MERELY OPENS POLITELY IS NOT A GREETING. It has a question
	// in it, and botWorthAsking is the path for that — treating it as a greeting
	// would answer "hello there!" to somebody who asked how to stake.
	for _, s := range []string{
		"hello, how do i stake?",
		"hi everyone, is the docket down?",
		"hey does anyone know what CC is",
		"",
		"hello hello hello hello hello hello",
	} {
		if botGreeting(s) {
			t.Errorf("should NOT have been a greeting: %q", s)
		}
	}
}

// ---- the wait, which is what makes it read as a participant -----------------

func TestBotDelayGrowsWithTheReplyAndIsCapped(t *testing.T) {
	short := botDelay("hi there", 18, BotTypeMax)
	long := botDelay(strings.Repeat("a", 300), 18, BotTypeMax)
	if short < botReadPause {
		t.Fatalf("even a short reply waits to be read: %s", short)
	}
	if long <= short {
		t.Fatalf("a long reply must take longer: short=%s long=%s", short, long)
	}
	/* AS IF A FAST TYPER WROTE IT, and the numbers moved when the owner said "the
	   clerk is a bit too slow": 300 characters at 35 c/s is about 8.6 seconds,
	   which the cap trims to 8. So the assertion is no longer "about seventeen
	   seconds" — it is that the delay is REAL TIME and no more than the cap. A
	   floor of four seconds still fails a build where the wait became a token
	   gesture, which is what this arm was written for. */
	if long < 4*time.Second || long > BotTypeMax {
		t.Fatalf("300 characters should take real time up to the cap, got %s", long)
	}
	if capped := botDelay(strings.Repeat("a", 100000), 18, BotTypeMax); capped != BotTypeMax {
		t.Fatalf("the wait must be capped, got %s", capped)
	}
	// Measured in RUNES, not bytes: a reply in a script with multi-byte
	// characters is not slower to type than the same number of Latin letters.
	if botDelay(strings.Repeat("é", 50), 18, BotTypeMax) !=
		botDelay(strings.Repeat("e", 50), 18, BotTypeMax) {
		t.Fatal("the wait must count characters, not bytes")
	}
}

/*
A GREETING ARRIVES IN ABOUT A SECOND, and a paragraph does not.

	BOTH WERE ASKED FOR and the first version honoured only the second: the model
	was told "one short line, under 100 characters", produced 60 to 64, and the
	typing model therefore held it back 4.3 to 4.4 seconds — MEASURED — against
	the ~1s that was asked for. A greeting that takes four and a half seconds has
	missed the moment it was answering.
	THE LENGTH IS WHAT RECONCILES THEM. Hold a greeting to what a greeting is and
	a fixed beat becomes its plausible typing time rather than an exception.
*/
func TestAGreetingArrivesInAboutASecondAndAnAnswerTakesItsTime(t *testing.T) {
	// The instruction the model is given, and the length it actually returns.
	long := "Hi — ask away if you have a question about how the site works."
	if got := botTrimTo(long, botGreetMaxChars); len(got) > botGreetMaxChars {
		t.Errorf("a greeting reply must be held to %d chars, got %d: %q",
			botGreetMaxChars, len(got), got)
	}
	// ...AND IT IS STILL A SENTENCE. A cap that cuts mid-word reads as a fault.
	if got := botTrimTo(long, botGreetMaxChars); strings.HasSuffix(got, " ") || got == "" {
		t.Errorf("the trimmed greeting is not presentable: %q", got)
	}

	greet := botWaitFor("hey, what would you like to know?", true, BotTypeCPS, BotTypeMax)
	if greet > 2*time.Second {
		t.Errorf("a greeting must arrive in about a second, got %s", greet)
	}
	if greet < 500*time.Millisecond {
		t.Errorf("...but not in the same instant it was posted, got %s", greet)
	}
	// EVEN IF THE MODEL OVERRUNS. The beat is fixed, and the cap above is what
	// keeps that from being implausibly fast for what is actually sent.
	if over := botWaitFor(strings.Repeat("x", 400), true, BotTypeCPS, BotTypeMax); over != greet {
		t.Errorf("the greeting beat must not depend on the model's length: %s vs %s", over, greet)
	}

	// AND THE OTHER HALF MUST NOT HAVE BEEN LOST. A paragraph still takes the
	// seconds a paragraph takes, which is the thing that stops an answer reading
	// as a machine.
	answer := botWaitFor(strings.Repeat("x", 150), false, BotTypeCPS, BotTypeMax)
	if answer < 5*time.Second {
		t.Errorf("a 150-character answer should take real time, got %s", answer)
	}
	if answer <= greet {
		t.Errorf("an answer must take longer than a greeting: %s vs %s", answer, greet)
	}
}

/*
THE CONSTRUCTOR CONNECTS THE HELPER, and this drives the hooks rather than

	reading them.
	WHAT THIS REPLACES. Wake and Subscribe are optional fields, so the one real
	caller forgetting either is a fault nothing fails on — and Wake WAS missing
	for a while, at a cost of replies the bot wrote in 3ms that readers did not
	see for up to twenty seconds. The bot's own tests passed throughout, because
	they set the fields themselves. The command has no seam a test can call, so
	the guard was a check that read main.go's TEXT, which could only show the line
	was written. Here the wiring is in a function, and these arms USE it.
*/
func TestNewBotIsConnectedToTheServerItSpeaksThrough(t *testing.T) {
	srv, s, _ := newServer(t)
	opts := BotOptions{Enabled: true, Model: "m", MinGap: time.Minute,
		Chains: map[string]bool{"dev": true}}

	if b := NewBot(s, srv, "", opts); b != nil {
		t.Error("no key means no helper")
	}
	off := opts
	off.Enabled = false
	if b := NewBot(s, srv, "sk-ant-key-000000", off); b != nil {
		t.Error("a key lying in the database is not a request to spend it")
	}

	b := NewBot(s, srv, "sk-ant-key-000000", opts)
	if b == nil {
		t.Fatal("a flag and a key should give a helper")
	}
	if b.Wake == nil || b.Subscribe == nil {
		t.Fatal("the constructor exists to attach these")
	}

	/* THE WAKE ACTUALLY WAKES A WAITER ON THAT SERVER. Non-nil is not the
	   property that matters — a function that points at the wrong pulse, or at a
	   different server, is non-nil too. So a real poll is held and the hook the
	   bot was handed is the thing that releases it. */
	if _, err := post(t, s, "orem", "ip-a", "something to poll past"); err != nil {
		t.Fatal(err)
	}
	msgs, _ := s.Recent(context.Background(), "dev", "orem", 0, 50)
	top := msgs[len(msgs)-1].ID

	ts := httptest.NewServer(srv.Routes())
	defer ts.Close()
	const wait = 4 * time.Second
	held := make(chan time.Duration, 1)
	go func() {
		t0 := time.Now()
		r, err := http.Get(fmt.Sprintf("%s/api/chat/dev/orem?wait=%d&seen=%d",
			ts.URL, int(wait.Seconds()), top))
		if err == nil {
			io.Copy(io.Discard, r.Body)
			r.Body.Close()
		}
		held <- time.Since(t0)
	}()
	time.Sleep(250 * time.Millisecond) // let it settle into the wait

	b.Wake("dev", "orem")
	if took := <-held; took > wait/2 {
		t.Errorf("the wake the constructor attached did not release a waiter: "+
			"%s against a %s poll", took.Round(time.Millisecond), wait)
	}

	/* AND THE SUBSCRIBE FIRES WHEN SOMETHING IS SAID. Same argument: a channel
	   from the wrong pulse would satisfy a nil check and never close. */
	ch := b.Subscribe()
	srv.Wake("dev", "ledger") // any room: the signal it hands back is the global one
	select {
	case <-ch:
	case <-time.After(2 * time.Second):
		t.Error("the subscription the constructor attached never fired")
	}
}

/*
A POST WAKES THE RUNNING HELPER, which is what makes "about a second" true of

	anything a reader experiences.
	THE TICK IS SET TO AN HOUR ON PURPOSE. That is the whole design of this test:
	if a reply arrives, the WAKE delivered it, because nothing else could have.
	Before the observer channel existed this timed out — an ordinary post fired
	the court's own channel and left the global one alone, the subscription never
	fired, and the helper waited for its tick. MEASURED: 1.22s after the post.
*/
func TestAPostWakesTheRunningHelper(t *testing.T) {
	srv, s, _ := newServer(t)
	m := &fakeModel{reply: "hey — what would you like to know?", in: 50, out: 10}
	b := NewBot(s, srv, "sk-ant-key-000000", BotOptions{
		Enabled: true, Model: "m", MinGap: time.Minute,
		Chains: map[string]bool{"dev": true},
	})
	if b == nil {
		t.Fatal("expected a helper")
	}
	b.Endpoint = m.server(t).URL
	b.GreetAfter = 30 * time.Minute
	b.Tick = time.Hour

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go b.Run(ctx)
	time.Sleep(200 * time.Millisecond) // let Run take its first subscription

	t0 := time.Now()
	if _, err := post(t, s, "orem", "ip-reader", "hi"); err != nil {
		t.Fatal(err)
	}
	srv.Wake("dev", "orem") // exactly what the HTTP handler does after a post

	for i := 0; i < 60; i++ {
		msgs, _ := s.Recent(ctx, "dev", "orem", 0, 50)
		if len(msgs) > 1 {
			if msgs[len(msgs)-1].Moniker != ClerkName {
				t.Fatalf("the reply is not the helper's: %+v", msgs)
			}
			if took := time.Since(t0); took > 4*time.Second {
				t.Errorf("woken, but slowly: %s", took.Round(time.Millisecond))
			}
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("no reply in six seconds, with a one-hour tick: the post did not wake it")
}

/*
A PANIC IN THE HELPER MUST NOT END THE SERVICE.

	MEASURED before the guard: a misbehaving hook took Run down and the panic
	reached the top of its goroutine. In production Run IS a bare goroutine inside
	kourtchat, so that is not a failed helper — it is the process serving chat to
	everybody, and the media archive besides, gone. Optional decoration must not
	be able to end the thing it decorates.
	Subscribe is the injection point because it is a hook the helper calls on
	every iteration, so a bad one is a realistic fault rather than a contrived
	one.
*/
func TestAPanicInTheHelperDoesNotEndTheService(t *testing.T) {
	s, _ := newStore(t)
	m := &fakeModel{reply: "PASS", in: 1, out: 1}
	b := newBot(t, s, m)
	b.Tick = 40 * time.Millisecond
	var hits int64
	b.Subscribe = func() <-chan struct{} {
		atomic.AddInt64(&hits, 1)
		panic("a hook went wrong")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 400*time.Millisecond)
	defer cancel()
	escaped := make(chan any, 1)
	go func() {
		defer func() { escaped <- recover() }()
		b.Run(ctx)
	}()

	select {
	case r := <-escaped:
		if r != nil {
			t.Fatalf("the panic escaped Run and would kill kourtchat: %v", r)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Run neither returned nor panicked")
	}
	// IT KEPT GOING, rather than being contained by returning. A guard that
	// caught the panic and then stopped looping would satisfy the check above
	// while leaving a helper that is permanently silent.
	if n := atomic.LoadInt64(&hits); n < 2 {
		t.Errorf("the loop should have carried on past the panic, got %d passes", n)
	}

	/* AND IT IS NOT SWALLOWED. A panic nobody can see is worse than a crash: the
	   crash at least gets noticed. It is counted as a failure, which is what puts
	   it on the diagnostics page, and classed "internal" — this code broke, not
	   the vendor, which is a different thing to go and look at. */
	st, err := s.BotStats(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if st.Failures < 1 {
		t.Errorf("a recovered panic must still be counted: %+v", st)
	}
	if st.FailKind != BotFailInternal {
		t.Errorf("a panic is our fault, not the vendor's: %q", st.FailKind)
	}
}

// ---- the key: write-once, and never readable -------------------------------

func TestBotKeyIsWriteOnceAndNeverReadBack(t *testing.T) {
	s, _ := newStore(t)
	if set, err := s.BotKeySet(); err != nil || set {
		t.Fatalf("a fresh database has no key: set=%v err=%v", set, err)
	}
	first, err := s.SetBotKeyOnce("sk-ant-first-key-000000000000")
	if err != nil || !first {
		t.Fatalf("the first set must take: first=%v err=%v", first, err)
	}
	// THE SECOND CALLER LOSES AND THE KEY DOES NOT MOVE. This is the whole
	// protection the design has: a form that could be re-submitted could
	// redirect the spending onto somebody else's account after the fact.
	second, err := s.SetBotKeyOnce("sk-ant-second-key-11111111111")
	if err != nil {
		t.Fatal(err)
	}
	if second {
		t.Fatal("a second set reported success")
	}
	got, ok, err := s.BotKey()
	if err != nil || !ok {
		t.Fatal(err)
	}
	if got != "sk-ant-first-key-000000000000" {
		t.Fatalf("the key was replaced: %q", got)
	}
}

// ---- the bot end to end, against a fake model ------------------------------

// fakeModel stands in for the API. It records what it was asked and answers
// with whatever the test set.
type fakeModel struct {
	reply  string
	in     int64
	out    int64
	calls  int
	prompt string
	system string
}

func (f *fakeModel) server(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req botAPIReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("bad request to the model: %v", err)
		}
		f.calls++
		f.system = req.System
		if len(req.Messages) > 0 {
			f.prompt = req.Messages[0].Content
		}
		// The key must reach the vendor and nowhere else; asserted here because
		// this is the only place that sees the outbound request.
		if r.Header.Get("x-api-key") == "" {
			t.Error("the request carried no key")
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]any{
			"content": []map[string]any{{"type": "text", "text": f.reply}},
			"usage":   map[string]any{"input_tokens": f.in, "output_tokens": f.out},
		})
	}))
}

func newBot(t *testing.T, s *Store, m *fakeModel) *Bot {
	t.Helper()
	srv := m.server(t)
	t.Cleanup(srv.Close)
	return &Bot{
		Store: s, Key: "sk-ant-test-key-0000000000", Model: "test-model",
		Endpoint: srv.URL, Chains: map[string]bool{"dev": true},
		Site: "kourt.xyz", Repo: "github.com/jaekwon/cryptocourt",
		ChainDocs: "docs.gno.land",
		InPerMTok: 1_000_000, OutPerMTok: 5_000_000,
		// No wait in tests: the delay is covered by TestBotDelay... as arithmetic,
		// and a test that actually slept would be a slow test asserting a clock.
		TypeCPS: 1e9, TypeMax: time.Nanosecond,
	}
}

func TestBotAnswersASiteQuestionAsTheClerkAndRecordsWhatItSpent(t *testing.T) {
	s, _ := newStore(t)
	ctx := context.Background()
	m := &fakeModel{reply: "Open the claim page and use the YES or NO button to stake.", in: 900, out: 30}
	b := newBot(t, s, m)

	if _, err := post(t, s, "orem", "ip-reader", "how do i stake on a claim?"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if m.calls != 1 {
		t.Fatalf("expected one model call, got %d", m.calls)
	}

	msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 2 {
		t.Fatalf("expected the question and one answer, got %d", len(msgs))
	}
	reply := msgs[len(msgs)-1]
	// AS anon, LIKE EVERYBODY ELSE. Asked for, and the reason the bot cannot know
	// itself by name.
	if reply.Country != ClerkCountry {
		t.Errorf("an answered question must fly the clerk's flag too, got %q", reply.Country)
	}
	if reply.Moniker != ClerkName {
		t.Errorf("the bot must post as the clerk, got %q", reply.Moniker)
	}
	if !strings.Contains(reply.Body, "YES or NO") {
		t.Errorf("the answer did not reach the room: %q", reply.Body)
	}

	// ...AND IT KNOWS THAT ROW IS ITS OWN, by id.
	mine, err := s.BotReplyIDs(ctx, "dev", "orem", 0)
	if err != nil {
		t.Fatal(err)
	}
	if !mine[reply.ID] {
		t.Errorf("the bot did not record its own message id %d", reply.ID)
	}

	st, err := s.BotStats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.Replies != 1 || st.InTokens != 900 || st.OutTokens != 30 {
		t.Errorf("accounting is wrong: %+v", st)
	}
	if st.Passes != 0 {
		t.Errorf("it answered, so nothing was passed on: %+v", st)
	}
	if st.LastAt == 0 {
		t.Errorf("it spoke, so there is a last-spoke time: %+v", st)
	}
	// 900 in at $1/Mtok and 30 out at $5/Mtok = 900 + 150 = 1050 micro-dollars.
	if st.CostMicros != 1050 {
		t.Errorf("cost should be 1050 micro-dollars, got %d", st.CostMicros)
	}
	if st.Model != "test-model" {
		t.Errorf("the model should be reported: %q", st.Model)
	}

	// THE CONTEXT IT WAS GIVEN. The whole point of the prompt is that it can
	// point at real places instead of inventing them.
	for _, want := range []string{"kourt.xyz", "cryptocourt", "gno.land"} {
		if !strings.Contains(m.system, want) {
			t.Errorf("the system prompt never mentioned %q", want)
		}
	}
}

func TestBotPassesWithoutSpeakingAndTheSpendIsStillCounted(t *testing.T) {
	s, _ := newStore(t)
	ctx := context.Background()
	m := &fakeModel{reply: "PASS", in: 700, out: 3}
	b := newBot(t, s, m)

	if _, err := post(t, s, "orem", "ip-reader", "is staking a scam or how does it work?"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	msgs, _ := s.Recent(ctx, "dev", "orem", 0, 50)
	if len(msgs) != 1 {
		t.Fatalf("a PASS must not post: %d messages", len(msgs))
	}
	// A PASS IS STILL CHARGED FOR THE INPUT, so a page that showed only
	// successful replies would understate the bill. Counted, with no reply.
	st, _ := s.BotStats(ctx)
	if st.InTokens != 700 {
		t.Errorf("the input spend was not recorded: %+v", st)
	}
	if st.CostMicros != 715 {
		t.Errorf("cost should be 700 + 15 = 715, got %d", st.CostMicros)
	}
	/* ...AND IT IS NOT AN ANSWER. This is the arm that was missing, and its
	   absence shipped a page reporting "3 replies" for a bot that had never
	   posted — MEASURED: three human messages, three PASSes, three replies
	   reported. bot_replies holds a row per CALL because a call that said
	   nothing was still charged, so the count of answers has to ask for the
	   rows attached to a message. */
	if st.Replies != 0 {
		t.Errorf("a PASS is not a reply, got Replies=%d", st.Replies)
	}
	if st.Passes != 1 {
		t.Errorf("a PASS should be counted as one, got Passes=%d", st.Passes)
	}
	if st.LastAt != 0 {
		t.Errorf("the bot never spoke, so there is no last-spoke time: %d", st.LastAt)
	}
}

func TestBotSpeaksOncePerGapAcrossEveryRoom(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	m := &fakeModel{reply: "Open a claim from the docket to stake on it.", in: 100, out: 10}
	b := newBot(t, s, m)
	b.MinGap = time.Minute

	if _, err := post(t, s, "orem", "ip-a", "how do i stake?"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}

	// A SECOND QUESTION, IN A DIFFERENT ROOM, INSIDE THE GAP. The throttle is
	// global on purpose: two rooms are not two allowances.
	*clock = clock.Add(5 * time.Second)
	if _, err := post(t, s, "ledger", "ip-b", "how does voting work?"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.Recent(ctx, "dev", "ledger", 0, 50); len(got) != 1 {
		t.Fatalf("the bot spoke twice inside its gap: %d messages in the second room", len(got))
	}

	/* PAST THE GAP IT MAY SPEAK AGAIN, and it answers the NEWEST thing waiting.
	   This used to say the throttled question "has been consumed by the
	   watermark, which is deliberate: a question that waited out the throttle is
	   stale, and MaxAge says so" — and that cost a real reader their first
	   message on the live site. MinGap there is ten seconds and MaxAge is ten
	   minutes, so the drop was calling a message stale that the code itself
	   considered fresh for another nine and a half. A throttled pass now returns
	   without consuming; see Bot.once.
	   THE COUNT IS THE SAME EITHER WAY — two questions and one answer — because
	   this pass answers the newest of the two rather than nothing, so the arm
	   below is not what distinguished the behaviours. The prompt is: it names the
	   message being answered, and the next assertion pins that it is the newer
	   one. TestAMessageArrivingInsideTheGapIsAnsweredAfterIt covers the case that
	   was silently dropped. */
	*clock = clock.Add(2 * time.Minute)
	if _, err := post(t, s, "ledger", "ip-b", "what does settled NO mean?"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.Recent(ctx, "dev", "ledger", 0, 50); len(got) != 3 {
		t.Fatalf("expected two questions and one answer, got %d", len(got))
	}
	if !strings.Contains(m.prompt, "what does settled NO mean?") {
		t.Errorf("it should answer the NEWEST question waiting, not the older one")
	}
}

/*
A MESSAGE THAT ARRIVES INSIDE THE GAP IS ANSWERED AFTER IT, not dropped.

	THE REPORT: a visitor said "hello?" in the covid room four seconds after the
	helper had answered somewhere else, and the log has no line for it at all —
	the scan considered it, could not speak, advanced the watermark past it, and
	nothing ever looked at it again. Reproduced live in two fresh rooms: a
	greeting 2.5s after a reply was still unanswered 75 seconds later.
	THE SHAPE IS THE REPORTED ONE: a reply somewhere else spends the allowance,
	the newcomer's greeting lands inside the gap, and the pass that follows the
	gap must pick it up. A greeting rather than a question, because a greeting is
	what a new reader actually sends and it is the one message whose whole value
	is that somebody answers it.
*/
func TestAMessageArrivingInsideTheGapIsAnsweredAfterIt(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	m := &fakeModel{reply: "Hey! Ask away.", in: 60, out: 8}
	b := newBot(t, s, m)
	b.MinGap = time.Minute

	// Somewhere else spends the allowance.
	if _, err := post(t, s, "orem", "ip-a", "how do i stake?"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if m.calls != 1 {
		t.Fatalf("the first question should have been answered (%d calls)", m.calls)
	}

	// The newcomer arrives five seconds later, in a room of their own.
	*clock = clock.Add(5 * time.Second)
	if _, err := post(t, s, "ledger", "ip-new", "hello?"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if m.calls != 1 {
		t.Fatalf("the gap should have held this pass back (%d calls)", m.calls)
	}

	// AND THE PASS AFTER THE GAP MUST FIND IT. Nothing new is posted here: the
	// only thing left to answer is the greeting that was already looked at once.
	*clock = clock.Add(2 * time.Minute)
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if m.calls != 2 {
		t.Fatalf("the newcomer's greeting was dropped for good (%d calls)", m.calls)
	}
	got, err := s.Recent(ctx, "dev", "ledger", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[1].Moniker != ClerkName {
		t.Fatalf("the greeting should have been answered in its own room: %+v", got)
	}
}

/*
A CALL THE VENDOR REFUSED STILL COUNTS AGAINST THE THROTTLE.

	MEASURED with a broken key: ten messages arriving in a room produced TEN calls
	over thirty seconds of clock, and the one-per-minute throttle held back none of
	them — because it read bot_replies, which only holds calls that produced
	something. Every message posted anywhere wakes this bot, so a revoked key made
	it an unthrottled loop against somebody else's API. After: one call.
	ONE A MINUTE IS THE RIGHT STEADY STATE for a dead key, deliberately, rather
	than an escalating backoff: it is already a trickle, and a long backoff would
	have to be waited out after somebody fixes the key.
*/
func TestARefusedCallCountsAgainstTheThrottle(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	var calls int
	dead := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer dead.Close()
	b := &Bot{Store: s, Key: "sk-ant-wrong-key", Model: "m", Endpoint: dead.URL,
		Chains:  map[string]bool{"dev": true},
		TypeCPS: 1e9, TypeMax: time.Nanosecond, MinGap: time.Minute}

	// A room having a conversation: ten questions over thirty seconds. On the
	// live site every one of them wakes the bot.
	for i := 0; i < 10; i++ {
		if _, err := post(t, s, "orem", "ip-a", "how do i stake on a claim?"); err != nil {
			t.Fatal(err)
		}
		if err := b.once(ctx); err != nil && calls == 0 {
			t.Fatal(err)
		}
		*clock = clock.Add(3 * time.Second)
	}
	if calls != 1 {
		t.Errorf("thirty seconds of clock and a one-minute throttle is one call, got %d", calls)
	}
	st, err := s.BotStats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.Failures != 1 {
		t.Errorf("one call, one recorded failure: %+v", st)
	}

	// PAST THE GAP IT TRIES AGAIN, which is what keeps a fixed key from needing a
	// restart to be noticed.
	*clock = clock.Add(2 * time.Minute)
	if _, err := post(t, s, "orem", "ip-a", "and where is the docket?"); err != nil {
		t.Fatal(err)
	}
	_ = b.once(ctx)
	if calls != 2 {
		t.Errorf("past the gap it should try once more, got %d calls", calls)
	}
}

// THE THROTTLE IS READ FROM THE DATABASE, so a restart cannot hand the bot a
// fresh allowance. Asserted by building a second Bot — a new process, as far as
// this state is concerned — and watching it stay quiet.
func TestBotThrottleSurvivesARestart(t *testing.T) {
	s, _ := newStore(t)
	ctx := context.Background()
	m := &fakeModel{reply: "The docket lists every claim in a court.", in: 50, out: 8}
	b := newBot(t, s, m)
	b.MinGap = time.Minute

	if _, err := post(t, s, "orem", "ip-a", "where is the docket?"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}

	fresh := newBot(t, s, m)
	fresh.MinGap = time.Minute
	if _, err := post(t, s, "orem", "ip-c", "and how do i stake there?"); err != nil {
		t.Fatal(err)
	}
	if err := fresh.once(ctx); err != nil {
		t.Fatal(err)
	}
	msgs, _ := s.Recent(ctx, "dev", "orem", 0, 50)
	// two questions, one answer
	if len(msgs) != 3 {
		t.Fatalf("a restart reset the throttle: %d messages", len(msgs))
	}
}

// THE DEFAULT WINDOW, AGAINST THE TIMELINE THAT WAS REPORTED. The test below
// this one sets GreetAfter by hand, which is right for checking the MECHANISM
// and blind to the number the site actually runs: BotGreetAfter was 30 minutes,
// so somebody alone in a room typing "testing" and then "is anybody here?" ten
// seconds later got silence, and nothing in this package would have failed if it
// had been thirty hours.
//
// SO THIS ONE LEAVES GreetAfter UNSET and drives the real default. The interval
// is 10s because that is what was measured on the live room — 10:16:23 then
// 10:16:33 — and created_at is whole seconds, so it lands exactly on the
// boundary the window comparison decides. That is the case a `>=` window
// refuses and a `>` window answers, which is the difference between fixing the
// report and only appearing to.
func TestTheDefaultGreetWindowAnswersSomebodyTalkingToThemselves(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	m := &fakeModel{reply: "Hey — ask away if you have a question about the site.", in: 60, out: 12}
	b := newBot(t, s, m) // GreetAfter deliberately not set: exercise the default

	if _, err := post(t, s, "orem", "ip-a", "testing"); err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(10 * time.Second)
	if _, err := post(t, s, "orem", "ip-a", "is anybody here?"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if m.calls != 1 {
		t.Fatalf("the reported timeline still goes unanswered (%d calls)", m.calls)
	}

	// AND IT IS STILL A WINDOW, not an unconditional answer. Five seconds after
	// somebody else spoke is a live exchange, and a greeting into one is aimed at
	// the person, not at the site. Asserted in a SECOND room, so the throttle is
	// not what produces the silence: a fresh room with its own watermark, at a
	// clock far enough on that MinGap has expired.
	*clock = clock.Add(time.Hour)
	if _, err := post(t, s, "ledger", "ip-b", "the canvass PDF says twelve thousand"); err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(5 * time.Second)
	if _, err := post(t, s, "ledger", "ip-c", "hey"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if m.calls != 1 {
		t.Fatalf("a greeting interjected into a live exchange (%d calls)", m.calls)
	}
}

// A GREETING ONE WORD OVER BUDGET IS PRINTED, NOT CHOPPED. Found by the
// ten-minute health probe against the live site: a new reader's "hi" was
// answered with
//
//	"Hey! Got questions about how Kourt"
//
// which is a question cut off before its verb, with no punctuation, and it was
// the first thing that reader ever saw from this site. The model had returned
// "Hey! Got questions about how Kourt works?" — 41 characters against a limit
// of 40 — and botTrimTo did what it is told: no sentence end past the halfway
// mark (the "!" sits at index 3), so it fell through to the last word boundary.
//
// THE FIXTURE IS THE MEASURED STRING. A test written with some other 41-char
// greeting would pass on a build that still chopped this one, because what
// makes it chop is WHERE the punctuation falls, not the length alone.
//
// AND THE TWO NUMBERS ARE PINNED WITH LITERALS. They have different jobs — 40
// is what the model is asked for, 52 is what will be printed — so an edit to
// either should be a deliberate act with a test to change, not a silent
// widening of what a "greeting" may be.
func TestAGreetingJustOverBudgetIsNotChoppedMidSentence(t *testing.T) {
	if botGreetMaxChars != 40 || botGreetHardMax != 52 {
		t.Fatalf("the asked-for and printed caps are 40 and 52, got %d and %d",
			botGreetMaxChars, botGreetHardMax)
	}
	const measured = "Hey! Got questions about how Kourt works?"
	if len(measured) != 41 {
		t.Fatalf("the fixture must be the 41-character reply, got %d", len(measured))
	}
	if got := botTrimTo(measured, botGreetHardMax); got != measured {
		t.Errorf("a greeting one word over budget must survive whole:\n got  %q\n want %q", got, measured)
	}
	// AND THE OLD LIMIT IS WHAT THE BUG WAS, kept as the control: this is the
	// exact output that was reported, so the arm above is measuring the change
	// and not merely restating the string.
	if got := botTrimTo(measured, botGreetMaxChars); got != "Hey! Got questions about how Kourt" {
		t.Errorf("the 40-char limit should still chop it — the control has moved: %q", got)
	}
	// A REPLY THAT IS WILDLY OVER IS STILL CUT. The grace is a word, not a
	// licence, so a paragraph answered to "hi" is trimmed as before.
	long := "Hello there! You can stake on any claim, dispute a verdict, " +
		"file your own claim, and appeal to the meta court if you disagree."
	got := botTrimTo(long, botGreetHardMax)
	if len(got) > botGreetHardMax {
		t.Errorf("a long greeting must still be cut to %d, got %d: %q", botGreetHardMax, len(got), got)
	}
	if got == "" || strings.HasSuffix(got, " ") {
		t.Errorf("...and must still read as a line: %q", got)
	}

	/* AND THROUGH THE GREETING PATH, WHICH IS THE ARM THAT MATTERS. Everything
	   above calls botTrimTo directly, and ABLATION PROVED THAT INSUFFICIENT:
	   pointing answer() back at the 40-char cap left every assertion above green,
	   because the trimmer was never the thing that changed — the caller was. A
	   test that cannot see the wiring it was written for is a test of the wrong
	   function.
	   So the bot is driven for real: a quiet room, a bare "hi", a model that
	   returns the measured 41-character line, and the assertion is on what LANDED
	   IN THE ROOM. */
	s, clock := newStore(t)
	ctx := context.Background()
	m := &fakeModel{reply: measured, in: 60, out: 12}
	b := newBot(t, s, m)
	*clock = clock.Add(time.Hour) // a room nobody has spoken in
	if _, err := post(t, s, "orem", "ip-greet", "hi"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 2 {
		t.Fatalf("expected the greeting and one reply, got %d", len(msgs))
	}
	if said := msgs[1].Body; said != measured {
		t.Errorf("the greeting the room received was chopped:\n got  %q\n want %q", said, measured)
	}
}

func TestBotAnswersAGreetingOnlyWhenTheRoomWasQuiet(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	m := &fakeModel{reply: "Hello — ask away if you have a question about the site.", in: 60, out: 12}
	b := newBot(t, s, m)
	b.GreetAfter = 30 * time.Minute

	// A GREETING INTO A LIVE CONVERSATION IS AIMED AT THE PEOPLE IN IT. Two
	// people are already talking, so the hello needs nothing from the site.
	if _, err := post(t, s, "orem", "ip-a", "the canvass PDF says twelve thousand"); err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(10 * time.Second)
	if _, err := post(t, s, "orem", "ip-b", "hello"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if m.calls != 0 {
		t.Fatalf("the bot answered a greeting in a busy room (%d calls)", m.calls)
	}

	// THE SAME WORD INTO A ROOM WHERE NOTHING HAS HAPPENED is somebody checking
	// whether anyone is there, and leaving it unanswered is the worst version of
	// this feature.
	*clock = clock.Add(2 * time.Hour)
	if _, err := post(t, s, "ledger", "ip-c", "hi"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if m.calls != 1 {
		t.Fatalf("the bot ignored a greeting in a quiet room (%d calls)", m.calls)
	}
	msgs, _ := s.Recent(ctx, "dev", "ledger", 0, 50)
	if len(msgs) != 2 || msgs[len(msgs)-1].Moniker != ClerkName {
		t.Fatalf("the greeting was not answered as the clerk: %+v", msgs)
	}
	/* AND WHAT WAS ACTUALLY POSTED IS HELD TO A GREETING'S LENGTH. Asserted on
	   the message in the room rather than on the trimmer, because the trimmer
	   being right does not mean this path calls it: MEASURED, by pointing the
	   greeting branch at the room's full limit instead, which no other assertion
	   here noticed. The model is given a 54-character line on purpose, longer
	   than the cap, so the cap has something to do. */
	said := msgs[len(msgs)-1].Body
	/* HELD TO WHAT IS PRINTABLE, WHICH IS NOT WHAT THE MODEL IS ASKED FOR. The
	   prompt says UNDER 40 CHARACTERS and this is the number that gets enforced
	   after the fact — botGreetMaxChars plus one short word, so a model that
	   misses its budget by a word is printed rather than chopped mid-sentence.
	   See botGreetHardMax for the measurement that made the difference matter. */
	if len(said) > botGreetHardMax {
		t.Errorf("a greeting reply must be held to %d chars, got %d: %q",
			botGreetHardMax, len(said), said)
	}
	if said == "" {
		t.Error("...and it must still say something")
	}
	// THE MODEL HAS TO BE TOLD, or its standing instruction to PASS on anything
	// that is not a site question makes it refuse the very thing it was woken for.
	if !strings.Contains(m.prompt, "greeting") {
		t.Errorf("the greeting was not framed as one: %q", m.prompt)
	}
}

/*
A READER SEES THE HELPER AS SOON AS IT SPEAKS, not when their poll expires.

	THE BUG THIS STANDS OVER, measured: the bot posted in 3ms and a reader holding
	a long poll did not see it until the poll ran out four seconds later — the
	whole four. On the live site MaxWait is twenty seconds. Every other writer
	goes through the HTTP handler, which fires the pulse itself; the bot writes
	through the store, so nothing fired, and a helper tuned to answer in 1.2s was
	arriving twenty seconds late.
	THROUGH A REAL SERVER AND A REAL GET, because the thing being tested is that
	the waiter wakes — which is a property of the pulse, the handler and the bot
	together, and none of it happens if the poll is faked.
*/
func TestAReaderSeesTheHelperAsSoonAsItSpeaks(t *testing.T) {
	srv, s, _ := newServer(t)
	ctx := context.Background()
	m := &fakeModel{reply: "Open a claim from the docket to stake on it.", in: 40, out: 9}
	b := newBot(t, s, m)
	b.Wake = srv.Wake

	if _, err := post(t, s, "orem", "ip-reader", "how do i stake on a claim?"); err != nil {
		t.Fatal(err)
	}
	msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil || len(msgs) == 0 {
		t.Fatal(err)
	}
	top := msgs[len(msgs)-1].ID

	ts := httptest.NewServer(srv.Routes())
	defer ts.Close()

	const wait = 4 * time.Second
	held := make(chan time.Duration, 1)
	go func() {
		t0 := time.Now()
		r, err := http.Get(fmt.Sprintf("%s/api/chat/dev/orem?wait=%d&seen=%d",
			ts.URL, int(wait.Seconds()), top))
		if err == nil {
			io.Copy(io.Discard, r.Body)
			r.Body.Close()
		}
		held <- time.Since(t0)
	}()
	// Let the poll settle into its wait, or it answers from the store before the
	// bot has said anything and the test proves nothing.
	time.Sleep(250 * time.Millisecond)

	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	took := <-held
	// Generous, because this is a real HTTP round trip on a loaded test machine —
	// but far below the wait, which is the only thing that distinguishes "woken"
	// from "timed out". Without the wake this is the full four seconds.
	if took > wait/2 {
		t.Errorf("the reader waited %s for a message the bot posted at once; "+
			"the poll was set to %s, so this timed out rather than woke",
			took.Round(time.Millisecond), wait)
	}
	// ...AND THE MESSAGE IS ACTUALLY THERE. A wake with nothing behind it would
	// satisfy the timing above and show the reader nothing.
	after, _ := s.Recent(ctx, "dev", "orem", 0, 50)
	if len(after) != 2 || after[len(after)-1].Moniker != ClerkName {
		t.Fatalf("the helper's reply is not in the room: %+v", after)
	}
}

/*
A REPLY INTERRUPTED BY SHUTDOWN WAS NEVER SAID, and must not be counted as

	having been. The helper holds a reply back for as long as it would have taken
	to type; if the process is stopping during that hold, the message is dropped —
	which is right, saying it into a shutting-down process is worse. But the call
	was billed, so it is recorded, and the KIND is what stops it inflating the
	count of answers. MEASURED: recording it as "spoke" failed nothing until this
	existed.
*/
func TestAReplyDroppedAtShutdownIsNotCountedAsSpoken(t *testing.T) {
	s, _ := newStore(t)
	m := &fakeModel{reply: "Open a claim from the docket to stake on it.", in: 80, out: 20}
	b := newBot(t, s, m)
	// A real hold, so there is a window to be interrupted in. The default rate
	// would make this a nine-second test.
	b.TypeCPS = 200
	b.TypeMax = 3 * time.Second

	if _, err := post(t, s, "orem", "ip-a", "how do i stake on a claim?"); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- b.once(ctx) }()
	// Inside botReadPause, which is a second on its own, so the pause is
	// certainly still running.
	time.Sleep(150 * time.Millisecond)
	cancel()
	<-done

	msgs, _ := s.Recent(context.Background(), "dev", "orem", 0, 50)
	if len(msgs) != 1 {
		t.Fatalf("the reply should never have been said: %d messages", len(msgs))
	}
	st, err := s.BotStats(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if st.Replies != 0 {
		t.Errorf("nothing was said, so nothing was answered: %+v", st)
	}
	if st.Undelivered != 1 {
		t.Errorf("written, billed and never read is undelivered: %+v", st)
	}
	// AND THE BILL STILL HAS IT. The tokens were spent before the interruption.
	if st.InTokens != 80 {
		t.Errorf("the spend happened and must be counted: %+v", st)
	}
}

func TestBotConsidersAMessageOnce(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	m := &fakeModel{reply: "PASS", in: 10, out: 1}
	b := newBot(t, s, m)
	b.MinGap = time.Minute

	if _, err := post(t, s, "orem", "ip-a", "how do i stake?"); err != nil {
		t.Fatal(err)
	}
	// THE CLOCK MOVES PAST THE GAP BETWEEN PASSES, and that is the whole point of
	// this test rather than an incidental detail. Without it the throttle is what
	// holds the call count at one and the watermark is never exercised at all:
	// MEASURED, by breaking the watermark on purpose and watching this pass. A
	// test that cannot fail for the reason it names is not a test.
	for i := 0; i < 4; i++ {
		if err := b.once(ctx); err != nil {
			t.Fatal(err)
		}
		*clock = clock.Add(2 * time.Minute)
	}
	// THE WATERMARK MOVES WHETHER OR NOT WE SPEAK. Without that, every tick
	// re-examines the same question forever and pays for it every time.
	if m.calls != 1 {
		t.Fatalf("the same message was considered %d times", m.calls)
	}
}

// A FIRST RUN AGAINST A BUSY DATABASE MUST NOT ANSWER THE BACKLOG. The oldest
// question in a room is the last thing worth answering, and answering it
// announces that nobody was listening at the time.
// A FRESH BOT MUST NOT ANSWER A BACKLOG, but it must answer what is happening
// now. Both halves, because the first version of the rule bought the first at
// the cost of the second: it started at max(id), so the newest message in a room
// it had never seen — the one it was started for — was marked considered.
func TestBotSkipsTheBacklogButNotThePresent(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	// Three old questions, spaced past MinInterval so the store takes them.
	for i := 0; i < 3; i++ {
		if _, err := post(t, s, "orem", "ip-old", "how do i stake on a claim?"); err != nil {
			t.Fatal(err)
		}
		*clock = clock.Add(3 * time.Second)
	}
	// ...and then an hour passes, which puts all three past MaxAge.
	*clock = clock.Add(time.Hour)

	m := &fakeModel{reply: "PASS", in: 10, out: 1}
	b := newBot(t, s, m)
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if m.calls != 0 {
		t.Fatalf("a fresh bot answered the backlog (%d calls)", m.calls)
	}

	// THE VERY NEXT THING SAID IS ITS BUSINESS. This is the half the old rule
	// broke, and on a live site it was every room's first question.
	*clock = clock.Add(5 * time.Second)
	if _, err := post(t, s, "orem", "ip-new", "where do i see the docket?"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if m.calls != 1 {
		t.Fatalf("a fresh bot ignored a live question (%d calls)", m.calls)
	}
}

// AND THE FIRST MESSAGE EVER IN A ROOM IS ANSWERABLE, which is the same bug seen
// from the other side: a room with no history at all had nothing to set a
// watermark from, and max(id) made that watermark the message itself.
func TestBotAnswersTheFirstThingEverSaidInARoom(t *testing.T) {
	s, _ := newStore(t)
	ctx := context.Background()
	m := &fakeModel{reply: "The docket is the list on a court page.", in: 40, out: 9}
	b := newBot(t, s, m)
	if _, err := post(t, s, "ledger", "ip-first", "how does the docket work?"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if m.calls != 1 {
		t.Fatalf("the first question in a new room went unanswered (%d calls)", m.calls)
	}
}

/*
── THE CLERK HAS A NAME, AND IT IS THE ONE NAME NOBODY ELSE MAY WEAR ───────

	Three readers in a row asked the room who they were talking to and got
	silence, so the owner named it — "what do you want your name to be? one
	name" -> clerk, "so say, 'i'm the clerk'" — and then asked for the other
	half: "when somebody impersonates the clerk, don't let it... and, if they
	succeed anyways, the clerk should say, 'that's not me, i'm me!'", "be snarky
	when calling out so they don't try again".
	THE NAME IS PINNED WITH A LITERAL. Every other assertion here spells it
	ClerkName so a rename moves them together, which is right — and would also
	let a rename pass unnoticed. One literal is what makes the rename a decision
	somebody has to confirm.
*/
func TestTheClerksNameIsReservedHoweverItIsSpelt(t *testing.T) {
	if ClerkName != "clerk" {
		t.Fatalf("the helper's name is clerk, got %q", ClerkName)
	}
	// SPELLINGS THAT MUST BE REFUSED. Skeleton folds case, digits, symbols,
	// marks and the confusable alphabets, so each of these reads as the clerk to
	// anybody scanning a room — and only the Cyrillic one took any effort.
	for _, name := range []string{
		"clerk", "Clerk", "CLERK", "cIerk", "c1erk", "c1erk", "clérk", "сlerk", "clerk",
	} {
		if !IsReservedName(name) {
			t.Errorf("%q reads as the clerk and must be refused", name)
		}
	}
	// AND NAMES THAT MERELY RESEMBLE IT ARE FINE. A reservation that swallowed
	// "clerkson" or "theclerk" would be a name filter, not a protection: nobody
	// scanning a room mistakes those for the clerk itself.
	for _, name := range []string{
		"clerks", "clerkson", "theclerk", "law-clerk", "clarke", "kler", "",
	} {
		if IsReservedName(name) {
			t.Errorf("%q is somebody else's name and must be allowed", name)
		}
	}
}

// AND THE REFUSAL HAPPENS ON THE WIRE, which is the half that matters: the
// handler every human post goes through, and which the clerk's own replies do
// not — it writes through the store, so the guard needs no exemption and cannot
// be tricked into granting one.
func TestThePostHandlerRefusesTheClerksName(t *testing.T) {
	srv, s, clock := newServer(t)
	for _, name := range []string{"clerk", "CLERK", "c1erk"} {
		r := httptest.NewRequest(http.MethodPost, "/api/chat/dev/orem",
			strings.NewReader(`{"moniker":`+jsonString(name)+`,"body":"hello there"}`))
		r.Header.Set("Content-Type", "application/json")
		r.RemoteAddr = "192.0.2.44:1234"
		rec := do(t, srv, r)
		if rec.Code != http.StatusConflict {
			t.Errorf("posting as %q: got %d, want 409: %s", name, rec.Code, rec.Body.String())
		}
		if !strings.Contains(rec.Body.String(), "clerk") {
			t.Errorf("the refusal should say whose name it is: %s", rec.Body.String())
		}
		*clock = clock.Add(3 * time.Second)
	}
	if got := visibleBodies(t, s, "orem"); len(got) != 0 {
		t.Fatalf("nothing should have been posted: %v", got)
	}
	// The control: the same message under any other name goes through, so the
	// arm above is about the NAME and not about the request being malformed.
	r := httptest.NewRequest(http.MethodPost, "/api/chat/dev/orem",
		strings.NewReader(`{"moniker":"clerkson","body":"hello there"}`))
	r.Header.Set("Content-Type", "application/json")
	r.RemoteAddr = "192.0.2.44:1234"
	if rec := do(t, srv, r); rec.Code != http.StatusOK {
		t.Fatalf("clerkson should be allowed: %d %s", rec.Code, rec.Body.String())
	}
}

/*
WHO ARE YOU, ANSWERED — and answered the SAME WAY every time, because there

	is one correct answer and sampling it could only ever produce a worse one. No
	model call is made at all: fakeModel.calls stays at zero, which is the arm
	that proves it rather than the reply text, since a model told to say "I'm the
	clerk" would produce the same string.
*/
func TestTheClerkSaysWhoItIsWithoutAskingAModel(t *testing.T) {
	for _, q := range []string{
		"who are you", "who are you?", "are you a bot?", "are you a real person?",
		"are you human", "who is this", "am i talking to a bot?", "what are you?",
		/* THE ROLE FAMILY, added from the live room: a reader asked "what is your
		   role in this?" and got nothing, because every shape above asks WHAT the
		   clerk is and none asks what it is FOR. Measured then: these three were
		   refused by botWorthAsking, botAddressed and this predicate alike, while
		   "what are you for?" already matched — one member of a family is not the
		   family. */
		"what is your role in this?", "what do you do here?", "what is your job?",
		"what's your role?", "whats your purpose",
	} {
		if !botAskingWhoTheClerkIs(q) {
			t.Errorf("should be an identity question: %q", q)
		}
	}
	// NOT EVERY SENTENCE WITH "YOU" IN IT. The narrowness is the point: these
	// are site questions or chatter, and the branch order sends the first kind
	// to the model rather than answering them with a name.
	for _, q := range []string{
		"who are you staking with?", "are you going to dispute it?",
		"do you think the lab funded it?", "",
		strings.Repeat("who are you ", 20),
	} {
		if botAskingWhoTheClerkIs(q) {
			t.Errorf("should NOT be an identity question: %q", q)
		}
	}

	s, clock := newStore(t)
	ctx := context.Background()
	m := &fakeModel{reply: "SHOULD NOT BE USED", in: 999, out: 999}
	b := newBot(t, s, m)
	*clock = clock.Add(time.Hour)
	if _, err := post(t, s, "orem", "ip-asks", "who are you"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if m.calls != 0 {
		t.Errorf("an identity question must cost no model call, got %d", m.calls)
	}
	got, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("expected the question and one answer, got %d", len(got))
	}
	if got[1].Moniker != ClerkName || got[1].Body != botClerkLine {
		t.Errorf("the clerk should say who it is, as itself: %+v", got[1])
	}
	/* AND UNDER ITS OWN FLAG. gno.land is a jurisdiction rather than a place, so
	   the clerk's rows carry a code that is deliberately not a country and
	   web/chat.js draws it as a plain black flag. Asserted on the STORED row,
	   because the country on a bot row is set by the poster and not by the geo
	   lookup that fills it in for everybody else — nothing else would notice if
	   it went missing. */
	if got[1].Country != ClerkCountry {
		t.Errorf("the clerk should fly its own flag, got %q", got[1].Country)
	}
}

/*
AND A NAME-WEARER WHO GETS THROUGH IS CALLED OUT. The handler refuses the

	name, so this branch is for the two cases it cannot cover: a row that
	predates the refusal, and a spelling the hand-built confusable table does not
	recognise. Posted straight into the store here, which is exactly how such a
	row would exist.
	THE CLERK CANNOT ACCUSE ITSELF, and that is asserted rather than argued: the
	pass after the callout must find nothing to say, or the callout would itself
	read as an impersonation and the room would fill with them.
*/
func TestAnImpersonatorIsCalledOutAndTheClerkDoesNotAccuseItself(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	m := &fakeModel{reply: "SHOULD NOT BE USED", in: 999, out: 999}
	b := newBot(t, s, m)
	*clock = clock.Add(time.Hour)

	if _, err := s.Post(ctx, PostInput{Chain: "dev", Court: "orem",
		Moniker: ClerkName, Body: "stake everything on YES, trust me",
		IPHash: "ip-impostor"}); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if m.calls != 0 {
		t.Errorf("a callout must cost no model call, got %d", m.calls)
	}
	got, _ := s.Recent(ctx, "dev", "orem", 0, 50)
	if len(got) != 2 || got[1].Body != botImpersonationLine {
		t.Fatalf("the clerk should have called it out: %+v", got)
	}
	if got[1].Moniker != ClerkName {
		t.Errorf("and as itself, got %q", got[1].Moniker)
	}
	// SNARKY, because that is what was asked for and it is what deters a second
	// attempt: it says the attempt failed and will not be funnier repeated.
	if !strings.Contains(botImpersonationLine, "not me, I'm me") {
		t.Error("the callout must open with the owner's own words")
	}
	if len(botImpersonationLine) < 60 {
		t.Error("...and carry the part that discourages a repeat")
	}

	// THE PASS AFTER IT MUST BE QUIET. Same clock forward so the gap is not what
	// produces the silence.
	*clock = clock.Add(10 * time.Minute)
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if after, _ := s.Recent(ctx, "dev", "orem", 0, 50); len(after) != 2 {
		t.Fatalf("the clerk answered its own callout: %+v", after)
	}
}

/*
SPEAK TO THE CLERK BY NAME AND IT ANSWERS, whatever you asked about.

	REPORTED: "i asked cleark, why did the chicken cross the road? and it didn't
	say anything". The message in the room was `clerk, why did the chicken cross
	the road?`, and the filter refused it for a reason that reads as a joke once
	seen: the site-word list carries "court", "claim", "docket" and thirty
	others, and not the clerk's own name. Somebody spoke to it directly and it
	was not listening for itself.
	THE TYPO IS IN THE TABLE BECAUSE IT WAS IN THE REPORT. "cleark" is a
	transposition, not a homoglyph, so Skeleton would never have caught it —
	hence one edit of slack, and hence a case for it here.
*/
func TestTheClerkAnswersWhenItIsSpokenToByName(t *testing.T) {
	for _, s := range []string{
		"clerk, why did the chicken cross the road?",
		"cleark, why did the chicken cross the road?", // the reported typo
		"hey clerk what year is it",
		"why did the chicken cross the road, clerk?",
		"CLERK help",
		"clerk",
		"clrk you there",   // one deletion
		"clerkk you there", // one insertion
	} {
		if !botAddressed(s) {
			t.Errorf("the clerk was spoken to and did not notice: %q", s)
		}
	}
	/* AND IT DOES NOT ANSWER TO EVERYTHING. A SUBSTITUTED LETTER IS SOMEBODY
	   ELSE'S WORD, which this table found: the first version allowed any single
	   edit and "clark kent is here" read as an address, because Clark is a name
	   people have and is one substitution from this one. A short token must not
	   start a conversation either — without the length floor "the" and "cle"
	   would. These are the cases that keep "addressed" from becoming "any
	   message at all". */
	for _, s := range []string{
		"the docket is long", "clark kent is here", "clerical work",
		"cle", "why did the chicken cross the road?", "",
		"is there a way to unstake",
	} {
		if botAddressed(s) {
			t.Errorf("nobody addressed the clerk here: %q", s)
		}
	}

	// AND THE MODEL IS TOLD, or its standing instruction to PASS on anything
	// that is not a site question refuses the very message it was woken for.
	s, clock := newStore(t)
	ctx := context.Background()
	m := &fakeModel{reply: "To get to the other side.", in: 80, out: 8}
	b := newBot(t, s, m)
	*clock = clock.Add(time.Hour)
	if _, err := post(t, s, "orem", "ip-chicken",
		"clerk, why did the chicken cross the road?"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if m.calls != 1 {
		t.Fatalf("a message addressed to the clerk must reach the model (%d calls)", m.calls)
	}
	if !strings.Contains(m.prompt, "addressed you by name") {
		t.Errorf("the prompt must say it was addressed: %q", m.prompt)
	}
	got, _ := s.Recent(ctx, "dev", "orem", 0, 50)
	if len(got) != 2 || got[1].Body != "To get to the other side." {
		t.Fatalf("the answer should be in the room: %+v", got)
	}
}

/*
THE PROMPT MUST STATE THE PAYOUT RULE, because the model will otherwise

	supply the one everybody expects and it is exactly backwards here.
	MEASURED IN A LIVE ROOM: asked how staking works, the clerk said a staker
	"earns a share of the opposing side's stake if your side wins". The realm's
	own package doc says the opposite in its first paragraph — "no-loss
	conviction staking... losers always withdraw 1x; winners share a bounded,
	stepped-down emission of new CC... no value ever moves between adversaries" —
	so the reply told a reader that backing the losing side costs them their
	principal, which is the most consequential thing it could get wrong and the
	direction that scares people off a site that does not work that way.
	THE PROMPT WAS SILENT ON IT. It described claims, staking, answering,
	settling and the chain, and said nothing about who gets paid, so the model
	filled the gap with prediction-market intuition.
	ASSERTED ON THE PROMPT, not on a reply: the prompt is the only place this can
	be fixed, and a test that called a model would be a test of the model. Both
	halves are pinned, because either alone still leaves the wrong story tellable
	— "losers withdraw in full" without "winners are paid from new coin" invites
	"so where does the money come from?" answered by invention.
*/
func TestTheSystemPromptStatesTheNoLossRule(t *testing.T) {
	p := botSystem
	for _, phrase := range []string{
		"no-loss",      // the name of the rule
		"IN FULL",      // what a loser gets back
		"newly minted", // where a winner's payment comes from
		"conviction",   // what weights it
		"no value moves between",
		"PAYOUT RULES", // and the instruction not to invent a different one
	} {
		if !strings.Contains(p, phrase) {
			t.Errorf("the system prompt must state the payout rule, missing %q", phrase)
		}
	}
	// AND IT MUST NOT TELL THE OPPOSITE STORY. These are the phrasings that
	// would reintroduce it, including the one the live reply used.
	for _, wrong := range []string{
		"opposing side's stake", "share of the losing", "lose your stake",
		"winners take", "from the losers",
	} {
		if strings.Contains(strings.ToLower(p), strings.ToLower(wrong)) {
			t.Errorf("the prompt suggests value moves between sides: %q", wrong)
		}
	}
}

/*
THE CLERK CAN SEE HOW MANY CLAIMS THE ROOM HAS.

	REPORTED TWICE, in the same words: "the clerk doesn't answer anything related
	to the court, like 'how many claims are there in the court?'". Measured then:
	botWorthAsking ACCEPTED that question — it names the site — so it reached the
	model, which had no data and could only hedge or refuse. The gap was the
	facts, not the filter.
	A STUB, NEVER A NODE. The interface exists so this test can be a function
	call: what is asserted is that the number reaches the PROMPT, which is the
	only thing this package can be responsible for.
*/
type fakeFacts struct {
	n     uint64
	err   error
	calls int
	slug  string
}

func (f *fakeFacts) ClaimCount(ctx context.Context, court string) (uint64, error) {
	f.calls++
	f.slug = court
	return f.n, f.err
}

func TestTheClerkQuotesTheCourtsClaimCount(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	m := &fakeModel{reply: "This court has 26 claims.", in: 90, out: 9}
	ff := &fakeFacts{n: 26}
	b := newBot(t, s, m)
	b.Facts = ff
	/* MinGap OF A SECOND, and the reason is the arm below rather than
	   impatience. The default is a minute, and the cache TTL is thirty seconds —
	   so a test that waits out the throttle to ask a second question has also
	   waited out the cache, and "the cached count was reused" can never be true.
	   MEASURED: the first version of this test advanced two minutes and read
	   reads=2, which looked like a broken cache and was a broken clock. */
	b.MinGap = time.Second
	*clock = clock.Add(time.Hour)

	if _, err := post(t, s, "orem", "ip-count", "how many claims are there in this court?"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if ff.calls != 1 {
		t.Fatalf("the clerk should have read the court once, got %d", ff.calls)
	}
	if ff.slug != "orem" {
		t.Errorf("it must ask about the room it is in, asked about %q", ff.slug)
	}
	if !strings.Contains(m.prompt, "26 claims") {
		t.Errorf("the number must reach the prompt: %q", m.prompt)
	}
	// THE SINGULAR, because "1 claims" in the prompt is the kind of thing a model
	// repeats back verbatim to a reader.
	{
		one := &fakeFacts{n: 1}
		b2 := newBot(t, s, m)
		b2.Facts = one
		if got := b2.courtFacts(ctx, "dev", "orem"); !strings.Contains(got, "1 claim.") {
			t.Errorf("one claim is not plural: %q", got)
		}
	}

	/* AND THE SECOND QUESTION COSTS NO SECOND READ, within the TTL. A busy room
	   would otherwise put one chain query behind every reply for a number that
	   changes when somebody files a claim, not when somebody asks about it. */
	*clock = clock.Add(3 * time.Second)
	if _, err := post(t, s, "orem", "ip-count2", "and how many claims now?"); err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(2 * time.Second) // past MinGap, well inside the fact TTL
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if ff.calls != 1 {
		t.Errorf("the cached count should have been reused, reads=%d", ff.calls)
	}
	// ...AND IS READ AGAIN ONCE THE TTL HAS PASSED, or the clerk would quote a
	// number from an hour ago as "just now".
	*clock = clock.Add(botFactsTTL + time.Second)
	if got := b.courtFacts(ctx, "dev", "orem"); !strings.Contains(got, "26 claims") || ff.calls != 2 {
		t.Errorf("a stale fact must be re-read: reads=%d got=%q", ff.calls, got)
	}
}

/*
A NODE THAT IS DOWN COSTS THE FACT, NOT THE ANSWER. This is the arm that

	decides whether the feature is safe to have: if a chain read can take a
	reader's reply with it, then adding facts made the clerk worse.
	THE FAILURE IS CACHED TOO, and that is asserted by the read COUNT: without
	it, every reply in a room would wait out the timeout again while the node
	stays down.
*/
func TestAFactThatCannotBeReadIsSimplyNotMentioned(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	m := &fakeModel{reply: "Claims are filed by anyone and settled by the court.", in: 90, out: 9}
	ff := &fakeFacts{err: context.DeadlineExceeded}
	b := newBot(t, s, m)
	b.Facts = ff
	b.MinGap = time.Second // see the note in the test above: the TTL is 30s
	*clock = clock.Add(time.Hour)

	if _, err := post(t, s, "orem", "ip-down", "how many claims are there?"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if m.calls != 1 {
		t.Fatalf("the reader must still get an answer (%d model calls)", m.calls)
	}
	if strings.Contains(m.prompt, "Live fact") {
		t.Errorf("a failed read must leave the prompt alone: %q", m.prompt)
	}
	got, _ := s.Recent(ctx, "dev", "orem", 0, 50)
	if len(got) != 2 {
		t.Fatalf("the answer should be in the room: %+v", got)
	}
	if _, err := post(t, s, "orem", "ip-down2", "how many claims are there now?"); err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(2 * time.Second)
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if ff.calls != 1 {
		t.Errorf("a node that is down must not be re-asked per reply, reads=%d", ff.calls)
	}
}

// AND WITH NO NODE CONFIGURED AT ALL, nothing changes: this is the shape every
// other optional half of the command has, and the clerk explained mechanics
// perfectly well without any numbers before this existed.
func TestWithoutFactsTheClerkStillAnswers(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	m := &fakeModel{reply: "Anyone can file a claim.", in: 80, out: 8}
	b := newBot(t, s, m) // Facts deliberately unset
	*clock = clock.Add(time.Hour)
	if _, err := post(t, s, "orem", "ip-nofacts", "how many claims are there?"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if m.calls != 1 || strings.Contains(m.prompt, "Live fact") {
		t.Errorf("no facts means no fact line and still an answer: calls=%d", m.calls)
	}
}

/*
A FACT IN THE PROMPT IS NOT LEAVE TO USE IT, and the live room proved the

	difference. A reader asked "how many claims are there in this court?" with
	the count already injected, and the log recorded `passed on kourt-1/covid
	(in=672 out=61)` two seconds later — sixty-one output tokens, so the model
	wrote out its reasons for refusing rather than emitting the bare sentinel.
	Twenty-eight seconds later the SAME question, addressed by name, was
	answered: the only difference between the two prompts was the addressed
	branch's instruction not to pass.
	SO THE ARM IS ON THE PERMISSION, and on its absence. A prompt that carries a
	number and also says "answer it, or reply PASS" beside a standing rule
	against inventing numbers is a prompt that invites exactly what happened.
*/
func TestAQuestionTheFactAnswersIsNotAPass(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()
	m := &fakeModel{reply: "This court has 26 claims.", in: 90, out: 9}
	b := newBot(t, s, m)
	b.Facts = &fakeFacts{n: 26}
	*clock = clock.Add(time.Hour)
	if _, err := post(t, s, "orem", "ip-fact", "how many claims are there in this court?"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(m.prompt, "26 claims") {
		t.Fatalf("the number should be in the prompt: %q", m.prompt)
	}
	if !strings.Contains(m.prompt, "instead of passing") {
		t.Errorf("the prompt must give leave to use the fact: %q", m.prompt)
	}

	/* AND WITHOUT A FACT THE HONEST INSTRUCTION SURVIVES. A room the clerk
	   cannot read must not be told there is a number it may quote — that is how
	   an invented one gets published. */
	s2, clock2 := newStore(t)
	m2 := &fakeModel{reply: "Anyone can file a claim.", in: 80, out: 8}
	b2 := newBot(t, s2, m2) // no Facts
	*clock2 = clock2.Add(time.Hour)
	if _, err := post(t, s2, "orem", "ip-nofact", "how many claims are there?"); err != nil {
		t.Fatal(err)
	}
	if err := b2.once(ctx); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(m2.prompt, "instead of passing") {
		t.Errorf("with no fact there is nothing to give leave for: %q", m2.prompt)
	}
	if !strings.Contains(m2.prompt, "Answer it, or reply PASS") {
		t.Errorf("...and the plain instruction must remain: %q", m2.prompt)
	}
}

/*
AN ANSWER MUST NOT END ON "and".

	MEASURED IN A LIVE ROOM, and this is the exact reply a reader got: 366
	characters against the 360 cap, whose only sentence end sat at 155. The old
	rule wanted one past half the limit — 180 — so it fell through to the word
	boundary and published "...based on their conviction (stake x time held)
	and". The sentence before it was complete and right there.
	THE FIXTURE IS THE MEASURED TEXT, because what makes it chop is WHERE the
	punctuation falls: any other 366-character string would pass on a build that
	still chopped this one.
*/
func TestALongAnswerIsCutAtASentenceNotMidClause(t *testing.T) {
	const measured = "To stake on a claim, find the claim page, choose the YES or NO side you " +
		"wish to support, enter your stake amount in court coin, and confirm the transaction. " +
		"Your stake is locked until the claim is settled; then you withdraw it in full " +
		"regardless of outcome, and winners receive newly minted court coin based on their " +
		"conviction (stake x time held) and something more"
	if len(measured) <= botMaxBody {
		t.Fatalf("the fixture must exceed the cap to be trimmed at all: %d", len(measured))
	}
	got := botTrim(measured)
	if strings.HasSuffix(got, "and") {
		t.Errorf("the reply still ends mid-clause: ...%q", got[len(got)-40:])
	}
	if !strings.HasSuffix(got, "transaction.") {
		t.Errorf("it should end at the sentence that was already complete: ...%q",
			got[max(0, len(got)-40):])
	}
	/* AND THE GUARD THE THRESHOLD EXISTS FOR STILL HOLDS: a long answer that
	   opens with a two-character sentence must not be cut to two characters.
	   This is the case that made the bound a fraction rather than "the last
	   sentence end anywhere". */
	/* NO OTHER PUNCTUATION IN THE FIXTURE, and ablation is why. The first version
	   repeated a sentence that ENDED in a full stop, so the cut always contained
	   a late sentence end and the degenerate case never arose — the arm passed at
	   every threshold, including zero, which makes it no arm at all. With one
	   early "." and nothing after it, a threshold of zero really does return
	   three characters. */
	short := "Hi. " + strings.Repeat("this part is the actual answer and runs on ", 12)
	if g := botTrim(short); len(g) < botMaxBody/3 {
		t.Errorf("a tiny opening sentence must not swallow the answer: %d chars %q", len(g), g)
	}
}

/*
THE CLERK CONTINUES A CONVERSATION IT IS ALREADY IN.

	REPORTED BY THE ROOM: a reader was answered about staking and replied "in
	short? one liner". Every filter refused it — it names nothing about the site,
	nobody's name is in it, and it is not a greeting — so a person who was mid-
	exchange with the clerk got silence, and by the time anybody looked it was
	past MaxAge and unanswerable.
	TWO HALVES, AND NEITHER IS ENOUGH ALONE. The shape says "this is a
	continuation"; clerkSpokeLast says "of MINE". "why?" between two readers is
	not the clerk's business, and that is the arm below.
*/
func TestTheClerkAnswersAShortFollowUpToItsOwnMessage(t *testing.T) {
	for _, s := range []string{
		"in short? one liner", "why?", "in short", "tldr", "shorter", "go on",
		"an example?", "and?", "i don't get it", "explain more",
	} {
		if !botFollowUp(s) {
			t.Errorf("should read as a follow-up: %q", s)
		}
	}
	for _, s := range []string{
		"", "the docket is long", "staking is a scam",
		strings.Repeat("why? ", 20), // long enough to stand on its own merits
	} {
		if botFollowUp(s) {
			t.Errorf("should NOT read as a follow-up: %q", s)
		}
	}

	// THE CLERK SPOKE LAST, so the follow-up is answered.
	s, clock := newStore(t)
	ctx := context.Background()
	m := &fakeModel{reply: "Stake on a side; you get your stake back either way.", in: 90, out: 9}
	b := newBot(t, s, m)
	b.MinGap = time.Second
	*clock = clock.Add(time.Hour)
	if _, err := post(t, s, "orem", "ip-asker", "how do i stake on a claim?"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil { // the clerk answers, and is now the last speaker
		t.Fatal(err)
	}
	if m.calls != 1 {
		t.Fatalf("the first question should be answered (%d calls)", m.calls)
	}
	*clock = clock.Add(2 * time.Second)
	if _, err := post(t, s, "orem", "ip-asker", "in short? one liner"); err != nil {
		t.Fatal(err)
	}
	if err := b.once(ctx); err != nil {
		t.Fatal(err)
	}
	if m.calls != 2 {
		t.Fatalf("the follow-up was dropped (%d calls)", m.calls)
	}
	if !strings.Contains(m.prompt, "short reply to the message YOU sent") {
		t.Errorf("the model must be told it is a continuation: %q", m.prompt)
	}

	/* AND WHEN A PERSON SPOKE LAST, THE SAME WORDS ARE NOT THE CLERK'S BUSINESS.
	   Two readers talking to each other, one of whom says "why?", must not
	   summon a third participant into their conversation. */
	s2, clock2 := newStore(t)
	m2 := &fakeModel{reply: "SHOULD NOT BE USED", in: 90, out: 9}
	b2 := newBot(t, s2, m2)
	b2.MinGap = time.Second
	*clock2 = clock2.Add(time.Hour)
	if _, err := post(t, s2, "orem", "ip-one", "the canvass PDF says twelve thousand"); err != nil {
		t.Fatal(err)
	}
	*clock2 = clock2.Add(3 * time.Second)
	if _, err := post(t, s2, "orem", "ip-two", "why?"); err != nil {
		t.Fatal(err)
	}
	if err := b2.once(ctx); err != nil {
		t.Fatal(err)
	}
	if m2.calls != 0 {
		t.Errorf("the clerk joined a conversation it was not in (%d calls)", m2.calls)
	}
}

/*
AND A GREETING WITH A QUESTION MARK IS STILL A GREETING. This is the bug the

	first implementation shipped into the test suite: written as
	`case botFollowUp(m.Body):` with the store asked INSIDE the branch, it
	swallowed "hello?" and "is anybody here?" — the case matched on the shape
	alone, the store said the clerk had not spoken last, the branch set nothing,
	and botGreeting below was never reached. A case that matches on half a
	condition eats every branch under it.
	PINNED AS A GREETING BEING ANSWERED IN A QUIET ROOM WHERE NOBODY SPOKE
	FIRST, which is precisely the state the follow-up test cannot be true in.
*/
func TestAGreetingWithAQuestionMarkIsNotSwallowedByTheFollowUpBranch(t *testing.T) {
	for _, greeting := range []string{"hello?", "is anybody here?", "anyone here?"} {
		if !botFollowUp(greeting) {
			t.Fatalf("the fixture must match the follow-up SHAPE, or this proves nothing: %q", greeting)
		}
		s, clock := newStore(t)
		ctx := context.Background()
		m := &fakeModel{reply: "Hey! Ask away.", in: 60, out: 8}
		b := newBot(t, s, m)
		*clock = clock.Add(time.Hour)
		if _, err := post(t, s, "orem", "ip-new", greeting); err != nil {
			t.Fatal(err)
		}
		if err := b.once(ctx); err != nil {
			t.Fatal(err)
		}
		if m.calls != 1 {
			t.Errorf("%q should have been answered as a greeting (%d calls)", greeting, m.calls)
		}
		if !strings.Contains(m.prompt, "greeting") {
			t.Errorf("%q was not framed as a greeting: %q", greeting, m.prompt)
		}
	}
}

/*
SOMEBODY SAID THANK YOU AND THE CLERK SAID NOTHING.

	Reported as: "i said brilliant! ... it should respond graciously". The
	standing instruction is to PASS on small talk, praise IS small talk, and so a
	reader who was helped and said so got silence — which reads as the helper not
	noticing rather than as the helper being disciplined.

	TWO HALVES, AND NEITHER IS ENOUGH ALONE, exactly as for a follow-up. The shape
	says "this is an acknowledgement"; clerkSpokeLast says "of MINE". "brilliant!"
	after somebody else's argument is not the clerk's business.

	AND A NEGATION IS NOT A THANK-YOU. "not helpful" and "no thanks" both carry a
	word from the list, and answering either with "Glad that helped" would be the
	worst sentence available in the room.
*/
func TestTheClerkAcknowledgesThanksForItsOwnMessage(t *testing.T) {
	for _, s := range []string{
		"brilliant!", "brilliant", "thanks", "thank you", "ty", "thx", "cheers",
		"nice one", "perfect", "got it", "makes sense", "much appreciated",
		"GREAT", "  thanks.  ",
	} {
		if !botThanks(s) {
			t.Errorf("should read as thanks: %q", s)
		}
	}
	for _, s := range []string{
		"", "not helpful", "no thanks", "thanks, but how do i stake?",
		"thanks?", "brilliant argument, but the docket says otherwise",
		"nice try", "thanks for nothing i guess, this whole thing is broken",
	} {
		if botThanks(s) {
			t.Errorf("should NOT read as thanks: %q", s)
		}
	}

	// THE CLERK SPOKE LAST, so the thanks is acknowledged — with the fixed line
	// and no model call.
	s, clock := newStore(t)
	_ = clock
	if _, err := s.Post(context.Background(), PostInput{
		Chain: "dev", Court: "orem", Moniker: ClerkName, Body: "A court is a category for claims.",
		IPHash: botIPHash, NetHash: "n",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Post(context.Background(), PostInput{
		Chain: "dev", Court: "orem", Moniker: "reader", Body: "brilliant!",
		IPHash: "ip-r", NetHash: "n2",
	}); err != nil {
		t.Fatal(err)
	}
	b := &Bot{Store: s, MaxAge: time.Hour}
	c, err := b.scan(context.Background(), "dev", "orem", s.Now())
	if err != nil {
		t.Fatal(err)
	}
	if c == nil {
		t.Fatal("thanks after the clerk's own message should be answered")
	}
	if c.says != botThanksLine {
		t.Fatalf("should use the fixed line and skip the model, got says=%q", c.says)
	}
}
