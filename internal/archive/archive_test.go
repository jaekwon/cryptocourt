package archive

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
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
	count  uint64
	byID   map[uint64][]string
	counts int // how many times ClaimCount was asked
}

func (f *fakeChain) ClaimCount(ctx context.Context, court string) (uint64, error) {
	f.counts++
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
	srv, _ := newTestServer(t)
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
