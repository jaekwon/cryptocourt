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
	// AS IF A FAST TYPER WROTE IT: 300 characters at 18 c/s is about 17 seconds,
	// so the delay has to be in that neighbourhood and not a token gesture.
	if long < 10*time.Second {
		t.Fatalf("300 characters should take a typist real time, got %s", long)
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
			if msgs[len(msgs)-1].Moniker != "anon" {
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

func TestBotAnswersASiteQuestionAsAnonAndRecordsWhatItSpent(t *testing.T) {
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
	if reply.Moniker != "anon" {
		t.Errorf("the bot must post as anon, got %q", reply.Moniker)
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

	// PAST THE GAP IT MAY SPEAK AGAIN — but the question it would have answered
	// has been consumed by the watermark, which is deliberate: a question that
	// waited out the throttle is stale, and MaxAge says so. A new one is answered.
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
	if len(msgs) != 2 || msgs[len(msgs)-1].Moniker != "anon" {
		t.Fatalf("the greeting was not answered as anon: %+v", msgs)
	}
	/* AND WHAT WAS ACTUALLY POSTED IS HELD TO A GREETING'S LENGTH. Asserted on
	   the message in the room rather than on the trimmer, because the trimmer
	   being right does not mean this path calls it: MEASURED, by pointing the
	   greeting branch at the room's full limit instead, which no other assertion
	   here noticed. The model is given a 54-character line on purpose, longer
	   than the cap, so the cap has something to do. */
	said := msgs[len(msgs)-1].Body
	if len(said) > botGreetMaxChars {
		t.Errorf("a greeting reply must be held to %d chars, got %d: %q",
			botGreetMaxChars, len(said), said)
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
	if len(after) != 2 || after[len(after)-1].Moniker != "anon" {
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
