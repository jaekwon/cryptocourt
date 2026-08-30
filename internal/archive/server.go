package archive

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var (
	digestRe = regexp.MustCompile(`^[0-9a-f]{64}$`)
	// The realm's own court-slug shape, so a malformed one is refused here
	// rather than travelling into a chain query.
	courtRe = regexp.MustCompile(`^[a-z0-9-]{1,32}$`)
)

type Server struct {
	store *Store
	log   *log.Logger
	// clientIP maps a request to the address rate limits are counted against.
	// Injected because the deployment sits behind nginx, where RemoteAddr is the
	// proxy for every request and would make one bucket for the whole internet.
	clientIP func(*http.Request) string
	limiter  *limiter
	chain    *Chain
}

func NewServer(store *Store, lg *log.Logger, clientIP func(*http.Request) string) *Server {
	if clientIP == nil {
		clientIP = func(r *http.Request) string { return r.RemoteAddr }
	}
	return &Server{store: store, log: lg, clientIP: clientIP, limiter: newLimiter()}
}

// Chain, when set, lets the archive verify that a claim really references a
// blob before keeping it. Without one nothing is ever promoted and every upload
// expires, which is the safe direction to fail: the archive forgets rather than
// becoming free storage.
func (s *Server) WithChain(c *Chain) *Server {
	s.chain = c
	return s
}

func (s *Server) Routes(mux *http.ServeMux) {
	mux.HandleFunc("/m/health", s.health)
	mux.HandleFunc("/m/claimed", s.claimed)
	mux.HandleFunc("/m/", s.blob)
	mux.HandleFunc("/m", s.upload)
}

// health answers whether media is working, and above all whether the SWEEP is
// still running.
//
// The sweep is what keeps this from being free permanent hosting, and it is
// silent when it finds nothing — which is almost always. Without a timestamp,
// "swept and found nothing" and "the goroutine died an hour after boot" look
// identical from outside, and the second is only discovered when the disk
// fills. Read swept_at, not the counts.
func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	st, err := s.store.Stats(r.Context())
	if err != nil {
		if s.log != nil {
			s.log.Printf("archive health: %v", err)
		}
		http.Error(w, "could not read archive state", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	// Never cached: a stale answer about whether a service is alive is worse
	// than no answer.
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{
		"staged": st.Staged, "promoted": st.Promoted, "blocked": st.Blocked,
		"pending_review": st.Pending, "swept_at": st.SweptAt,
		"backfilled_at": st.BackfilledAt, "reviewed_at": st.ReviewedAt,
		"chain_seen_at": st.ChainSeenAt,
		// Said outright rather than left to be inferred from a zero.
		"sweeping":  st.SweptAt > 0,
		"promoting": s.chain != nil,
	})
}

// claimed promotes every blob a claim references, after asking the chain.
//
// The composer calls this once its transaction is broadcast, so bytes uploaded
// seconds earlier stop being temporary. It needs no authentication and takes no
// claim of its own: the CHAIN decides what is referenced, and the worst a
// stranger can do by calling it for someone else's claim is make that claim's
// evidence permanent, which is what filing it already asked for.
//
// A court and claim that reference nothing promote nothing. There is no path
// here that keeps bytes no claim points at.
func (s *Server) claimed(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	if r.Method == http.MethodOptions {
		w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST, OPTIONS")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if s.chain == nil {
		http.Error(w, "this archive cannot reach a chain", http.StatusServiceUnavailable)
		return
	}
	// Every call costs an outbound query, so it is metered like an upload —
	// otherwise it is a way to make this service hammer the node for free.
	if !s.limiter.allow(s.clientIP(r), time.Now()) {
		http.Error(w, "too many requests; try again shortly", http.StatusTooManyRequests)
		return
	}

	court := r.URL.Query().Get("court")
	if !courtRe.MatchString(court) {
		http.Error(w, "bad court", http.StatusBadRequest)
		return
	}
	claimID, err := strconv.ParseUint(r.URL.Query().Get("claim"), 10, 64)
	if err != nil || claimID == 0 {
		http.Error(w, "bad claim id", http.StatusBadRequest)
		return
	}

	hashes, err := s.chain.ClaimHashes(r.Context(), court, claimID)
	if err != nil {
		if s.log != nil {
			s.log.Printf("archive: claim %s/%d: %v", court, claimID, err)
		}
		http.Error(w, "could not read that claim", http.StatusBadGateway)
		return
	}
	promoted := 0
	for _, h := range hashes {
		if err := s.store.Promote(r.Context(), h); err != nil {
			if s.log != nil {
				s.log.Printf("archive: promoting %s: %v", h, err)
			}
			continue
		}
		promoted++
	}

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	_ = json.NewEncoder(w).Encode(map[string]int{"promoted": promoted})
}

// blob serves bytes by digest.
//
// The URL is derivable from the hash alone, which is what lets a client — and
// the realm's own markdown — reach the archive without anything being stored on
// chain to point at it.
func (s *Server) blob(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	sum := strings.TrimPrefix(r.URL.Path, "/m/")
	if !digestRe.MatchString(sum) {
		http.NotFound(w, r)
		return
	}
	mime, body, err := s.store.Get(r.Context(), sum)
	if err != nil {
		// A blocked blob and an absent one answer identically: a takedown that
		// announced itself would be a lookup oracle for what has been taken down.
		http.NotFound(w, r)
		return
	}

	h := w.Header()
	h.Set("Content-Type", mime)
	// The name is the content, so the bytes at this URL can never change and the
	// answer is cacheable forever.
	h.Set("Cache-Control", "public, max-age=31536000, immutable")
	h.Set("ETag", `"`+sum+`"`)
	// NEVER LET THE BROWSER GUESS. The type is one of five raster formats and the
	// bytes came from a stranger; sniffing is how "image" becomes "document".
	h.Set("X-Content-Type-Options", "nosniff")
	// Belt and braces for the same reason SVG is refused at the door: even if a
	// type ever slipped through, nothing here may fetch, script or frame.
	h.Set("Content-Security-Policy", "default-src 'none'; sandbox")
	// Any client may verify these bytes against the hash — that is the whole
	// point of publishing them — so the read is deliberately open.
	h.Set("Access-Control-Allow-Origin", "*")
	// The realm's markdown points every gnoweb reader here, so their referrer
	// would otherwise say which claim they are reading.
	h.Set("Referrer-Policy", "no-referrer")

	if r.Method == http.MethodHead {
		w.WriteHeader(http.StatusOK)
		return
	}
	if _, err := w.Write(body); err != nil && s.log != nil {
		s.log.Printf("archive: writing %s: %v", sum, err)
	}
}

// upload stages bytes and answers with their digest.
//
// It does NOT accept a digest from the caller. The archive hashes what it
// received, so bytes can never sit at an address that does not describe them.
func (s *Server) upload(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	if r.Method == http.MethodOptions {
		w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST, OPTIONS")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	ip := s.clientIP(r)
	if !s.limiter.allow(ip, time.Now()) {
		http.Error(w, "too many uploads; try again shortly", http.StatusTooManyRequests)
		return
	}

	mime := strings.TrimSpace(strings.SplitN(r.Header.Get("Content-Type"), ";", 2)[0])
	if !MIMEServable(mime) {
		// Named rather than generic: the composer converts everything to WebP, so
		// a caller seeing this is a script or a mistake, and both are helped by
		// being told which types exist.
		http.Error(w, "unsupported type: send image/png, image/jpeg, image/webp, "+
			"image/gif or image/avif", http.StatusUnsupportedMediaType)
		return
	}

	// MaxBytes+1 so an oversized body is REFUSED rather than silently truncated
	// into a different image with a different hash than the uploader computed.
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxBytes+1))
	if err != nil {
		// MaxBytesReader FAILS THE READ; it does not hand back a long body. So
		// the size check below could never run, and an oversized upload got
		// "could not read the upload" — a generic answer to a specific and very
		// common problem, with the useful message sitting unreachable underneath
		// it. Verified against the running service, not deduced.
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			http.Error(w, "that image is too large — the limit is 256 KB, and the "+
				"composer shrinks pictures to fit before sending them",
				http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, "could not read the upload", http.StatusBadRequest)
		return
	}
	if len(body) > MaxBytes {
		// Belt and braces: reached only if MaxBytesReader ever stops erroring.
		http.Error(w, "that image is too large", http.StatusRequestEntityTooLarge)
		return
	}

	// A court hint lets backfill find these bytes if the composer never gets to
	// call /m/claimed — a closed tab must not cost somebody their evidence.
	court := r.URL.Query().Get("court")
	if court != "" && !courtRe.MatchString(court) {
		http.Error(w, "bad court", http.StatusBadRequest)
		return
	}
	sum, err := s.store.Put(r.Context(), mime, body, court)
	if err != nil {
		if s.log != nil {
			s.log.Printf("archive: put from %s: %v", ip, err)
		}
		http.Error(w, "could not store the upload", http.StatusBadRequest)
		return
	}

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	// The URL is returned as well as the digest so the composer never has to
	// build it, and so this stays the one place that knows the shape.
	_ = json.NewEncoder(w).Encode(map[string]string{
		"sha256": sum,
		"url":    "/m/" + sum,
	})
}
