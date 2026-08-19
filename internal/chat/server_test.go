package chat

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
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
	if err := store.Heartbeat(ctx, true); err != nil {
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
