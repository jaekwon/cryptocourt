package archive

import (
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// THE TWO SEAMS NO OTHER TEST REACHES, and docs/CLAIM_MEDIA.md names them both:
// the composer's canvas work, and the archive serving bytes to a page that
// verifies them.
//
// Everything either side of those is covered. media.js is exercised by a node
// harness, this package by Go tests, the realm by its own tests and by a txtar
// against a real node. What none of them touches is the part that only exists
// inside a browser: createImageBitmap, a canvas resize, toBlob("image/webp"),
// and then a POST of those exact bytes to a real archive that stores them,
// serves them back, and has its digest checked by the page that filed them.
//
// That is also the part a person meets FIRST — dropping a photo into the
// composer is step one — and the doc has carried "it has never run against a
// real image" as a known hole since the feature was built.
//
// The direction is inverted on purpose: Go owns the server, because httptest
// gives a real listener on a real port for free and the alternative is a
// long-lived dev binary that something has to remember to kill. Node drives the
// browser, because that is where every other overlay harness already lives.
//
// SAME ORIGIN MATTERS. The page is served by this same server, so archiveBase()
// returning "" is the truth here exactly as it is in production behind nginx —
// and crypto.subtle, which mediaDigest needs, is available without arguing about
// whether file:// counts as a secure context.
func TestComposerAgainstRealArchive(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node not installed - skipping the browser seam")
	}

	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	// Each script gets the same live archive and the same page. Split by subject
	// rather than by cost: one covers the bytes (resize, encode, upload, verify),
	// the other covers how a file gets in at all (paste, drop, pick).
	scripts := []string{"compose_upload.js", "compose_intake.js"}
	for _, name := range scripts {
		if _, err := os.Stat(filepath.Join(root, "web", "tests", "browser", name)); err != nil {
			t.Fatalf("missing harness: %v", err)
		}
	}

	store := testStore(t)
	srv := NewServer(store, log.New(io.Discard, "", 0), func(r *http.Request) string {
		// Every request in this test comes from the same loopback address, and
		// the limiter's burst is smaller than the number of uploads a harness
		// might make. Keying on the request instead keeps the test measuring the
		// composer rather than the rate limit — which has its own tests.
		return r.URL.Path + r.URL.RawQuery + time.Now().String()
	})
	mux := http.NewServeMux()
	srv.Routes(mux)
	// STANDING IN FOR A CHAIN. The public read serves claimed bytes only, and
	// what normally claims them is /m/claimed or Backfill — both of which need a
	// node this test does not have. So the harness asks for promotion directly,
	// which lets it assert the interesting half too: that the very same URL is a
	// 404 until it is claimed.
	//
	// Test scaffolding, mounted here rather than in the package: nothing in
	// production may promote on request.
	mux.HandleFunc("/test/promote", func(w http.ResponseWriter, r *http.Request) {
		if err := store.Promote(r.Context(), r.URL.Query().Get("sha")); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	// The overlay itself, from the working tree. Serving the directory rather
	// than the one file because index.html loads media.js beside it.
	mux.Handle("/", http.FileServer(http.Dir(filepath.Join(root, "web"))))

	// TLS, and not for secrecy. mediaMirrorFault refuses any mirror that is not
	// https — the realm refuses it too — so over plain http the archive's own
	// address would be rejected by the composer and this harness would be
	// measuring a condition production never has. The browser is told to accept
	// the self-signed certificate.
	ts := httptest.NewTLSServer(mux)
	defer ts.Close()

	for _, name := range scripts {
		t.Run(name, func(t *testing.T) {
			cmd := exec.Command(node, filepath.Join(root, "web", "tests", "browser", name), ts.URL)
			cmd.Dir = root
			// puppeteer resolves by walking up from the repo, hence Dir.
			out, err := cmd.CombinedOutput()
			text := string(out)
			if strings.Contains(text, "puppeteer not installed") {
				t.Skip("puppeteer not installed - skipping the browser seam")
			}
			t.Log("\n" + text)
			if err != nil || !strings.Contains(text, "ALL PASS") {
				t.Fatalf("browser harness failed: %v", err)
			}
		})
	}
}
