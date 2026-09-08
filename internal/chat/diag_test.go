package chat

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func diagOf(t *testing.T, srv *Server) map[string]any {
	t.Helper()
	rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/diag", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("diag returned %d: %s", rec.Code, rec.Body.String())
	}
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("diag is not JSON: %v", err)
	}
	return out
}

// THE WHOLE POINT OF THE PAGE IS WHAT IT DOES NOT SAY. This is the assertion
// that keeps it from growing into an admin console with no login: the payload is
// checked against an allowlist of KEYS, so a field added later fails here and
// has to be argued for, rather than shipping because it was useful.
func TestDiagPublishesCountsAndNothingElse(t *testing.T) {
	srv, s, _ := newServer(t)
	if _, err := post(t, s, "orem", "ip-a", "a message in the room"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SetBotKeyOnce("sk-ant-secret-key-do-not-leak-me"); err != nil {
		t.Fatal(err)
	}

	rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/diag", nil))
	body := rec.Body.String()

	allowed := map[string]bool{
		"ok": true, "holding": true, "holding_peak": true,
		"courts_active": true, "messages_last_hour": true,
		"bot_key_set": true, "bot": true,
	}
	var out map[string]any
	if err := json.Unmarshal([]byte(body), &out); err != nil {
		t.Fatal(err)
	}
	for k := range out {
		if !allowed[k] {
			t.Errorf("diag published an unlisted field %q — see the allow list in diag.go", k)
		}
	}
	botAllowed := map[string]bool{
		"enabled": true, "model": true, "replies": true, "passes": true,
		"last_at": true, "in_tokens": true, "out_tokens": true, "cost_micros": true,
		"failures": true, "last_fail_at": true, "fail_kind": true,
		"undelivered": true,
	}
	if bot, ok := out["bot"].(map[string]any); ok {
		for k := range bot {
			if !botAllowed[k] {
				t.Errorf("diag published an unlisted bot field %q", k)
			}
		}
	}

	// THE KEY IS NEVER IN THE PAYLOAD IN ANY FORM — not the key, not a prefix,
	// not its length. Checked against the raw body rather than the parsed map,
	// because a leak could be anywhere in it.
	if strings.Contains(body, "sk-ant") || strings.Contains(body, "secret-key") {
		t.Fatalf("the key reached the public payload: %s", body)
	}
	if out["bot_key_set"] != true {
		t.Errorf("bot_key_set should be true once a key is set: %v", out["bot_key_set"])
	}
	// Not a number that could be a key length.
	if bot, ok := out["bot"].(map[string]any); ok {
		if _, present := bot["key_len"]; present {
			t.Error("the key's length is as good as a hint; it must not be published")
		}
	}
}

func TestDiagCountsTheRoomAndTheHour(t *testing.T) {
	srv, s, clock := newServer(t)
	if got := diagOf(t, srv)["messages_last_hour"]; got != float64(0) {
		t.Fatalf("a fresh store has nothing in the last hour: %v", got)
	}
	for _, court := range []string{"orem", "ledger"} {
		if _, err := post(t, s, court, "ip-"+court, "something said here"); err != nil {
			t.Fatal(err)
		}
		*clock = clock.Add(3 * time.Second)
	}
	d := diagOf(t, srv)
	if d["messages_last_hour"] != float64(2) {
		t.Errorf("expected 2 messages in the hour, got %v", d["messages_last_hour"])
	}
	if d["courts_active"] != float64(2) {
		t.Errorf("expected 2 active rooms, got %v", d["courts_active"])
	}
	// AN HOUR LATER THEY ARE NOT RECENT. A count called "last hour" that never
	// falls is a gauge that only goes up, which is not a diagnostic.
	*clock = clock.Add(2 * time.Hour)
	d = diagOf(t, srv)
	if d["messages_last_hour"] != float64(0) || d["courts_active"] != float64(0) {
		t.Errorf("the window did not move: %v", d)
	}
}

func TestDiagIsGETOnlyAndNotCached(t *testing.T) {
	srv, _, _ := newServer(t)
	rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/diag", nil))
	// A NUMBER SERVED FROM A CACHE IS A LIE WITH A TIMESTAMP, and this is the one
	// page whose whole value is being current.
	if cc := rec.Header().Get("Cache-Control"); cc != "no-store" {
		t.Errorf("diag must not be cacheable, got %q", cc)
	}
	post := httptest.NewRequest(http.MethodPost, "/api/chat/diag", strings.NewReader("{}"))
	post.Header.Set("Content-Type", "application/json")
	if rec := do(t, srv, post); rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST to diag should be refused, got %d", rec.Code)
	}
}

// ---- the key form ----------------------------------------------------------

func keyReq(body string) *http.Request {
	r := httptest.NewRequest(http.MethodPost, "/api/chat/botkey", strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	return r
}

func TestBotKeyFormTakesOneKeyAndRefusesTheNext(t *testing.T) {
	srv, s, _ := newServer(t)
	srv.BotKeyBootstrap = true

	if rec := do(t, srv, keyReq(`{"key":"sk-ant-aaaaaaaaaaaaaaaaaaaaaa"}`)); rec.Code != http.StatusOK {
		t.Fatalf("the first key should be accepted, got %d: %s", rec.Code, rec.Body.String())
	}
	// 409 AND THE KEY DOES NOT MOVE. A form that could be re-submitted could
	// redirect the spending onto another account after the fact.
	rec := do(t, srv, keyReq(`{"key":"sk-ant-bbbbbbbbbbbbbbbbbbbbbb"}`))
	if rec.Code != http.StatusConflict {
		t.Fatalf("a second key should conflict, got %d", rec.Code)
	}
	// AND THE REFUSAL SAYS NOTHING ABOUT THE KEY IT IS KEEPING.
	if strings.Contains(rec.Body.String(), "sk-ant") {
		t.Fatalf("the refusal echoed a key: %s", rec.Body.String())
	}
	got, _, err := s.BotKey()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(got, "aaaaaaaa") {
		t.Fatalf("the stored key changed: %q", got)
	}
}

func TestBotKeyFormRefusesRubbishAndWrongMethods(t *testing.T) {
	srv, _, _ := newServer(t)
	srv.BotKeyBootstrap = true

	for name, body := range map[string]string{
		"too short":     `{"key":"short"}`,
		"empty":         `{"key":""}`,
		"whitespace":    `{"key":"sk-ant with a space in it aaaa"}`,
		"not an object": `"sk-ant-aaaaaaaaaaaaaaaaaaaaaa"`,
	} {
		if rec := do(t, srv, keyReq(body)); rec.Code != http.StatusBadRequest {
			t.Errorf("%s should be a 400, got %d", name, rec.Code)
		}
	}
	if rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/botkey", nil)); rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("GET on the key endpoint should be refused, got %d", rec.Code)
	}
	// NO CONTENT-TYPE IS NOT A WRITE. csrfOK is what actually protects this, and
	// a form post from another origin is the attack it is there for.
	plain := httptest.NewRequest(http.MethodPost, "/api/chat/botkey",
		strings.NewReader(`{"key":"sk-ant-aaaaaaaaaaaaaaaaaaaaaa"}`))
	if rec := do(t, srv, plain); rec.Code == http.StatusOK {
		t.Error("a write with no JSON content type was accepted")
	}
	cross := keyReq(`{"key":"sk-ant-aaaaaaaaaaaaaaaaaaaaaa"}`)
	cross.Header.Set("Sec-Fetch-Site", "cross-site")
	if rec := do(t, srv, cross); rec.Code != http.StatusForbidden {
		t.Errorf("a cross-site write should be refused, got %d", rec.Code)
	}
}

// THE WINDOW CAN BE SHUT. Write-once alone is trust-on-first-use: whoever
// reaches the form first claims the slot. An operator who has set the key out of
// band turns this off, and then the endpoint accepts nothing at all.
func TestBotKeyFormCanBeClosed(t *testing.T) {
	srv, s, _ := newServer(t)
	srv.BotKeyBootstrap = false
	rec := do(t, srv, keyReq(`{"key":"sk-ant-aaaaaaaaaaaaaaaaaaaaaa"}`))
	if rec.Code != http.StatusForbidden {
		t.Fatalf("a closed window should refuse, got %d", rec.Code)
	}
	if set, _ := s.BotKeySet(); set {
		t.Fatal("a key was stored through a closed window")
	}
}

// ---- the count above the chat box ------------------------------------------

// THE ASKER IS ONE OF THEM, and the helper is another. A lone reader seeing
// "0 here" on their own screen is the bug this guards: a GET answered
// immediately is not holding a connection, so the gauge alone would say nobody
// is present to the very person who is.
func TestHereCountsTheAskerAndTheHelper(t *testing.T) {
	srv, _, _ := newServer(t)
	if got := srv.here(); got != 1 {
		t.Fatalf("a reader must count themselves, got %d", got)
	}
	srv.BotEnabled = true
	if got := srv.here(); got != 2 {
		t.Fatalf("the helper is one more participant, got %d", got)
	}
	srv.hold.enter()
	srv.hold.enter()
	if got := srv.here(); got != 4 {
		t.Fatalf("two waiters plus the asker plus the helper is 4, got %d", got)
	}
	srv.hold.leave()
	if got := srv.here(); got != 3 {
		t.Fatalf("a waiter that left must stop counting, got %d", got)
	}
}

// AND THE POLL CARRIES IT, so the panel needs no second request — and there is
// no field telling the page which of them is not a person.
func TestPollReplyCarriesHereAndDoesNotDecomposeIt(t *testing.T) {
	srv, s, _ := newServer(t)
	srv.BotEnabled = true
	if _, err := post(t, s, "orem", "ip-a", "hello there everyone"); err != nil {
		t.Fatal(err)
	}
	rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/dev/orem", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("poll returned %d", rec.Code)
	}
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if out["here"] != float64(2) {
		t.Errorf("the poll should carry here=2, got %v", out["here"])
	}
	for _, leak := range []string{"bot", "bot_here", "humans", "is_bot", "helper"} {
		if _, present := out[leak]; present {
			t.Errorf("the poll reply decomposed the count via %q", leak)
		}
	}
}

/*
IT TAKES BOTH A FLAG AND A KEY, and the truth table is pinned because the two

	answers this replaces disagreed: the reported flag came from --bot alone while
	the goroutine needed a key too, so --bot with no key published enabled=true
	and put a phantom participant in every room's count.
*/
func TestBotRunsOnlyWithBothAFlagAndAKey(t *testing.T) {
	for _, c := range []struct {
		flagOn, keySet, want bool
		why                  string
	}{
		{true, true, true, "asked for, and able"},
		{true, false, false, "asked for with nothing to authenticate with"},
		{false, true, false, "a key lying in the database is not a request to spend it"},
		{false, false, false, "neither"},
	} {
		if got := BotRunnable(c.flagOn, c.keySet); got != c.want {
			t.Errorf("BotRunnable(%v,%v) = %v, want %v — %s",
				c.flagOn, c.keySet, got, c.want, c.why)
		}
	}
}

// AND A HELPER THAT IS NOT RUNNING IS NOT IN THE ROOM. The count and the page's
// flag are the same field, so this is the consequence of the table above.
func TestANonRunningHelperIsNotCounted(t *testing.T) {
	srv, _, _ := newServer(t)
	srv.BotEnabled = BotRunnable(true, false)
	if got := srv.here(); got != 1 {
		t.Errorf("only the asker is here, got %d", got)
	}
	if d := diagOf(t, srv); d["bot"].(map[string]any)["enabled"] != false {
		t.Errorf("the page should not claim a helper that cannot run: %v", d["bot"])
	}
	srv.BotEnabled = BotRunnable(true, true)
	if got := srv.here(); got != 2 {
		t.Errorf("a running helper is one more, got %d", got)
	}
}

/*
A HELPER THAT IS FAILING DOES NOT LOOK LIKE ONE NOBODY HAS ASKED ANYTHING.

	MEASURED with a deliberately wrong key: five consecutive rejected calls left
	the payload reading enabled=true, replies=0, passes=0, in_tokens=0,
	cost_micros=0 — byte-for-byte what a healthy idle helper reads. An operator
	had no way to tell them apart on the page whose only job is telling them
	apart.
*/
func TestAFailingHelperIsDistinguishableFromAnIdleOne(t *testing.T) {
	srv, s, clock := newServer(t)
	srv.BotEnabled = true
	ctx := context.Background()

	idle := diagOf(t, srv)["bot"].(map[string]any)
	if idle["failures"] != float64(0) {
		t.Fatalf("an idle helper has failed nothing: %v", idle)
	}
	if _, present := idle["fail_kind"]; present {
		t.Errorf("an idle helper should not name a failure kind: %v", idle)
	}

	dead := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// A body that would be a leak if it ever reached the page.
		w.WriteHeader(http.StatusUnauthorized)
		w.Write([]byte(`{"error":{"message":"invalid x-api-key sk-ant-LEAK"}}`))
	}))
	defer dead.Close()
	b := &Bot{Store: s, Key: "sk-ant-wrong-key-000000", Model: "m",
		Endpoint: dead.URL, Chains: map[string]bool{"dev": true},
		TypeCPS: 1e9, TypeMax: time.Nanosecond, MinGap: time.Minute}

	for i := 0; i < 3; i++ {
		if _, err := post(t, s, "orem", "ip-a", "how do i stake on a claim?"); err != nil {
			t.Fatal(err)
		}
		_ = b.once(ctx)
		*clock = clock.Add(2 * time.Minute)
	}

	rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/diag", nil))
	body := rec.Body.String()
	var out map[string]any
	if err := json.Unmarshal([]byte(body), &out); err != nil {
		t.Fatal(err)
	}
	bot := out["bot"].(map[string]any)
	if bot["failures"] != float64(3) {
		t.Errorf("three rejected calls should be three failures: %v", bot)
	}
	// REFUSED, NOT UNREACHABLE: the vendor answered and said no, which sends an
	// operator to the key rather than to the network.
	if bot["fail_kind"] != BotFailRefused {
		t.Errorf("a 401 is a refusal, got %v", bot["fail_kind"])
	}
	if bot["last_fail_at"] == nil || bot["last_fail_at"] == float64(0) {
		t.Errorf("a failure has a time: %v", bot)
	}
	// AND A REFUSAL IS NOT BILLED, so it must not appear in the cost — the tokens
	// stay at zero while the failures climb.
	if bot["cost_micros"] != float64(0) || bot["in_tokens"] != float64(0) {
		t.Errorf("a refused call was never billed: %v", bot)
	}
	if bot["replies"] != float64(0) || bot["passes"] != float64(0) {
		t.Errorf("a refused call neither spoke nor passed: %v", bot)
	}

	/* AND NOTHING THE VENDOR SAID REACHES THE PAGE. The 401 body above carries a
	   string shaped like a key on purpose; the payload may contain the class of
	   failure and nothing else. */
	for _, leak := range []string{"sk-ant", "LEAK", "invalid x-api-key", "401"} {
		if strings.Contains(body, leak) {
			t.Errorf("the vendor's message reached the public payload (%q): %s", leak, body)
		}
	}
}

// THE KIND IS A CLOSED SET, so a caller inventing a word cannot put arbitrary
// text on a public page. Three words now: a recovered panic is "internal",
// which is this code breaking rather than the vendor.
func TestAFailureKindIsOneOfTheClosedSet(t *testing.T) {
	s, _ := newStore(t)
	ctx := context.Background()
	if err := s.RecordBotFailure(ctx, "<script>alert(1)</script>"); err != nil {
		t.Fatal(err)
	}
	st, err := s.BotStats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.FailKind != BotFailUnreachable && st.FailKind != BotFailRefused &&
		st.FailKind != BotFailInternal {
		t.Errorf("an invented kind reached the page: %q", st.FailKind)
	}
	// ...and the count still moved, because the number is the part that matters.
	if st.Failures != 1 {
		t.Errorf("the failure was dropped rather than recorded coarsely: %+v", st)
	}
}

/*
A REPLY THE ROOM REFUSED IS NOT A REPLY WITH NOTHING TO SAY.

	MEASURED: with the same short greeting in three rooms, the cross-court
	duplicate rule refuses the third — DupCourts is 2, so the third is the one
	that trips — and the page reported passes=1. That is a reply which was
	written, billed at 300 micro-dollars, and never delivered, shown to an
	operator as the outcome that needs no attention. The two could not be further
	apart in what they ask of somebody reading this page.
*/
func TestAnUndeliveredReplyIsNotCountedAsAPass(t *testing.T) {
	srv, s, clock := newServer(t)
	srv.BotEnabled = true
	ctx := context.Background()
	// One phrase, three rooms. The 40-character greeting cap makes this the
	// likely shape rather than a contrived one.
	m := &fakeModel{reply: "hey — what would you like to know?", in: 50, out: 10}
	b := newBot(t, s, m)
	b.MinGap = time.Minute
	b.GreetAfter = 30 * time.Minute

	for _, court := range []string{"orem", "ledger", "annex"} {
		if _, err := post(t, s, court, "ip-r"+court, "hi"); err != nil {
			t.Fatal(err)
		}
		if err := b.once(ctx); err != nil {
			t.Fatal(err)
		}
		*clock = clock.Add(90 * time.Second)
	}

	// The third room got the greeting and no answer.
	third, _ := s.Recent(ctx, "dev", "annex", 0, 50)
	if len(third) != 1 {
		t.Fatalf("expected the duplicate rule to refuse the third room, got %d messages "+
			"— if DupCourts changed, this test is measuring nothing", len(third))
	}

	st, err := s.BotStats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.Undelivered != 1 {
		t.Errorf("the refused reply should be one undelivered, got %+v", st)
	}
	if st.Passes != 0 {
		t.Errorf("nothing passed here — the model answered every time: %+v", st)
	}
	if st.Replies != 2 {
		t.Errorf("two rooms did get an answer: %+v", st)
	}
	// AND IT IS STILL IN THE BILL. The tokens were spent whatever became of the
	// message; a cost that dropped undelivered replies would understate it.
	if st.CostMicros != 300 {
		t.Errorf("three billed calls at 100 each: %+v", st)
	}
	// It is also not a FAILURE: the model answered fine. Conflating the two would
	// send an operator to the key when the fault is in the room.
	if st.Failures != 0 {
		t.Errorf("the model did not fail: %+v", st)
	}
}

/*
THE COLUMN ARRIVES ON AN EXISTING DATABASE, and the rows already in it are

	read correctly. Before `kind` the outcome was inferred from the sign of
	msg_id, so on an older database a negative id means a pass and nothing else —
	which is what makes the backfill safe. Without it every old pass would read as
	a reply, and the count of answers would jump on upgrade.
*/
func TestTheKindColumnBackfillsAnOlderDatabase(t *testing.T) {
	s, _ := newStore(t)
	ctx := context.Background()
	// A row as the older code would have left it: negative id, and the column's
	// default rather than a considered value.
	if _, err := s.w.Exec(
		`INSERT INTO bot_replies (msg_id, chain, court, model, in_tokens, out_tokens,
		   cost_micros, kind, created_at) VALUES (-1,'','','m',10,1,11,'spoke',1)`); err != nil {
		t.Fatal(err)
	}
	if err := migrate(s.w); err != nil {
		t.Fatal(err)
	}
	st, err := s.BotStats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.Passes != 1 || st.Replies != 0 {
		t.Errorf("an old negative-id row is a pass, not a reply: %+v", st)
	}
	// IDEMPOTENT: running it again must not move anything, and must not touch a
	// row that has since been written with a considered kind.
	if _, err := s.w.Exec(
		`INSERT INTO bot_replies (msg_id, chain, court, model, in_tokens, out_tokens,
		   cost_micros, kind, created_at) VALUES (-2,'','','m',5,1,6,'undelivered',2)`); err != nil {
		t.Fatal(err)
	}
	if err := migrate(s.w); err != nil {
		t.Fatal(err)
	}
	st, _ = s.BotStats(ctx)
	if st.Undelivered != 1 || st.Passes != 1 {
		t.Errorf("a second migration rewrote a considered kind: %+v", st)
	}
}

/*
A REAL HELD POLL SHOWS UP IN THE COUNT, and this is the arm that was missing.

	WHAT WAS TESTED BEFORE. holdGauge as a bare object, and here() with the gauge
	nudged by the test itself — both of which confirm the counter counts and say
	nothing about whether the handler is attached to it. MEASURED: removing
	s.hold.enter and s.hold.leave from the messages handler entirely failed ZERO
	tests, so the active-connections number could have become permanently 0 with
	the suite green.
	THROUGH REAL REQUESTS, because that is the only thing that can tell. Two
	readers hold a poll; the count is then read the way the page reads it.
*/
func TestARealHeldPollIsCountedAsAConnection(t *testing.T) {
	srv, s, _ := newServer(t)
	ctx := context.Background()
	if _, err := post(t, s, "orem", "ip-a", "something to poll past"); err != nil {
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
	const readers = 2
	done := make(chan struct{}, readers)
	for i := 0; i < readers; i++ {
		go func() {
			defer func() { done <- struct{}{} }()
			r, err := http.Get(fmt.Sprintf("%s/api/chat/dev/orem?wait=%d&seen=%d",
				ts.URL, int(wait.Seconds()), top))
			if err == nil {
				io.Copy(io.Discard, r.Body)
				r.Body.Close()
			}
		}()
	}
	// Long enough for both to be inside the wait, well short of the wait itself.
	time.Sleep(500 * time.Millisecond)

	d := diagOf(t, srv)
	if d["holding"] != float64(readers) {
		t.Errorf("two readers holding a poll should read as %d, got %v — "+
			"if this is 0 the handler is not attached to the gauge at all",
			readers, d["holding"])
	}
	if d["holding_peak"] != float64(readers) {
		t.Errorf("the peak should have seen them too: %v", d["holding_peak"])
	}

	/* AND THEY STOP COUNTING WHEN THEY LEAVE. A gauge that only goes up is a
	   gauge that says nothing after an hour of traffic — and `leave` is a
	   separate line from `enter`, so it can be lost on its own. */
	for i := 0; i < readers; i++ {
		<-done
	}
	after := diagOf(t, srv)
	if after["holding"] != float64(0) {
		t.Errorf("both polls ended, so nothing is held: %v", after["holding"])
	}
	if after["holding_peak"] != float64(readers) {
		t.Errorf("...but the peak remembers them: %v", after["holding_peak"])
	}
}

/*
A READER WHO NAVIGATES AWAY STOPS BEING COUNTED, which is the commonest exit

	of all and had no test.
	MEASURED: deleting the leave() on the hung-up path failed ZERO tests. Every
	page navigation aborts an in-flight poll, so a leak there is not an edge case
	— it is the normal way a poll ends, and holding would climb monotonically
	until the number meant nothing. The count is right today; nothing was
	protecting it.
*/
func TestAReaderWhoHangsUpStopsBeingCounted(t *testing.T) {
	srv, s, _ := newServer(t)
	ctx := context.Background()
	if _, err := post(t, s, "orem", "ip-a", "something to poll past"); err != nil {
		t.Fatal(err)
	}
	msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil || len(msgs) == 0 {
		t.Fatal(err)
	}
	top := msgs[len(msgs)-1].ID

	ts := httptest.NewServer(srv.Routes())
	defer ts.Close()

	// A wait long enough that the poll cannot end on its own inside this test:
	// if the count falls, it is the disconnect that did it.
	rctx, cancel := context.WithCancel(context.Background())
	req, err := http.NewRequestWithContext(rctx, http.MethodGet,
		fmt.Sprintf("%s/api/chat/dev/orem?wait=8&seen=%d", ts.URL, top), nil)
	if err != nil {
		t.Fatal(err)
	}
	ended := make(chan struct{})
	go func() {
		defer close(ended)
		if r, err := http.DefaultClient.Do(req); err == nil {
			io.Copy(io.Discard, r.Body)
			r.Body.Close()
		}
	}()
	time.Sleep(400 * time.Millisecond)
	if d := diagOf(t, srv)["holding"]; d != float64(1) {
		t.Fatalf("the reader should be holding a connection: %v", d)
	}

	cancel() // navigate away
	<-ended
	// The handler notices through r.Context(); give it a moment to unwind.
	var got any
	for i := 0; i < 40; i++ {
		got = diagOf(t, srv)["holding"]
		if got == float64(0) {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if got != float64(0) {
		t.Errorf("a reader who hung up is still counted: holding=%v — this leaks "+
			"on every navigation, so the number climbs and stops meaning anything", got)
	}
	// ...and the peak still remembers they were there.
	if p := diagOf(t, srv)["holding_peak"]; p != float64(1) {
		t.Errorf("the peak should have seen them: %v", p)
	}
}

/*
A REQUEST THAT DOES NOT WAIT IS NOT A HELD CONNECTION, which is the claim the

	gauge's own comment makes: the number means "readers holding a connection",
	not "requests being served". Asserted through the PEAK, because an instant
	request cannot be caught in the act — if the gauge were taken for every
	request the peak would have climbed, and it is monotonic so it cannot hide it.
*/
func TestARequestThatDoesNotWaitIsNotCounted(t *testing.T) {
	srv, s, _ := newServer(t)
	if _, err := post(t, s, "orem", "ip-a", "a message to read"); err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(srv.Routes())
	defer ts.Close()

	// Twenty ordinary reads, none of them asking to wait — the shape of an older
	// client, and of the first poll of any busy court.
	for i := 0; i < 20; i++ {
		r, err := http.Get(ts.URL + "/api/chat/dev/orem")
		if err != nil {
			t.Fatal(err)
		}
		io.Copy(io.Discard, r.Body)
		r.Body.Close()
	}
	d := diagOf(t, srv)
	if d["holding"] != float64(0) {
		t.Errorf("nothing is being held: %v", d["holding"])
	}
	if d["holding_peak"] != float64(0) {
		t.Errorf("twenty non-waiting reads must never have been counted, "+
			"peak=%v — the gauge is being taken for requests rather than waits",
			d["holding_peak"])
	}
}

/*
MANY WAITERS, SOME HANGING UP, AND MODERATION FIRING THROUGHOUT — the only

	test here that exercises the gauge and both pulse paths concurrently, and
	worth having because every other one is sequential.
	WHAT IT WOULD CATCH: a leak that only appears when exits interleave, and a
	race in the peak's compare-and-swap. Run it with -race for the second.
	THE PEAK IS THE WITNESS, not a live sampler. A first version of this polled
	the payload in a goroutine and never saw more than one waiter at a time — the
	diagnostics read is serialised against waiters that come and go in
	milliseconds — and would have reported success while measuring nothing. The
	peak is monotonic, so it cannot miss having climbed.
*/
func TestTheGaugeSurvivesManyWaitersAtOnce(t *testing.T) {
	srv, s, _ := newServer(t)
	ctx := context.Background()

	// A baseline, so a reader asking for "anything after this" actually WAITS.
	// Without it HasSince is true, the wait block is skipped, and nothing is held
	// at all — which is how the first version of this measured a peak of zero.
	if _, err := post(t, s, "orem", "ip-seed", "a seed message"); err != nil {
		t.Fatal(err)
	}
	msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil || len(msgs) == 0 {
		t.Fatal(err)
	}
	top := msgs[len(msgs)-1].ID

	ts := httptest.NewServer(srv.Routes())
	var wg sync.WaitGroup
	const readers = 10

	for i := 0; i < readers; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			for j := 0; j < 3; j++ {
				// Staggered deadlines, so the exits interleave rather than all
				// landing together: hang-ups and timeouts mixed.
				rctx, c := context.WithTimeout(ctx, time.Duration(60+n*11)*time.Millisecond)
				req, err := http.NewRequestWithContext(rctx, http.MethodGet,
					fmt.Sprintf("%s/api/chat/dev/orem?wait=2&seen=%d", ts.URL, top), nil)
				if err == nil {
					if r, err := http.DefaultClient.Do(req); err == nil {
						io.Copy(io.Discard, r.Body)
						r.Body.Close()
					}
				}
				c()
			}
		}(i)
	}
	// The other pulse path, running at the same time.
	wg.Add(1)
	go func() {
		defer wg.Done()
		for j := 0; j < 15; j++ {
			srv.WakeAll()
			time.Sleep(12 * time.Millisecond)
		}
	}()
	wg.Wait()
	ts.Close()

	// Give the last handlers a moment to unwind their defers.
	var holding any
	for i := 0; i < 40; i++ {
		holding = diagOf(t, srv)["holding"]
		if holding == float64(0) {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	d := diagOf(t, srv)
	if p, ok := d["holding_peak"].(float64); !ok || p < 2 {
		t.Fatalf("no concurrent waiters were ever observed (peak=%v) — this test "+
			"is measuring nothing, and the seed message above is what makes them wait",
			d["holding_peak"])
	}
	if holding != float64(0) {
		t.Errorf("the gauge leaked under concurrent load: holding=%v", holding)
	}
}

func TestHoldGaugeRemembersItsPeak(t *testing.T) {
	var g holdGauge
	g.enter()
	g.enter()
	g.enter()
	g.leave()
	g.leave()
	g.leave()
	if n := g.now.Load(); n != 0 {
		t.Fatalf("every waiter left, so now should be 0, got %d", n)
	}
	if p := g.peak.Load(); p != 3 {
		t.Fatalf("the peak should survive them leaving, got %d", p)
	}
}
