package archive

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	_ "modernc.org/sqlite"
)

// Bodies that really start like the type they claim, because the store now reads
// the type out of the BYTES rather than trusting the caller's header. Prefixing
// a tag onto a PNG to make it distinct would break its signature, so distinctness
// goes in the PAYLOAD and the magic stays intact.
func pngWith(tag string) []byte {
	return []byte("\x89PNG\r\n\x1a\n" + tag + strings.Repeat("payload", 8))
}

func webpWith(tag string) []byte {
	return []byte("RIFF" + "\x00\x00\x00\x00" + "WEBP" + tag + strings.Repeat("payload", 8))
}

var pngBody = pngWith("")

// NAMED AFTER THE TEST, so two calls inside one test share a database. That is
// usually what is wanted and once was not: a fixture meaning to be empty came
// back holding the blob the same test had already stored, and the failure read
// as a bug in the code under test. namedStore is for the case that needs its
// own.
func testStore(t *testing.T) *Store {
	t.Helper()
	return namedStore(t, t.Name())
}

func namedStore(t *testing.T, name string) *Store {
	t.Helper()
	db, err := sql.Open("sqlite", "file:"+name+"?mode=memory&cache=shared")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	s, err := NewStore(db)
	if err != nil {
		t.Fatalf("schema: %v", err)
	}
	return s
}

func TestTheArchiveNamesBytesByTheirOwnHash(t *testing.T) {
	// The archive hashes what it RECEIVED and never takes a digest from the
	// caller. Trusting a submitted one would let anyone park bytes at an address
	// that does not describe them, which is the single thing content addressing
	// exists to prevent and the reason a client can believe any mirror at all.
	st := testStore(t)
	ctx := context.Background()

	sum, err := st.Put(ctx, "image/png", pngBody, "")
	if err != nil {
		t.Fatalf("put: %v", err)
	}
	if sum != Digest(pngBody) {
		t.Fatalf("stored under %q, want the digest of the bytes", sum)
	}

	mime, got, err := st.Get(ctx, sum)
	if err != nil || mime != "image/png" || string(got) != string(pngBody) {
		t.Fatalf("get returned (%q, %d bytes, %v)", mime, len(got), err)
	}
}

func TestSVGIsRefusedBecauseWeServeItFromOurOwnOrigin(t *testing.T) {
	// Inside an <img> an SVG is inert. Followed directly it is a DOCUMENT, and an
	// SVG document can carry script — which would run as kourt.xyz, on the origin
	// that holds people's sessions. There is no image an author needs that cannot
	// be a PNG.
	st := testStore(t)
	for _, mime := range []string{
		"image/svg+xml", "text/html", "application/pdf", "", "image/png; charset=x",
	} {
		if MIMEServable(mime) {
			t.Fatalf("%q must not be servable", mime)
		}
		if _, err := st.Put(context.Background(), mime, pngBody, ""); err == nil {
			t.Fatalf("%q was accepted by the store", mime)
		}
	}
	// The control: the five raster types are servable.
	for _, mime := range []string{"image/png", "image/jpeg", "image/webp", "image/gif", "image/avif"} {
		if !MIMEServable(mime) {
			t.Fatalf("%q must be servable", mime)
		}
	}
}

func TestUnreferencedBytesExpireAndReferencedOnesDoNot(t *testing.T) {
	// THE ANTI-ABUSE MECHANISM. Without the sweep, POST /m is free permanent
	// hosting on someone else's disk for anyone with a script. Promotion ties
	// the storage to an on-chain claim, which costs a deposit.
	st := testStore(t)
	ctx := context.Background()

	kept, _ := st.Put(ctx, "image/png", pngBody, "")
	dropped, _ := st.Put(ctx, "image/webp", webpWith("other"), "")
	if err := st.Promote(ctx, kept); err != nil {
		t.Fatalf("promote: %v", err)
	}

	// Nothing expires before its time.
	if n, _ := st.SweepStaged(ctx, time.Now()); n != 0 {
		t.Fatalf("swept %d blobs that were still fresh", n)
	}

	n, err := st.SweepStaged(ctx, time.Now().Add(StageTTL+time.Minute))
	if err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if n != 1 {
		t.Fatalf("sweep removed %d blobs, want exactly the unpromoted one", n)
	}
	if _, _, err := st.Get(ctx, dropped); err != ErrNotFound {
		t.Fatal("unreferenced bytes must not survive the sweep")
	}
	if _, _, err := st.Get(ctx, kept); err != nil {
		t.Fatal("bytes a claim references must survive the sweep")
	}
}

func TestReuploadDoesNotExtendOrUndoAnything(t *testing.T) {
	st := testStore(t)
	ctx := context.Background()

	sum, _ := st.Put(ctx, "image/png", pngBody, "")
	if err := st.Promote(ctx, sum); err != nil {
		t.Fatalf("promote: %v", err)
	}
	// Re-uploading must not un-promote something already permanent...
	if _, err := st.Put(ctx, "image/png", pngBody, ""); err != nil {
		t.Fatalf("re-put: %v", err)
	}
	if n, _ := st.SweepStaged(ctx, time.Now().Add(StageTTL*2)); n != 0 {
		t.Fatal("a re-upload un-promoted a permanent blob")
	}

	// ...nor extend the life of something already expiring, which would let a
	// script keep bytes alive indefinitely by re-posting them.
	tmp, _ := st.Put(ctx, "image/webp", webpWith("tmp"), "")
	if _, err := st.Put(ctx, "image/webp", webpWith("tmp"), ""); err != nil {
		t.Fatalf("re-put staged: %v", err)
	}
	if n, _ := st.SweepStaged(ctx, time.Now().Add(StageTTL+time.Minute)); n != 1 {
		t.Fatal("a re-upload extended a staged blob's life")
	}
	if _, _, err := st.Get(ctx, tmp); err != ErrNotFound {
		t.Fatal("the re-uploaded staged blob should have expired")
	}
}

func TestABlockedBlobIsIndistinguishableFromAnAbsentOne(t *testing.T) {
	// A takedown that announced itself would be a lookup oracle for exactly what
	// has been taken down.
	st := testStore(t)
	ctx := context.Background()
	sum, _ := st.Put(ctx, "image/png", pngBody, "")
	if err := st.Block(ctx, sum); err != nil {
		t.Fatalf("block: %v", err)
	}
	if _, _, err := st.Get(ctx, sum); err != ErrNotFound {
		t.Fatalf("a blocked blob answered %v, want ErrNotFound", err)
	}
}

func newTestServer(t *testing.T) (*Server, *Store) {
	t.Helper()
	st := testStore(t)
	return NewServer(st, nil, func(r *http.Request) string { return "test-client" }), st
}

func TestTheHandlerServesBytesUncacheablyWrongNever(t *testing.T) {
	srv, st := newTestServer(t)
	sum, _ := st.Put(context.Background(), "image/png", pngBody, "")
	// Promoted, because the public read serves CLAIMED bytes only — staged ones
	// are never reviewed by anything, so they are never published. See
	// GetServable. Every test below that fetches over HTTP needs the promotion a
	// real claim performs.
	if err := st.Promote(context.Background(), sum); err != nil {
		t.Fatalf("promote: %v", err)
	}

	mux := http.NewServeMux()
	srv.Routes(mux)

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/m/"+sum, nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("GET returned %d", rec.Code)
	}
	h := rec.Header()
	// nosniff is the one that matters most: the bytes came from a stranger, and
	// sniffing is how "image" becomes "document".
	if h.Get("X-Content-Type-Options") != "nosniff" {
		t.Fatal("a blob must be served with nosniff")
	}
	if !strings.Contains(h.Get("Content-Security-Policy"), "default-src 'none'") {
		t.Fatal("a blob must be served under a CSP that can run nothing")
	}
	if h.Get("Access-Control-Allow-Origin") != "*" {
		t.Fatal("any client must be able to fetch and verify these bytes")
	}
	if h.Get("Referrer-Policy") != "no-referrer" {
		t.Fatal("a reader's claim must not leak to the archive in a referrer")
	}
	if !strings.Contains(h.Get("Cache-Control"), "immutable") {
		t.Fatal("a content-addressed URL can never go stale")
	}

	// A digest that is not a digest is a 404, never a database lookup. Uppercase
	// is included deliberately: hex has two spellings and only one may address a
	// blob, or the same bytes would live at two URLs and cache as two objects.
	for _, bad := range []string{"/m/nothex", "/m/" + strings.ToUpper(sum), "/m/",
		"/m/" + sum + "extra", "/m/" + sum[:63]} {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, bad, nil))
		if rec.Code != http.StatusNotFound {
			t.Fatalf("%q returned %d, want 404", bad, rec.Code)
		}
	}

	// Traversal never reaches the handler at all: ServeMux cleans the path and
	// redirects first, and the digest pattern would refuse it even if it did.
	// What matters is only that no blob is served.
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/m/../etc/passwd", nil))
	if rec.Code == http.StatusOK {
		t.Fatalf("a traversal path served a body: %q", rec.Body.String())
	}
}

func TestUploadReturnsTheDigestItComputed(t *testing.T) {
	srv, _ := newTestServer(t)
	mux := http.NewServeMux()
	srv.Routes(mux)

	req := httptest.NewRequest(http.MethodPost, "/m", strings.NewReader(string(pngBody)))
	req.Header.Set("Content-Type", "image/png")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("POST returned %d: %s", rec.Code, rec.Body.String())
	}
	var got map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got["sha256"] != Digest(pngBody) {
		t.Fatalf("returned %q, want the digest of what was sent", got["sha256"])
	}
	if got["url"] != "/m/"+Digest(pngBody) {
		t.Fatalf("returned url %q", got["url"])
	}

	// An oversized body is REFUSED, never truncated: a truncated image is a
	// different image with a different hash than the uploader computed, and it
	// would be stored under that hash as though it were what they sent.
	//
	// THE STATUS IS ASSERTED EXACTLY. This used to accept 413 OR 400, and the
	// service answered 400 with "could not read the upload" — because
	// MaxBytesReader fails the READ rather than handing back a long body, so the
	// specific message sat unreachable below it. A test that accepts either
	// status cannot see that, and this one did not: it was found by posting a
	// 300 KB file at the running binary.
	big := strings.Repeat("x", MaxBytes+64)
	req = httptest.NewRequest(http.MethodPost, "/m", strings.NewReader(big))
	req.Header.Set("Content-Type", "image/png")
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("an oversized upload returned %d, want 413: %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "too large") {
		t.Fatalf("...and must say so in words: %q", rec.Body.String())
	}

	// And an SVG never gets in through the door.
	req = httptest.NewRequest(http.MethodPost, "/m", strings.NewReader("<svg/>"))
	req.Header.Set("Content-Type", "image/svg+xml")
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("an SVG upload returned %d, want 415", rec.Code)
	}
}

func TestOneClientCannotFillTheStagingArea(t *testing.T) {
	l := newLimiter()
	now := time.Now()
	for i := 0; i < uploadBurst; i++ {
		if !l.allow("ip", now) {
			t.Fatalf("refused request %d of the burst", i+1)
		}
	}
	if l.allow("ip", now) {
		t.Fatal("the burst must not be unbounded")
	}
	// A different client is unaffected — the bucket is per-client, not global.
	if !l.allow("other", now) {
		t.Fatal("one client's burst must not refuse everyone else")
	}
	// And the bucket refills.
	if !l.allow("ip", now.Add(uploadRefill+time.Second)) {
		t.Fatal("the bucket must refill over time")
	}
}

// fakeNode answers abci_query the way a gno node does: the payload is base64 in
// response.Data, and qeval wraps a string result as `("..." string)`.
func fakeNode(t *testing.T, mediaJSON string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		quoted, err := json.Marshal(mediaJSON)
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		payload := "(" + string(quoted) + " string)"
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"jsonrpc": "2.0", "id": "archive",
			"result": map[string]any{"response": map[string]any{
				"Data": base64.StdEncoding.EncodeToString([]byte(payload)),
			}},
		})
	}))
}

func TestOnlyTheChainDecidesWhatIsWorthKeeping(t *testing.T) {
	st := testStore(t)
	ctx := context.Background()

	claimed, _ := st.Put(ctx, "image/png", pngBody, "")
	stray, _ := st.Put(ctx, "image/webp", webpWith("stray"), "")
	purged, _ := st.Put(ctx, "image/png", pngWith("purged"), "")

	// The claim references `claimed`, and carries a purged slot whose bytes must
	// NOT be bought permanent storage — the court has withdrawn its pointer.
	node := fakeNode(t, `[{"kind":"img","sha256":"`+claimed+`","mirrors":[]},`+
		`{"kind":"img","purged":true,"sha256":"`+purged+`"}]`)
	defer node.Close()

	srv := NewServer(st, nil, func(r *http.Request) string { return "c" }).
		WithChain(&Chain{RPC: node.URL, PkgPath: "gno.land/r/kourt/kourtv2", HTTP: node.Client()})
	mux := http.NewServeMux()
	srv.Routes(mux)

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/m/claimed?court=covid&claim=7", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("promote returned %d: %s", rec.Code, rec.Body.String())
	}

	// After the TTL: exactly the claimed blob survives.
	if _, err := st.SweepStaged(ctx, time.Now().Add(StageTTL+time.Minute)); err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if _, _, err := st.Get(ctx, claimed); err != nil {
		t.Fatal("bytes a claim references must be kept")
	}
	if _, _, err := st.Get(ctx, stray); err != ErrNotFound {
		t.Fatal("bytes no claim references must expire — that is the whole mechanism")
	}
	if _, _, err := st.Get(ctx, purged); err != ErrNotFound {
		t.Fatal("a purged slot must not buy its bytes permanent storage")
	}
}

func TestWithoutAChainNothingIsKept(t *testing.T) {
	// FAIL-CLOSED MEANS FORGET, NOT KEEP. An archive that cannot reach a chain
	// cannot know what is referenced, and the safe answer is to let everything
	// expire rather than to become free permanent storage by default.
	st := testStore(t)
	srv := NewServer(st, nil, func(r *http.Request) string { return "c" })
	mux := http.NewServeMux()
	srv.Routes(mux)

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/m/claimed?court=covid&claim=1", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("promote without a chain returned %d, want 503", rec.Code)
	}

	sum, _ := st.Put(context.Background(), "image/png", pngBody, "")
	if _, err := st.SweepStaged(context.Background(), time.Now().Add(StageTTL+time.Minute)); err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if _, _, err := st.Get(context.Background(), sum); err != ErrNotFound {
		t.Fatal("with no chain to consult, uploads must expire")
	}
}

func TestAMalformedClaimNeverReachesTheNode(t *testing.T) {
	st := testStore(t)
	node := fakeNode(t, "[]")
	defer node.Close()
	srv := NewServer(st, nil, func(r *http.Request) string { return "c" }).
		WithChain(&Chain{RPC: node.URL, PkgPath: "p", HTTP: node.Client()})
	mux := http.NewServeMux()
	srv.Routes(mux)

	for _, q := range []string{
		"?court=&claim=1", "?court=Covid&claim=1", "?court=a/b&claim=1",
		"?court=covid&claim=0", "?court=covid&claim=x", "?court=covid",
	} {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/m/claimed"+q, nil))
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("%q returned %d, want 400", q, rec.Code)
		}
	}
}

// fakeChain answers backfill without a node.
type fakeChain struct {
	count   uint64
	byID    map[uint64][]string
	counts  int    // how many times ClaimCount was asked
	unknown string // a court this chain refuses to answer for
}

func (f *fakeChain) ClaimCount(ctx context.Context, court string) (uint64, error) {
	f.counts++
	if f.unknown != "" && court == f.unknown {
		// What a node really answers for a court that is not there: the realm's
		// mustCourt panics and qeval returns the abort as an error.
		return 0, fmt.Errorf("qeval: unknown court %q", court)
	}
	return f.count, nil
}
func (f *fakeChain) ClaimHashes(ctx context.Context, court string, id uint64) ([]string, error) {
	return f.byID[id], nil
}

func TestAClosedTabDoesNotCostSomebodyTheirEvidence(t *testing.T) {
	// THE HOLE THIS CLOSES. Promotion used to happen only when the composer
	// called /m/claimed after broadcasting. Every path that skips that call —
	// the tab closed, the network dropped, the claim filed from the CLI or from
	// gnoweb — lost the bytes an hour later even though a valid claim referenced
	// them. Losing evidence quietly is worse than any missing feature.
	st := testStore(t)
	ctx := context.Background()

	filed, _ := st.Put(ctx, "image/png", pngBody, "covid")
	orphan, _ := st.Put(ctx, "image/webp", webpWith("orphan"), "covid")

	chain := &fakeChain{count: 3, byID: map[uint64][]string{2: {filed}}}
	kept, err := st.Backfill(ctx, chain)
	if err != nil {
		t.Fatalf("backfill: %v", err)
	}
	if kept != 1 {
		t.Fatalf("backfill kept %d, want the one claim 2 references", kept)
	}

	if _, err := st.SweepStaged(ctx, time.Now().Add(StageTTL+time.Minute)); err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if _, _, err := st.Get(ctx, filed); err != nil {
		t.Fatal("bytes a filed claim references must survive without any client call")
	}
	if _, _, err := st.Get(ctx, orphan); err != ErrNotFound {
		t.Fatal("bytes no claim references must still expire")
	}
}

func TestBackfillCostsNothingWhenThereIsNothingStaged(t *testing.T) {
	// The steady state is "no uploads waiting", and it must not cost a node
	// query per court per pass — this loop runs forever.
	st := testStore(t)
	ctx := context.Background()
	chain := &fakeChain{count: 100}

	if _, err := st.Backfill(ctx, chain); err != nil {
		t.Fatalf("backfill: %v", err)
	}
	if chain.counts != 0 {
		t.Fatalf("asked the node %d times with nothing staged", chain.counts)
	}

	// A blob with NO court hint cannot be found this way and must not make the
	// worker scan blindly — it relies on /m/claimed instead.
	if _, err := st.Put(ctx, "image/png", pngBody, ""); err != nil {
		t.Fatalf("put: %v", err)
	}
	if _, err := st.Backfill(ctx, chain); err != nil {
		t.Fatalf("backfill: %v", err)
	}
	if chain.counts != 0 {
		t.Fatal("a blob with no court hint must not trigger a scan")
	}
}

func TestTheCursorDoesNotRescanOrSkip(t *testing.T) {
	st := testStore(t)
	ctx := context.Background()
	a, _ := st.Put(ctx, "image/png", pngBody, "covid")
	chain := &fakeChain{count: 2, byID: map[uint64][]string{2: {a}}}

	if _, err := st.Backfill(ctx, chain); err != nil {
		t.Fatalf("backfill: %v", err)
	}
	// A second blob arrives, and a later claim references it. The cursor must
	// resume rather than start over.
	b, _ := st.Put(ctx, "image/webp", webpWith("second"), "covid")
	chain.count = 4
	chain.byID[4] = []string{b}
	if _, err := st.Backfill(ctx, chain); err != nil {
		t.Fatalf("backfill 2: %v", err)
	}
	if _, err := st.SweepStaged(ctx, time.Now().Add(StageTTL+time.Minute)); err != nil {
		t.Fatalf("sweep: %v", err)
	}
	for _, sum := range []string{a, b} {
		if _, _, err := st.Get(ctx, sum); err != nil {
			t.Fatalf("a claim referenced %s and it was swept anyway", sum[:8])
		}
	}
}

type fakeEye struct {
	v    ImageVerdict
	err  error
	seen int
}

func (f *fakeEye) ClassifyImage(ctx context.Context, mime string, body []byte) (ImageVerdict, error) {
	f.seen++
	return f.v, f.err
}

func TestAModelThatCannotAnswerLeavesTheEvidenceServing(t *testing.T) {
	// THE CHOICE THIS PINS. Fail-closed would mean an Ollama outage silently
	// withdrawing every exhibit in every court — a worse failure than the one it
	// protects against, and one nobody would notice until a reader complained.
	// internal/scan settled the same question for text: an unreadable verdict
	// carries no more weight than a clean one.
	st := testStore(t)
	ctx := context.Background()
	sum, _ := st.Put(ctx, "image/png", pngBody, "")
	if err := st.Promote(ctx, sum); err != nil {
		t.Fatalf("promote: %v", err)
	}

	eye := &fakeEye{err: errors.New("ollama is not running")}
	if n, err := st.ReviewPass(ctx, eye, 10); err != nil || n != 0 {
		t.Fatalf("a failing model blocked %d (err %v)", n, err)
	}
	if _, _, err := st.Get(ctx, sum); err != nil {
		t.Fatal("an image must keep serving when the model cannot answer")
	}
	// It records nothing, so the next pass tries again: the outage delays a
	// judgement rather than making one.
	left, _ := st.Unreviewed(ctx, 10)
	if len(left) != 1 {
		t.Fatalf("the blob should still be waiting for a verdict, got %d", len(left))
	}

	// With no classifier at all, the same: this service does not require a model
	// in order to serve a court's evidence.
	if n, err := st.ReviewPass(ctx, nil, 10); err != nil || n != 0 {
		t.Fatalf("no classifier blocked %d (err %v)", n, err)
	}
}

func TestOnlyTheSeriousAndTheSureAreBlockedWithoutAPerson(t *testing.T) {
	st := testStore(t)
	ctx := context.Background()

	for _, tc := range []struct {
		name  string
		v     ImageVerdict
		block bool
	}{
		{"clean", ImageVerdict{Label: "clean", Confidence: 0.99}, false},
		// A model that dislikes an image for any other reason gets a person, not
		// a veto: being wrong here costs a court a piece of evidence with nobody
		// told.
		{"serious but unsure", ImageVerdict{Label: AutoBlockLabel, Confidence: 0.5}, false},
		{"sure but not serious", ImageVerdict{Label: "rude", Confidence: 0.99}, false},
		{"serious and sure", ImageVerdict{Label: AutoBlockLabel, Confidence: 0.95}, true},
	} {
		body := pngWith(tc.name)
		sum, err := st.Put(ctx, "image/png", body, "")
		if err != nil {
			t.Fatalf("%s: put: %v", tc.name, err)
		}
		did, err := st.Review(ctx, sum, tc.v)
		if err != nil {
			t.Fatalf("%s: review: %v", tc.name, err)
		}
		if did != tc.block {
			t.Fatalf("%s: blocked=%v, want %v", tc.name, did, tc.block)
		}
		_, _, gerr := st.Get(ctx, sum)
		if tc.block && gerr != ErrNotFound {
			t.Fatalf("%s: a blocked image still served", tc.name)
		}
		if !tc.block && gerr != nil {
			t.Fatalf("%s: an image nobody blocked stopped serving", tc.name)
		}
	}
}

func TestEveryAutomaticRefusalHasAHumanUndo(t *testing.T) {
	// This is what makes auto-blocking survivable at all: a model's mistake is
	// reversible by a person, and the reversal leaves a record of having
	// happened.
	st := testStore(t)
	ctx := context.Background()
	sum, _ := st.Put(ctx, "image/png", pngBody, "")
	if _, err := st.Review(ctx, sum, ImageVerdict{Label: AutoBlockLabel, Confidence: 0.99,
		Why: "the model's prose, stored and never parsed for instructions"}); err != nil {
		t.Fatalf("review: %v", err)
	}
	if _, _, err := st.Get(ctx, sum); err != ErrNotFound {
		t.Fatal("the fixture should have blocked it")
	}
	// THE QUEUE MUST SAY WHY, or nobody works through it. This used to return
	// bare hashes: 64-character hex strings, with the reason each was flagged
	// stored one table over and reachable only by a query the caller had to know
	// to write. A queue that cannot say why is a queue in name only.
	pending, perr := st.PendingReview(ctx, 10)
	if perr != nil {
		t.Fatalf("pending: %v", perr)
	}
	if len(pending) != 1 {
		t.Fatalf("a blocked image must reach an operator's queue, got %d", len(pending))
	}
	row := pending[0]
	if row.SHA256 != sum || row.Label != AutoBlockLabel {
		t.Fatalf("the row must name the image and the label: %+v", row)
	}
	if !strings.Contains(row.Why, "the model's prose") {
		t.Fatalf("the row must carry the reason it was flagged: %+v", row)
	}
	// Whether it is ALREADY off the site is the first thing to know: one row is
	// an emergency and the rest are reading.
	if !row.Blocked {
		t.Fatalf("an auto-blocked image must say so in the queue: %+v", row)
	}
	if err := st.Clear(ctx, sum); err != nil {
		t.Fatalf("clear: %v", err)
	}
	if _, _, err := st.Get(ctx, sum); err != nil {
		t.Fatal("a person overruling the model must restore the image")
	}
	if p, _ := st.PendingReview(ctx, 10); len(p) != 0 {
		t.Fatal("a cleared review must leave the queue")
	}
}

func TestOnlyPromotedBytesAreWorthJudging(t *testing.T) {
	// Classifying bytes that are about to expire is work spent on something
	// nobody claimed — and on a public endpoint, work anybody can ask for.
	st := testStore(t)
	ctx := context.Background()
	staged, _ := st.Put(ctx, "image/png", pngBody, "")
	kept, _ := st.Put(ctx, "image/webp", webpWith("kept"), "")
	if err := st.Promote(ctx, kept); err != nil {
		t.Fatalf("promote: %v", err)
	}
	todo, err := st.Unreviewed(ctx, 10)
	if err != nil {
		t.Fatalf("unreviewed: %v", err)
	}
	if len(todo) != 1 || todo[0] != kept {
		t.Fatalf("only promoted bytes are judged, got %v (staged was %s)", todo, staged[:8])
	}
	eye := &fakeEye{v: ImageVerdict{Label: "clean", Confidence: 0.9}}
	if _, err := st.ReviewPass(ctx, eye, 10); err != nil {
		t.Fatalf("pass: %v", err)
	}
	if eye.seen != 1 {
		t.Fatalf("the model was shown %d blobs, want 1", eye.seen)
	}
}

func TestTheEyeSendsAnImageAndTakesOnlyAClosedSetBack(t *testing.T) {
	var got eyeReq
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&got)
		_ = json.NewEncoder(w).Encode(map[string]any{"message": map[string]string{
			"content": `{"verdict":"explicit","confidence":88,"why":"a photograph"}`}})
	}))
	defer srv.Close()

	eye := NewOllamaEye(srv.URL, "vision")
	eye.HTTP = srv.Client()
	v, err := eye.ClassifyImage(context.Background(), "image/png", pngBody)
	if err != nil {
		t.Fatalf("classify: %v", err)
	}

	// The bytes ride as base64 in `images`, which is what makes this a vision
	// call rather than a text one.
	if len(got.Messages) != 2 || len(got.Messages[1].Images) != 1 {
		t.Fatalf("the image must be sent with the request: %+v", got.Messages)
	}
	if got.Messages[1].Images[0] != base64.StdEncoding.EncodeToString(pngBody) {
		t.Fatal("the image sent was not the image asked about")
	}
	// A path that can withdraw evidence must not be a dice roll.
	if got.Options["temperature"] != float64(0) {
		t.Fatalf("temperature must be 0, got %v", got.Options["temperature"])
	}
	// The enum is enforced at the SAMPLER: an invented label cannot be emitted,
	// which is stronger than rejecting it afterwards.
	sch, _ := json.Marshal(got.Format)
	for _, want := range []string{eyeClean, eyeIllegal, eyeExplicit, eyeViolent} {
		if !strings.Contains(string(sch), want) {
			t.Fatalf("the schema must pin %q: %s", want, sch)
		}
	}
	if strings.Contains(string(sch), "block") || strings.Contains(string(sch), "delete") {
		t.Fatal("the model has no vocabulary for a consequence and must not be given one")
	}

	// A model answering on 0-100 is not a reason to throw its judgement away.
	if v.Label != eyeExplicit || v.Confidence != 0.88 {
		t.Fatalf("got %+v, want explicit at 0.88", v)
	}
	// ...and this label is not the one that acts alone.
	if v.Label == AutoBlockLabel {
		t.Fatal("explicit must not be the auto-block label")
	}
}

func TestEveryUnusableAnswerIsAnErrorSoItIsTriedAgain(t *testing.T) {
	// A stored "unknown" would mark the image REVIEWED and it would never be
	// looked at again. Returning an error instead means ReviewPass records
	// nothing and the next pass retries — an outage delays a judgement rather
	// than making one.
	for _, body := range []string{
		`{"message":{"content":"not json at all"}}`,
		`{"message":{"content":"{}"}}`,
		`{"message":{"content":""}}`,
	} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, _ = w.Write([]byte(body))
		}))
		eye := NewOllamaEye(srv.URL, "vision")
		eye.HTTP = srv.Client()
		v, err := eye.ClassifyImage(context.Background(), "image/png", pngBody)
		srv.Close()
		if err == nil {
			t.Fatalf("%s: an unusable answer must be an error, got %+v", body, v)
		}
		if v.Label == AutoBlockLabel {
			t.Fatalf("%s: a broken answer must never block", body)
		}
	}

	// A type the store would never hold does not get sent to a model at all.
	eye := NewOllamaEye("http://127.0.0.1:1", "vision")
	if _, err := eye.ClassifyImage(context.Background(), "image/svg+xml", pngBody); err == nil {
		t.Fatal("an unservable type must be refused before it reaches the model")
	}
}

func TestTheBytesDecideTheType(t *testing.T) {
	// A caller may label anything image/png. nosniff keeps a BROWSER from acting
	// on that lie, but "a browser will not execute it" is a smaller promise than
	// "this archive holds images" — and the thing serving them is a court.
	st := testStore(t)
	ctx := context.Background()

	for _, tc := range []struct {
		mime string
		body []byte
		why  string
	}{
		{"image/png", []byte("<html><script>alert(1)</script></html>"), "html dressed as a png"},
		{"image/png", []byte("%PDF-1.7 not an image at all"), "a pdf dressed as a png"},
		{"image/png", webpWith("x"), "a real image under the wrong label"},
		{"image/webp", pngWith("x"), "the same, the other way round"},
		{"image/png", []byte("\x89PN"), "a truncated signature"},
	} {
		if _, err := st.Put(ctx, tc.mime, tc.body, ""); err == nil {
			t.Fatalf("%s was accepted", tc.why)
		}
	}

	// The controls: each type stored under its own name.
	for _, tc := range []struct {
		mime string
		body []byte
	}{
		{"image/png", pngWith("ok")},
		{"image/webp", webpWith("ok")},
	} {
		if _, err := st.Put(ctx, tc.mime, tc.body, ""); err != nil {
			t.Fatalf("%s was refused: %v", tc.mime, err)
		}
	}

	// And the sniffer knows what it knows.
	if SniffMIME([]byte("GIF89a....")) != "image/gif" {
		t.Fatal("a gif must be recognised")
	}
	if SniffMIME(nil) != "" || SniffMIME([]byte("nope")) != "" {
		t.Fatal("unrecognised bytes must sniff to nothing, never to a default")
	}
}

func TestBytesSurviveTheRoundTripThroughHTTP(t *testing.T) {
	// THE ARCHIVE HALF OF THE BROWSER SEAM. Everything else tests the store; this
	// tests what a page actually gets: upload over HTTP, fetch over HTTP, and the
	// bytes that come back must hash to what went in — because the page verifies
	// exactly that, and a single byte lost in the transport would show every
	// reader "this no longer matches what was filed".
	srv, st := newTestServer(t)
	mux := http.NewServeMux()
	srv.Routes(mux)

	sent := pngWith("round-trip")
	req := httptest.NewRequest(http.MethodPost, "/m?court=covid", bytes.NewReader(sent))
	req.Header.Set("Content-Type", "image/png")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("upload returned %d: %s", rec.Code, rec.Body.String())
	}
	var up map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &up); err != nil {
		t.Fatalf("decode: %v", err)
	}

	// STAGED BYTES ARE NOT PUBLISHED. Nothing reviews an upload no claim
	// references — the classifier's queue selects promoted rows only — so until
	// this upload is claimed, serving it would make POST /m a way to publish an
	// arbitrary picture on this court's domain, unreviewed, with CORS open to
	// everyone and a year of immutable caching to outlive the sweep.
	staged := httptest.NewRecorder()
	mux.ServeHTTP(staged, httptest.NewRequest(http.MethodGet, up["url"], nil))
	if staged.Code != http.StatusNotFound {
		t.Fatalf("an unclaimed upload must not be served, got %d", staged.Code)
	}

	// What a filed claim does, through /m/claimed or Backfill.
	if err := st.Promote(context.Background(), strings.TrimPrefix(up["url"], "/m/")); err != nil {
		t.Fatalf("promote: %v", err)
	}

	get := httptest.NewRecorder()
	mux.ServeHTTP(get, httptest.NewRequest(http.MethodGet, up["url"], nil))
	if get.Code != http.StatusOK {
		t.Fatalf("fetch returned %d", get.Code)
	}
	back := get.Body.Bytes()
	if !bytes.Equal(back, sent) {
		t.Fatalf("what came back is not what went in: %d bytes vs %d", len(back), len(sent))
	}
	// The check the page performs, performed here.
	if Digest(back) != up["sha256"] {
		t.Fatal("the served bytes do not hash to the digest the archive named")
	}
	// And the page can only run that check if the read is open to it.
	if get.Header().Get("Access-Control-Allow-Origin") != "*" {
		t.Fatal("a page on another origin must be able to fetch and verify")
	}
	if ct := get.Header().Get("Content-Type"); ct != "image/png" {
		t.Fatalf("served as %q, want the type the bytes actually are", ct)
	}
}

func TestAPersonCanActOnWhatTheModelMissed(t *testing.T) {
	// WITHOUT THIS THE HUMAN IS STRICTLY WEAKER THAN THE MODEL: an operator
	// could undo an automatic block and could do nothing about an image the
	// classifier had waved through. That inverts the arrangement this archive
	// claims to have, where a model sorts a queue and a person decides.
	st := testStore(t)
	ctx := context.Background()
	sum, _ := st.Put(ctx, "image/png", pngBody, "")

	// The model saw nothing wrong, so nothing is blocked and nothing is queued.
	if _, err := st.Review(ctx, sum, ImageVerdict{Label: "clean", Confidence: 0.99}); err != nil {
		t.Fatalf("review: %v", err)
	}
	if _, _, err := st.Get(ctx, sum); err != nil {
		t.Fatal("a clean verdict must leave the image serving")
	}
	if q, _ := st.PendingReview(ctx, 10); len(q) != 0 {
		t.Fatalf("a clean image must not sit in the queue, got %d", len(q))
	}

	// A person disagrees.
	if err := st.BlockByOperator(ctx, sum, "a face nobody consented to publish"); err != nil {
		t.Fatalf("block: %v", err)
	}
	if _, _, err := st.Get(ctx, sum); err != ErrNotFound {
		t.Fatal("an operator's block must actually stop it serving")
	}

	// And the act is visible, labelled as a person's rather than a model's, so
	// the queue does not read as though the classifier had found it.
	q, err := st.PendingReview(ctx, 10)
	if err != nil || len(q) != 1 {
		t.Fatalf("the block must be visible in the queue: %d rows, err %v", len(q), err)
	}
	if q[0].Label != OperatorLabel {
		t.Fatalf("a person's judgement must not be labelled as a model's: %+v", q[0])
	}
	if !strings.Contains(q[0].Why, "consented") || !q[0].Blocked {
		t.Fatalf("the reason and the state must both be recorded: %+v", q[0])
	}
	// A model can never emit this label, so the two can never be confused.
	for _, l := range []string{eyeClean, eyeIllegal, eyeExplicit, eyeViolent} {
		if l == OperatorLabel {
			t.Fatal("the operator label must not be one a model can produce")
		}
	}

	// The undo still works on a person's block, not only a model's.
	if err := st.Clear(ctx, sum); err != nil {
		t.Fatalf("clear: %v", err)
	}
	if _, _, err := st.Get(ctx, sum); err != nil {
		t.Fatal("clearing an operator block must restore the image")
	}
}

func TestTheModelsProseCannotReachATerminalIntact(t *testing.T) {
	// THE PROSE IS ATTACKER-INFLUENCED. A model is asked to describe a picture,
	// and the picture may contain text. The prompt says that text is not an
	// instruction, but a model is not a parser and that is not a promise. The
	// answer then lands in an operator's terminal via `kourtchatctl images`,
	// where a C0 escape can clear the screen or overwrite the line above — the
	// line describing a DIFFERENT image.
	st := testStore(t)
	ctx := context.Background()
	sum, _ := st.Put(ctx, "image/png", pngBody, "")

	hostile := "clean\x1b[2J\x1b[1;1Hillegal 99% BLOCKED spoofed row\x00\x07"
	if _, err := st.Review(ctx, sum, ImageVerdict{Label: "violent", Confidence: 0.5,
		Why: hostile}); err != nil {
		t.Fatalf("review: %v", err)
	}
	q, _ := st.PendingReview(ctx, 10)
	if len(q) != 1 {
		t.Fatalf("expected the row, got %d", len(q))
	}
	for _, r := range q[0].Why {
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f) {
			t.Fatalf("a control character survived into the queue: %q", q[0].Why)
		}
	}
	// The words survive; only what a terminal would obey is gone.
	if !strings.Contains(q[0].Why, "spoofed row") {
		t.Fatalf("the prose itself must be kept for the operator: %q", q[0].Why)
	}

	// RUNES, NOT BYTES. A byte cap rations characters by how expensive they are
	// to encode and can cut one in half — the unit mistake internal/scan says
	// this repository has already made twice.
	long := strings.Repeat("あ", whyMaxRunes+50)
	sum2, _ := st.Put(ctx, "image/webp", webpWith("jp"), "")
	if _, err := st.Review(ctx, sum2, ImageVerdict{Label: "violent", Confidence: 0.4,
		Why: long}); err != nil {
		t.Fatalf("review: %v", err)
	}
	q2, _ := st.PendingReview(ctx, 10)
	var jp string
	for _, r := range q2 {
		if r.SHA256 == sum2 {
			jp = r.Why
		}
	}
	if !utf8.ValidString(jp) {
		t.Fatalf("a truncated explanation must still be valid UTF-8: %q", jp)
	}
	// A Japanese explanation gets the same number of CHARACTERS as an English
	// one, which a byte cap would not have given it.
	if n := utf8.RuneCountInString(strings.TrimSuffix(jp, "…")); n != whyMaxRunes {
		t.Fatalf("got %d runes, want %d — the cap must count characters", n, whyMaxRunes)
	}
}

func TestClaimCountReadsWhatANodeActuallyAnswers(t *testing.T) {
	// THIS PARSE WAS NEVER RUN. Every backfill test uses a fake chain, so the
	// real one's reading of the node's reply had 0% coverage — and it sits on the
	// path that keeps evidence alive. If it returns zero where the node said
	// twelve, backfill walks nothing, promotes nothing, and the bytes expire an
	// hour later with nobody told.
	//
	// The shape is the one a node really sends, taken from the txtar: qeval wraps
	// a value as ("..." type) and the payload arrives base64 in response.Data.
	for _, tc := range []struct {
		payload string
		want    uint64
		bad     bool
	}{
		{"(12 uint64)", 12, false},
		{"(0 uint64)", 0, false},
		{"(4294967296 uint64)", 4294967296, false},
		{"  (7 uint64)\n", 7, false},
		{"(\"nope\" string)", 0, true},
		{"", 0, true},
		{"garbage", 0, true},
	} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_ = json.NewEncoder(w).Encode(map[string]any{
				"jsonrpc": "2.0", "id": "archive",
				"result": map[string]any{"response": map[string]any{
					"Data": base64.StdEncoding.EncodeToString([]byte(tc.payload)),
				}},
			})
		}))
		c := &Chain{RPC: srv.URL, PkgPath: "gno.land/r/kourt/kourtv2", HTTP: srv.Client()}
		got, err := c.ClaimCount(context.Background(), "covid")
		srv.Close()
		if tc.bad {
			if err == nil {
				t.Fatalf("%q was read as %d, want an error", tc.payload, got)
			}
			// An unreadable answer must not read as ZERO: backfill would take
			// that for "this court has no claims" and stop looking.
			if got != 0 {
				t.Fatalf("%q returned %d alongside its error", tc.payload, got)
			}
			continue
		}
		if err != nil || got != tc.want {
			t.Fatalf("%q -> (%d, %v), want %d", tc.payload, got, err, tc.want)
		}
	}

	// A node that will not answer is an error, never a zero — the cursor must
	// stay where it was rather than advance past claims nobody read.
	down := &Chain{RPC: "http://127.0.0.1:1", PkgPath: "p", HTTP: &http.Client{}}
	if _, err := down.ClaimCount(context.Background(), "covid"); err == nil {
		t.Fatal("an unreachable node must be an error")
	}
}

func TestTheLimiterReclaimsIdleBucketsWithoutEvictingActiveOnes(t *testing.T) {
	// reapLocked had 0% coverage. It runs only when the map is full, which no
	// test reached — and it is the path that decides whether a burst from many
	// addresses evicts the buckets of the clients currently being metered.
	l := newLimiter()
	now := time.Now()

	// Fill the map with clients that have just spent a token.
	for i := 0; i < limiterMaxIPs; i++ {
		if !l.allow(fmt.Sprintf("ip-%d", i), now) {
			t.Fatalf("client %d was refused while the map had room", i)
		}
	}
	// A NEW client arriving into a full map of ACTIVE buckets is refused rather
	// than let through unmetered: this is a burst larger than the service is
	// sized for, and letting it past is the failure the limiter exists to stop.
	if l.allow("newcomer", now) {
		t.Fatal("a full map of active buckets must not admit an unmetered client")
	}

	// Once those buckets have sat full long enough to be indistinguishable from
	// a client that never called, they are reclaimed and the newcomer gets in.
	later := now.Add(uploadRefill*time.Duration(uploadBurst) + time.Minute)
	if !l.allow("newcomer", later) {
		t.Fatal("idle buckets must be reclaimed so new clients can be metered")
	}

	// And a client that is still spending is NOT evicted: it keeps its bucket
	// and its remaining tokens, or a busy uploader would be handed a fresh
	// burst every time the map filled.
	busy := "ip-0"
	for i := 0; i < uploadBurst; i++ {
		l.allow(busy, later)
	}
	if l.allow(busy, later) {
		t.Fatal("a spent bucket must not be silently replaced with a full one")
	}
}

// errChain fails ClaimCount after a set number of calls, and can fail one
// specific claim's hashes.
type errChain struct {
	count    uint64
	byID     map[uint64][]string
	failFrom int // ClaimCount fails on this call number onward (1-based); 0 = never
	calls    int
	badID    uint64
}

func (e *errChain) ClaimCount(ctx context.Context, court string) (uint64, error) {
	e.calls++
	if e.failFrom > 0 && e.calls >= e.failFrom {
		return 0, errors.New("node unreachable")
	}
	return e.count, nil
}
func (e *errChain) ClaimHashes(ctx context.Context, court string, id uint64) ([]string, error) {
	if id == e.badID {
		return nil, errors.New("that claim cannot be read")
	}
	return e.byID[id], nil
}

func TestANodeThatWillNotAnswerDoesNotCostTheClaimsBehindIt(t *testing.T) {
	// THE FAILURE BACKFILL EXISTS TO PREVENT. If the cursor advanced when the
	// node errored, those claims would never be walked again — and the bytes
	// they reference would expire an hour later with nobody told. Silent
	// evidence loss, produced by an outage rather than an attacker.
	st := testStore(t)
	ctx := context.Background()
	sum, _ := st.Put(ctx, "image/png", pngBody, "covid")

	chain := &errChain{count: 5, byID: map[uint64][]string{3: {sum}}, failFrom: 1}
	if _, err := st.Backfill(ctx, chain); err == nil {
		t.Fatal("a node that will not answer must be reported, not swallowed")
	}
	// The cursor must not have moved: the claims were never read.
	if c, _ := st.cursor(ctx, "covid"); c != 0 {
		t.Fatalf("the cursor advanced to %d past claims nobody read", c)
	}

	// When the node comes back, the same claims are walked and the bytes kept.
	chain.failFrom = 0
	if kept, err := st.Backfill(ctx, chain); err != nil || kept != 1 {
		t.Fatalf("after the outage: kept %d, err %v", kept, err)
	}
	if _, err := st.SweepStaged(ctx, time.Now().Add(StageTTL+time.Minute)); err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if _, _, err := st.Get(ctx, sum); err != nil {
		t.Fatal("an outage must delay the promotion, never lose it")
	}
}

func TestOneUnreadableClaimDoesNotStopTheOnesBehindIt(t *testing.T) {
	st := testStore(t)
	ctx := context.Background()
	a, _ := st.Put(ctx, "image/png", pngWith("a"), "covid")
	b, _ := st.Put(ctx, "image/png", pngWith("b"), "covid")

	// Claim 2 cannot be read — purged, or never existed. Claim 3 must still be
	// walked, or one hole in a docket would strand everything after it.
	chain := &errChain{count: 3, badID: 2,
		byID: map[uint64][]string{1: {a}, 3: {b}}}
	if kept, err := st.Backfill(ctx, chain); err != nil || kept != 2 {
		t.Fatalf("kept %d, err %v — a hole must not stop the walk", kept, err)
	}
}

func TestOnePassWalksABoundedNumberOfClaims(t *testing.T) {
	// Without the clamp, a court with a hundred thousand claims is walked in one
	// pass — a sweeper loop that does not come back for hours, and a node asked
	// a hundred thousand questions in a burst.
	st := testStore(t)
	ctx := context.Background()
	if _, err := st.Put(ctx, "image/png", pngBody, "covid"); err != nil {
		t.Fatalf("put: %v", err)
	}
	asked := map[uint64]bool{}
	chain := &countingChain{count: 100000, asked: asked}

	if _, err := st.Backfill(ctx, chain); err != nil {
		t.Fatalf("backfill: %v", err)
	}
	if len(asked) != backfillBatch {
		t.Fatalf("one pass asked about %d claims, want the batch of %d",
			len(asked), backfillBatch)
	}
	// And the next pass RESUMES rather than starting over, or the tail of a long
	// docket is never reached at all.
	if c, _ := st.cursor(ctx, "covid"); c != backfillBatch {
		t.Fatalf("the cursor is at %d, want %d", c, backfillBatch)
	}
	asked2 := map[uint64]bool{}
	chain.asked = asked2
	if _, err := st.Backfill(ctx, chain); err != nil {
		t.Fatalf("second pass: %v", err)
	}
	if asked2[1] {
		t.Fatal("the second pass re-walked claim 1 instead of resuming")
	}
}

type countingChain struct {
	count uint64
	asked map[uint64]bool
}

func (c *countingChain) ClaimCount(ctx context.Context, court string) (uint64, error) {
	return c.count, nil
}
func (c *countingChain) ClaimHashes(ctx context.Context, court string, id uint64) ([]string, error) {
	c.asked[id] = true
	return nil, nil
}

func TestEveryTypeItClaimsToStoreIsActuallyRecognised(t *testing.T) {
	// SniffMIME was only ever exercised with PNG, WebP and GIF. The other two
	// branches never ran — so a wrong JPEG signature would have refused every
	// JPEG upload, which is the commonest photograph there is, and nothing would
	// have said why.
	//
	// Real leading bytes, not invented ones: JPEG is SOI + APP0, AVIF is an
	// ISO-BMFF box whose brand sits after "ftyp".
	jpeg := append([]byte{0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10}, []byte("JFIF\x00")...)
	avif := append([]byte{0, 0, 0, 0x20}, []byte("ftypavif")...)
	avis := append([]byte{0, 0, 0, 0x20}, []byte("ftypavis")...)

	for _, tc := range []struct {
		body []byte
		want string
	}{
		{jpeg, "image/jpeg"},
		{avif, "image/avif"},
		{avis, "image/avif"},
		{pngBody, "image/png"},
		{webpWith(""), "image/webp"},
		{[]byte("GIF89a and the rest"), "image/gif"},
		{[]byte("GIF87a and the rest"), "image/gif"},
		// A box that is not an image brand must not pass as one.
		{append([]byte{0, 0, 0, 0x20}, []byte("ftypmp42")...), ""},
		{[]byte{0xff, 0xd8}, ""}, // truncated SOI
	} {
		if got := SniffMIME(tc.body); got != tc.want {
			t.Fatalf("SniffMIME(%q…) = %q, want %q", tc.body[:min(6, len(tc.body))], got, tc.want)
		}
	}

	// And the store accepts a real JPEG end to end, which is the thing a person
	// actually does.
	st := testStore(t)
	if _, err := st.Put(context.Background(), "image/jpeg", jpeg, ""); err != nil {
		t.Fatalf("a real JPEG was refused: %v", err)
	}
	if _, err := st.Put(context.Background(), "image/png", nil, ""); err == nil {
		t.Fatal("an empty body must be refused")
	}
}

func TestTheBrowsersPreflightIsAnswered(t *testing.T) {
	// A cross-origin POST is preceded by an OPTIONS request, and a browser that
	// does not like the answer never sends the upload at all. Neither preflight
	// had ever run: the composer would have failed at its first step with no
	// error the page could show.
	srv, st := newTestServer(t)
	mux := http.NewServeMux()
	srv.Routes(mux)

	for _, path := range []string{"/m", "/m/claimed"} {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest(http.MethodOptions, path, nil))
		if rec.Code != http.StatusNoContent {
			t.Fatalf("%s preflight returned %d", path, rec.Code)
		}
		if rec.Header().Get("Access-Control-Allow-Origin") != "*" {
			t.Fatalf("%s preflight must allow the page's origin", path)
		}
		if !strings.Contains(rec.Header().Get("Access-Control-Allow-Methods"), "POST") {
			t.Fatalf("%s preflight must allow POST: %q", path,
				rec.Header().Get("Access-Control-Allow-Methods"))
		}
	}

	// HEAD is how a client asks whether a blob is there without pulling it —
	// the cheapest question the archive answers.
	sum, _ := st.Put(context.Background(), "image/png", pngBody, "")
	if err := st.Promote(context.Background(), sum); err != nil {
		t.Fatalf("promote: %v", err)
	}
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodHead, "/m/"+sum, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("HEAD returned %d", rec.Code)
	}
	if rec.Body.Len() != 0 {
		t.Fatalf("HEAD must send no body, sent %d bytes", rec.Body.Len())
	}
	if rec.Header().Get("Content-Type") != "image/png" {
		t.Fatal("HEAD must still describe what is there")
	}
}

func TestAModelsUnitsAreNormalisedRatherThanTrusted(t *testing.T) {
	// A model answering on 0-100 is not a reason to throw its judgement away,
	// but neither is one answering -5 or 400 a reason to act on it. Both clamps
	// were unexercised.
	for _, tc := range []struct{ in, want float64 }{
		{0.9, 0.9}, {88, 0.88}, {100, 1}, {0, 0}, {-5, 0}, {400, 1},
	} {
		if got := normalizeEyeConfidence(tc.in); got != tc.want {
			t.Fatalf("normalizeEyeConfidence(%v) = %v, want %v", tc.in, got, tc.want)
		}
	}

	// clipWhy turns a newline into a space rather than dropping it: the prose is
	// printed on one line, and joining two sentences without a gap between them
	// makes a word that was never written.
	if got := clipWhy("first line\nsecond\tthird"); got != "first line second third" {
		t.Fatalf("clipWhy folded to %q", got)
	}
	// A person's block with no stated reason still records something, or the
	// queue shows an act with a blank beside it.
	st := testStore(t)
	ctx := context.Background()
	sum, _ := st.Put(ctx, "image/png", pngBody, "")
	if err := st.BlockByOperator(ctx, sum, ""); err != nil {
		t.Fatalf("block: %v", err)
	}
	q, _ := st.PendingReview(ctx, 10)
	if len(q) != 1 || q[0].Why == "" {
		t.Fatalf("a reasonless block must still say who did it: %+v", q)
	}
}

// realmPayload is the exact JSON the realm answers ClaimMedia with, captured
// from a node in gnoland/testdata/kourtv2_media.txtar. realm/r/kourtv2's own
// suite asserts encodeMedia still produces it, and web/tests/media_test.js holds
// it too.
//
// WHY IT IS A LITERAL HERE. chain.go declares its own mediaItem with its own
// json tags, and every test above fed it JSON this file wrote — which checks
// encoding/json, not whether two Go programs agree about a field name. If the
// realm renamed sha256, this parser would return no hashes, backfill would
// promote nothing, and every filed image would expire an hour later with nobody
// told. That is a silent loss of evidence caused by a rename.
const realmPayload = `[{"kind":"img","sha256":"1111111111111111111111111111111111111111111111111111111111111111",` +
	`"mime":"image/webp","w":800,"h":600,"bytes":90210,"caption":"the memo",` +
	`"mirrors":["https://i.imgur.com/abc.webp"]}]`

const realmPayloadPurged = `[{"kind":"img","purged":true},` +
	`{"kind":"img","sha256":"2222222222222222222222222222222222222222222222222222222222222222",` +
	`"mime":"image/webp","w":8,"h":6,"bytes":9,"caption":"kept","mirrors":[]}]`

func TestTheArchiveReadsWhatTheRealmActuallyWrites(t *testing.T) {
	node := fakeNode(t, realmPayload)
	defer node.Close()
	c := &Chain{RPC: node.URL, PkgPath: "gno.land/r/kourt/kourtv2", HTTP: node.Client()}

	hashes, err := c.ClaimHashes(context.Background(), "covid", 1)
	if err != nil {
		t.Fatalf("the archive cannot read what the realm sends: %v", err)
	}
	if len(hashes) != 1 || hashes[0] != strings.Repeat("1", 64) {
		t.Fatalf("got %v, want the one hash the payload carries", hashes)
	}

	// A TOMBSTONED SLOT MUST NOT BUY STORAGE. The court has withdrawn its
	// pointer to those bytes, and reading the marker wrongly would keep them
	// forever — the one direction where a parsing mistake costs disk instead of
	// evidence.
	node2 := fakeNode(t, realmPayloadPurged)
	defer node2.Close()
	c2 := &Chain{RPC: node2.URL, PkgPath: "p", HTTP: node2.Client()}
	h2, err := c2.ClaimHashes(context.Background(), "covid", 1)
	if err != nil {
		t.Fatalf("purged payload: %v", err)
	}
	if len(h2) != 1 || h2[0] != strings.Repeat("2", 64) {
		t.Fatalf("got %v, want only the surviving exhibit", h2)
	}

	// And an empty claim is empty, not an error: the map asks about every claim
	// it draws, most of which carry nothing.
	node3 := fakeNode(t, "[]")
	defer node3.Close()
	c3 := &Chain{RPC: node3.URL, PkgPath: "p", HTTP: node3.Client()}
	if h, err := c3.ClaimHashes(context.Background(), "covid", 1); err != nil || len(h) != 0 {
		t.Fatalf("an empty claim gave (%v, %v)", h, err)
	}
}

// clientClaimedPath and clientUploadPath are exactly what web/media.js builds,
// asserted there as strings. Both are parsed here, so a rename on either side
// fails on the side that made it.
//
// The promotion call is the one that matters most: mediaClaimed swallows
// failures on purpose — by the time it runs the claim is already on chain, and
// a hiccup should cost availability rather than the record — so a parameter
// name the handler does not read would go unnoticed entirely, and the bytes
// would expire an hour later.
const clientClaimedPath = "/m/claimed?court=covid&claim=7"
const clientUploadPath = "/m?court=covid"

func TestTheArchiveParsesTheCallsTheOverlayBuilds(t *testing.T) {
	st := testStore(t)
	sum, _ := st.Put(context.Background(), "image/png", pngBody, "covid")
	node := fakeNode(t, `[{"kind":"img","sha256":"`+sum+`","mirrors":[]}]`)
	defer node.Close()

	srv := NewServer(st, nil, func(r *http.Request) string { return "c" }).
		WithChain(&Chain{RPC: node.URL, PkgPath: "p", HTTP: node.Client()})
	mux := http.NewServeMux()
	srv.Routes(mux)

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, clientClaimedPath, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("the call the overlay builds returned %d: %s", rec.Code, rec.Body.String())
	}
	var out map[string]int
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	// Promoted ONE — proof the court and claim were both read, not merely
	// accepted. A handler that ignored the parameters would answer 200 and
	// promote nothing, which is exactly the silence this pins.
	if out["promoted"] != 1 {
		t.Fatalf("promoted %d, want 1 — the parameters were not read", out["promoted"])
	}

	// And the upload path the overlay builds carries its court into the row
	// backfill later looks at.
	body := pngWith("via-client-path")
	req := httptest.NewRequest(http.MethodPost, clientUploadPath, bytes.NewReader(body))
	req.Header.Set("Content-Type", "image/png")
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("upload returned %d", rec.Code)
	}
	courts, err := st.StagedCourts(context.Background())
	if err != nil {
		t.Fatalf("staged courts: %v", err)
	}
	found := false
	for _, c := range courts {
		if c == "covid" {
			found = true
		}
	}
	if !found {
		t.Fatalf("the court hint did not reach the row: %v", courts)
	}
}

func TestHealthCanTellASweepFromASilence(t *testing.T) {
	// THE ONE QUESTION THIS ANSWERS. The sweep is what keeps the archive from
	// being free permanent hosting, and it is silent when it finds nothing —
	// which is almost always. Without a stamp, "swept and found nothing" and
	// "the goroutine died an hour after boot" look identical from outside, and
	// the second is discovered when the disk fills.
	srv, st := newTestServer(t)
	srv = srv.WithHealthDetail(true)
	mux := http.NewServeMux()
	srv.Routes(mux)
	ctx := context.Background()

	read := func() map[string]any {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/m/health", nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("health returned %d", rec.Code)
		}
		if rec.Header().Get("Cache-Control") != "no-store" {
			t.Fatal("a stale answer about whether a service is alive is worse than none")
		}
		var out map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatalf("decode: %v", err)
		}
		return out
	}

	// Before any sweep has run, it says so rather than reporting a healthy zero.
	if h := read(); h["sweeping"] != false || h["swept_at"].(float64) != 0 {
		t.Fatalf("a service that has never swept must not look swept: %v", h)
	}
	// And it says promotion is off, which is the other way media quietly dies.
	if read()["promoting"] != false {
		t.Fatal("an archive with no chain must say it cannot promote")
	}

	staged, _ := st.Put(ctx, "image/png", pngBody, "covid")
	kept, _ := st.Put(ctx, "image/webp", webpWith("k"), "covid")
	if err := st.Promote(ctx, kept); err != nil {
		t.Fatalf("promote: %v", err)
	}
	if err := st.BlockByOperator(ctx, kept, "a face nobody consented to"); err != nil {
		t.Fatalf("block: %v", err)
	}

	h := read()
	if h["staged"].(float64) != 1 || h["promoted"].(float64) != 1 || h["blocked"].(float64) != 1 {
		t.Fatalf("the counts do not describe the store: %v", h)
	}
	if h["pending_review"].(float64) != 1 {
		t.Fatalf("an operator's queue depth must be visible: %v", h)
	}

	// A SWEEP THAT DELETES NOTHING STILL COUNTS AS A SWEEP. This is the case the
	// stamp exists for: the usual pass finds nothing, and it must still prove
	// the loop is alive.
	if n, err := st.SweepStaged(ctx, time.Now()); err != nil || n != 0 {
		t.Fatalf("sweep deleted %d (err %v) — nothing was old enough", n, err)
	}
	h = read()
	if h["sweeping"] != true || h["swept_at"].(float64) == 0 {
		t.Fatalf("a sweep that found nothing must still be recorded: %v", h)
	}
	if h["staged"].(float64) != 1 {
		t.Fatal("...and must not have deleted anything")
	}
	_ = staged
}

func TestABackfillThatFailsEveryPassDoesNotLookLikeOneThatRuns(t *testing.T) {
	// THE WORST FAILURE TO LEAVE INVISIBLE. If backfill stops, nothing else in
	// this service changes: the sweep keeps running and stamping, `promoting`
	// still reads true because a chain is configured, and filed evidence expires
	// an hour after upload because nothing promoted it. Only a stamp separates
	// "walked and found nothing new" — the usual pass — from "has not completed
	// since Tuesday".
	st := testStore(t)
	ctx := context.Background()
	if _, err := st.Put(ctx, "image/png", pngBody, "covid"); err != nil {
		t.Fatalf("put: %v", err)
	}

	// A node that answers but errors.
	broken := &errChain{count: 5, failFrom: 1}
	if _, err := st.Backfill(ctx, broken); err == nil {
		t.Fatal("the fixture must fail")
	}
	if s, _ := st.Stats(ctx); s.BackfilledAt != 0 {
		t.Fatalf("a failing backfill stamped itself as complete: %+v", s)
	}
	// ...while the sweep keeps stamping, which is exactly how a broken backfill
	// hides behind a healthy-looking service.
	if _, err := st.SweepStaged(ctx, time.Now()); err != nil {
		t.Fatalf("sweep: %v", err)
	}
	s, _ := st.Stats(ctx)
	if s.SweptAt == 0 {
		t.Fatal("the sweep must stamp")
	}
	if s.BackfilledAt != 0 {
		t.Fatalf("the sweep's stamp must not stand in for backfill's: %+v", s)
	}
	// A NODE THAT WAS ASKED AND ERRORED MUST NOT COUNT AS SEEN. This is the arm
	// that distinguishes stamping on a successful answer from stamping on any
	// attempt — the empty-store case below cannot, because it never asks.
	if s.ChainSeenAt != 0 {
		t.Fatalf("an unreachable node was recorded as having answered: %+v", s)
	}

	// When the node recovers, a COMPLETE pass stamps — including one that
	// promotes nothing, since finding nothing new is the normal case.
	broken.failFrom = 0
	if _, err := st.Backfill(ctx, broken); err != nil {
		t.Fatalf("backfill: %v", err)
	}
	if s, _ := st.Stats(ctx); s.BackfilledAt == 0 {
		t.Fatalf("a completed pass must stamp even when it kept nothing: %+v", s)
	}

	// A PASS THAT ASKED NOTHING MUST NOT VOUCH FOR THE NODE. This is the false
	// reassurance the chain stamp exists for, and it was observed on a live
	// service: an unreachable node still showed a recent backfilled_at, because
	// the pass had nothing staged and so never asked.
	empty := namedStore(t, t.Name()+"-empty")
	if _, err := empty.Backfill(ctx, &errChain{count: 3, failFrom: 1}); err != nil {
		t.Fatalf("a pass with nothing staged must succeed: %v", err)
	}
	es, _ := empty.Stats(ctx)
	if es.BackfilledAt == 0 {
		t.Fatal("the pass completed and must say so")
	}
	if es.ChainSeenAt != 0 {
		t.Fatalf("...but it asked the node nothing, so it cannot vouch for it: %+v", es)
	}
	// And when a pass DOES reach the node, that is recorded on its own.
	if s, _ := st.Stats(ctx); s.ChainSeenAt == 0 {
		t.Fatalf("a pass that read a claim count must record the node answered: %+v", s)
	}

	// The review pass is stamped the same way, and separately: a model that has
	// stopped is milder — images serve unreviewed rather than disappearing — but
	// it is still worth being able to see.
	if s, _ := st.Stats(ctx); s.ReviewedAt != 0 {
		t.Fatal("nothing has reviewed yet")
	}
	if _, err := st.ReviewPass(ctx, &fakeEye{v: ImageVerdict{Label: "clean", Confidence: 1}}, 5); err != nil {
		t.Fatalf("review: %v", err)
	}
	if s, _ := st.Stats(ctx); s.ReviewedAt == 0 {
		t.Fatalf("a review pass must stamp: %+v", s)
	}
}

func TestHealthTellsAStrangerNothingToMeterAgainst(t *testing.T) {
	// pending_review IS A LIVE COUNT OF WHAT THE CLASSIFIER FLAGGED, on an
	// endpoint anybody can poll. Published, it lets somebody probing what the
	// model blocks upload, poll, and read the answer off the counter — one image
	// at a time, without ever filing a claim. A free oracle for the one part of
	// this service whose worth depends on not being easy to map.
	//
	// internal/chat settled this policy already: the operator's numbers are
	// behind -health-detail, and only a field with a reader who needs it stays
	// public. Nothing here has such a reader.
	srv, st := newTestServer(t) // detail OFF, as an operator gets it by default
	mux := http.NewServeMux()
	srv.Routes(mux)
	ctx := context.Background()

	sum, _ := st.Put(ctx, "image/png", pngBody, "covid")
	if err := st.BlockByOperator(ctx, sum, "a face nobody consented to"); err != nil {
		t.Fatalf("block: %v", err)
	}
	if _, err := st.SweepStaged(ctx, time.Now()); err != nil {
		t.Fatalf("sweep: %v", err)
	}

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/m/health", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("health returned %d", rec.Code)
	}
	var pub map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &pub); err != nil {
		t.Fatalf("decode: %v", err)
	}
	// It still answers the only question a stranger has a right to ask.
	if pub["ok"] != true {
		t.Fatalf("a liveness check must still answer: %v", pub)
	}
	for _, secret := range []string{"pending_review", "blocked", "staged", "promoted",
		"swept_at", "backfilled_at", "reviewed_at", "chain_seen_at", "promoting", "sweeping"} {
		if _, told := pub[secret]; told {
			t.Fatalf("%q is published to anyone who asks: %v", secret, pub)
		}
	}

	// And an operator who turns it on gets everything, on the same flag the
	// chat's own numbers use — one decision, not two.
	on := http.NewServeMux()
	srv.WithHealthDetail(true).Routes(on)
	rec = httptest.NewRecorder()
	on.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/m/health", nil))
	var opr map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &opr); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if opr["pending_review"].(float64) != 1 || opr["blocked"].(float64) != 1 {
		t.Fatalf("the operator must still get the numbers: %v", opr)
	}
}

func TestAFloodReadsAsOneFilingRatherThanManyIncidents(t *testing.T) {
	// internal/chat settled this about its own queue: flooding buries the entry
	// that matters under decoys, and the answer is not a new punishment but a
	// VIEW that resists it — seventy messages from one address are one row
	// saying seventy. A claim here carries up to seven exhibits, so a flat
	// worst-first list interleaves one filing's decoys with everything else and
	// an operator reads seven incidents instead of one.
	st := testStore(t)
	ctx := context.Background()

	// One filing with several flagged exhibits, and one real thing elsewhere.
	for i, tag := range []string{"a", "b", "c"} {
		sum, err := st.Put(ctx, "image/png", pngWith(tag), "covid")
		if err != nil {
			t.Fatalf("put: %v", err)
		}
		if err := st.PromoteFor(ctx, sum, "covid", 12); err != nil {
			t.Fatalf("promote: %v", err)
		}
		// Ascending confidence, so a worst-first sort would scatter them.
		if _, err := st.Review(ctx, sum, ImageVerdict{Label: "violent",
			Confidence: 0.4 + float64(i)/10, Why: "decoy " + tag}); err != nil {
			t.Fatalf("review: %v", err)
		}
	}
	real1, _ := st.Put(ctx, "image/png", pngWith("real"), "origins")
	if err := st.PromoteFor(ctx, real1, "origins", 3); err != nil {
		t.Fatalf("promote: %v", err)
	}
	if _, err := st.Review(ctx, real1, ImageVerdict{Label: AutoBlockLabel,
		Confidence: 0.99, Why: "the one that matters"}); err != nil {
		t.Fatalf("review: %v", err)
	}

	q, err := st.PendingReview(ctx, 20)
	if err != nil {
		t.Fatalf("pending: %v", err)
	}
	if len(q) != 4 {
		t.Fatalf("expected four flagged, got %d", len(q))
	}
	// EVERY ROW SAYS WHERE IT CAME FROM. Without this an operator cannot tell a
	// filing from a coincidence, and cannot reach the source — which is on chain
	// and is what PurgeClaimMedia takes.
	for _, r := range q {
		if r.Court == "" || r.Claim == 0 {
			t.Fatalf("a queued image with no origin cannot be acted on: %+v", r)
		}
	}
	// The three decoys arrive together rather than interleaved with the one that
	// matters, even though their confidences straddle nothing in common.
	if !(q[0].Court == "covid" && q[1].Court == "covid" && q[2].Court == "covid") {
		t.Fatalf("one filing's exhibits must arrive together: %+v", q)
	}
	if q[3].Court != "origins" || q[3].Why != "the one that matters" {
		t.Fatalf("the other filing must be its own group: %+v", q[3])
	}
}

func TestBlockingHidesAndForgettingDestroys(t *testing.T) {
	// "We no longer serve it" and "we no longer have it" are different
	// sentences, and only one of them answers the question the label `illegal`
	// asks. docs/CLAIM_MEDIA.md §3.2 puts the obligation on this service
	// precisely because it is the one holding the bytes — an archive that could
	// only ever hide them would be answering the wrong question.
	st := testStore(t)
	ctx := context.Background()
	sum, _ := st.Put(ctx, "image/png", pngBody, "covid")
	if err := st.BlockByOperator(ctx, sum, "a face nobody consented to"); err != nil {
		t.Fatalf("block: %v", err)
	}

	// Blocked: not served, still HELD. This is the state that looks finished and
	// is not.
	if _, _, err := st.Get(ctx, sum); err != ErrNotFound {
		t.Fatal("a blocked image must not serve")
	}
	var held int
	if err := st.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM blobs WHERE sha256 = ?`, sum).Scan(&held); err != nil {
		t.Fatalf("count: %v", err)
	}
	if held != 1 {
		t.Fatal("blocking must not silently destroy — an operator may be overruling a model")
	}

	gone, err := st.Forget(ctx, sum)
	if err != nil || !gone {
		t.Fatalf("forget: %v (gone=%v)", err, gone)
	}
	if err := st.db.QueryRowContext(ctx,
		`SELECT COUNT(*) FROM blobs WHERE sha256 = ?`, sum).Scan(&held); err != nil {
		t.Fatalf("count: %v", err)
	}
	if held != 0 {
		t.Fatal("forgetting must actually destroy the bytes")
	}

	// THE RECORD SURVIVES THE BYTES. An operator looking later needs to see
	// something was here and was destroyed; by then the model's prose described
	// bytes nobody can check.
	q, _ := st.PendingReview(ctx, 10)
	if len(q) != 1 {
		t.Fatalf("the review row must outlive the bytes, got %d", len(q))
	}
	if q[0].Why != "destroyed by an operator" {
		t.Fatalf("the row must say what happened: %+v", q[0])
	}
	// AND IT MUST NOT READ AS SERVING. The blob row is gone, so a LEFT JOIN
	// answers blocked=0 — which reported "still serving" for the entries an
	// operator had acted hardest on, the exact opposite of what happened.
	if !q[0].Gone || q[0].Blocked {
		t.Fatalf("a destroyed image must not read as serving: %+v", q[0])
	}
	// AND THE ORIGIN OUTLIVES THE BYTES. court and claim live on the blob row,
	// so destroying it also destroyed the only record of which filing this came
	// from — leaving "filed by an unknown claim" against the entry an operator
	// had just acted hardest on, and no way back to the source on chain.
	if q[0].Court != "covid" {
		t.Fatalf("the filing that produced it must still be readable: %+v", q[0])
	}

	// AND THE DRY RUN MUST SEE A BLOCKED BLOB. Get refuses one deliberately, so
	// asking it "is there anything to destroy" answered no about precisely the
	// images an operator is asking about.
	other, _ := st.Put(ctx, "image/webp", webpWith("blocked"), "covid")
	if err := st.BlockByOperator(ctx, other, "held back"); err != nil {
		t.Fatalf("block: %v", err)
	}
	if _, _, err := st.Get(ctx, other); err != ErrNotFound {
		t.Fatal("the fixture must be blocked")
	}
	if held, err := st.Held(ctx, other); err != nil || !held {
		t.Fatalf("a blocked blob is still HELD: held=%v err=%v", held, err)
	}
	if held, _ := st.Held(ctx, strings.Repeat("e", 64)); held {
		t.Fatal("nothing must not read as held")
	}

	// Forgetting something that was never here is not an error, and says so.
	if gone, err := st.Forget(ctx, strings.Repeat("f", 64)); err != nil || gone {
		t.Fatalf("forgetting nothing: gone=%v err=%v", gone, err)
	}
}

func TestOneBogusCourtHintCannotStopEverybodyElsesPromotion(t *testing.T) {
	// THE CHEAPEST DENIAL OF SERVICE IN THIS PACKAGE, and it costs one upload.
	//
	// The court on an upload is a HINT the client supplies, unvalidated, and
	// backfill walks exactly the courts that have staged bytes. Ask a node about
	// a court that does not exist and it does not shrug — the realm's mustCourt
	// panics and qeval returns an error. Backfill treated that the same as an
	// unreachable node and returned, abandoning every court it had not reached
	// yet, while the caller logged the error and swept anyway.
	//
	// So: POST /m?court=does-not-exist with any small image, once an hour, and
	// nobody's evidence is ever promoted again. The bytes honest people uploaded
	// are deleted by the sweep at the TTL — including from claims filed through
	// gnoweb or the CLI, which have no /m/claimed and rely on this entirely.
	// "Losing evidence quietly is worse than any missing feature" is the comment
	// at the top of backfill.go; this was the way it happened.
	ctx := context.Background()
	st := testStore(t)

	// THE ATTACKER GOES FIRST, which costs them nothing to arrange and is the
	// case that matters: StagedCourts has no ORDER BY, so which court a pass
	// reaches before the abort is not a property anybody controls. Written the
	// other way round this test passed against the broken code, because the
	// honest court happened to be promoted before the poison one was reached.
	if _, err := st.Put(ctx, "image/png", pngWith("attacker"), "nosuchcourt"); err != nil {
		t.Fatalf("put: %v", err)
	}
	filed, err := st.Put(ctx, "image/png", pngWith("real-evidence"), "realcourt")
	if err != nil {
		t.Fatalf("put: %v", err)
	}

	chain := &fakeChain{count: 1, byID: map[uint64][]string{1: {filed}}, unknown: "nosuchcourt"}
	// The error is still reported — an operator should hear about it — but the
	// pass must finish the courts that CAN be answered.
	kept, berr := st.Backfill(ctx, chain)
	if berr == nil {
		t.Fatal("a court the node cannot answer for must still be reported")
	}
	if kept != 1 {
		t.Fatalf("the honest court's evidence was not promoted: kept %d", kept)
	}

	// And it survives the sweep, which is the whole point: promotion is what
	// stands between a filed exhibit and deletion at the TTL.
	if _, err := st.SweepStaged(ctx, time.Now().Add(StageTTL+time.Minute)); err != nil {
		t.Fatalf("sweep: %v", err)
	}
	if _, _, err := st.Get(ctx, filed); err != nil {
		t.Fatalf("the evidence a claim references was swept: %v", err)
	}
}

func TestTheOriginOfABlobCannotBeRewrittenByAStranger(t *testing.T) {
	// THE OPERATOR'S QUEUE IS GROUPED BY ORIGIN, and PendingReview says why in as
	// many words: a flat worst-first list interleaves one filing's seven exhibits
	// with everything else, "so the operator reads seven separate incidents
	// instead of one — and deciding about the source is the action that actually
	// ends it".
	//
	// That makes filed_court the one field an operator acts on. It was
	// last-writer-wins: every promotion overwrote it, and a blob is addressed by
	// its HASH, which is public — it is in ClaimMedia's output and in the archive
	// URL itself. So anyone could file their own claim quoting somebody else's
	// image and take ownership of the row.
	//
	// Both directions hurt. An attacker can point a stranger's evidence at their
	// own throwaway court so an operator bans the wrong source; or, holding
	// something that is about to be judged, file a second claim from a burner
	// court AFTER the first so the "decide about the source" action lands there
	// instead of on them.
	//
	// It is not only adversarial: two honest claims quoting the same document
	// flipped the attribution back and forth on every pass, so the queue was not
	// even stable.
	ctx := context.Background()
	st := testStore(t)

	sum, err := st.Put(ctx, "image/png", pngWith("someone's evidence"), "realcourt")
	if err != nil {
		t.Fatalf("put: %v", err)
	}
	// The claim that actually filed it.
	if err := st.PromoteFor(ctx, sum, "realcourt", 7); err != nil {
		t.Fatalf("promote: %v", err)
	}
	// A stranger files their own claim quoting the same hash. Nothing here is
	// forged: the chain really does say their claim references it.
	if err := st.PromoteFor(ctx, sum, "burner", 1); err != nil {
		t.Fatalf("promote: %v", err)
	}

	// Reviewed, so it reaches the queue an operator reads.
	if _, err := st.Review(ctx, sum, ImageVerdict{Label: "explicit", Confidence: 0.7, Why: "x"}); err != nil {
		t.Fatalf("review: %v", err)
	}
	pending, err := st.PendingReview(ctx, 10)
	if err != nil {
		t.Fatalf("pending: %v", err)
	}
	if len(pending) != 1 {
		t.Fatalf("expected one row, got %d", len(pending))
	}
	if pending[0].Court != "realcourt" || pending[0].Claim != 7 {
		t.Fatalf("the operator was shown %s/%d as the origin; a stranger rewrote it",
			pending[0].Court, pending[0].Claim)
	}

	// AND THE RE-USE IS STILL A PROMOTION. Refusing to rewrite the origin must
	// not refuse to keep the bytes: a second claim quoting them is a second
	// reason not to sweep them.
	if _, _, err := st.GetServable(ctx, sum); err != nil {
		t.Fatalf("a re-used blob stopped being served: %v", err)
	}

	// FIRST-WINS IS NOT WRITE-ONCE-AND-NEVER-AGAIN. The ordinary path promotes
	// with no attribution at all — Promote() from /m/claimed's older sibling, or
	// a backfill pass that knows the court but not yet the claim — and the first
	// caller that HAS an origin must still be able to record it. An empty field
	// is not an owner.
	// namedStore, not testStore: testStore names the database after the test, so
	// a second one inside the same test IS the first one — and PendingReview then
	// answers with both blobs.
	blank := namedStore(t, t.Name()+"/unattributed")
	sum2, err := blank.Put(ctx, "image/png", pngWith("later attribution"), "")
	if err != nil {
		t.Fatalf("put: %v", err)
	}
	if err := blank.Promote(ctx, sum2); err != nil {
		t.Fatalf("promote: %v", err)
	}
	if err := blank.PromoteFor(ctx, sum2, "realcourt", 3); err != nil {
		t.Fatalf("promote for: %v", err)
	}
	if _, err := blank.Review(ctx, sum2, ImageVerdict{Label: "explicit", Confidence: 0.7, Why: "x"}); err != nil {
		t.Fatalf("review: %v", err)
	}
	got, err := blank.PendingReview(ctx, 10)
	if err != nil {
		t.Fatalf("pending: %v", err)
	}
	if len(got) != 1 || got[0].Court != "realcourt" || got[0].Claim != 3 {
		t.Fatalf("an unattributed blob never got its origin: %+v", got)
	}
}
