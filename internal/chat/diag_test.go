package chat

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
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
		"enabled": true, "model": true, "replies": true, "last_at": true,
		"in_tokens": true, "out_tokens": true, "cost_micros": true,
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
