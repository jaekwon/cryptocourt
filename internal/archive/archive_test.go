package archive

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

// A one-pixel PNG, so the tests exercise a real servable type rather than
// whatever bytes happened to be handy.
var pngBody = []byte("\x89PNG\r\n\x1a\n" + strings.Repeat("payload", 8))

func testStore(t *testing.T) *Store {
	t.Helper()
	db, err := sql.Open("sqlite", "file:"+t.Name()+"?mode=memory&cache=shared")
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

	sum, err := st.Put(ctx, "image/png", pngBody)
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
		if _, err := st.Put(context.Background(), mime, pngBody); err == nil {
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

	kept, _ := st.Put(ctx, "image/png", pngBody)
	dropped, _ := st.Put(ctx, "image/webp", append([]byte("other"), pngBody...))
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

	sum, _ := st.Put(ctx, "image/png", pngBody)
	if err := st.Promote(ctx, sum); err != nil {
		t.Fatalf("promote: %v", err)
	}
	// Re-uploading must not un-promote something already permanent...
	if _, err := st.Put(ctx, "image/png", pngBody); err != nil {
		t.Fatalf("re-put: %v", err)
	}
	if n, _ := st.SweepStaged(ctx, time.Now().Add(StageTTL*2)); n != 0 {
		t.Fatal("a re-upload un-promoted a permanent blob")
	}

	// ...nor extend the life of something already expiring, which would let a
	// script keep bytes alive indefinitely by re-posting them.
	tmp, _ := st.Put(ctx, "image/webp", append([]byte("tmp"), pngBody...))
	if _, err := st.Put(ctx, "image/webp", append([]byte("tmp"), pngBody...)); err != nil {
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
	sum, _ := st.Put(ctx, "image/png", pngBody)
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
	sum, _ := st.Put(context.Background(), "image/png", pngBody)

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
	big := strings.Repeat("x", MaxBytes+64)
	req = httptest.NewRequest(http.MethodPost, "/m", strings.NewReader(big))
	req.Header.Set("Content-Type", "image/png")
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != http.StatusRequestEntityTooLarge && rec.Code != http.StatusBadRequest {
		t.Fatalf("an oversized upload returned %d", rec.Code)
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

	claimed, _ := st.Put(ctx, "image/png", pngBody)
	stray, _ := st.Put(ctx, "image/webp", append([]byte("stray"), pngBody...))
	purged, _ := st.Put(ctx, "image/gif", append([]byte("purged"), pngBody...))

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

	sum, _ := st.Put(context.Background(), "image/png", pngBody)
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
