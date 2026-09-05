package archive

import (
	"bytes"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// health's THREE UNHAPPY PATHS, measured as the only uncovered blocks in the
// handler: the method gate, the store-error path, and HEAD.
//
// The happy paths are already well covered — public-versus-detail, the sweep
// stamp, no-store — and those are the ones a reader thinks to write. These three
// are what a monitor actually exercises when something is wrong, which is the
// moment a health endpoint has to be right.

// A monitor that pokes /m/health with the wrong verb must be told which verbs
// exist, not merely refused. Without the Allow header a 405 is a dead end: the
// spec requires it, and an operator debugging a probe has nothing to go on.
func TestHealthRefusesOtherMethodsAndSaysWhichOnesItTakes(t *testing.T) {
	srv, _ := newTestServer(t)
	mux := http.NewServeMux()
	srv.Routes(mux)

	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete} {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest(method, "/m/health", nil))
		if rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s /m/health returned %d, want 405", method, rec.Code)
		}
		if got := rec.Header().Get("Allow"); got != "GET, HEAD" {
			t.Errorf("%s: Allow was %q, want %q — a 405 without it is a dead end",
				method, got, "GET, HEAD")
		}
	}
}

/*
A BROKEN STORE IS A 500, AND THE REASON GOES TO THE LOG, NOT THE WIRE.

/m/health is PUBLIC — Routes mounts it with no auth and the handler sets
Access-Control-Allow-Origin: *. So the failure text is readable by anyone, and a
driver error is exactly the kind of string that names a file path, a schema or a
version. The handler answers with a fixed sentence and logs the real one, and
that split is what this pins: the body must NOT carry the underlying error.

The store is broken by closing the database out from under it, which is also the
shape of the real thing — the disk goes away, or the file is replaced under a
running process.
*/
func TestHealthOnABrokenStoreSaysNothingItShouldNot(t *testing.T) {
	st := testStore(t)
	var logged bytes.Buffer
	srv := NewServer(st, log.New(&logged, "", 0), func(r *http.Request) string { return "test" })
	mux := http.NewServeMux()
	srv.Routes(mux)

	// Sanity first: it is healthy while the store is open, so the failure below
	// is caused by the close and not by the fixture.
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/m/health", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("setup: health returned %d before the store was broken", rec.Code)
	}

	if err := st.db.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/m/health", nil))
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("a health check on a dead store returned %d, want 500", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "could not read archive state") {
		t.Errorf("the refusal must say what failed in general terms, got %q", body)
	}
	// The specific leak this guards. "closed" is what database/sql says here;
	// "sql" and "database" cover a driver that words it differently.
	for _, leak := range []string{"closed", "sql", "database", "sqlite"} {
		if strings.Contains(strings.ToLower(body), leak) {
			t.Errorf("the public body leaked driver detail (%q): %q", leak, body)
		}
	}
	// ...and it is not merely swallowed. An operator has to be able to find out
	// what actually happened, which is the other half of not saying it publicly.
	if !strings.Contains(logged.String(), "archive health") {
		t.Errorf("the real error must reach the log, got %q", logged.String())
	}
	if strings.TrimSpace(logged.String()) == "archive health:" {
		t.Error("the log line must carry the underlying error, not just the prefix")
	}
}

/*
HEAD IS A GET WITHOUT THE BODY, and both halves of that matter.

A HEAD that writes a body is a protocol violation, and net/http will not save the
handler from it — httptest records exactly what was written. Uptime monitors
default to HEAD, so this is the request most likely to be in production and least
likely to be exercised by hand.

The headers are asserted too, because a HEAD whose headers differ from its GET is
worse than one that fails: a monitor reading Cache-Control from HEAD would cache
a liveness answer the GET path declares uncacheable.
*/
func TestHealthHeadSetsTheHeadersAndWritesNoBody(t *testing.T) {
	srv, _ := newTestServer(t)
	srv = srv.WithHealthDetail(true)
	mux := http.NewServeMux()
	srv.Routes(mux)

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodHead, "/m/health", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("HEAD /m/health returned %d, want 200", rec.Code)
	}
	if n := rec.Body.Len(); n != 0 {
		t.Errorf("HEAD wrote %d bytes of body: %q", n, rec.Body.String())
	}
	for h, want := range map[string]string{
		"Content-Type":           "application/json; charset=utf-8",
		"Cache-Control":          "no-store",
		"X-Content-Type-Options": "nosniff",
	} {
		if got := rec.Header().Get(h); got != want {
			t.Errorf("HEAD %s = %q, want %q — a monitor reading headers from HEAD "+
				"must see what GET declares", h, got, want)
		}
	}

	// And GET still answers with a body, so the early return above is scoped to
	// HEAD rather than having turned the handler mute.
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/m/health", nil))
	if rec.Body.Len() == 0 {
		t.Error("GET /m/health wrote no body")
	}
}
