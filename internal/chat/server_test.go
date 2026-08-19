package chat

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func newServer(t *testing.T) (*Server, *Store, *time.Time) {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "chat.db"))
	if err != nil {
		t.Fatal(err)
	}
	clock := time.Unix(1_700_000_000, 0)
	s.Now = func() time.Time { return clock }
	t.Cleanup(func() { s.Close() })
	key := make([]byte, 32)
	h, err := NewHasher(key)
	if err != nil {
		t.Fatal(err)
	}
	return &Server{
		Store: s, Hasher: h,
		Chains:        map[string]bool{"dev": true},
		CountryHeader: "X-Country",
	}, s, &clock
}

// testAddr is httptest.NewRequest's own default RemoteAddr. Using it rather than
// overriding is deliberate: an earlier version of this helper set an address only
// "if empty", which never fired, so the server hashed one address while the test
// punished another and a real kick read as "ok".
const testAddr = "192.0.2.1"

func do(t *testing.T, srv *Server, req *http.Request) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	srv.Routes().ServeHTTP(rec, req)
	return rec
}

func postReq(t *testing.T, path, moniker, body string) *http.Request {
	t.Helper()
	b, _ := json.Marshal(postBody{Moniker: moniker, Body: body})
	r := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(b))
	r.Header.Set("Content-Type", "application/json")
	return r
}

func TestPostThenGet(t *testing.T) {
	srv, _, _ := newServer(t)
	if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", "alice", "hello court")); rec.Code != 200 {
		t.Fatalf("post: %d %s", rec.Code, rec.Body)
	}
	rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/dev/orem", nil))
	if rec.Code != 200 {
		t.Fatalf("get: %d %s", rec.Code, rec.Body)
	}
	var reply getReply
	if err := json.Unmarshal(rec.Body.Bytes(), &reply); err != nil {
		t.Fatal(err)
	}
	if len(reply.Messages) != 1 || reply.Messages[0].Body != "hello court" {
		t.Fatalf("got %+v", reply)
	}
	if reply.You.State != "ok" {
		t.Fatalf("an unpunished caller should read ok, got %q", reply.You.State)
	}
	if reply.Next != reply.Messages[0].ID {
		t.Fatal("next must be the last id, or the poller re-reads forever")
	}
}

// THE CSRF PAIR. CORS does not protect a write, so these two are what stop any
// web page making its visitors post from their own addresses.
func TestCSRF(t *testing.T) {
	srv, _, _ := newServer(t)

	// A CORS-safelisted content type sends with no preflight and would execute.
	b, _ := json.Marshal(postBody{Moniker: "alice", Body: "posted by a third party"})
	r := httptest.NewRequest(http.MethodPost, "/api/chat/dev/orem", bytes.NewReader(b))
	r.Header.Set("Content-Type", "text/plain")
	if rec := do(t, srv, r); rec.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("text/plain must be refused with 415, got %d", rec.Code)
	}

	// A real cross-site fetch announces itself, and browsers will not let script
	// forge the header.
	r = postReq(t, "/api/chat/dev/orem", "alice", "posted from another site")
	r.Header.Set("Sec-Fetch-Site", "cross-site")
	if rec := do(t, srv, r); rec.Code != http.StatusForbidden {
		t.Fatalf("cross-site must be refused with 403, got %d", rec.Code)
	}

	// PAIRED POSITIVE, twice over, or the above is just a test that posting
	// fails: same-origin works, and an absent Sec-Fetch-Site works too. Absent is
	// allowed on purpose — the header only reaches potentially-trustworthy
	// origins, so on plain HTTP it never arrives, and refusing it would block
	// curl and the operator CLI for nothing.
	r = postReq(t, "/api/chat/dev/orem", "alice", "posted from our own page")
	r.Header.Set("Sec-Fetch-Site", "same-origin")
	if rec := do(t, srv, r); rec.Code != 200 {
		t.Fatalf("same-origin must be accepted, got %d %s", rec.Code, rec.Body)
	}
}

func TestPreflight(t *testing.T) {
	srv, _, _ := newServer(t)
	rec := do(t, srv, httptest.NewRequest(http.MethodOptions, "/api/chat/dev/orem", nil))
	if rec.Code != http.StatusNoContent {
		t.Fatalf("preflight: %d", rec.Code)
	}
	// Without this the first browser POST fails, because application/json is
	// exactly what triggers a preflight.
	if got := rec.Header().Get("Access-Control-Allow-Headers"); !strings.Contains(got, "Content-Type") {
		t.Fatalf("preflight must permit Content-Type, got %q", got)
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "*" {
		t.Fatalf("the file:// demo needs a wildcard origin, got %q", got)
	}
}

func TestUnknownChainAndCourt(t *testing.T) {
	srv, _, _ := newServer(t)
	// A client-chosen chain with no allowlist would be a fresh partition and a
	// fresh budget per made-up name.
	if rec := do(t, srv, postReq(t, "/api/chat/nosuchchain/orem", "a", "hello there")); rec.Code != 404 {
		t.Fatalf("unknown chain must 404, got %d", rec.Code)
	}
	if rec := do(t, srv, postReq(t, "/api/chat/dev/NotACourt", "a", "hello there")); rec.Code != 404 {
		t.Fatalf("malformed court must 404, got %d", rec.Code)
	}
	// Paired positive.
	if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", "a", "hello there")); rec.Code != 200 {
		t.Fatalf("a known chain and court must work, got %d", rec.Code)
	}
}

func TestGetClampsSinceAndLimit(t *testing.T) {
	srv, _, clock := newServer(t)
	for i := 0; i < 5; i++ {
		if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", "alice", "message here now")); rec.Code != 200 {
			t.Fatalf("seed %d: %d %s", i, rec.Code, rec.Body)
		}
		*clock = clock.Add(MinInterval)
	}
	// A negative cursor and an absurd limit must not become a whole-table dump.
	rec := do(t, srv, httptest.NewRequest(http.MethodGet,
		"/api/chat/dev/orem?since=-1&limit=999999999", nil))
	if rec.Code != 200 {
		t.Fatalf("get: %d", rec.Code)
	}
	var reply getReply
	if err := json.Unmarshal(rec.Body.Bytes(), &reply); err != nil {
		t.Fatal(err)
	}
	if len(reply.Messages) != 5 {
		t.Fatalf("want the five real messages, got %d", len(reply.Messages))
	}
}

func TestRejectsBadInput(t *testing.T) {
	srv, _, _ := newServer(t)
	cases := []struct{ name, moniker, body string }{
		{"empty body", "alice", ""},
		{"empty moniker", "", "hello there"},
		{"body too long", "alice", strings.Repeat("ab", MaxBodyRunes)},
		{"moniker too long", strings.Repeat("ab", MaxMonikerRunes), "hello there"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", c.moniker, c.body)); rec.Code != 400 {
				t.Fatalf("want 400, got %d %s", rec.Code, rec.Body)
			}
		})
	}
}

// A kicked caller learns their state from the GET, not by having a message eaten.
func TestKickedCallerIsToldBeforeTyping(t *testing.T) {
	srv, st, _ := newServer(t)
	ctx := context.Background()
	addr := mustAddr(t, testAddr)
	ipHash, netHash := HashPair(srv.Hasher, addr)
	if _, err := st.Consequence(ctx, Infraction{
		IPHash: ipHash, NetHash: netHash, Kind: KindKick,
		Reason: ReasonSpam, Duration: time.Hour,
	}); err != nil {
		t.Fatal(err)
	}

	rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/dev/orem", nil))
	var reply getReply
	if err := json.Unmarshal(rec.Body.Bytes(), &reply); err != nil {
		t.Fatal(err)
	}
	if reply.You.State != KindKick || reply.You.Until == 0 {
		t.Fatalf("the caller must be told their own state, got %+v", reply.You)
	}
	if reply.You.Ref == 0 {
		t.Fatal("an appeal needs a reference to quote")
	}
	// And a post is refused with the same information rather than silence.
	if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", "alice", "let me in")); rec.Code != 403 {
		t.Fatalf("want 403, got %d %s", rec.Code, rec.Body)
	}
}

func TestThrottleReturns429WithRetryAfter(t *testing.T) {
	srv, _, _ := newServer(t)
	if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", "alice", "first one here")); rec.Code != 200 {
		t.Fatal(rec.Body)
	}
	rec := do(t, srv, postReq(t, "/api/chat/dev/orem", "alice", "immediately again"))
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("want 429, got %d", rec.Code)
	}
	if rec.Header().Get("Retry-After") == "" {
		t.Fatal("429 must say when to come back")
	}
}

// The country code comes from a trusted proxy header or not at all, and anything
// that is not two letters is dropped rather than rendered.
func TestCountryHeaderIsValidated(t *testing.T) {
	srv, st, _ := newServer(t)
	r := postReq(t, "/api/chat/dev/orem", "alice", "where am i from")
	r.Header.Set("X-Country", "<script>x</script>")
	if rec := do(t, srv, r); rec.Code != 200 {
		t.Fatal(rec.Body)
	}
	msgs, err := st.Recent(context.Background(), "dev", "orem", 0, 10)
	if err != nil {
		t.Fatal(err)
	}
	if msgs[0].Country != "" {
		t.Fatalf("a malformed country must be dropped, got %q", msgs[0].Country)
	}
	// Paired positive.
	r = postReq(t, "/api/chat/dev/orem", "bob", "and now a real one")
	r.Header.Set("X-Country", "de")
	r.RemoteAddr = "198.51.100.7:2222"
	if rec := do(t, srv, r); rec.Code != 200 {
		t.Fatal(rec.Body)
	}
	msgs, _ = st.Recent(context.Background(), "dev", "orem", 0, 10)
	if msgs[1].Country != "DE" {
		t.Fatalf("a real country must be kept and upper-cased, got %q", msgs[1].Country)
	}
}

func TestHealthReportsNoScanner(t *testing.T) {
	srv, _, _ := newServer(t)
	rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/health", nil))
	if rec.Code != 200 {
		t.Fatalf("health: %d", rec.Code)
	}
	var h Health
	if err := json.Unmarshal(rec.Body.Bytes(), &h); err != nil {
		t.Fatal(err)
	}
	if !h.OK || h.Enforcing {
		t.Fatalf("with no scanner: ok and not enforcing, got %+v", h)
	}
}

// A message never leaves the server carrying a model's opinion about its author.
func TestVerdictNeverReachesTheWire(t *testing.T) {
	srv, st, _ := newServer(t)
	if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", "alice", "a scanned message")); rec.Code != 200 {
		t.Fatal(rec.Body)
	}
	if err := st.RecordVerdict(context.Background(), 1, "scam"); err != nil {
		t.Fatal(err)
	}
	rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/dev/orem", nil))
	if strings.Contains(rec.Body.String(), "scam") {
		t.Fatalf("a verdict must never be published: %s", rec.Body)
	}
}

func mustAddr(t *testing.T, s string) netip.Addr {
	t.Helper()
	a, err := netip.ParseAddr(s)
	if err != nil {
		t.Fatal(err)
	}
	return a
}
