package chat

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jaekwon/kourt/internal/geo"
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
/* THE DAY'S SPEND AGAINST THE CEILING, which is the row that explains a silence.

A capped helper says NOTHING, and silence on this site already had four causes a
reader cannot tell apart: the reply gap, the local filter, a model pass, and a
room that refused the post. The ceiling was a fifth, and its only record was a
line in the journal — on the page whose whole purpose is telling those apart.
*/
func TestDiagReportsTheDaysSpendAgainstTheCeiling(t *testing.T) {
	srv, s, clock := newServer(t)
	srv.BotEnabled = true
	srv.BotCostCap = 2_000_000

	// Spend from two days ago must not count against today, the same window the
	// gate uses — one definition, so the page cannot say there is budget left
	// while the gate refuses to spend it.
	*clock = clock.Add(24 * time.Hour)
	if err := s.recordBotSpend(context.Background(), "m", botKindPass, 0, 0, 900_000); err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(48 * time.Hour)
	if err := s.recordBotSpend(context.Background(), "m", botKindSpoke, 0, 0, 400_000); err != nil {
		t.Fatal(err)
	}

	var got struct {
		Bot struct {
			CapMicros  int64 `json:"cap_micros"`
			SpentToday int64 `json:"spent_today"`
		} `json:"bot"`
	}
	rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/diag", nil))
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.Bot.CapMicros != 2_000_000 {
		t.Errorf("the ceiling must be published, got %d", got.Bot.CapMicros)
	}
	if got.Bot.SpentToday != 400_000 {
		t.Errorf("today's spend is 400000; the page says %d — a window that "+
			"counted all time would say 1300000", got.Bot.SpentToday)
	}

	/* AND NO CEILING IS ALSO AN ANSWER, and the one an operator most needs: zero
	   is the default, so a deployment that has never set a cap must SHOW that
	   rather than showing nothing. Neither field is omitempty for this reason. */
	srv.BotCostCap = 0
	rec = do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/diag", nil))
	if !strings.Contains(rec.Body.String(), `"cap_micros":0`) {
		t.Errorf("no ceiling must be published as zero, not omitted: %s", rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"spent_today":400000`) {
		t.Errorf("the day's spend must still be published: %s", rec.Body.String())
	}
}

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
		// THE PRESENCE TALLIES, ARGUED FOR IN diag.go's HEADER RATHER THAN HERE.
		// here_by_country is a location and the rule above it said locations were
		// not allowed, so the rule now states the carve-out: a count per country,
		// detached from every name, hash, room and message, and only for
		// countries at or above hereFloor. The rest of these are counts of keys
		// whose keys are not published — how many networks, how many rooms.
		"here_networks": true, "here_rooms": true,
		"here_by_country": true, "here_elsewhere": true, "geo_known": true,
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
		/* THE DAY'S CEILING AND WHAT IS LEFT OF IT. Both are operator figures
		   already visible to anybody who can read this endpoint, and neither says
		   anything about a person: the cap is a flag this process was started
		   with, and the spend is a sum over the helper's own calls. They are here
		   because a capped helper is SILENT, and this is the page whose whole job
		   is telling one silence from another. */
		"cap_micros": true, "spent_today": true,
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
	a := holder{cc: "DE", net: "net-a", room: "dev\x00orem"}
	b := holder{cc: "US", net: "net-b", room: "dev\x00orem"}
	srv.hold.enter(a)
	srv.hold.enter(b)
	if got := srv.here(); got != 4 {
		t.Fatalf("two waiters plus the asker plus the helper is 4, got %d", got)
	}
	/* AND A WAITER BETWEEN POLLS STILL COUNTS, which reverses what this arm used
	   to assert. It required the count to drop the instant a poll returned, and
	   that was measured on the live site as the reader-visible bug it is: a long
	   poll is not held continuously, so with one reader on the page the count
	   was right for about six seconds out of every ten. See holdLinger. */
	srv.hold.leave(b)
	if got := srv.here(); got != 4 {
		t.Fatalf("a waiter between two polls is still in the room, got %d", got)
	}
	/* ...UNTIL THE WINDOW PASSES. The clock is injected rather than slept on,
	   which is the only reason this can assert both sides of a 45-second
	   window in a unit test. */
	base := time.Now()
	srv.hold.mu.Lock()
	srv.hold.clock = func() time.Time { return base.Add(holdLinger + time.Second) }
	srv.hold.mu.Unlock()
	if got := srv.here(); got != 3 {
		t.Fatalf("a waiter gone longer than the window must stop counting, got %d", got)
	}
	/* AND IT IS THE DEPARTED ONE THAT WENT, not just "one of them". Checking the
	   total again would assert the same 3 twice and distinguish nothing: a
	   window that expired on age alone would drop `a` — which never left — and
	   still print 3 by keeping `b`. So the tally itself is read. */
	byCC, nets, _ := srv.hold.snapshot()
	if byCC["DE"] != 1 || byCC["US"] != 0 || nets != 1 {
		t.Fatalf("the waiter still polling must survive the window and the one "+
			"that left must not: %v, %d nets", byCC, nets)
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
	h := []holder{
		{cc: "DE", net: "n1", room: "r1"},
		{cc: "DE", net: "n2", room: "r1"},
		{cc: "US", net: "n3", room: "r2"},
	}
	for _, x := range h {
		g.enter(x)
	}
	// AT THE PEAK, the tallies say what the room is made of. Asserted here rather
	// than in its own test because this is the only moment all three are held.
	if byCC, nets, rooms := g.snapshot(); byCC["DE"] != 2 || byCC["US"] != 1 || nets != 3 || rooms != 2 {
		t.Fatalf("tallies at the peak: %v, %d nets, %d rooms", byCC, nets, rooms)
	}
	for _, x := range h {
		g.leave(x)
	}
	if n := g.now.Load(); n != 0 {
		t.Fatalf("every waiter left, so now should be 0, got %d", n)
	}
	if p := g.peak.Load(); p != 3 {
		t.Fatalf("the peak should survive them leaving, got %d", p)
	}
	/* AND THE TALLIES HOLD FOR THE WINDOW, then empty. This arm used to require
	   them to empty the INSTANT the last poll returned, and that requirement was
	   the bug: a reader between two polls has not left the room. What must still
	   be true is that they empty EVENTUALLY — a key kept forever would make
	   HereNetworks count everyone who has ever polled, which climbs for the life
	   of the process and means nothing within an hour. */
	if byCC, nets, rooms := g.snapshot(); byCC["DE"] != 2 || nets != 3 || rooms != 2 {
		t.Fatalf("between polls the room is still the room: %v, %d nets, %d rooms",
			byCC, nets, rooms)
	}
	base := time.Now()
	g.mu.Lock()
	g.clock = func() time.Time { return base.Add(holdLinger + time.Second) }
	g.mu.Unlock()
	byCC, nets, rooms := g.snapshot()
	if len(byCC) != 0 || nets != 0 || rooms != 0 {
		t.Fatalf("once the window has passed with nothing in flight the tallies "+
			"must empty: %v, %d nets, %d rooms", byCC, nets, rooms)
	}
	/* AND THE MAPS THEMSELVES ARE GONE, not merely reporting zero. The published
	   numbers come from present(), so a map full of expired keys would report
	   correctly while growing without bound — the leak this test was written to
	   catch in the first place, which a check on the reported counts alone can
	   no longer see. */
	g.mu.Lock()
	sizes := [3]int{len(g.byCC), len(g.byNet), len(g.byRoom)}
	g.mu.Unlock()
	if sizes != [3]int{0, 0, 0} {
		t.Fatalf("expired keys were reported as absent but never forgotten: %v", sizes)
	}
	/* A READER WHO KEEPS POLLING NEVER EXPIRES, which is the other half and the
	   one that would empty a busy room if it were wrong. Same gauge, same jumped
	   clock: enter again and the tally must come back and stay. */
	g.enter(h[0])
	if byCC, _, _ := g.snapshot(); byCC["DE"] != 1 {
		t.Fatalf("a reader polling after the window must count again: %v", byCC)
	}
}

// AND THE COUNT COMES BACK DOWN WHEN A ROOM PARTLY EMPTIES. The window holds
// the recent maximum, so the thing that must be proved is that the maximum
// DECAYS to what is actually there rather than standing forever.
//
// MEASURED AS A GAP FIRST: deleting the peak reset from sweep failed zero tests.
// Without it, a room that once had three readers in it reports three for the
// life of the process — every sweep re-stamps the stale peak, so it never even
// expires. The page would name a country on the strength of readers who left an
// hour ago, which is the floor's argument quietly turned into a lie.
func TestAPartlyEmptiedRoomDecaysToWhatIsLeft(t *testing.T) {
	var g holdGauge
	base := time.Now()
	at := base
	g.clock = func() time.Time { return at }
	h := []holder{
		{cc: "SE", net: "n1", room: "r1"},
		{cc: "SE", net: "n2", room: "r1"},
		{cc: "SE", net: "n3", room: "r1"},
	}
	for _, x := range h {
		g.enter(x)
	}
	if byCC, nets, _ := g.snapshot(); byCC["SE"] != 3 || nets != 3 {
		t.Fatalf("three in flight: %v, %d nets", byCC, nets)
	}
	g.leave(h[1])
	g.leave(h[2])
	// WITHIN THE WINDOW THEY ARE STILL THERE — this is the feature, and it is
	// what makes the decay below a real question rather than a tautology.
	at = at.Add(5 * time.Second)
	if byCC, _, _ := g.snapshot(); byCC["SE"] != 3 {
		t.Fatalf("just after leaving, the room is still three: %v", byCC)
	}
	// PAST IT, ONLY THE ONE STILL HOLDING COUNTS.
	at = at.Add(holdLinger + time.Second)
	if byCC, nets, rooms := g.snapshot(); byCC["SE"] != 1 || nets != 1 || rooms != 1 {
		t.Fatalf("the window passed, so only the holder is left: %v, %d nets, %d rooms",
			byCC, nets, rooms)
	}
	// AND IT DOES NOT CREEP BACK. A sweep that re-stamped a stale peak would
	// report three again on the next read.
	at = at.Add(holdLinger + time.Second)
	if byCC, _, _ := g.snapshot(); byCC["SE"] != 1 {
		t.Fatalf("the old peak came back: %v", byCC)
	}
}

// A READER WHO KEEPS POLLING IS NEVER DROPPED, ACROSS ANY LENGTH OF TIME — the
// property the whole window exists to provide, and the one no other arm covers.
//
// WHY IT NEEDS ITS OWN TEST. The arms above enter and leave once, so they cannot
// see the case that actually broke: a peak RE-ACHIEVED at the same level must
// re-stamp its clock. With `>` instead of `>=` in bump, a lone reader sets
// peak=1 at t0 and never refreshes it, so 45 seconds later the window has
// expired underneath somebody who never left and the count goes back to
// flickering with their poll cycle — the original bug, restored, with every
// other test still green.
func TestASteadyPollerNeverFallsOutOfTheRoom(t *testing.T) {
	var g holdGauge
	base := time.Now()
	at := base
	g.clock = func() time.Time { return at }
	h := holder{cc: "NO", net: "n1", room: "r1"}

	// Six seconds holding, four between, for five times the window.
	for at.Sub(base) < 5*holdLinger {
		g.enter(h)
		at = at.Add(6 * time.Second)
		if byCC, _, _ := g.snapshot(); byCC["NO"] != 1 {
			t.Fatalf("in flight at %s: %v", at.Sub(base), byCC)
		}
		g.leave(h)
		at = at.Add(4 * time.Second)
		// BETWEEN POLLS IS THE ASSERTION. This is the moment the live count is
		// zero and only the window is holding the reader in the room.
		if byCC, _, _ := g.snapshot(); byCC["NO"] != 1 {
			t.Fatalf("between polls at %s the reader vanished: %v", at.Sub(base), byCC)
		}
		if n := g.presentTotal(); n != 1 {
			t.Fatalf("between polls at %s the total was %d", at.Sub(base), n)
		}
	}
	// AND THEY DO LEAVE EVENTUALLY. Without this the test would pass on a gauge
	// that never forgets anybody.
	at = at.Add(holdLinger + time.Second)
	if n := g.presentTotal(); n != 0 {
		t.Fatalf("after the window with no poll the room should be empty, got %d", n)
	}
}

// ---- where the room is ------------------------------------------------------

// geoStub is a country file with three rows in it.
type geoStub map[string]string

func (g geoStub) Country(a netip.Addr) string { return g[a.Unmap().String()] }

// THE TALLIES COME FROM THE CONNECTIONS BEING HELD, which is the whole feature
// and the part no unit test on hereRows can reach: the poll path has to resolve
// a country at all. It did not — the machinery for country lookup existed, was
// tested, and was wired only into the POST path, so a room full of readers
// produced no location information of any kind.
//
// HELD ON PURPOSE, and the seed message is what makes them wait: without a
// baseline HasSince is true, the wait block is skipped, nothing is held, and
// this would measure an empty gauge and pass.
func TestHereTalliesComeFromTheHeldConnections(t *testing.T) {
	srv, s, _ := newServer(t)
	srv.Geo = geoStub{
		"203.0.113.1":  "DE",
		"203.0.113.2":  "DE",
		"198.51.100.9": "US",
	}
	if _, err := post(t, s, "orem", "ip-seed", "a seed message"); err != nil {
		t.Fatal(err)
	}
	msgs, err := s.Recent(context.Background(), "dev", "orem", 0, 50)
	if err != nil || len(msgs) == 0 {
		t.Fatal(err)
	}
	top := msgs[len(msgs)-1].ID

	ctx, release := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	/* RELEASED BEFORE IT IS WAITED ON. defer is last-in-first-out, so a
	   `defer release()` written above `defer wg.Wait()` runs AFTER it — the
	   waiters were still holding, and this test sat out the full twenty-second
	   wait to prove something it had already proved. One defer, in order. */
	defer func() { release(); wg.Wait() }()
	for _, remote := range []string{"203.0.113.1:1111", "203.0.113.2:2222", "198.51.100.9:3333"} {
		wg.Add(1)
		go func(remote string) {
			defer wg.Done()
			req := httptest.NewRequest(http.MethodGet,
				fmt.Sprintf("/api/chat/dev/orem?wait=20&seen=%d", top), nil).WithContext(ctx)
			req.RemoteAddr = remote
			srv.Routes().ServeHTTP(httptest.NewRecorder(), req)
		}(remote)
	}

	// Wait for all three to be inside the hold. Polled rather than slept: the
	// gauge is the only thing that knows, and a fixed sleep is either flaky or
	// slow.
	var d map[string]any
	for i := 0; i < 100; i++ {
		d = diagOf(t, srv)
		if d["holding"] == float64(3) {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if d["holding"] != float64(3) {
		t.Fatalf("three readers should be holding, got %v — nothing was measured", d["holding"])
	}

	if d["geo_known"] != true {
		t.Errorf("a loaded country file should say so: %v", d["geo_known"])
	}
	/* BOTH COUNTRIES ARE NAMED. Two in Germany and one in the United States, and
	   with the floor at one the lone holder is named too — that is the change
	   made on "i want everyone to see the same thing". This used to assert the
	   opposite: one row for DE, with the American folded into elsewhere.
	   Largest first, so the page does not reshuffle between polls. */
	rows, _ := d["here_by_country"].([]any)
	if len(rows) != 2 {
		t.Fatalf("both countries should be named, got %v", d["here_by_country"])
	}
	first, _ := rows[0].(map[string]any)
	second, _ := rows[1].(map[string]any)
	if first["cc"] != "DE" || first["n"] != float64(2) {
		t.Errorf("want DE with 2 first, got %v", first)
	}
	if second["cc"] != "US" || second["n"] != float64(1) {
		t.Errorf("want US with 1 second, got %v", second)
	}
	// ELSEWHERE IS EMPTY NOW: nothing is withheld for being small, and all three
	// of these addresses are in the country file.
	if d["here_elsewhere"] != float64(0) {
		t.Errorf("nothing should be withheld, got %v", d["here_elsewhere"])
	}
	/* THREE ADDRESSES, TWO NETWORKS — and getting this wrong is what the
	   assertion is for. A network here is the /24, the same unit a range
	   consequence applies to (NetPrefix), so 203.0.113.1 and 203.0.113.2 are ONE
	   network and 198.51.100.9 is the second. Measured: this test first expected
	   three, on the assumption that the net hash covered a single address the way
	   the ip hash does. The number is a floor under "how many people", never a
	   count of them, and it is coarser than it looks. */
	if d["here_networks"] != float64(2) {
		t.Errorf("two /24s hold these three readers, got %v", d["here_networks"])
	}
	if d["here_rooms"] != float64(1) {
		t.Errorf("all three are in one room, got %v", d["here_rooms"])
	}
}

// AND THE KEYS BEHIND THOSE COUNTS ARE NOT PUBLISHED. here_networks is the SIZE
// of a map whose keys are the same hashed network identifiers a consequence is
// recorded against, and here_rooms the size of one keyed by room. A count is
// allowed; the keys are not, and "we only send the length" is a property of the
// code that has to be checked rather than trusted.
func TestHereCountsKeysWithoutPublishingThem(t *testing.T) {
	srv, s, _ := newServer(t)
	srv.Geo = geoStub{"203.0.113.1": "DE"}
	if _, err := post(t, s, "orem", "ip-seed", "a seed message"); err != nil {
		t.Fatal(err)
	}
	msgs, _ := s.Recent(context.Background(), "dev", "orem", 0, 50)
	top := msgs[len(msgs)-1].ID

	ctx, release := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	defer func() { release(); wg.Wait() }() // see the sibling test: order matters
	wg.Add(1)
	go func() {
		defer wg.Done()
		req := httptest.NewRequest(http.MethodGet,
			fmt.Sprintf("/api/chat/dev/orem?wait=20&seen=%d", top), nil).WithContext(ctx)
		req.RemoteAddr = "203.0.113.1:1111"
		srv.Routes().ServeHTTP(httptest.NewRecorder(), req)
	}()

	var body string
	for i := 0; i < 100; i++ {
		rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/diag", nil))
		body = rec.Body.String()
		if strings.Contains(body, `"holding":1`) {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !strings.Contains(body, `"holding":1`) {
		t.Fatalf("nobody was holding, so this measured nothing: %s", body)
	}

	// The hashes this connection is counted under, computed the same way the
	// server computes them, and looked for in the raw payload.
	_, netHash := HashPair(srv.Hasher, netip.MustParseAddr("203.0.113.1"))
	for _, secret := range []string{netHash, "orem", "203.0.113.1"} {
		if strings.Contains(body, secret) {
			t.Errorf("the payload published %q, which is a key and not a count: %s", secret, body)
		}
	}
}

// THE FLOOR, on its own, because it decides what the map is allowed to say and
// it should be readable without holding any connections open.
//
// THIS TEST USED TO BE CALLED NamesNoLoneHolder, and that guarantee is gone on
// purpose: the floor was lowered to one on the instruction "i want everyone to
// see the same thing", so a country with a single connection IS named now. The
// old name is recorded here because a test whose title asserts the opposite of
// the behaviour is worse than no test — it is a claim somebody will quote.
func TestHereFloorNamesEveryCountryWithAnybody(t *testing.T) {
	rows, elsewhere := hereRows(map[string]int{"DE": 3, "FR": 2, "NO": 1, "": 4})
	if len(rows) != 3 {
		t.Fatalf("every country with a connection is named, got %v", rows)
	}
	// Largest first, so the page does not reshuffle between two polls that saw
	// the same room.
	if rows[0].CC != "DE" || rows[0].N != 3 || rows[1].CC != "FR" || rows[1].N != 2 ||
		rows[2].CC != "NO" || rows[2].N != 1 {
		t.Errorf("want DE=3, FR=2, NO=1 in that order, got %v", rows)
	}
	// ELSEWHERE IS NOW ONLY THE UNPLACEABLE. It used to carry the lone Norwegian
	// as well; with the floor at one there is nothing withheld for being small,
	// so anything in here is a connection whose country the file could not name.
	if elsewhere != 4 {
		t.Errorf("want the 4 unknown and nothing else, got %d", elsewhere)
	}
	// And a country at exactly the floor IS named — the boundary, stated.
	if rows, _ := hereRows(map[string]int{"JP": hereFloor}); len(rows) != 1 {
		t.Errorf("a country at exactly the floor should be named, got %v", rows)
	}
	if rows, _ := hereRows(map[string]int{"JP": hereFloor - 1}); len(rows) != 0 {
		t.Errorf("one below the floor must not be named, got %v", rows)
	}
}

// WITH NO COUNTRY FILE, EVERY CONNECTION IS "ELSEWHERE" — which is exactly what
// a room full of readers in small countries also looks like. geo_known is what
// tells an operator which of the two they are looking at, the same way the bot's
// Failures field distinguishes a broken helper from an idle one.
func TestGeoKnownSaysWhetherThereIsAFileAtAll(t *testing.T) {
	srv, _, _ := newServer(t)
	if d := diagOf(t, srv); d["geo_known"] != false {
		t.Errorf("no file loaded, so geo_known must be false: %v", d["geo_known"])
	}
	srv.Geo = geoStub{}
	if d := diagOf(t, srv); d["geo_known"] != true {
		t.Errorf("a file is loaded, so geo_known must be true: %v", d["geo_known"])
	}
}

// ---- the change signal, which is what makes the map flash ------------------

// hereOf reads the presence payload through the handler, with whatever query
// the caller wants. Through the handler rather than the struct, because the
// long poll is part of what is being tested.
func hereOf(t *testing.T, srv *Server, query string) map[string]any {
	t.Helper()
	rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/here"+query, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("here returned %d: %s", rec.Code, rec.Body.String())
	}
	var out map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("here is not JSON: %v", err)
	}
	return out
}

// EVERY CHANGE MOVES THE NUMBER, and nothing else about the change is published.
func TestHerePublishesAChangeCountAndNothingAboutTheChange(t *testing.T) {
	srv, _, _ := newServer(t)
	was, _ := hereOf(t, srv, "")["events"].(float64)
	/* THROUGH THE HANDLER, NOT THE STORE, and that distinction is the whole
	   reliability of this feature. Store.Post does not fire the pulse — the HTTP
	   handler does, right after it, and so does the bot after its own reply. A
	   first version of this test wrote straight to the store and measured a
	   counter that never moved, which is the same gap that once left the site's
	   answerer deaf to every message. Posting the way a reader does is the only
	   version of this test worth having. */
	if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", "alice",
		"something happened in here")); rec.Code != 200 {
		t.Fatalf("post: %d %s", rec.Code, rec.Body)
	}
	now, _ := hereOf(t, srv, "")["events"].(float64)
	if now <= was {
		t.Fatalf("a post must move the change count: %v then %v", was, now)
	}
	/* AND THE PAYLOAD STILL SAYS NOTHING ELSE. The body is checked as raw text
	   because a leak could be anywhere in it: the court that changed, the
	   address that changed it, and what was said are all things the flash must
	   not carry. */
	rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/here", nil))
	body := rec.Body.String()
	for _, forbidden := range []string{"orem", "alice", "something happened"} {
		if strings.Contains(body, forbidden) {
			t.Fatalf("the presence payload named %q: %s", forbidden, body)
		}
	}
}

// A POLL THAT ALREADY KNOWS THE NUMBER WAITS; ONE THAT DOES NOT IS ANSWERED AT
// ONCE. Both halves, because a long poll that never waits is an interval with
// extra steps, and one that never returns early is a bug nobody sees until the
// page stops updating.
func TestHereLongPollWaitsOnlyWhenThereIsNothingNew(t *testing.T) {
	// The clock is needed because this test posts twice and the abuse limit is
	// one message per address every two seconds — a real limit, so the test
	// moves time rather than asking to be exempted from it.
	srv, _, clock := newServer(t)
	/* SOMETHING HAS TO HAVE HAPPENED FIRST. A first version of this asked for
	   `since=0` on a fresh server and expected an immediate answer — but a fresh
	   server's count IS zero, so the client was up to date and holding was
	   correct. The test was wrong, not the handler. */
	if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", "alice",
		"so the count is not zero")); rec.Code != 200 {
		t.Fatalf("post: %d %s", rec.Code, rec.Body)
	}
	at := hereOf(t, srv, "")["events"].(float64)
	if at <= 0 {
		t.Fatalf("the count should have moved before this test begins, got %v", at)
	}

	// BEHIND THE COUNT: answered immediately, no waiting.
	done := make(chan time.Duration, 1)
	go func() {
		t0 := time.Now()
		hereOf(t, srv, "?since=0&wait=20")
		done <- time.Since(t0)
	}()
	select {
	case d := <-done:
		if d > 3*time.Second {
			t.Fatalf("a client behind the count should not wait, took %s", d)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a client behind the count waited instead of being answered")
	}

	// UP TO DATE: holds, and a post releases it. The release is what proves the
	// wait is on the change signal rather than on a timer.
	rel := make(chan float64, 1)
	go func() {
		rel <- hereOf(t, srv, fmt.Sprintf("?since=%d&wait=20", int64(at)))["events"].(float64)
	}()
	select {
	case <-rel:
		t.Fatal("a client that is up to date must hold, not answer at once")
	case <-time.After(300 * time.Millisecond):
	}
	*clock = clock.Add(3 * time.Second)
	if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", "bob",
		"and this releases the waiter")); rec.Code != 200 {
		t.Fatalf("post: %d %s", rec.Code, rec.Body)
	}
	select {
	case got := <-rel:
		if got <= at {
			t.Fatalf("the released poll reported a stale count: %v after %v", got, at)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a post did not release the presence poll")
	}

	/* AND A CLIENT AHEAD OF THE COUNT IS ANSWERED AT ONCE, which is the restart
	   case rather than a curiosity: the counter resets when the process does, so
	   a page that has been open across a restart is holding a number higher than
	   anything the new process will produce. Treating "not equal" as "something
	   changed" is what stops that page from hanging for a full wait on every
	   poll, forever. */
	ahead := make(chan time.Duration, 1)
	go func() {
		t0 := time.Now()
		hereOf(t, srv, "?since=999999&wait=20")
		ahead <- time.Since(t0)
	}()
	select {
	case d := <-ahead:
		if d > 3*time.Second {
			t.Fatalf("a client ahead of the count should not wait, took %s", d)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a client ahead of the count hung; a restart would hang every open page")
	}
}

// AND READING THIS PAGE DOES NOT MAKE THE ROOM LOOK BUSIER.
//
// THE ONE MISTAKE THAT WOULD UNDO THE NUMBER. The tally means "people with a
// chat open". Somebody reading the presence page has no chat open, so if this
// handler entered the gauge the way the messages handler does, the figure would
// count its own audience — a page reporting a bigger room the longer you look at
// it, and worse, two readers of THIS page in one country would be enough to name
// that country on a site where nobody is chatting at all.
func TestReadingThePresencePageIsNotPresence(t *testing.T) {
	srv, _, _ := newServer(t)
	held := make(chan struct{})
	go func() {
		defer close(held)
		at := srv.pulse().changeCount()
		hereOf(t, srv, fmt.Sprintf("?since=%d&wait=2", at))
	}()
	// While that poll is parked, the gauge must show nobody.
	time.Sleep(400 * time.Millisecond)
	if n := srv.hold.now.Load(); n != 0 {
		t.Fatalf("a presence reader was counted as a held chat connection: %d", n)
	}
	if total := srv.hold.presentTotal(); total != 0 {
		t.Fatalf("a presence reader reached the windowed tally: %d", total)
	}
	byCC, nets, rooms := srv.hold.snapshot()
	if len(byCC) != 0 || nets != 0 || rooms != 0 {
		t.Fatalf("a presence reader reached the tallies: %v, %d nets, %d rooms",
			byCC, nets, rooms)
	}
	<-held
}

// ---- the map's cells ------------------------------------------------------

// cellGeo is a geo table that places one address in one cell and names its
// country, which is the whole surface the presence page uses.
type cellGeo struct {
	cc   string
	cell map[string]uint16
}

func (g cellGeo) Country(netip.Addr) string { return g.cc }
func (g cellGeo) Cell(a netip.Addr) uint16  { return g.cell[a.String()] }

// THE PAYLOAD IS AN ALLOWLIST HERE TOO, for the reason /diag's is: this page is
// public, its whole value is what it refuses to say, and a field added later
// must fail a test and be argued for rather than shipping because it was handy.
func TestHerePublishesCellsAndNothingElse(t *testing.T) {
	srv, _, _ := newServer(t)
	out := hereOf(t, srv, "")
	allowed := map[string]bool{
		"by_country": true, "elsewhere": true, "networks": true, "rooms": true,
		"geo_known": true, "events": true,
		// THE MAP'S OWN TWO. by_cell is a position, which the rule above by_country
		// carves out for a count-per-country; the carve-out here is a count per
		// ~550km cell, at the cell's centre, with no name attached and the same
		// floor a country gets. cells_known says whether this build can place at
		// all, which is the healthy-looks-like-broken distinction.
		"by_cell": true, "cells_known": true,
	}
	for k := range out {
		if !allowed[k] {
			t.Errorf("the presence payload published an unlisted field %q — argue "+
				"for it in diag.go before adding it here", k)
		}
	}
	// A cell row carries three things and no fourth.
	if rows, ok := out["by_cell"].([]any); ok {
		for _, r := range rows {
			m, _ := r.(map[string]any)
			for k := range m {
				if k != "lat" && k != "lon" && k != "n" {
					t.Errorf("a cell row published %q; a dot needs a position and a count", k)
				}
			}
		}
	}
}

// A CELL IS NAMED ON THE SAME TERMS A COUNTRY IS, whatever those terms are.
//
// WRITTEN AGAINST hereFloor RATHER THAN AGAINST 2, and the first version of this
// test asserted 2 and failed — correctly. The floor was lowered to one on the
// instruction "i want everyone to see the same thing", with the alternative
// (each reader shown their own country and nobody else's) put and declined. A
// test that pinned 2 would have been asserting a policy the owner had already
// reversed, so what is pinned instead is that the map and the table apply the
// SAME floor: a lone reader appearing in one and not the other is precisely the
// asymmetry that instruction rejected.
//
// AND WITH THE FLOOR AT ONE, THE CELL IS THE PROTECTION. That is the whole
// reason this breakdown is a ~550km square with no name on it rather than a
// city: visibility is no longer traded against precision, it is traded against
// resolution, and the resolution is fixed by the grid instead of by how many
// people happen to be online.
func TestACellIsNamedOnTheSameTermsAsACountry(t *testing.T) {
	oslo := geo.CellOf(59.91, 10.75)
	if oslo == 0 {
		t.Fatal("the fixture needs a real cell")
	}
	// Exactly at the floor: named. One under it: not.
	if rows := hereCells(map[uint16]int{oslo: hereFloor}); len(rows) != 1 {
		t.Errorf("a cell at the floor of %d must be named, got %v", hereFloor, rows)
	}
	if hereFloor > 1 {
		if rows := hereCells(map[uint16]int{oslo: hereFloor - 1}); len(rows) != 0 {
			t.Errorf("a cell under the floor must not be named, got %v", rows)
		}
	}
	// The same floor the country table uses, read from the same constant by the
	// same comparison — so the two cannot drift apart.
	byCC, _ := hereRows(map[string]int{"NO": hereFloor})
	if len(byCC) != 1 {
		t.Errorf("the country table disagrees about the floor: %v", byCC)
	}

	/* AND THE DOT IS AT THE CELL'S CENTRE, NOT AT THE READER. This is the
	   assertion that matters at any floor: a dot drawn on the connection's own
	   coordinate would publish the position the cell exists to withhold, and
	   with a floor of one it would do so for a single identifiable person. */
	rows := hereCells(map[uint16]int{oslo: 2})
	if len(rows) != 1 {
		t.Fatalf("expected one cell, got %v", rows)
	}
	lat, lon, _ := geo.CellCentre(oslo)
	if rows[0].Lat != lat || rows[0].Lon != lon {
		t.Errorf("the dot is at %v,%v; the cell's centre is %v,%v",
			rows[0].Lat, rows[0].Lon, lat, lon)
	}
	if rows[0].Lat == 59.91 && rows[0].Lon == 10.75 {
		t.Error("the dot is drawn at the reader's own coordinate")
	}
	/* ...AND IT IS FAR ENOUGH AWAY TO MEAN SOMETHING. Oslo sits inside its cell,
	   so the centre is tens to hundreds of kilometres off — which is the number
	   this design offers in place of the floor it no longer has. */
	if d := (lat-59.91)*(lat-59.91) + (lon-10.75)*(lon-10.75); d < 0.01 {
		t.Errorf("the cell centre is only %.3f degrees from the reader", d)
	}
}

// CELL 0 IS NOT A PLACE. It means the address could not be placed — a
// country-only file, or one of the handful of rows the vendor has no coordinate
// for — and it must never become a dot in the Gulf of Guinea.
func TestAnUnplaceableConnectionIsNotADot(t *testing.T) {
	if rows := hereCells(map[uint16]int{0: 9}); len(rows) != 0 {
		t.Errorf("cell 0 became %v", rows)
	}
	var g holdGauge
	g.enter(holder{cc: "US", net: "n1", room: "r1", cell: 0})
	_, _, _, byCell := g.snapshotAll()
	if len(byCell) != 0 {
		t.Errorf("an unplaceable connection reached the cell tally: %v", byCell)
	}
	// ...while still being counted as present and as in its country.
	byCC, _, _, _ := g.snapshotAll()
	if byCC["US"] != 1 {
		t.Errorf("it must still count in its country, got %v", byCC)
	}
}

// A COUNTRY-ONLY BUILD SAYS SO RATHER THAN LOOKING EMPTY. The deploy falls back
// to the country file when the city one cannot be fetched, and a map with no
// dots has to be distinguishable from a map that cannot draw any.
func TestACountryOnlyBuildAdmitsItCannotPlace(t *testing.T) {
	srv, _, _ := newServer(t)
	srv.Geo = stubGeo{cc: "US"} // Country only: no Cell method
	if srv.CellsKnown() {
		t.Error("a country-only geo must not claim it can place")
	}
	if out := hereOf(t, srv, ""); out["cells_known"] != false {
		t.Errorf("cells_known should be false, got %v", out["cells_known"])
	}
	if srv.cellOf(netip.MustParseAddr("1.2.3.4")) != 0 {
		t.Error("a country-only geo placed an address")
	}
	// And with a placing geo it says the opposite.
	srv.Geo = cellGeo{cc: "NO", cell: map[string]uint16{"1.2.3.4": 7}}
	if !srv.CellsKnown() {
		t.Error("a placing geo must say it can place")
	}
	if got := srv.cellOf(netip.MustParseAddr("1.2.3.4")); got != 7 {
		t.Errorf("cellOf returned %d, want 7", got)
	}
}

// AND THE CELL GOES THROUGH THE SAME WINDOW A COUNTRY DOES. If it did not, the
// map and the table would disagree about who is in the room — the map blinking
// while the table held steady, or the reverse.
func TestACellRidesTheSameWindowAsACountry(t *testing.T) {
	var g holdGauge
	base := time.Now()
	at := base
	g.clock = func() time.Time { return at }
	h := holder{cc: "SE", net: "n1", room: "r1", cell: 900}
	g.enter(h)
	g.leave(h)
	at = at.Add(5 * time.Second)
	byCC, _, _, byCell := g.snapshotAll()
	if byCC["SE"] != 1 || byCell[900] != 1 {
		t.Fatalf("between polls both must hold: %v / %v", byCC, byCell)
	}
	at = at.Add(holdLinger + time.Second)
	byCC, _, _, byCell = g.snapshotAll()
	if len(byCC) != 0 || len(byCell) != 0 {
		t.Fatalf("past the window both must empty: %v / %v", byCC, byCell)
	}
}
