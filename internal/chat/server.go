package chat

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Server is the HTTP surface. It enforces; it never scans.
type Server struct {
	Store  *Store
	Hasher *Hasher
	Policy IPPolicy

	// Chains maps a chain name to nothing in particular — its presence is the
	// allowlist. A client-chosen path segment with no allowlist would be a fresh
	// table partition and a fresh per-court budget per made-up name.
	Chains map[string]bool

	// CountryHeader, when set, is a trusted proxy header carrying an ISO country
	// code (Cloudflare's CF-IPCountry, say). Empty means no flags, which is the
	// honest default: the alternative is shipping every visitor's address to a
	// third-party geolocation API for a decoration.
	CountryHeader string

	// Geo resolves a country from the address when no proxy header does. Optional:
	// a nil Geo means no flags, which is a working configuration rather than a
	// degraded one.
	//
	// The header wins when both are present, because a CDN sitting in front of us
	// has better information than a database we downloaded last month.
	Geo interface {
		Country(netip.Addr) string
	}

	Log *log.Logger
}

var (
	courtRe = regexp.MustCompile(`^[a-z0-9-]{1,32}$`)
	chainRe = regexp.MustCompile(`^[A-Za-z0-9._-]{1,32}$`)
	ccRe    = regexp.MustCompile(`^[A-Z]{2}$`)
)

func (s *Server) Routes() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/chat/health", s.health)
	mux.HandleFunc("/api/chat/", s.messages)
	return mux
}

// cors answers the preflight and sets the shared headers.
//
// ACAO is "*" because the repo's own demo path opens the page from file://, whose
// origin is null, and gnodev already does exactly this for the same reason. That is
// safe for reads. It is NOT what protects writes — see csrfOK.
func (s *Server) cors(w http.ResponseWriter, r *http.Request) bool {
	h := w.Header()
	h.Set("Access-Control-Allow-Origin", "*")
	h.Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	h.Set("Access-Control-Allow-Headers", "Content-Type")
	h.Set("Access-Control-Max-Age", "600")
	h.Set("Vary", "Origin")
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return true
	}
	return false
}

// csrfOK is what actually protects a write, because CORS does not.
//
// A cross-origin fetch with mode:'no-cors', or a form with enctype="text/plain",
// is CORS-SAFELISTED: it is sent without a preflight and it executes. CORS
// withholds only the response, which an attacker does not want — the side effect is
// the point, and here identity IS the client address, which the browser attaches
// for free. Without this, any web page could make its visitors post scam text and
// collect the timeouts.
//
// Two checks:
//
//   - Content-Type must be application/json. That type is not safelisted, so a
//     cross-origin POST now needs a preflight, which we answer.
//   - Sec-Fetch-Site, WHEN PRESENT, must not be cross-site. Browsers set it and
//     script cannot forge it.
//
// Absent Sec-Fetch-Site is ALLOWED, deliberately. The header is only sent to
// potentially-trustworthy origins, so on plain HTTP it never arrives at all, and
// requiring it would refuse curl, the operator CLI and every non-browser client
// while buying nothing on the deployments where it is missing. The Content-Type
// rule is the load-bearing half; this one is defence in depth on HTTPS.
func csrfOK(r *http.Request) error {
	ct := r.Header.Get("Content-Type")
	if i := strings.IndexByte(ct, ';'); i >= 0 {
		ct = ct[:i]
	}
	if strings.TrimSpace(strings.ToLower(ct)) != "application/json" {
		return errors.New("posting requires Content-Type: application/json")
	}
	if site := r.Header.Get("Sec-Fetch-Site"); site == "cross-site" {
		return errors.New("cross-site posting is refused")
	}
	return nil
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	if s.cors(w, r) {
		return
	}
	h, err := s.Store.Health(r.Context())
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "health unavailable")
		return
	}
	writeJSON(w, http.StatusOK, h)
}

// path splits /api/chat/{chain}/{court}.
func (s *Server) path(r *http.Request) (chain, court string, err error) {
	rest := strings.TrimPrefix(r.URL.Path, "/api/chat/")
	parts := strings.Split(rest, "/")
	if len(parts) != 2 {
		return "", "", errors.New("expected /api/chat/{chain}/{court}")
	}
	chain, court = parts[0], parts[1]
	if !chainRe.MatchString(chain) || !s.Chains[chain] {
		return "", "", fmt.Errorf("unknown chain %q", chain)
	}
	if !courtRe.MatchString(court) {
		return "", "", fmt.Errorf("malformed court %q", court)
	}
	return chain, court, nil
}

func (s *Server) client(r *http.Request) (netip.Addr, error) {
	return s.Policy.ClientIP(r.RemoteAddr, r.Header.Get("X-Forwarded-For"))
}

func (s *Server) messages(w http.ResponseWriter, r *http.Request) {
	if s.cors(w, r) {
		return
	}
	chain, court, err := s.path(r)
	if err != nil {
		writeErr(w, http.StatusNotFound, err.Error())
		return
	}
	addr, err := s.client(r)
	if err != nil {
		// A request that bypassed the proxy is refused rather than treated as
		// ordinary traffic, or the header rules could simply be sidestepped.
		writeErr(w, http.StatusForbidden, "cannot determine client address")
		return
	}
	ipHash, netHash := HashPair(s.Hasher, addr)

	switch r.Method {
	case http.MethodGet:
		s.get(w, r, chain, court, ipHash, netHash)
	case http.MethodPost:
		s.post(w, r, chain, court, addr, ipHash, netHash)
	default:
		writeErr(w, http.StatusMethodNotAllowed, "GET or POST")
	}
}

type getReply struct {
	Messages []Message `json:"messages"`
	Next     int64     `json:"next"`
	You      Status    `json:"you"`
}

func (s *Server) get(w http.ResponseWriter, r *http.Request, chain, court, ipHash, netHash string) {
	// Clamped, because unclamped they are a whole-table dump per request.
	since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
	if since < 0 {
		since = 0
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	msgs, err := s.Store.Recent(r.Context(), chain, court, since, limit)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "cannot read messages")
		return
	}
	// The caller's own state, so the composer can be disabled BEFORE they type
	// into a box that would refuse them. Their own timeout is not a leak; the
	// category and the model's reasoning would be an evasion oracle, and are not
	// included.
	you, err := s.Store.Status(r.Context(), ipHash, netHash)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "cannot read status")
		return
	}
	// A nil slice marshals as `null`, and a client writing the obvious
	// `for (const m of data.messages)` then crashes on an empty room — which is
	// exactly the state a court is in before anyone speaks, and the state a
	// moderated court returns to. An empty list is a list.
	if msgs == nil {
		msgs = []Message{}
	}
	next := since
	if n := len(msgs); n > 0 {
		next = msgs[n-1].ID
	}
	writeJSON(w, http.StatusOK, getReply{Messages: msgs, Next: next, You: you})
}

type postBody struct {
	Moniker string `json:"moniker"`
	Body    string `json:"body"`
}

func (s *Server) post(w http.ResponseWriter, r *http.Request, chain, court string,
	addr netip.Addr, ipHash, netHash string) {
	if err := csrfOK(r); err != nil {
		code := http.StatusForbidden
		if strings.Contains(err.Error(), "Content-Type") {
			code = http.StatusUnsupportedMediaType
		}
		writeErr(w, code, err.Error())
		return
	}
	var in postBody
	r.Body = http.MaxBytesReader(w, r.Body, MaxInputBytes*2)
	if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, "expected {\"moniker\":…,\"body\":…}")
		return
	}
	moniker, err := SanitizeMoniker(in.Moniker)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "moniker: "+err.Error())
		return
	}
	body, err := SanitizeBody(in.Body)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "message: "+err.Error())
		return
	}

	country := ""
	if s.CountryHeader != "" {
		if cc := strings.ToUpper(strings.TrimSpace(r.Header.Get(s.CountryHeader))); ccRe.MatchString(cc) {
			country = cc
		}
	}
	if country == "" && s.Geo != nil {
		// Validated on the way in as well, not only on the way out: a lookup table
		// is a file somebody edited, and two letters is the whole contract.
		if cc := strings.ToUpper(s.Geo.Country(addr)); ccRe.MatchString(cc) {
			country = cc
		}
	}

	id, err := s.Store.Post(r.Context(), PostInput{
		Chain: chain, Court: court, Moniker: moniker, Body: body,
		IPHash: ipHash, NetHash: netHash, Country: country,
		Suffix: s.Hasher.PublicSuffix(addr, court, s.Store.Now().Unix()),
	})
	switch {
	case err == nil:
		writeJSON(w, http.StatusOK, map[string]int64{"id": id})
	case errors.Is(err, ErrKicked):
		you, _ := s.Store.Status(r.Context(), ipHash, netHash)
		writeJSON(w, http.StatusForbidden, map[string]any{
			"error": "posting is blocked for this address", "you": you,
		})
	case errors.Is(err, ErrThrottled), errors.Is(err, ErrDuplicate):
		w.Header().Set("Retry-After", "10")
		writeErr(w, http.StatusTooManyRequests, err.Error())
	case errors.Is(err, ErrPurged):
		writeErr(w, http.StatusGone, "this court is no longer served")
	default:
		if s.Log != nil {
			s.Log.Printf("post %s/%s: %v", chain, court, err)
		}
		writeErr(w, http.StatusServiceUnavailable, "cannot accept messages right now")
	}
}

// Suffix is exposed for the operator CLI and tests.
func (s *Server) Suffix(addr netip.Addr, court string) string {
	return s.Hasher.PublicSuffix(addr, court, time.Now().Unix())
}
