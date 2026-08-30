package archive

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

// TestClaimedIsMeteredBeforeItAsksTheNode.
//
// /m/claimed turns an unauthenticated request into an outbound query, and the
// comment beside its limiter says why that matters: "otherwise it is a way to
// make this service hammer the node for free". The guard was there and had never
// been exercised — coverage showed the 429 branch at zero.
//
// This package has already been bitten by exactly that. reapLocked compared
// stored token counts without refilling first, so a full bucket looked
// permanently non-full and the map could never be reclaimed; 4096 distinct
// uploaders and nobody could ever upload again. Its 0% coverage is what hid it.
//
// The assertion that matters is not the status code. It is that the node hears
// NOTHING once the limit is reached — a 429 returned after the query would meter
// the caller and not the amplification.
func TestClaimedIsMeteredBeforeItAsksTheNode(t *testing.T) {
	var asked int64
	node := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt64(&asked, 1)
		// A well-formed empty answer: the handler's own behaviour past this point
		// is not what is under test.
		fmt.Fprint(w, `{"result":{"response":{"ResponseBase":{"Data":""}}}}`)
	}))
	defer node.Close()

	st := testStore(t)
	srv := NewServer(st, log.New(io.Discard, "", 0),
		// One bucket for every request, which is what a single caller looks like.
		func(r *http.Request) string { return "one-caller" })
	srv = srv.WithChain(&Chain{RPC: node.URL, PkgPath: "gno.land/r/kourt/kourtv2"})
	mux := http.NewServeMux()
	srv.Routes(mux)

	post := func() int {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/m/claimed?court=med&claim=1", nil))
		return rec.Code
	}

	// Enough to outrun any burst this package would sensibly choose.
	limited, askedWhenLimited := 0, int64(0)
	for i := 0; i < uploadBurst*3; i++ {
		if post() == http.StatusTooManyRequests {
			limited = i + 1
			askedWhenLimited = atomic.LoadInt64(&asked)
			break
		}
	}
	if limited == 0 {
		t.Fatalf("never refused after %d calls; the meter is not holding", uploadBurst*3)
	}

	// And it stays refused without the node hearing another word.
	for i := 0; i < 5; i++ {
		if code := post(); code != http.StatusTooManyRequests {
			t.Fatalf("call %d after the limit returned %d, not 429", i, code)
		}
	}
	if got := atomic.LoadInt64(&asked); got != askedWhenLimited {
		t.Fatalf("the node was asked %d more times while the caller was refused",
			got-askedWhenLimited)
	}
	if askedWhenLimited == 0 {
		t.Fatal("the node was never asked at all, so this proves nothing about the limit")
	}
}

// A wrong method is refused before anything else happens, and says which methods
// there are. Also previously uncovered.
func TestClaimedRefusesAWrongMethod(t *testing.T) {
	srv := NewServer(testStore(t), log.New(io.Discard, "", 0), nil)
	mux := http.NewServeMux()
	srv.Routes(mux)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/m/claimed?court=med&claim=1", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET /m/claimed returned %d", rec.Code)
	}
	if !strings.Contains(rec.Header().Get("Allow"), "POST") {
		t.Fatalf("a refusal must say what is allowed: %q", rec.Header().Get("Allow"))
	}
}

// TestUploadIsMeteredAndNothingLands is the same question at the other
// unauthenticated endpoint, and the meter there is the FIRST line of the
// anti-abuse story rather than the second: StageTTL bounds how long unreferenced
// bytes live, and this bounds how fast they arrive. Its 429 branch had never
// run either.
//
// The status code is again not the assertion. What matters is that a refused
// upload leaves nothing on the disk, since the whole point is bytes not landing.
func TestUploadIsMeteredAndNothingLands(t *testing.T) {
	ctx := t.Context()
	st := testStore(t)
	srv := NewServer(st, log.New(io.Discard, "", 0),
		func(r *http.Request) string { return "one-uploader" })
	mux := http.NewServeMux()
	srv.Routes(mux)

	post := func(tag string) int {
		req := httptest.NewRequest(http.MethodPost, "/m", strings.NewReader(string(pngWith(tag))))
		req.Header.Set("Content-Type", "image/png")
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		return rec.Code
	}

	limited := 0
	var storedWhenLimited int64
	for i := 0; i < uploadBurst*3; i++ {
		if post(fmt.Sprintf("body-%d", i)) == http.StatusTooManyRequests {
			limited = i + 1
			s, err := st.Stats(ctx)
			if err != nil {
				t.Fatal(err)
			}
			storedWhenLimited = s.Staged
			break
		}
	}
	if limited == 0 {
		t.Fatalf("never refused after %d uploads; the meter is not holding", uploadBurst*3)
	}
	if storedWhenLimited == 0 {
		t.Fatal("nothing was ever stored, so this proves nothing about the limit")
	}
	for i := 0; i < 5; i++ {
		if code := post(fmt.Sprintf("after-%d", i)); code != http.StatusTooManyRequests {
			t.Fatalf("upload %d after the limit returned %d, not 429", i, code)
		}
	}
	s, err := st.Stats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if s.Staged != storedWhenLimited {
		t.Fatalf("%d more blob(s) landed while the uploader was refused",
			s.Staged-storedWhenLimited)
	}
}

// TestUploadRefusesACourtNoCourtCouldHave guards the hint at the door.
//
// courtRe was widened to 32 characters at some point and is now pinned to the
// realm's own slug rule; the handler's refusal was never tested, only the
// regexp. A hint the chain cannot hold is a name backfill would ask a node
// about for nothing.
func TestUploadRefusesACourtNoCourtCouldHave(t *testing.T) {
	ctx := t.Context()
	st := testStore(t)
	srv := NewServer(st, log.New(io.Discard, "", 0), func(r *http.Request) string { return "x" })
	mux := http.NewServeMux()
	srv.Routes(mux)

	for _, bad := range []string{strings.Repeat("a", 12), "Upper", "has%20space", "dot.dot"} {
		req := httptest.NewRequest(http.MethodPost, "/m?court="+bad,
			strings.NewReader(string(pngWith("body"))))
		req.Header.Set("Content-Type", "image/png")
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("court=%q returned %d, not 400", bad, rec.Code)
		}
	}
	s, err := st.Stats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if s.Staged != 0 {
		t.Fatalf("a refused hint still landed %d blob(s)", s.Staged)
	}
}
