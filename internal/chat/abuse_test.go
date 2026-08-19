package chat

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
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

// SPREADING TRAFFIC ACROSS ROOMS MUST NOT BUY MORE OF IT.
//
// The court in a path is client-chosen and only shape-checked, so one address can invent
// as many rooms as it likes — measured, 110 distinct rooms in ten minutes of clock, bounded
// only by the per-address rate. The worry that follows is obvious: §5's per-court soft cap
// and fair share are per COURT, so does scattering messages across invented rooms evade
// them and multiply what one address can post?
//
// It does not, and that is worth pinning rather than reasoning about, because it is the
// difference between "the namespace is untidy" and "the throttle has a hole in it".
// PerIPMax is per ADDRESS per window and does not care which room a message went to, so it
// binds either way. This test is what keeps that true if the per-court rules are ever
// tightened into the address's budget.
func TestScatteringAcrossRoomsDoesNotRaiseTheCeiling(t *testing.T) {
	attempts := 20

	// All in one room.
	one, oneClock := newStore(t)
	oneCount := 0
	for i := 0; i < attempts; i++ {
		*oneClock = oneClock.Add(MinInterval + 100*time.Millisecond)
		if _, err := one.Post(context.Background(), PostInput{
			Chain: "dev", Court: "orem", Moniker: "a",
			Body:   fmt.Sprintf("message %d in a single room", i),
			IPHash: "ip-a", NetHash: "net-a",
		}); err == nil {
			oneCount++
		}
	}

	// The same address, the same clock, one message per invented room.
	many, manyClock := newStore(t)
	manyCount := 0
	for i := 0; i < attempts; i++ {
		*manyClock = manyClock.Add(MinInterval + 100*time.Millisecond)
		if _, err := many.Post(context.Background(), PostInput{
			Chain: "dev", Court: fmt.Sprintf("invented-%02d", i), Moniker: "a",
			Body:   fmt.Sprintf("message %d scattered around", i),
			IPHash: "ip-a", NetHash: "net-a",
		}); err == nil {
			manyCount++
		}
	}

	if oneCount != manyCount {
		t.Fatalf("scattering changed what one address could post: %d in one room vs %d "+
			"across %d rooms — the per-address ceiling must not depend on the court",
			oneCount, manyCount, attempts)
	}
	// And the ceiling must actually have bitten, or the equality above is two unlimited
	// numbers agreeing with each other.
	if oneCount >= attempts {
		t.Fatalf("the fixture never reached a limit (%d of %d accepted); it proves nothing",
			oneCount, attempts)
	}
	if oneCount != PerIPMax {
		t.Errorf("the binding constraint should be PerIPMax=%d, got %d — if this changed "+
			"deliberately, the comment above needs revisiting", PerIPMax, oneCount)
	}
	t.Logf("one address: %d accepted in one room, %d across %d invented rooms (PerIPMax=%d)",
		oneCount, manyCount, attempts, PerIPMax)
}

// AND THE BURST FLOOR IS PER ADDRESS TOO, not per room.
//
// Separate from the ceiling above, and it took its own fixture to see: that test advances
// the clock past MinInterval before every post, so the interval never binds in either arm
// and scoping it per court survived unnoticed. The properties are different — one bounds
// how MUCH an address can post in a window, this one bounds how FAST. If the two-second
// floor were per room, an address could post to room A and room B back to back and burst
// at whatever rate it could invent names.
func TestTheBurstFloorIsPerAddressNotPerRoom(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()

	if _, err := s.Post(ctx, PostInput{
		Chain: "dev", Court: "orem", Moniker: "a", Body: "the first message",
		IPHash: "ip-a", NetHash: "net-a",
	}); err != nil {
		t.Fatal(err)
	}
	// A DIFFERENT room AND a different name, immediately, from the same address. No clock
	// movement at all.
	//
	// Both changes at once on purpose. Scoping the floor by court is one hole and scoping
	// it by MONIKER is a worse one — a moniker is free and unowned, so an attacker types a
	// new name per message and the floor evaporates entirely. An earlier version of this
	// reused the name "a" and the moniker-scoped mutation survived it.
	_, err := s.Post(ctx, PostInput{
		Chain: "dev", Court: "another-room", Moniker: "a-different-name",
		Body: "and one right after", IPHash: "ip-a", NetHash: "net-a",
	})
	if err == nil {
		t.Fatal("neither a different room nor a different name may reset the per-address " +
			"interval; an address could otherwise burst as fast as it can type new ones")
	}
	if !errors.Is(err, ErrThrottled) {
		t.Fatalf("want a throttle refusal, got %v", err)
	}

	// PAIRED POSITIVE: once the interval has passed, the other room works. Otherwise the
	// assertion above is satisfied by a service that refuses second messages outright.
	*clock = clock.Add(MinInterval + time.Second)
	if _, err := s.Post(ctx, PostInput{
		Chain: "dev", Court: "another-room", Moniker: "a", Body: "and now it is allowed",
		IPHash: "ip-a", NetHash: "net-a",
	}); err != nil {
		t.Fatalf("after the interval the other room must accept it: %v", err)
	}
	// THE BYSTANDER, and deliberately on the SAME NETWORK as the throttled address.
	//
	// This is the /24 collateral class showing up in the throttle rather than in
	// enforcement. If the floor were scoped to net_hash, two unrelated people behind one
	// NAT — a campus, an office, carrier CGNAT — would silently throttle each other, and
	// one person talking would impose a two-second wait on their neighbour. A stranger on
	// a DIFFERENT network does not test this: net-scoping lets them through too, which is
	// why the earlier version of this line missed it.
	if _, err := s.Post(ctx, PostInput{
		Chain: "dev", Court: "orem", Moniker: "b", Body: "an unrelated person talking",
		IPHash: "ip-b", NetHash: "net-a", // same /24, different address
	}); err != nil {
		t.Fatalf("a neighbour behind the same NAT must not inherit somebody else's "+
			"interval: %v", err)
	}
}
