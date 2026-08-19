package chat

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
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

	// AppealTo is where a punished person is told to complain, and it is empty by default.
	//
	// The panel told anyone it paused "You can appeal — quote reference 9" and there was no
	// channel anywhere: not in the panel, not in kourtchatctl, not in CHAT.md. The whole
	// operator surface — `why`, `unban`, the evidence copy that survives pruning — exists to
	// service appeals, and the person being invited to make one had nowhere to send it.
	//
	// The brief for that surface said an IP-consequence system with no reversal makes
	// "appealable" a lie. A reversal nobody can reach is the same lie one step later.
	//
	// Empty means the panel says nothing about appealing rather than inventing a route, the
	// same way an absent CFG.chat means no chat rather than a guessed origin. Promising a
	// process that does not exist is worse than admitting there is none.
	AppealTo string

	// HealthDetail serves the operator's numbers — backlog, heartbeat, unscannable — on the
	// public /api/chat/health. OFF by default, and that default is the finding.
	//
	// Those numbers are exactly what an attacker needs to time an attack: `enforcing:false`
	// says nobody is being punished at this moment, a large `backlog` says the scanner is
	// behind so post now, and `scanner_seen_at` says whether it is alive and how long ago it
	// ran, which is not otherwise observable. Measured on a running server: an anonymous
	// GET returned all four, and no client in this repo reads any of them —
	// `kourtchatctl status` gets them from the database directly.
	//
	// `enforcing` stays public because it has a legitimate consumer: the panel says so when
	// moderation is in dry run, per §6, and that asymmetry favours the honest side. An
	// attacker can discover dry-run mode in one post; a reader cannot discover it at all.
	HealthDetail bool

	Log *log.Logger

	// One line per cause, not per request. A refusal for an unidentifiable client is either a
	// misconfiguration — in which case it fires for EVERY request and would fill the disk — or
	// somebody probing the origin directly, in which case they choose the rate. See
	// logClientRefusal.
	loggedNoClient, loggedUntrustedPeer sync.Once
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
	site := r.Header.Get("Sec-Fetch-Site")
	if site == "cross-site" {
		return errors.New("cross-site posting is refused")
	}
	// WHEN THE HEADER IS ABSENT, COMPARE ORIGIN AGAINST HOST INSTEAD.
	//
	// "Absent is allowed" left plain HTTP with no protection at all, and measurement is the only
	// reason that is known. A hostile page's PREFLIGHT for a cross-origin JSON POST is answered
	// 204 with `Access-Control-Allow-Origin: *` and POST among the methods, so the browser goes
	// ahead and sends the write; the Content-Type requirement stops the SAFELISTED shapes (a form
	// cannot produce application/json) but not this one, which is preflighted on purpose. Measured
	// against the real server, Origin https://evil.example on 127.0.0.1:
	//
	//	POST without Sec-Fetch-Site   200, and the message was in the room
	//	POST with    Sec-Fetch-Site   403
	//
	// So the pair covers HTTPS and localhost completely and a plain-HTTP origin not at all — the
	// header is only sent to potentially-trustworthy origins.
	//
	// Requiring the header there is not available: no browser sends it, so every legitimate post
	// would be refused too. But Origin and Host are both set by the browser and neither is
	// forgeable by script, so on a cross-HOST write they are enough on their own.
	//
	// Only in the ABSENT case, so nothing that works today changes. When the header arrives it
	// keeps deciding, which matters because `same-site` covers a SUBDOMAIN split — a page on
	// www talking to an API on api — that a host comparison would refuse. Those deployments are
	// on HTTPS by definition of the header arriving at all.
	if site == "" {
		if o := r.Header.Get("Origin"); o != "" && !sameHostAsOrigin(o, r.Host) {
			return errors.New("cross-origin posting is refused")
		}
	}
	return nil
}

// sameHostAsOrigin compares an Origin header with the Host being addressed, ignoring port.
//
// Port is ignored because a chat service on another port of the same host is the deployment §11
// calls the real one, and it is same-SITE: the browser would have said so if it had been able to.
// An unparseable or opaque origin — "null", which is what a file:// page sends — is NOT a match,
// so it is refused rather than waved through.
func sameHostAsOrigin(origin, host string) bool {
	u, err := url.Parse(origin)
	if err != nil || u.Host == "" {
		return false
	}
	return strings.EqualFold(hostWithoutPort(u.Host), hostWithoutPort(host))
}

func hostWithoutPort(hostport string) string {
	if h, _, err := net.SplitHostPort(hostport); err == nil {
		return h
	}
	return hostport
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

// publicHealth is what an anonymous caller gets: enough to keep the page honest, and
// nothing that helps somebody choose a moment.
type publicHealth struct {
	OK        bool   `json:"ok"`
	Enforcing bool   `json:"enforcing"`
	AppealTo  string `json:"appeal_to,omitempty"`
}

// appealTo returns the configured contact, refusing anything that is not plainly one line.
//
// Operator-supplied and rendered in a page. The panel escapes everything it writes, so this is
// not the last line of defence — but a control character or a newline in a contact string is a
// misconfiguration worth swallowing rather than serving, and a very long one is a paste
// accident.
func (s *Server) appealTo() string {
	v := strings.TrimSpace(s.AppealTo)
	if v == "" || len(v) > 200 {
		return ""
	}
	for _, r := range v {
		if r < 0x20 || r == 0x7f {
			return ""
		}
	}
	return v
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
	if s.HealthDetail {
		writeJSON(w, http.StatusOK, struct {
			Health
			AppealTo string `json:"appeal_to,omitempty"`
		}{h, s.appealTo()})
		return
	}
	writeJSON(w, http.StatusOK, publicHealth{
		OK: h.OK, Enforcing: h.Enforcing, AppealTo: s.appealTo(),
	})
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

// logClientRefusal tells the operator why requests are being refused, because the 403 goes to the
// client and the person who can fix it never sees it.
//
// The all-trusted-chain refusal added in b64c86d is the case that forced this. A `--trusted-proxy`
// range wide enough to contain the real clients refuses EVERY request, and the log said nothing at
// all — so the symptom is "nobody can post" and the cause is invisible. That is the shape this
// service keeps finding: a control that will not say why.
//
// ONE LINE PER CAUSE. A misconfiguration fires on every request and would fill the disk; somebody
// probing the origin directly chooses the rate. Neither is worth more than one line, because both
// are persistent conditions rather than events.
//
// The header is printed with %q ON PURPOSE. It is attacker-controlled and does not pass through the
// sanitiser — nothing else here does either, since a court name is bounded by courtRe and a body by
// SanitizeBody — so a raw Printf would put escape sequences straight into an operator's terminal.
// %q renders them as \x1b. Truncated as well, because the header can be hundreds of kilobytes.
func (s *Server) logClientRefusal(r *http.Request, err error) {
	if s.Log == nil {
		return
	}
	xff := r.Header.Get("X-Forwarded-For")
	if len(xff) > 120 {
		xff = xff[:120] + "…"
	}
	switch {
	case errors.Is(err, ErrNoClientHop):
		s.loggedNoClient.Do(func() {
			s.Log.Printf("refusing requests: every X-Forwarded-For hop is inside "+
				"--trusted-proxy, so no client can be identified. Narrow the range. "+
				"peer=%q header=%q. Logged once.", r.RemoteAddr, xff)
		})
	case errors.Is(err, ErrUntrustedPeer):
		s.loggedUntrustedPeer.Do(func() {
			s.Log.Printf("refusing requests from a peer that is not a trusted proxy: "+
				"peer=%q. If this is your proxy, add it to --trusted-proxy; if not, somebody "+
				"is reaching the origin directly. Logged once.", r.RemoteAddr)
		})
	}
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
		s.logClientRefusal(r, err)
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

	// Now is this server's clock, so a reader can render `created_at` without trusting its own.
	//
	// Every message carries an absolute timestamp and the panel turns it into "5m" by
	// subtracting. Measured through the shipped chatWhen: a client ten minutes FAST reads a
	// message posted one second ago as "10m", and one two hours SLOW reads a two-hour-old
	// message as "just now" — which in a court misrepresents the order in which things were
	// said. Status.Seconds fixed the same arithmetic for one status line; this fixes it for
	// every row, and for anything added later that needs to know when the server thinks it is.
	Now int64 `json:"now"`
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
	switch {
	case errors.Is(err, ErrWithdrawn):
		// The same 410 a POST gets, because the court is in the same state either way.
		// Answering 200 with an empty list would be a lie of a different shape: the panel
		// would render "nobody has said anything here yet" about a court that was withdrawn.
		writeErr(w, http.StatusGone, "this court is no longer served")
		return
	case err != nil:
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
	writeJSON(w, http.StatusOK, getReply{Messages: msgs, Next: next, You: you, Now: s.Store.Now().Unix()})
}

// Which field a refusal is about, so the sentence can name it correctly.
type refusalField int

const (
	fieldMoniker refusalField = iota
	fieldBody
)

// refusalText turns a sanitiser error into something the person who typed it can act on.
//
// It used to be `"moniker: " + err.Error()`, and the sanitiser's messages are written for a
// message BODY, so a rejected name read:
//
//	{"error":"moniker: message is too long"}                  the wrong field, named twice over
//	{"error":"message: message is too long"}                  and a stutter on the other path
//	{"error":"moniker: message contains control characters"}
//
// Three problems in one line. It names the wrong field, it stutters, and it gives no LIMIT — while
// the throttle two cases below says "one message every 2s" and "10 per 1m0s". A caller told only
// "too long" can do nothing but guess, and the moniker's rule is not guessable: it counts LETTERS,
// so marks do not consume the budget and 24 is not a character count.
//
// The sentinels stay as identities and the sentence is composed here, at the boundary, which is
// where presentation belongs — the store's callers want `errors.Is`, not prose. The numbers come
// from the constants, so they cannot drift from what is enforced, and the wording follows
// chatValidate in web/chat.js so the two surfaces do not contradict each other about one rule.
func refusalText(f refusalField, err error) string {
	name, thing := "your message", "characters"
	limit := MaxBodyRunes
	if f == fieldMoniker {
		name, thing = "your name", "letters"
		limit = MaxMonikerRunes
	}
	switch {
	case errors.Is(err, ErrEmpty):
		if f == fieldMoniker {
			return "pick a name first"
		}
		return "type something"
	case errors.Is(err, ErrTooLong):
		return fmt.Sprintf("%s is too long (%d %s maximum)", name, limit, thing)
	case errors.Is(err, ErrOversize):
		return fmt.Sprintf("%s is far too long to process (%d bytes maximum)", name, MaxInputBytes)
	case errors.Is(err, ErrControl):
		return name + " contains characters that cannot be displayed"
	case errors.Is(err, ErrJoiners):
		return name + " contains too many invisible joining characters"
	case errors.Is(err, ErrMarks):
		return name + " stacks too many accents on one character"
	}
	// An unrecognised sanitiser error still has to say which field, and must not stutter.
	return name + ": " + err.Error()
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
	// Twice MaxInputBytes, because the JSON around the two fields costs something and the cap has
	// to bound MEMORY before Decode reads any of it. The sanitiser's own limit is per field and is
	// checked after.
	const requestCap = MaxInputBytes * 2
	r.Body = http.MaxBytesReader(w, r.Body, requestCap)
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(&in); err != nil {
		// TOO BIG IS NOT MALFORMED, and both used to report the second. Measured: a 100 kB body of
		// perfectly valid JSON came back 400 with "expected {"moniker":…,"body":…}", which sends a
		// client to their serialiser when the fix is to send less. A 5 kB body — over the
		// sanitiser's per-field limit but under this cap — already said "far too long to process",
		// so the same condition was reported two different ways depending on which check caught it.
		//
		// 413 rather than 400, because a client can act on the difference, and the message names
		// the limit that is actually theirs to work with rather than this internal cap.
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			writeErr(w, http.StatusRequestEntityTooLarge, fmt.Sprintf(
				"the request is too large; a message may be up to %d bytes", MaxInputBytes))
			return
		}
		writeErr(w, http.StatusBadRequest, "expected {\"moniker\":…,\"body\":…}")
		return
	}
	// Anything after the first JSON value is refused. Decode stops at the end of one
	// value and ignores the rest, so `{"moniker":"a","body":"b"} <anything at all>` was
	// accepted — measured, not theorised. On its own that is only laxness; the reason to
	// close it is that it lets two readers of the same request disagree. A proxy, WAF or
	// audit log that parses the whole body sees content the server never stored, and
	// "what was actually posted" stops having one answer.
	//
	// Unknown FIELDS are still allowed, deliberately: rejecting those would make every
	// future client that sends a new key a 400 against an older server.
	if dec.More() {
		writeErr(w, http.StatusBadRequest, "unexpected content after the JSON object")
		return
	}
	moniker, err := SanitizeMoniker(in.Moniker)
	if err != nil {
		writeErr(w, http.StatusBadRequest, refusalText(fieldMoniker, err))
		return
	}
	body, err := SanitizeBody(in.Body)
	if err != nil {
		writeErr(w, http.StatusBadRequest, refusalText(fieldBody, err))
		return
	}

	// THE HEADER IS ONLY BELIEVED FROM A TRUSTED PROXY, and it used not to be checked at all.
	//
	// CountryHeader's own description calls it "a trusted proxy header", and nothing established
	// that it came from one: r.Header.Get was read on every request. In proxy mode that was
	// harmless by accident — an untrusted peer is already refused a few lines above, at s.client
	// — but with --country-header set and --behind-proxy off, every client chose the flag shown
	// beside their own name.
	//
	// The flag is decoration and §8 says nothing may be built on it, so this is not a hole in a
	// boundary. It is still worth closing: a flag is a credibility affordance to a human reader,
	// and §6 measured what one of those is worth to a scammer — gemma3:4b rates the same lure
	// from "kourt-moderator" as legitimate and from "dave" as a scam. A flag an impersonator
	// picks is that same discount, aimed at people rather than at the model. A wrong decoration
	// somebody chose is worse than no decoration.
	//
	// Ignored rather than refused at startup, unlike the IP policy's own unsafe combination:
	// flags going quiet is a smaller change to impose on a running deployment than not starting,
	// and cmd/kourtchat warns about the configuration where it now has no effect.
	country := ""
	if s.CountryHeader != "" && s.Policy.TrustsPeer(r.RemoteAddr) {
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
	case errors.Is(err, ErrThrottled):
		// Ten seconds is short for the per-minute windows and long for the 2s
		// interval. Being early costs one more refused attempt, which is the
		// harmless direction, and every throttle window here is under a minute.
		w.Header().Set("Retry-After", "10")
		writeErr(w, http.StatusTooManyRequests, err.Error())
	case errors.Is(err, ErrDuplicate):
		// SEPARATE FROM THE THROTTLE, because the same header was wrong by 60x.
		// A duplicate is remembered for DupWindow — ten minutes — so a client
		// honouring `Retry-After: 10` retries in ten seconds and is refused
		// again, and again, for the rest of the window. Derived from the
		// constant so the two cannot drift apart.
		w.Header().Set("Retry-After", strconv.Itoa(int(DupWindow.Seconds())))
		writeErr(w, http.StatusTooManyRequests, err.Error())
	case errors.Is(err, ErrWithdrawn):
		writeErr(w, http.StatusGone, "this court is no longer served")
	default:
		if s.Log != nil {
			s.Log.Printf("post %s/%s: %v", chain, court, err)
		}
		writeErr(w, http.StatusServiceUnavailable, "cannot accept messages right now")
	}
}
