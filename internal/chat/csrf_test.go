package chat

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// WHAT PROTECTS A WRITE, AND THE DEPLOYMENT WHERE IT USED TO PROTECT NOTHING.
//
// Two checks guard a POST: Content-Type must be application/json, and Sec-Fetch-Site must not say
// cross-site. The reasoning behind them is sound for the SAFELISTED shapes — a form cannot produce
// application/json, and a no-cors fetch cannot set it either, so neither can reach this endpoint
// without a preflight.
//
// A preflighted fetch can. Measured against the real server with Origin https://evil.example:
//
//	OPTIONS preflight             204, Access-Control-Allow-Origin *, POST among the methods
//	POST without Sec-Fetch-Site   200, and the message was in the room
//	POST with    Sec-Fetch-Site   403
//
// Sec-Fetch-* is only sent to potentially-trustworthy origins, so on plain HTTP to anything but
// localhost it never arrives and "absent is allowed" meant a hostile page could make its visitors
// post — which is the attack the comment above csrfOK opens by describing. Nothing here uses
// cookies, so the attack needs no credentials: the identity IS the visitor's address.
//
// Requiring the header on those deployments is not available — no browser sends it, so every
// legitimate post would go too. Origin and Host are both browser-set and unforgeable by script,
// so the absent case compares those instead. Only the absent case, which is why the whole suite
// stayed green: when the header arrives it keeps deciding.
func TestWhatIsAllowedToPost(t *testing.T) {
	const host = "chat.example.com:8788"
	for _, c := range []struct {
		name        string
		contentType string
		origin      string
		site        string
		wantRefused bool
	}{
		// THE ATTACK, in the shape that was measured succeeding.
		{"a hostile page on plain HTTP, so no Sec-Fetch-Site arrives",
			"application/json", "https://evil.example", "", true},

		// THE ORDINARY POSTS IT MUST NOT REFUSE. Without these the table above would be
		// satisfied by a check that refuses everything.
		{"the page itself, same host, no Sec-Fetch-Site",
			"application/json", "https://chat.example.com:8788", "", false},
		{"the same host on ANOTHER PORT, which §11 calls the real deployment",
			"application/json", "https://chat.example.com:9999", "", false},
		{"curl and the operator CLI, which send no Origin at all",
			"application/json", "", "", false},

		// UNCHANGED WHERE THE HEADER ARRIVES, which is what keeps this additive.
		{"the header still decides when present: cross-site is refused",
			"application/json", "https://evil.example", "cross-site", true},
		{"and same-site is allowed even across HOSTS, which is the subdomain split",
			"application/json", "https://api.example.com", "same-site", false},
		{"same-origin, spelled out", "application/json", "https://chat.example.com:8788", "same-origin", false},

		// A file:// page sends the opaque origin. It has no host to compare, so it is refused
		// rather than waved through — and it was already refused wherever the header arrives.
		{"an opaque origin from a file:// page", "application/json", "null", "", true},

		// The other half of the guard, so this table is not only about one check.
		{"a form's content type cannot reach this endpoint",
			"application/x-www-form-urlencoded", "https://chat.example.com:8788", "same-origin", true},
		{"nor text/plain, which is the other safelisted write",
			"text/plain", "", "", true},
		{"a charset parameter is not a different type",
			"application/json; charset=utf-8", "", "", false},
	} {
		t.Run(c.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodPost, "http://"+host+"/api/chat/dev/orem",
				strings.NewReader(`{"moniker":"a","body":"b"}`))
			r.Host = host
			if c.contentType != "" {
				r.Header.Set("Content-Type", c.contentType)
			}
			if c.origin != "" {
				r.Header.Set("Origin", c.origin)
			}
			if c.site != "" {
				r.Header.Set("Sec-Fetch-Site", c.site)
			}
			err := csrfOK(r)
			if c.wantRefused && err == nil {
				t.Errorf("this must be refused and was allowed (origin=%q site=%q type=%q)",
					c.origin, c.site, c.contentType)
			}
			if !c.wantRefused && err != nil {
				t.Errorf("this is an ordinary post and must be allowed: %v", err)
			}
		})
	}
}

// The host comparison on its own, including the port-insensitivity the deployment above needs.
func TestSameHostAsOrigin(t *testing.T) {
	for _, c := range []struct {
		origin, host string
		want         bool
	}{
		{"https://a.example.com", "a.example.com", true},
		{"https://a.example.com:9999", "a.example.com:8788", true}, // ports differ, same host
		{"HTTPS://A.EXAMPLE.COM", "a.example.com:8788", true},      // hosts are case-insensitive
		{"https://evil.example", "a.example.com:8788", false},
		{"https://a.example.com.evil.example", "a.example.com:8788", false}, // suffix trickery
		{"null", "a.example.com:8788", false},
		{"", "a.example.com:8788", false},
		{"not a url", "a.example.com:8788", false},
		{"http://[::1]:8788", "[::1]:8788", true}, // IPv6 literals keep their brackets
	} {
		if got := sameHostAsOrigin(c.origin, c.host); got != c.want {
			t.Errorf("sameHostAsOrigin(%q, %q) = %v, want %v", c.origin, c.host, got, c.want)
		}
	}
}

// THE REPLY DEPENDS ON WHO ASKED, SO NO SHARED CACHE MAY STORE IT.
//
// GET /api/chat/{chain}/{court} carries a `you` block computed from the requester's address.
// Measured against the running server, one URL and two X-Forwarded-For values behind a trusted
// proxy: 203.0.113.10 got {"state":"kick","until":...,"ref":1,"seconds":3600} and 198.51.100.55
// got {"state":"ok"}. The only cache-relevant header was `Vary: Origin`, which is the wrong axis.
//
// There is nothing to vary on: the address comes from the connection, or from X-Forwarded-For
// which must not be a cache key. §3 is written for a deployment behind a CDN — --country-header
// names CF-IPCountry in its own usage — and a shared cache holding one person's block would tell
// innocent readers they are timed out and hand them another person's appeal reference.
func TestNoSharedCacheMayStoreAPerRequesterReply(t *testing.T) {
	srv, st, _ := newServer(t)
	ctx := context.Background()
	if _, err := st.Post(ctx, PostInput{
		Chain: "dev", Court: "orem", Moniker: "alice", Body: "an ordinary message here",
		IPHash: "ip-a", NetHash: "net-a",
	}); err != nil {
		t.Fatal(err)
	}

	for _, c := range []struct{ name, method, path string }{
		{"the transcript, which carries the `you` block", http.MethodGet, "/api/chat/dev/orem"},
		{"health, which carries enforcing and appeal_to", http.MethodGet, "/api/chat/health"},
	} {
		t.Run(c.name, func(t *testing.T) {
			rec := do(t, srv, httptest.NewRequest(c.method, c.path, nil))
			if rec.Code != 200 {
				t.Fatalf("%s: %d %s", c.path, rec.Code, rec.Body)
			}
			if got := rec.Header().Get("Cache-Control"); !strings.Contains(got, "no-store") {
				t.Errorf("Cache-Control is %q; a reply that depends on the requester must not "+
					"be storable by a shared cache", got)
			}
			// The paired arm: the response still carries its content. A header added by
			// breaking the body would satisfy the assertion above.
			if rec.Body.Len() == 0 {
				t.Error("the response body is empty, so this measures a broken handler")
			}
		})
	}

	// THE PREFLIGHT IS DIFFERENT AND MUST STAY CACHEABLE. Access-Control-Max-Age is how long a
	// browser may remember the answer; no-store there would argue with it and cost a round trip
	// on every post.
	t.Run("the preflight keeps its cacheability", func(t *testing.T) {
		r := httptest.NewRequest(http.MethodOptions, "/api/chat/dev/orem", nil)
		r.Header.Set("Origin", "https://example.com")
		r.Header.Set("Access-Control-Request-Method", "POST")
		rec := do(t, srv, r)
		if rec.Code != http.StatusNoContent {
			t.Fatalf("preflight: %d", rec.Code)
		}
		if got := rec.Header().Get("Access-Control-Max-Age"); got == "" {
			t.Error("the preflight must still say how long it may be remembered")
		}
		if got := rec.Header().Get("Cache-Control"); strings.Contains(got, "no-store") {
			t.Errorf("no-store on the preflight contradicts Access-Control-Max-Age: %q", got)
		}
	})

	// And the fact that motivates all of it, asserted rather than only measured: two requesters,
	// one URL, different bodies.
	t.Run("two requesters really do get different bodies", func(t *testing.T) {
		bodies := map[string]string{}
		for _, ip := range []string{"198.51.100.1:1111", "203.0.113.9:2222"} {
			r := httptest.NewRequest(http.MethodGet, "/api/chat/dev/orem", nil)
			r.RemoteAddr = ip
			rec := do(t, srv, r)
			if rec.Code != 200 {
				t.Fatalf("%s: %d", ip, rec.Code)
			}
			bodies[ip] = rec.Body.String()
		}
		// Both are "ok" here, so this asserts the WEAKER available property: the reply is
		// computed per requester at all. The divergence itself was measured live against a real
		// consequence, which a unit fixture cannot reach without an operator action.
		for ip, b := range bodies {
			if !strings.Contains(b, `"you"`) {
				t.Errorf("%s got a reply with no `you` block, so there would be nothing "+
					"requester-specific to cache: %s", ip, b)
			}
		}
	})
}
