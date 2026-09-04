package chat

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"path/filepath"
	"strconv"
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
		// An EMPTY moniker is no longer here: it is answered with DefaultMoniker, and
		// TestABlankNameIsAnon below is where that lives. A name typed out of characters a
		// reader cannot see is still refused, and it is the one case that still reaches
		// ErrEmpty on the moniker.
		{"invisible moniker", "​​", "hello there"},
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

// A BLANK NAME IS ANSWERED, NOT REFUSED. It used to 400 with "pick a name first",
// which asked a reader to make a decision before they could say anything — on a panel
// whose own warning is that a name here proves nothing.
//
// The assertion is on what is STORED and read back, not on the 200: the default is only
// worth anything if the message carries it, and a handler that accepted the post and
// wrote an empty moniker would pass a status check while the transcript showed a blank
// where a name goes.
//
// Whitespace counts as blank for this — a space bar is not a name — and the default is
// sanitized like any other, which the letter count proves rather than assumes.
func TestABlankNameIsAnon(t *testing.T) {
	srv, _, clock := newServer(t)
	for i, blank := range []string{"", "   ", "\t\n"} {
		if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", blank, "hello court")); rec.Code != 200 {
			t.Fatalf("blank %d: want 200, got %d %s", i, rec.Code, rec.Body)
		}
		*clock = clock.Add(MinInterval)
	}
	rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/dev/orem", nil))
	if rec.Code != 200 {
		t.Fatalf("get: %d", rec.Code)
	}
	var reply getReply
	if err := json.Unmarshal(rec.Body.Bytes(), &reply); err != nil {
		t.Fatal(err)
	}
	if len(reply.Messages) != 3 {
		t.Fatalf("want the three posts, got %d", len(reply.Messages))
	}
	for _, m := range reply.Messages {
		if m.Moniker != DefaultMoniker {
			t.Errorf("a blank name must be stored as %q, got %q", DefaultMoniker, m.Moniker)
		}
	}
	// The default passes the same sanitizer every chosen name does, and it must survive
	// it unchanged — a default the moniker rules would refuse or rewrite is a default
	// that only works until somebody tightens them.
	if got, err := SanitizeMoniker(DefaultMoniker); err != nil || got != DefaultMoniker {
		t.Errorf("SanitizeMoniker(%q) = %q, %v — the default must be a legal name",
			DefaultMoniker, got, err)
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
// trustHeaders puts a server into the ONLY configuration where a country header means anything:
// proxy mode, with the address these fixtures connect from listed as a trusted proxy.
//
// Both country tests below used to pass without it, which is exactly what the gate exists to
// stop — with --country-header set and --behind-proxy off, the header is just something the
// client typed, and every client picked the flag shown beside their own name.
func trustHeaders(srv *Server) {
	srv.Policy = IPPolicy{
		BehindProxy: true,
		Trusted:     []netip.Prefix{netip.MustParsePrefix("198.51.100.0/24")},
	}
}

func TestCountryHeaderIsValidated(t *testing.T) {
	srv, st, _ := newServer(t)
	trustHeaders(srv)
	r := postReq(t, "/api/chat/dev/orem", "alice", "where am i from")
	r.Header.Set("X-Country", "<script>x</script>")
	r.RemoteAddr = "198.51.100.6:2222"
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

// An empty room must serialise as an empty LIST, not null.
//
// Found live: a nil slice marshals as `null`, so a client writing the obvious
// `for (const m of data.messages)` crashes — on a brand new court, and again the
// moment moderation hides the only message there.
func TestEmptyRoomIsAnEmptyList(t *testing.T) {
	srv, _, _ := newServer(t)
	rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/dev/quiet", nil))
	if rec.Code != 200 {
		t.Fatalf("get: %d", rec.Code)
	}
	if strings.Contains(rec.Body.String(), `"messages":null`) {
		t.Fatalf("an empty room must return [], got %s", rec.Body)
	}
	var reply struct {
		Messages []Message `json:"messages"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &reply); err != nil {
		t.Fatal(err)
	}
	if reply.Messages == nil {
		t.Fatal("messages decoded as nil; a client iterating it would crash")
	}
	if len(reply.Messages) != 0 {
		t.Fatalf("want an empty list, got %d", len(reply.Messages))
	}
}

// stubGeo is a fake lookup table for the precedence test.
type stubGeo struct{ cc string }

func (s stubGeo) Country(netip.Addr) string { return s.cc }

// The proxy header wins over the table, because a CDN in front of us has better
// information than a database downloaded last month — and a bad value from either
// is dropped rather than rendered.
func TestCountryPrecedenceAndValidation(t *testing.T) {
	cases := []struct {
		name, header, geo, want string
	}{
		{"header only", "DE", "", "DE"},
		{"table only", "", "FR", "FR"},
		{"header beats the table", "DE", "FR", "DE"},
		{"a bad header falls back to the table", "not-a-code", "FR", "FR"},
		{"a bad table value is dropped", "", "<script>", ""},
		{"neither", "", "", ""},
		{"lowercase is normalised", "de", "", "DE"},
	}
	for i, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			srv, st, _ := newServer(t)
			trustHeaders(srv)
			if c.geo != "" {
				srv.Geo = stubGeo{cc: c.geo}
			}
			r := postReq(t, "/api/chat/dev/orem", "alice", "where am i from")
			if c.header != "" {
				r.Header.Set("X-Country", c.header)
			}
			// A distinct address per case, so the per-address interval does not
			// refuse the post and quietly make every assertion vacuous.
			r.RemoteAddr = fmt.Sprintf("198.51.100.%d:1111", i+10)
			if rec := do(t, srv, r); rec.Code != 200 {
				t.Fatalf("post: %d %s", rec.Code, rec.Body)
			}
			msgs, err := st.Recent(context.Background(), "dev", "orem", 0, 10)
			if err != nil {
				t.Fatal(err)
			}
			if len(msgs) != 1 {
				t.Fatalf("want one message, got %d", len(msgs))
			}
			if msgs[0].Country != c.want {
				t.Fatalf("want %q, got %q", c.want, msgs[0].Country)
			}
		})
	}
}

// A FROZEN COURT IS NOT SERVED, which is what the word means and what the tool says.
//
// Freeze gated only Post. So a purged court refused new messages with "this court is no
// longer served" while handing its entire transcript to anybody who asked, and
// `kourtchatctl freeze` printed "its history is no longer served" — a control announcing a
// property it did not have. Found by reading the read path and then measuring it: POST 410,
// GET 200 with every message still there.
//
// Both verbs, both directions, and the neighbouring courts that must be untouched: freeze is
// per chain AND court, so it is exactly the kind of predicate that quietly matches too much.
func TestAFrozenCourtIsNeitherReadNorWritten(t *testing.T) {
	srv, store, clk := newServer(t)
	srv.Chains["test"] = true
	ctx := context.Background()

	// Three partitions: the one to be frozen, another court on the same chain, and the
	// same court name on another chain.
	for _, c := range []struct{ path, body string }{
		{"/api/chat/dev/orem", "something that must stop being served"},
		{"/api/chat/dev/ledger", "an unrelated court on the same chain"},
		{"/api/chat/test/orem", "the same court name on another chain"},
	} {
		*clk = clk.Add(MinInterval + time.Second)
		if rec := do(t, srv, postReq(t, c.path, "alice", c.body)); rec.Code != 200 {
			t.Fatalf("setup %s: %d %s", c.path, rec.Code, rec.Body)
		}
	}
	// Precondition, asserted: it IS served before the freeze, or the test proves nothing.
	if rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/dev/orem", nil)); rec.Code != 200 {
		t.Fatalf("precondition: the court must be served before freezing, got %d", rec.Code)
	}

	if err := store.Freeze(ctx, "dev", "orem"); err != nil {
		t.Fatal(err)
	}

	// THE FIX: reading is refused, with the same 410 the write path already gave.
	rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/dev/orem", nil))
	if rec.Code != http.StatusGone {
		t.Fatalf("a frozen court must not be read: got %d %s", rec.Code, rec.Body)
	}
	if strings.Contains(rec.Body.String(), "must stop being served") {
		t.Fatal("the refusal must not carry the transcript it is refusing")
	}
	// Not an empty list dressed up as a normal answer — that would render as "nobody has
	// said anything here yet" about a court that was withdrawn.
	if strings.Contains(rec.Body.String(), `"messages"`) {
		t.Errorf("a frozen court must not answer with a messages list at all: %s", rec.Body)
	}
	*clk = clk.Add(MinInterval + time.Second)
	if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", "alice", "and posting is refused")); rec.Code != http.StatusGone {
		t.Fatalf("a frozen court must not be written: got %d", rec.Code)
	}

	// THE BYSTANDERS. Same chain different court, and same court name different chain.
	for _, p := range []string{"/api/chat/dev/ledger", "/api/chat/test/orem"} {
		if rec := do(t, srv, httptest.NewRequest(http.MethodGet, p, nil)); rec.Code != 200 {
			t.Errorf("%s must still be served: got %d %s", p, rec.Code, rec.Body)
		}
		*clk = clk.Add(MinInterval + time.Second)
		if rec := do(t, srv, postReq(t, p, "bob", "still able to talk over here")); rec.Code != 200 {
			t.Errorf("%s must still accept messages: got %d %s", p, rec.Code, rec.Body)
		}
	}

	// Freeze stops serving; it does not erase. The rows are still there for an operator
	// who needs them, and the pruner is the separate, irreversible step.
	var n int
	if err := store.r.QueryRow(
		`SELECT count(*) FROM messages WHERE chain='dev' AND court='orem'`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n == 0 {
		t.Error("freeze must not delete: erasure is the pruner's job and a separate decision")
	}
}

// A WITHDRAWN COURT IS NOT MODERATED EITHER.
//
// Third instance of the same shape in as many passes: `frozen` was honoured by Post, then by
// Recent, and by nothing else. So a court withdrawn for an on-chain purge was still being
// handed to the scanner — inference and consequences over content nobody can read — and still
// filling a moderator's review queue with messages that have no available action, since they
// are already unserved.
//
// The reasoning is Claim's own, applied consistently: it skips `hidden` because punished
// content must stop driving verdicts, and withdrawn content is in the same position.
func TestAFrozenCourtIsNotScannedOrQueued(t *testing.T) {
	srv, store, clk := newServer(t)
	srv.Chains["test"] = true
	ctx := context.Background()

	// Two courts, so the bystander is explicit. One message each, flagged and uncited so
	// both are queue candidates, plus one left unscanned in each for the backlog.
	type seed struct{ path, court, body string }
	for _, c := range []seed{
		{"/api/chat/dev/orem", "orem", "flagged in the court that will be frozen"},
		{"/api/chat/dev/orem", "orem", "unscanned in the court that will be frozen"},
		{"/api/chat/dev/ledger", "ledger", "flagged in the court that stays live"},
		{"/api/chat/dev/ledger", "ledger", "unscanned in the court that stays live"},
		// The SAME court name on another chain. frozen is keyed on both, so this is the
		// row that catches a predicate matching on court alone — which it did not, until
		// this line existed.
		{"/api/chat/test/orem", "orem", "flagged in the same name on another chain"},
	} {
		*clk = clk.Add(MinInterval + time.Second)
		if rec := do(t, srv, postReq(t, c.path, "someone", c.body)); rec.Code != 200 {
			t.Fatalf("setup %s: %d %s", c.body, rec.Code, rec.Body)
		}
	}
	for _, id := range []int64{1, 3, 5} { // the "flagged" ones
		if err := store.RecordVerdict(ctx, id, "scam"); err != nil {
			t.Fatal(err)
		}
	}

	// Preconditions, asserted: before the freeze BOTH courts are scanned and queued.
	before, err := store.Claim(ctx, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(before) != 2 {
		t.Fatalf("precondition: both unscanned messages should be claimable, got %d", len(before))
	}
	// Claim marks them; put them back so the post-freeze comparison is fair.
	if _, err := store.w.ExecContext(ctx,
		`UPDATE messages SET scan_state=?, claimed_at=0 WHERE id IN (2,4)`, ScanNew); err != nil {
		t.Fatal(err)
	}
	q, err := store.PendingReview(ctx, false, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(q) != 3 {
		t.Fatalf("precondition: all three flagged messages should be queued, got %d", len(q))
	}

	if err := store.Freeze(ctx, "dev", "orem"); err != nil {
		t.Fatal(err)
	}

	// The scanner must not be offered withdrawn content.
	claimed, err := store.Claim(ctx, 50)
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range claimed {
		if p.Chain == "dev" && p.Court == "orem" {
			t.Errorf("a frozen court must not be scanned: offered id=%d %q", p.ID, p.Body)
		}
	}
	// PAIRED POSITIVE: the live court is still scanned, so this is not "scan nothing".
	live := 0
	for _, p := range claimed {
		if p.Court == "ledger" {
			live++
		}
	}
	if live != 1 {
		t.Errorf("the live court must still be scanned, got %d of its messages", live)
	}

	// And no moderator is asked about a court nobody can read.
	q, err = store.PendingReview(ctx, false, 50)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range q {
		// chain AND court: `test/orem` shares the name and is NOT frozen, so matching on
		// the court alone would fail this test on a row that belongs there.
		if r.Chain == "dev" && r.Court == "orem" {
			t.Errorf("a frozen court must not fill the review queue: id=%d %q", r.ID, r.Body)
		}
	}
	// Both survivors: the live court on this chain, and the same court NAME on another
	// chain, which must be untouched because frozen is keyed on chain AND court.
	if len(q) != 2 {
		t.Errorf("the two unfrozen deferrals must remain, got %d rows", len(q))
	}
	sawOtherChain := false
	for _, r := range q {
		if r.Chain == "test" && r.Court == "orem" {
			sawOtherChain = true
		}
	}
	if !sawOtherChain {
		t.Error("freezing dev/orem must not freeze test/orem: frozen is keyed on both")
	}
	// The grouped view collapses by AUTHOR, and every message here comes from httptest's
	// single address, so one group is the right answer — its COUNT is what shows the frozen
	// row was excluded. Asserting two groups was my error, not the code's.
	groups, err := store.ReviewGroups(ctx, false, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(groups) != 1 {
		t.Fatalf("one author, one group: %+v", groups)
	}
	if groups[0].Count != 2 {
		t.Errorf("the group must count the two unfrozen deferrals and not the frozen one, "+
			"got %d", groups[0].Count)
	}

	// THE INVARIANT THIS FIX COULD HAVE BROKEN. Excluding frozen rows from Claim without
	// excluding them from the backlog would recreate the phantom backlog in a new place:
	// counted forever, never claimable.
	//
	// Compared as a straight equality against a FRESH claim. The first version wrote
	// `Backlog != a && Backlog != b`, which passes whenever either happens to match, and
	// a mutation that broke the invariant survived it.
	if _, err := store.w.ExecContext(ctx,
		`UPDATE messages SET scan_state=?, claimed_at=0 WHERE scan_state=?`,
		ScanNew, ScanClaimed); err != nil {
		t.Fatal(err)
	}
	h, err := store.Health(ctx)
	if err != nil {
		t.Fatal(err)
	}
	fresh, err := store.Claim(ctx, 50)
	if err != nil {
		t.Fatal(err)
	}
	if h.Backlog != len(fresh) {
		t.Errorf("the backlog must equal what Claim offers, or it never drains: "+
			"Backlog=%d, Claim=%d", h.Backlog, len(fresh))
	}
	for _, p := range fresh {
		if p.Chain == "dev" && p.Court == "orem" {
			t.Errorf("still offering the frozen court after a reclaim: id=%d", p.ID)
		}
	}
}

// THE PUBLIC HEALTH ENDPOINT MUST NOT HELP SOMEBODY CHOOSE A MOMENT.
//
// It is unauthenticated, and it was returning the operator's whole telemetry: `enforcing`,
// `backlog`, `scanner_seen_at` and `unscannable`. Those are the four things an attacker wants
// — nobody is being punished right now, the scanner is N messages behind, it last ran at this
// timestamp, it fails this often — and measured on a running server an anonymous GET returned
// all of them. No client in this repo read any of them; `kourtchatctl status` reads the
// database directly.
//
// `enforcing` stays, because §6 requires the panel to disclose dry-run mode and that asymmetry
// favours the honest side: an attacker learns it in one post, a reader cannot learn it at all.
func TestPublicHealthWithholdsOperatorTelemetry(t *testing.T) {
	srv, store, _ := newServer(t)
	ctx := context.Background()

	// Give it something to leak: a backlog, a heartbeat, and an unscannable row.
	if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", "alice", "an unscanned message")); rec.Code != 200 {
		t.Fatal("setup post failed")
	}
	if err := store.Heartbeat(ctx, true, 5*time.Second); err != nil {
		t.Fatal(err)
	}
	h, err := store.Health(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if h.Backlog == 0 || h.ScannerSeen == 0 || !h.Enforcing {
		t.Fatalf("precondition: there must be telemetry to withhold, got %+v", h)
	}

	body := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/health", nil)).Body.String()
	for _, field := range []string{"backlog", "scanner_seen_at", "unscannable"} {
		if strings.Contains(body, field) {
			t.Errorf("the public health endpoint must not carry %q: %s", field, body)
		}
	}
	// PAIRED POSITIVE: it still answers the two things it is for, or it is not a health
	// endpoint at all.
	var pub struct {
		OK        bool `json:"ok"`
		Enforcing bool `json:"enforcing"`
	}
	if err := json.Unmarshal([]byte(body), &pub); err != nil {
		t.Fatal(err)
	}
	if !pub.OK || !pub.Enforcing {
		t.Errorf("it must still report ok and enforcing: %s", body)
	}

	// AND THE OPT-IN, so an operator whose monitoring wants the numbers can have them.
	srv.HealthDetail = true
	body = do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/health", nil)).Body.String()
	for _, field := range []string{"backlog", "scanner_seen_at", "unscannable", "enforcing"} {
		if !strings.Contains(body, field) {
			t.Errorf("with -health-detail the response must carry %q: %s", field, body)
		}
	}
}

// THE APPEAL ROUTE, WHICH THE PANEL PROMISED AND NOTHING PROVIDED.
//
// A punished reader was told "You can appeal — quote reference 9", and there was no channel
// anywhere: not in web/chat.js, not in kourtchatctl, not in CHAT.md. The whole operator surface
// — `why`, `unban`, the evidence copy that outlives pruning — exists to service appeals, and the
// person invited to make one had nowhere to send it. The brief for that surface said a system
// with no reversal makes "appealable" a lie; a reversal nobody can reach is the same lie a step
// later.
//
// Empty by default, and empty means the panel says nothing about appealing rather than inventing
// a route — the same rule as an absent CFG.chat meaning no chat rather than a guessed origin.
func TestTheAppealContactIsPublishedOnlyWhenSet(t *testing.T) {
	srv, _, _ := newServer(t)

	body := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/health", nil)).Body.String()
	if strings.Contains(body, "appeal_to") {
		t.Errorf("unset, it must be absent rather than empty-but-present: %s", body)
	}

	srv.AppealTo = "mods@example.org"
	body = do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/health", nil)).Body.String()
	if !strings.Contains(body, "mods@example.org") {
		t.Errorf("set, it must reach the panel: %s", body)
	}
	// It travels with the detailed form too, or an operator who turned on -health-detail would
	// lose the one field their users need.
	srv.HealthDetail = true
	body = do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/health", nil)).Body.String()
	if !strings.Contains(body, "mods@example.org") || !strings.Contains(body, "backlog") {
		t.Errorf("with -health-detail both must be present: %s", body)
	}
	srv.HealthDetail = false

	// A misconfiguration is swallowed rather than served. The panel escapes what it writes, so
	// this is not the last line of defence — but a newline or a control character in a contact
	// string is somebody's mistake, and a 300-character one is a paste accident.
	for _, bad := range []string{
		"   ",
		"mods@example.org\nX-Injected: yes",
		"mods@example.org\x00",
		"mods@example.org\x1b[31m",
		strings.Repeat("a", 201),
	} {
		srv.AppealTo = bad
		body = do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/health", nil)).Body.String()
		if strings.Contains(body, "appeal_to") {
			t.Errorf("a malformed contact must be withheld, got %s for %q", body, bad)
		}
	}
	// PAIRED POSITIVE: ordinary contacts of every shape an operator would actually use.
	for _, good := range []string{
		"mods@example.org",
		"https://example.org/appeal",
		"the #court-mods channel",
		"  mods@example.org  ", // trimmed, not refused
	} {
		srv.AppealTo = good
		body = do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/health", nil)).Body.String()
		if !strings.Contains(body, "appeal_to") {
			t.Errorf("%q is a reasonable contact and must be published: %s", good, body)
		}
	}
}

// A DUPLICATE'S Retry-After WAS WRONG BY SIXTY TIMES.
//
// Both refusals are 429, which is right, and they shared one `Retry-After: 10`, which was not: a
// duplicate is remembered for DupWindow — ten minutes — so a client honouring that header retried
// in ten seconds and was refused again, and again, until the window ran out. The two cases are
// separate now and the duplicate's value is derived from the constant.
//
// Both arms are asserted, because the bug was not "the header is absent" but "the header is
// confidently wrong", and only comparing them catches that.
func TestRetryAfterMatchesTheRefusalItDescribes(t *testing.T) {
	srv, _, clock := newServer(t)
	const body = "claim your free airdrop at example dot com now"

	// Two courts hold the message; both are accepted.
	for _, court := range []string{"a", "b"} {
		if rec := do(t, srv, postReq(t, "/api/chat/dev/"+court, "alice", body)); rec.Code != 200 {
			t.Fatalf("court %s: %d %s", court, rec.Code, rec.Body)
		}
		*clock = clock.Add(MinInterval + time.Second)
	}
	// The third is a duplicate, not a throttle.
	rec := do(t, srv, postReq(t, "/api/chat/dev/c", "alice", body))
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("want 429 for a duplicate, got %d %s", rec.Code, rec.Body)
	}
	want := strconv.Itoa(int(DupWindow.Seconds()))
	if got := rec.Header().Get("Retry-After"); got != want {
		t.Errorf("a duplicate is remembered for %s, so Retry-After must be %s, got %q — "+
			"a client honouring a shorter value retries into the same refusal",
			DupWindow, want, got)
	}
	// And it tells the person the remedy, since waiting is not the only one.
	if !strings.Contains(rec.Body.String(), "post something different") {
		t.Errorf("the message must say what to do, got %s", rec.Body)
	}

	// THE OTHER ARM: an ordinary throttle keeps the short value. Same status, different wait,
	// which is the whole point of separating them.
	if rec := do(t, srv, postReq(t, "/api/chat/dev/d", "alice", "a different sentence")); rec.Code != 200 {
		t.Fatalf("setup: %d %s", rec.Code, rec.Body)
	}
	rec = do(t, srv, postReq(t, "/api/chat/dev/d", "alice", "immediately again, different too"))
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("want 429 for the interval, got %d %s", rec.Code, rec.Body)
	}
	if got := rec.Header().Get("Retry-After"); got == want {
		t.Errorf("a 2s interval must not quote the duplicate window (%s); got %q", DupWindow, got)
	} else if got == "" {
		t.Error("a throttle still has to say when to come back")
	}
}

// A CURSOR PAST EVERY ROW THAT EXISTS MUST NOT FREEZE THE ROOM.
//
// The endpoint hands back `next` in every response, so a client is invited to poll incrementally.
// `messages.id` is a rowid and prune can empty a court, at which point ids restart at 1 (§7) — so a
// saved cursor asks for `id > 40000` in a court whose newest row is 12 and receives an empty room
// until 40,000 more messages accumulate. Measured before the fix: cursor 8, room holding 2, client
// shown 0.
//
// This panel does not use `since` — chat.js re-reads the last 50 rows every poll so that HIDING
// becomes visible, which appending by id cannot do — so the fix is for every other client, and the
// contract the endpoint advertises.
func TestAStaleCursorRecoversInsteadOfShowingAnEmptyRoom(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()

	var ids []int64
	for i := 0; i < 8; i++ {
		id, err := post(t, s, "orem", "ip-a", "message "+string(rune('a'+i))+" about the docket")
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
		*clock = clock.Add(MinInterval)
	}
	first, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	cursor := first[len(first)-1].ID

	// THE PAIRED POSITIVE, and it is the one that keeps this from being a full fetch every poll:
	// an idle client's cursor equals the newest visible id, and must still receive nothing.
	if m, err := s.Recent(ctx, "dev", "orem", cursor, 50); err != nil {
		t.Fatal(err)
	} else if len(m) != 0 {
		t.Fatalf("an idle poll must return nothing, got %d — the fallback is firing on the "+
			"common case and every poll is now a full read", len(m))
	}

	// Retention empties the court; ids restart well below the saved cursor.
	for _, id := range ids {
		if err := s.RecordVerdict(ctx, id, "clean"); err != nil {
			t.Fatal(err)
		}
	}
	*clock = clock.Add(48 * time.Hour)
	if res, err := s.Prune(ctx, 24*time.Hour, 1000); err != nil {
		t.Fatal(err)
	} else if res.Deleted != len(ids) {
		t.Fatalf("precondition: the court must empty, deleted %d of %d", res.Deleted, len(ids))
	}
	for i := 0; i < 2; i++ {
		if _, err := post(t, s, "orem", "ip-b", "fresh message "+string(rune('a'+i))); err != nil {
			t.Fatal(err)
		}
		*clock = clock.Add(MinInterval)
	}

	room, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(room) != 2 {
		t.Fatalf("precondition: the room holds two new messages, got %d", len(room))
	}
	got, err := s.Recent(ctx, "dev", "orem", cursor, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(room) {
		t.Errorf("a client polling with cursor %d sees %d of %d messages; a cursor past every "+
			"row that exists cannot be valid and must fall back to a full read",
			cursor, len(got), len(room))
	}

	// And an idle poll on the NEW ids is still quiet, so the fallback did not become permanent.
	newCursor := room[len(room)-1].ID
	if m, err := s.Recent(ctx, "dev", "orem", newCursor, 50); err != nil {
		t.Fatal(err)
	} else if len(m) != 0 {
		t.Errorf("after re-syncing, an idle poll must be quiet again, got %d", len(m))
	}
}

// UNFREEZE MUST GIVE BACK EVERYTHING FREEZE TOOK, which is three things and not one.
//
// §9 draws the line this rests on — "'Stop showing this' and 'destroy the evidence' are different
// decisions and only one of them cannot be undone" — and then nothing could undo the first. There
// was no Unfreeze in the store and no command in the tool, so `freeze dev/oren` for `dev/orem`
// withdrew a live court for good: 410 to every reader, posts refused, moderation stopped, recovery
// only by hand-editing SQLite.
//
// Freeze reaches three places and took two passes to get there, which is recorded in §9:
//
//	Post      refuses the write
//	Recent    410 on the read           (missed in the first pass — the transcript kept serving)
//	Claim     stops moderating it       (missed in the second — inference was still spent, and a
//	                                     moderator's queue still filled with its messages)
//
// So this asserts all three coming back. A fix that restored reads and writes while leaving the
// court unmoderated would pass any test that only checked the obvious two, and it is exactly the
// shape §9's audit table is full of.
func TestUnfreezeRestoresReadsWritesAndModeration(t *testing.T) {
	srv, s, clock := newServer(t)
	ctx := context.Background()

	// A live court with something in it.
	if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", "alice", "before the freeze")); rec.Code != 200 {
		t.Fatal(rec.Body)
	}
	*clock = clock.Add(MinInterval + time.Second)
	if err := s.Freeze(ctx, "dev", "orem"); err != nil {
		t.Fatal(err)
	}

	// Frozen: all three off. Asserted so the restoration below is not vacuous.
	if rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/dev/orem", nil)); rec.Code != http.StatusGone {
		t.Fatalf("precondition: a frozen court reads 410, got %d", rec.Code)
	}
	if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", "alice", "during the freeze")); rec.Code == 200 {
		t.Fatal("precondition: a frozen court must refuse writes")
	}
	if pend, err := s.Claim(ctx, 10); err != nil {
		t.Fatal(err)
	} else if len(pend) != 0 {
		t.Fatalf("precondition: a frozen court is not scanned, got %d claimable", len(pend))
	}

	lifted, err := s.Unfreeze(ctx, "dev", "orem")
	if err != nil {
		t.Fatal(err)
	}
	if !lifted {
		t.Fatal("unfreezing a frozen court must report that it changed something")
	}

	// 1. The read.
	rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/dev/orem", nil))
	if rec.Code != 200 {
		t.Errorf("the history must be served again, got %d %s", rec.Code, rec.Body)
	}
	// 2. The write.
	*clock = clock.Add(MinInterval + time.Second)
	if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", "alice", "after the thaw")); rec.Code != 200 {
		t.Errorf("posts must be accepted again, got %d %s", rec.Code, rec.Body)
	}
	// 3. MODERATION, the one a partial fix leaves behind.
	pend, err := s.Claim(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(pend) == 0 {
		t.Error("a court back in service must be scanned again; leaving it unmoderated is the " +
			"same half-applied control §9 records freeze itself having twice")
	}

	// The row stays, stamped, so a later operator can see it was frozen at all.
	var at, liftedAt int64
	if err := s.r.QueryRow(`SELECT at, coalesce(lifted_at,0) FROM frozen
	   WHERE chain='dev' AND court='orem'`).Scan(&at, &liftedAt); err != nil {
		t.Fatalf("the freeze must be recorded as lifted rather than deleted: %v", err)
	}
	if at == 0 || liftedAt == 0 {
		t.Errorf("both stamps must survive: at=%d lifted_at=%d", at, liftedAt)
	}
}

// The typo guard, and the paired positive that keeps it honest.
func TestUnfreezeReportsWhenThereWasNothingToLift(t *testing.T) {
	s, _ := newStore(t)
	ctx := context.Background()

	// Never frozen: nothing to lift, and the caller must be able to tell.
	if lifted, err := s.Unfreeze(ctx, "dev", "orem"); err != nil {
		t.Fatal(err)
	} else if lifted {
		t.Error("a court that was never frozen must not report a lift; the CLI turns this into " +
			"a refusal, because \"dev/oren is back in service\" over a live court is the same " +
			"lie one verb along")
	}

	// Two courts, one frozen. Lifting the other must not touch it.
	if err := s.Freeze(ctx, "dev", "orem"); err != nil {
		t.Fatal(err)
	}
	if lifted, err := s.Unfreeze(ctx, "dev", "other"); err != nil {
		t.Fatal(err)
	} else if lifted {
		t.Error("lifting a different court must not report a change")
	}
	if frozen, err := s.IsFrozen(ctx, "dev", "orem"); err != nil {
		t.Fatal(err)
	} else if !frozen {
		t.Error("and must not thaw the court that IS frozen")
	}
	// A second lift of an already-lifted court is also nothing.
	if _, err := s.Unfreeze(ctx, "dev", "orem"); err != nil {
		t.Fatal(err)
	}
	if lifted, err := s.Unfreeze(ctx, "dev", "orem"); err != nil {
		t.Fatal(err)
	} else if lifted {
		t.Error("lifting twice must report nothing the second time")
	}
}

// AND IT MUST BE RE-FREEZABLE. The old INSERT OR IGNORE would hit the surviving row and do
// nothing, leaving the tool printing "its history is no longer served" over a live court — a
// control that announces a property it does not have, which is the failure §9 names.
func TestACourtCanBeFrozenAgainAfterBeingLifted(t *testing.T) {
	s, _ := newStore(t)
	ctx := context.Background()

	for round := 0; round < 2; round++ {
		if err := s.Freeze(ctx, "dev", "orem"); err != nil {
			t.Fatal(err)
		}
		if frozen, err := s.IsFrozen(ctx, "dev", "orem"); err != nil {
			t.Fatal(err)
		} else if !frozen {
			t.Fatalf("round %d: freeze must take effect", round)
		}
		if _, err := s.Unfreeze(ctx, "dev", "orem"); err != nil {
			t.Fatal(err)
		}
		if frozen, err := s.IsFrozen(ctx, "dev", "orem"); err != nil {
			t.Fatal(err)
		} else if frozen {
			t.Fatalf("round %d: the lift must take effect", round)
		}
	}
}

// A REFUSAL MUST NAME THE RIGHT FIELD AND SAY WHAT WOULD BE ACCEPTED.
//
// The server used to write `"moniker: " + err.Error()`, and the sanitiser's messages are phrased
// for a message BODY, so a rejected name came back as:
//
//	{"error":"moniker: message is too long"}                  the wrong field, named twice over
//	{"error":"message: message is too long"}                  a stutter on the other path
//	{"error":"moniker: message contains control characters"}
//
// Three problems in one line: it names the wrong thing, it stutters, and it gives no LIMIT — while
// the throttle two cases below says "one message every 2s" and "10 per 1m0s". A caller told only
// "too long" can do nothing but guess, and the moniker's rule is not guessable, because it counts
// LETTERS: marks do not consume the budget, so 24 is not a character count.
func TestARefusalNamesTheFieldAndItsLimit(t *testing.T) {
	for _, c := range []struct {
		err         error
		field       refusalField
		wants       []string
		mustNotHave []string
	}{
		{ErrTooLong, fieldMoniker,
			[]string{"your name", "too long", strconv.Itoa(MaxMonikerRunes), "letters"},
			[]string{"message", "characters"}},
		{ErrTooLong, fieldBody,
			[]string{"your message", "too long", strconv.Itoa(MaxBodyRunes), "characters"},
			[]string{"name", "letters"}},
		{ErrEmpty, fieldMoniker, []string{"name"}, []string{"message"}},
		{ErrEmpty, fieldBody, []string{"something"}, []string{"name"}},
		{ErrControl, fieldMoniker, []string{"your name", "cannot be displayed"}, []string{"message"}},
		{ErrControl, fieldBody, []string{"your message", "cannot be displayed"}, []string{"name"}},
		{ErrJoiners, fieldBody, []string{"your message", "joining"}, []string{"name"}},
		{ErrMarks, fieldBody, []string{"your message", "accents"}, []string{"name"}},
		{ErrOversize, fieldBody,
			[]string{"your message", strconv.Itoa(MaxInputBytes), "bytes"}, []string{"name"}},
	} {
		got := refusalText(c.field, c.err)
		label := "body"
		if c.field == fieldMoniker {
			label = "moniker"
		}
		t.Run(label+"/"+c.err.Error(), func(t *testing.T) {
			for _, w := range c.wants {
				if !strings.Contains(got, w) {
					t.Errorf("must contain %q, got %q", w, got)
				}
			}
			for _, n := range c.mustNotHave {
				if strings.Contains(got, n) {
					t.Errorf("must NOT contain %q — that is the other field's word, got %q", n, got)
				}
			}
			// The stutter, asserted directly: it was the visible symptom.
			if strings.Count(got, "message") > 1 {
				t.Errorf("says \"message\" more than once, got %q", got)
			}
			if strings.Contains(got, ": message is") {
				t.Errorf("the old stutter is back, got %q", got)
			}
		})
	}
}

// The numbers must come from the constants, not from a literal that agrees with them today. Written
// as a comparison rather than a fixed string so raising a limit updates the message for free.
func TestARefusalQuotesTheLimitThatIsActuallyEnforced(t *testing.T) {
	for _, c := range []struct {
		field refusalField
		limit int
	}{{fieldMoniker, MaxMonikerRunes}, {fieldBody, MaxBodyRunes}} {
		got := refusalText(c.field, ErrTooLong)
		if !strings.Contains(got, strconv.Itoa(c.limit)) {
			t.Errorf("refusal %q does not quote the enforced limit %d", got, c.limit)
		}
		// And no OTHER limit, which is how a copied line goes wrong: a name refusal quoting 400
		// would send somebody trimming to the wrong length.
		for _, other := range []int{MaxMonikerRunes, MaxBodyRunes, MaxInputBytes} {
			if other == c.limit {
				continue
			}
			if strings.Contains(got, strconv.Itoa(other)) {
				t.Errorf("refusal %q quotes %d, which is a different limit", got, other)
			}
		}
	}
}

// End to end, because the sentence is only useful if it reaches the caller: a refused name comes
// back over HTTP as the composed text and not as the sanitiser's own words.
func TestTheComposedRefusalIsWhatTheCallerReceives(t *testing.T) {
	srv, _, _ := newServer(t)
	long := strings.Repeat("ab", MaxMonikerRunes) // well over the letter limit, no identical run
	rec := do(t, srv, postReq(t, "/api/chat/dev/orem", long, "hello there"))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("want 400, got %d %s", rec.Code, rec.Body)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "your name is too long") {
		t.Errorf("the caller must get the composed sentence, got %s", body)
	}
	if strings.Contains(body, "moniker: message") {
		t.Errorf("the old text is back, got %s", body)
	}
	// The paired positive: an acceptable name and body are not refused, so none of the above is
	// passing for a server that rejects everything.
	if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", "alice", "an ordinary message")); rec.Code != 200 {
		t.Errorf("an ordinary post must succeed, got %d %s", rec.Code, rec.Body)
	}
}

// TOO BIG IS NOT MALFORMED, and both used to report the second.
//
// The body is bounded by http.MaxBytesReader before Decode reads any of it, which is right — the
// per-field limit in the sanitiser is checked after, and cannot bound memory. But when that cap
// tripped, Decode returned an error and the handler blamed the JSON. Measured live: a 100 kB body of
// perfectly valid JSON came back 400 with `expected {"moniker":…,"body":…}`, which sends a client to
// their serialiser when the fix is to send less. A 5 kB body — over the sanitiser's limit, under the
// cap — already said "far too long to process", so ONE condition was reported two ways depending on
// which check happened to catch it.
//
// The four regimes are asserted together because the point is that they are distinguishable, not
// that any one of them has a particular string.
func TestAnOversizeRequestSaysSoRatherThanBlamingTheJSON(t *testing.T) {
	srv, _, _ := newServer(t)

	post := func(raw string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPost, "/api/chat/dev/orem", strings.NewReader(raw))
		r.Header.Set("Content-Type", "application/json")
		return do(t, srv, r)
	}
	jsonOf := func(n int) string {
		b, err := json.Marshal(postBody{Moniker: "alice", Body: strings.Repeat("x", n)})
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}

	// 1. Past the request cap: valid JSON, too much of it.
	rec := post(jsonOf(100_000))
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("an oversize request must be 413, got %d %s", rec.Code, rec.Body)
	}
	if strings.Contains(rec.Body.String(), "expected {") {
		t.Errorf("and must not blame the JSON, which was valid: %s", rec.Body)
	}
	if !strings.Contains(rec.Body.String(), strconv.Itoa(MaxInputBytes)) {
		t.Errorf("and must name the limit that is the client's to work with: %s", rec.Body)
	}

	// 2. Over the sanitiser's per-field limit but under the cap: the other size regime, which must
	// name the SAME actionable number.
	rec = post(jsonOf(MaxInputBytes + 1000))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("a field over its limit is a 400, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), strconv.Itoa(MaxInputBytes)) {
		t.Errorf("and names the same limit: %s", rec.Body)
	}

	// 3. Genuinely malformed JSON keeps the message that describes it. Without this the fix could
	// have been "call everything too large".
	rec = post(`{"moniker":`)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("malformed JSON is a 400, got %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "expected {") {
		t.Errorf("and must still say the shape it wanted: %s", rec.Body)
	}

	// 4. THE PAIRED POSITIVE: an ordinary post still works, so none of the above is passing for a
	// handler that refuses everything.
	rec = post(`{"moniker":"alice","body":"an ordinary message"}`)
	if rec.Code != http.StatusOK {
		t.Errorf("an ordinary post must succeed, got %d %s", rec.Code, rec.Body)
	}
}

// A REFUSAL THE OPERATOR CANNOT SEE IS A SERVICE THAT SILENTLY STOPPED.
//
// The 403 goes to the client. When the cause is a `--trusted-proxy` range wide enough to contain the
// real clients, EVERY request is refused and the person who can fix it never sees the message — the
// symptom is "nobody can post" and the log said nothing at all.
//
// Once per cause, because both causes are persistent conditions rather than events: a
// misconfiguration fires on every request and would fill the disk, and somebody probing the origin
// directly chooses the rate.
func TestARefusedClientIsLoggedOncePerCause(t *testing.T) {
	logs := func(srv *Server) *bytes.Buffer {
		var b bytes.Buffer
		srv.Log = log.New(&b, "", 0)
		return &b
	}
	post := func(srv *Server, remote, xff string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(http.MethodPost, "/api/chat/dev/orem",
			strings.NewReader(`{"moniker":"alice","body":"hello there"}`))
		r.Header.Set("Content-Type", "application/json")
		r.RemoteAddr = remote
		if xff != "" {
			r.Header.Set("X-Forwarded-For", xff)
		}
		return do(t, srv, r)
	}

	t.Run("an all-trusted chain says which knob is wrong", func(t *testing.T) {
		srv, _, _ := newServer(t)
		srv.Policy = IPPolicy{BehindProxy: true, Trusted: prefixes(t, "10.0.0.0/8")}
		out := logs(srv)
		if rec := post(srv, "10.0.0.7:443", "10.0.0.3"); rec.Code != http.StatusForbidden {
			t.Fatalf("precondition: this must be refused, got %d", rec.Code)
		}
		got := out.String()
		for _, want := range []string{"--trusted-proxy", "10.0.0.7", "Narrow the range"} {
			if !strings.Contains(got, want) {
				t.Errorf("the line must contain %q, got %q", want, got)
			}
		}

		// ONCE. Ten more refusals must add nothing, or a misconfiguration fills the disk.
		before := out.Len()
		for i := 0; i < 10; i++ {
			post(srv, "10.0.0.7:443", "10.0.0.3")
		}
		if out.Len() != before {
			t.Errorf("ten more refusals added %d bytes; this must be once per cause",
				out.Len()-before)
		}
	})

	t.Run("an untrusted peer gets its own line", func(t *testing.T) {
		srv, _, _ := newServer(t)
		srv.Policy = IPPolicy{BehindProxy: true, Trusted: prefixes(t, "10.0.0.0/8")}
		out := logs(srv)
		if rec := post(srv, "203.0.113.9:5555", "1.2.3.4"); rec.Code != http.StatusForbidden {
			t.Fatalf("precondition: this must be refused, got %d", rec.Code)
		}
		got := out.String()
		if !strings.Contains(got, "203.0.113.9") {
			t.Errorf("the line must name the peer, got %q", got)
		}
		if strings.Contains(got, "Narrow the range") {
			t.Errorf("and must not be the other cause's advice, got %q", got)
		}
	})

	// THE ONE WITH TEETH: the header is attacker-controlled and does not pass through the
	// sanitiser, so a raw Printf would put escape sequences into an operator's terminal. ANSI can
	// rewrite the lines above it, which is a way to hide the very refusal being reported.
	t.Run("escape sequences in the header cannot reach a terminal raw", func(t *testing.T) {
		srv, _, _ := newServer(t)
		srv.Policy = IPPolicy{BehindProxy: true, Trusted: prefixes(t, "10.0.0.0/8")}
		out := logs(srv)
		// A VALID trusted hop plus junk as a separate entry. Appending the escapes to the IP
		// instead makes that hop malformed, which takes the no-header branch — the peer becomes
		// the client, the request SUCCEEDS, and nothing is logged. That is the correct behaviour
		// and it is how the first version of this case measured nothing.
		post(srv, "10.0.0.7:443", "10.0.0.3, \x1b[2K\x1b[Anothing to see")
		got := out.String()
		if strings.ContainsRune(got, 0x1b) {
			t.Errorf("a raw ESC reached the log: %q", got)
		}
		if !strings.Contains(got, `\x1b`) {
			t.Errorf("and it must still be visible as an escape, so the operator sees the "+
				"attempt: %q", got)
		}
	})

	// THE PAIRED POSITIVE: an ordinary request logs nothing. Without this the assertions above
	// pass for a logger that narrates every request.
	t.Run("an accepted request says nothing", func(t *testing.T) {
		srv, _, _ := newServer(t)
		srv.Policy = IPPolicy{BehindProxy: true, Trusted: prefixes(t, "127.0.0.0/8")}
		out := logs(srv)
		if rec := post(srv, "127.0.0.1:5555", "203.0.113.7"); rec.Code != http.StatusOK {
			t.Fatalf("precondition: this must be accepted, got %d %s", rec.Code, rec.Body)
		}
		if out.Len() != 0 {
			t.Errorf("an accepted request must log nothing, got %q", out.String())
		}
	})
}

// A CLIENT MUST NOT CHOOSE THE FLAG SHOWN BESIDE ITS OWN NAME.
//
// CountryHeader is described as "a trusted proxy header" and nothing established that it came
// from one: r.Header.Get was read on every request. In proxy mode that was harmless by accident,
// because s.client refuses an untrusted peer with a 403 before this code runs. With
// --country-header set and --behind-proxy off there is no such refusal, and the header was
// believed from anybody.
//
// §8 says the flag is decoration and nothing may be built on it, so this is not a hole in a
// boundary. It is worth closing because a flag is a credibility affordance aimed at readers, and
// §6 measured what one of those is worth: gemma3:4b reads the same lure from "kourt-moderator" as
// legitimate and from "dave" as a scam. A flag an impersonator picks is that discount pointed at
// people instead of at the model.
func TestADirectClientCannotChooseItsOwnFlag(t *testing.T) {
	srv, st, _ := newServer(t)
	// No proxy configuration: the documented default, and the one where X-Forwarded-For is
	// already "not consulted at all". The country header now gets the same treatment.
	r := postReq(t, "/api/chat/dev/orem", "alice", "i would like a flag please")
	r.Header.Set("X-Country", "DE")
	r.RemoteAddr = "203.0.113.9:5555"
	if rec := do(t, srv, r); rec.Code != 200 {
		t.Fatalf("the post itself must still succeed — only the flag is refused: %d %s",
			rec.Code, rec.Body)
	}
	msgs, err := st.Recent(context.Background(), "dev", "orem", 0, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 1 {
		t.Fatalf("want the message stored, got %d", len(msgs))
	}
	if msgs[0].Country != "" {
		t.Errorf("a client set X-Country: DE on a direct connection and got %q. On a server "+
			"that is not behind a proxy the header is only something the client typed",
			msgs[0].Country)
	}

	// THE BYSTANDER: the local table is a different source and must be unaffected. Gating the
	// header on proxy mode must not turn flags off for a deployment that resolves them itself.
	srv2, st2, _ := newServer(t)
	srv2.Geo = stubGeo{cc: "FR"}
	r2 := postReq(t, "/api/chat/dev/orem", "bob", "and i get mine from the table")
	r2.Header.Set("X-Country", "DE") // ignored; the table answers
	r2.RemoteAddr = "203.0.113.10:5555"
	if rec := do(t, srv2, r2); rec.Code != 200 {
		t.Fatalf("post: %d %s", rec.Code, rec.Body)
	}
	msgs2, err := st2.Recent(context.Background(), "dev", "orem", 0, 10)
	if err != nil {
		t.Fatal(err)
	}
	if msgs2[0].Country != "FR" {
		t.Errorf("a locally-resolved flag must still work without a proxy, and must not be "+
			"overridden by the client's own header: got %q, want FR", msgs2[0].Country)
	}
}

// TrustsPeer is the predicate both header paths now share, so its own table is worth having —
// including the two cases that answer no for different reasons.
func TestTrustsPeer(t *testing.T) {
	proxied := IPPolicy{
		BehindProxy: true,
		Trusted:     []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8")},
	}
	for _, c := range []struct {
		name   string
		policy IPPolicy
		remote string
		want   bool
	}{
		{"a trusted proxy in proxy mode", proxied, "10.1.2.3:4444", true},
		{"a direct client reaching the origin", proxied, "203.0.113.9:4444", false},
		{"proxy mode off, even from the listed range", IPPolicy{
			Trusted: []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8")},
		}, "10.1.2.3:4444", false},
		{"an unparseable peer", proxied, "not-an-address", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			if got := c.policy.TrustsPeer(c.remote); got != c.want {
				t.Errorf("TrustsPeer(%q) = %v, want %v", c.remote, got, c.want)
			}
		})
	}
}
