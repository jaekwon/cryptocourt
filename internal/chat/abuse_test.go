package chat

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The HTTP surface under deliberate abuse.
//
// Everything else about this service is reached through here, and this is the only part
// of it exposed to the open internet. The existing server tests cover the decisions —
// CSRF, the chain allowlist, the throttle, the field limits. What they do not cover is
// malformed input: path shapes, type confusion in the JSON, bodies that are too big,
// and the content-type variants a real client actually sends.
//
// Every refusal here is paired with the ordinary request it must NOT refuse, because a
// handler that 400s everything passes a table of refusals and serves nobody. Two of the
// pairs matter more than the rest: `application/json; charset=utf-8` is what a great
// many HTTP clients send and refusing it would be a self-inflicted outage, and a
// too-large body must be REFUSED rather than truncated into a shorter message that then
// looks legitimate.

// postOK advances past the per-address interval and asserts the post lands.
//
// Needed because every request in this file comes from httptest's single default address
// against a frozen clock, so the SECOND accepted post in any fixture is a 429. The first
// version of these tests read as five content-type failures that were really one throttle
// doing its job — the throttle is not what is under test here, so it is stepped over
// rather than worked around.
func postOK(t *testing.T, srv *Server, clk *time.Time, path, ct, body string) {
	t.Helper()
	*clk = clk.Add(MinInterval + time.Second)
	rec := do(t, srv, rawPost(t, path, ct, body))
	if rec.Code != 200 {
		t.Fatalf("%q must be accepted, got %d %s", ct, rec.Code, rec.Body)
	}
}

func rawPost(t *testing.T, path, contentType, body string) *http.Request {
	t.Helper()
	r := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	if contentType != "" {
		r.Header.Set("Content-Type", contentType)
	}
	return r
}

// PATH SHAPES. path() splits on "/" and demands exactly two segments; net/http cleans
// the URL before a handler sees it. Between them the traversal cases should never reach
// a court name, but "should" is doing a lot of work in a sentence about path parsing.
func TestMalformedPathsAreRefused(t *testing.T) {
	srv, _, clk := newServer(t)
	for _, p := range []string{
		"/api/chat/dev/orem/extra",                 // a third segment
		"/api/chat/dev",                            // only one
		"/api/chat/",                               // none
		"/api/chat/dev/",                           // empty court
		"/api/chat//orem",                          // empty chain
		"/api/chat/dev/orem/",                      // trailing slash after a valid pair
		"/api/chat/dev/../../secret",               // traversal, pre-cleaning
		"/api/chat/dev/%2e%2e",                     // traversal, encoded
		"/api/chat/dev/OREM",                       // the court regex is lower-case only
		"/api/chat/dev/orem%20two",                 // a space
		"/api/chat/dev/" + strings.Repeat("x", 33), // one over the 32-rune cap
	} {
		t.Run(p, func(t *testing.T) {
			rec := do(t, srv, postReq(t, p, "alice", "hello there"))
			if rec.Code == 200 {
				t.Fatalf("%s was ACCEPTED; it must not be", p)
			}
			// 404 or 405 are both fine; what must never happen is a 500, which would
			// mean the path reached code that did not expect it.
			if rec.Code >= 500 {
				t.Fatalf("%s produced %d — a malformed path must be refused, not crash",
					p, rec.Code)
			}
		})
	}
	// PAIRED POSITIVE, and the exact-length boundary rather than a comfortable name:
	// 32 runes is legal, 33 is not, and only checking a short name would leave the
	// boundary untested in both directions.
	longButLegal := strings.Repeat("x", 32)
	postOK(t, srv, clk, "/api/chat/dev/"+longButLegal, "application/json",
		`{"moniker":"alice","body":"a 32-character court is legal"}`)
	postOK(t, srv, clk, "/api/chat/dev/orem", "application/json",
		`{"moniker":"alice","body":"and the ordinary path works"}`)
}

// TYPE CONFUSION. The decoder targets two string fields; anything else must be a 400
// and not a panic. `null` and `{}` are the interesting ones — both decode without error
// into empty strings, so they have to be caught by the sanitiser rather than the decoder.
func TestJSONTypeConfusion(t *testing.T) {
	srv, _, clk := newServer(t)
	for _, body := range []string{
		`{"moniker": 123, "body": "hello there"}`,
		`{"moniker": {}, "body": "hello there"}`,
		`{"moniker": [], "body": "hello there"}`,
		`{"moniker": true, "body": "hello there"}`,
		`{"moniker": "alice", "body": 42}`,
		`{"moniker": "alice", "body": ["hello"]}`,
		`{"moniker": null, "body": null}`,
		`{}`,
		`null`,
		`[]`,
		`"just a string"`,
		`42`,
		``,
		`{"moniker": "alice", "body": "unterminated`,
		`{"moniker": "alice", "body": "hello there"} trailing garbage`,
		`{"moniker":"alice","body":"hello there"}{"moniker":"b","body":"smuggled"}`,
	} {
		t.Run(fmt.Sprintf("%.34q", body), func(t *testing.T) {
			rec := do(t, srv, rawPost(t, "/api/chat/dev/orem", "application/json", body))
			if rec.Code == 200 {
				t.Fatalf("accepted %q", body)
			}
			if rec.Code >= 500 {
				t.Fatalf("%q produced %d — malformed JSON must be a 400, not a crash",
					body, rec.Code)
			}
		})
	}
	// TRAILING WHITESPACE IS NOT TRAILING GARBAGE. Refusing content after the JSON value
	// is only safe if the check ignores what real clients append: a newline from a shell
	// heredoc, CRLF from a Windows tool, a stray space. Getting this wrong would refuse
	// `curl --data @file` and read as a mysterious 400. json.Decoder skips whitespace
	// before reporting More(), and this is the assertion that keeps that true.
	for i, tail := range []string{"\n", "\r\n", "  ", "\t", "\n\n  \n"} {
		postOK(t, srv, clk, "/api/chat/dev/orem", "application/json",
			fmt.Sprintf(`{"moniker":"alice","body":"trailing whitespace %d"}`, i)+tail)
	}

	// Duplicate keys: Go keeps the last. Not a vulnerability, but worth pinning so the
	// behaviour is a decision rather than a surprise — a client sending both must not
	// be able to smuggle a body past a reviewer reading the first.
	postOK(t, srv, clk, "/api/chat/dev/orem", "application/json",
		`{"body":"the first one","moniker":"alice","body":"the second one"}`)
	var got struct{ Messages []Message }
	rec2 := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/dev/orem", nil))
	if err := json.Unmarshal(rec2.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	// Asserted on the newest message rather than "the only one" — the whitespace cases
	// above left five in the room, and an assertion that counts rows breaks whenever a
	// neighbouring case posts.
	if len(got.Messages) == 0 {
		t.Fatal("nothing was stored")
	}
	last := got.Messages[len(got.Messages)-1]
	if last.Body != "the second one" {
		t.Fatalf("the LAST duplicate key wins; newest message is %q", last.Body)
	}
	for _, m := range got.Messages {
		if m.Body == "the first one" {
			t.Fatal("the first duplicate key must not be what got stored")
		}
	}
}

// SIZE. A body over the reader's cap must be refused outright. Truncation would be the
// dangerous outcome: a 10MB message cut down to something short and plausible, accepted
// as though the sender had written it.
func TestOversizedBodyIsRefusedNotTruncated(t *testing.T) {
	srv, store, clk := newServer(t)
	huge := strings.Repeat("a", MaxInputBytes*4)
	b, _ := json.Marshal(postBody{Moniker: "alice", Body: huge})
	r := httptest.NewRequest(http.MethodPost, "/api/chat/dev/orem", bytes.NewReader(b))
	r.Header.Set("Content-Type", "application/json")
	rec := do(t, srv, r)
	if rec.Code == 200 {
		t.Fatal("a body over the cap was accepted")
	}
	if rec.Code >= 500 {
		t.Fatalf("an oversized body must be a 4xx, got %d", rec.Code)
	}
	// The half that matters: nothing was stored. A truncated accept would leave a row.
	msgs, err := store.Recent(t.Context(), "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 0 {
		t.Fatalf("nothing must be stored from a refused body, got %d rows: %q",
			len(msgs), msgs[0].Body)
	}
	// PAIRED POSITIVE at the boundary the sanitiser enforces, not the reader's: a
	// message of exactly MaxBodyRunes must still be accepted.
	*clk = clk.Add(MinInterval + time.Second)
	if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", "alice",
		strings.Repeat("a", MaxBodyRunes))); rec.Code != 200 {
		t.Fatalf("a maximum-length message must be accepted, got %d %s", rec.Code, rec.Body)
	}
}

// CONTENT TYPE. The rule is load-bearing for CSRF, so it must be strict about the type
// and relaxed about everything a real client decorates it with. Refusing
// "application/json; charset=utf-8" would be a self-inflicted outage.
func TestContentTypeVariants(t *testing.T) {
	srv, _, clk := newServer(t)
	body := `{"moniker":"alice","body":"an ordinary message"}`
	accept := []string{
		"application/json",
		"application/json; charset=utf-8",
		"application/json;charset=UTF-8",
		"APPLICATION/JSON",
		"Application/Json; charset=utf-8",
		"  application/json  ",
	}
	for i, ct := range accept {
		t.Run("accept "+ct, func(t *testing.T) {
			// A distinct body per case, or the duplicate rule refuses the second one and
			// the test reads as a content-type failure.
			postOK(t, srv, clk, "/api/chat/dev/orem", ct,
				fmt.Sprintf(`{"moniker":"alice","body":"an ordinary message number %d"}`, i))
		})
	}
	for _, ct := range []string{
		"", "text/plain", "text/plain;charset=utf-8", "application/x-www-form-urlencoded",
		"multipart/form-data", "application/jsonx", "application/json-patch+json",
		"text/json", "json",
	} {
		t.Run("refuse "+ct, func(t *testing.T) {
			rec := do(t, srv, rawPost(t, "/api/chat/dev/orem", ct, body))
			if rec.Code != http.StatusUnsupportedMediaType {
				t.Fatalf("%q must be refused with 415, got %d", ct, rec.Code)
			}
		})
	}
}

// METHODS. Anything but GET, POST and OPTIONS is a 405 — and specifically not a 404,
// which would suggest the court does not exist.
func TestUnsupportedMethods(t *testing.T) {
	srv, _, _ := newServer(t)
	for _, m := range []string{http.MethodPut, http.MethodDelete, http.MethodPatch,
		http.MethodHead, http.MethodTrace} {
		t.Run(m, func(t *testing.T) {
			r := httptest.NewRequest(m, "/api/chat/dev/orem", nil)
			rec := do(t, srv, r)
			if rec.Code != http.StatusMethodNotAllowed {
				t.Fatalf("%s must be 405, got %d", m, rec.Code)
			}
		})
	}
	// PAIRED POSITIVES: the three that must work.
	if rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/dev/orem", nil)); rec.Code != 200 {
		t.Fatalf("GET must work, got %d", rec.Code)
	}
	if rec := do(t, srv, httptest.NewRequest(http.MethodOptions, "/api/chat/dev/orem", nil)); rec.Code != 204 {
		t.Fatalf("OPTIONS must be 204, got %d", rec.Code)
	}
	if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", "alice", "hello there")); rec.Code != 200 {
		t.Fatalf("POST must work, got %d %s", rec.Code, rec.Body)
	}
}

// QUERY PARAMETERS. since and limit are clamped elsewhere; what is checked here is that
// garbage in them cannot produce an error or an unbounded read.
func TestGarbageQueryParameters(t *testing.T) {
	srv, _, _ := newServer(t)
	if rec := do(t, srv, postReq(t, "/api/chat/dev/orem", "alice", "a message to find")); rec.Code != 200 {
		t.Fatal("setup post failed")
	}
	for _, q := range []string{
		"?since=abc", "?since=-1", "?since=99999999999999999999",
		"?limit=abc", "?limit=-5", "?limit=0", "?limit=100000",
		"?since=1&since=2", "?limit=10&limit=abc",
		"?since=%00", "?limit=1e9", "?unknown=1",
		"?since=" + strings.Repeat("9", 400),
	} {
		t.Run(q, func(t *testing.T) {
			rec := do(t, srv, httptest.NewRequest(http.MethodGet, "/api/chat/dev/orem"+q, nil))
			if rec.Code != 200 {
				t.Fatalf("garbage query params must be clamped, not refused: got %d %s",
					rec.Code, rec.Body)
			}
			var got struct{ Messages []Message }
			if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
				t.Fatalf("the reply must still be JSON: %v", err)
			}
			if len(got.Messages) > 200 {
				t.Fatalf("the limit clamp did not hold: %d messages", len(got.Messages))
			}
		})
	}
}
