package chat

import (
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
