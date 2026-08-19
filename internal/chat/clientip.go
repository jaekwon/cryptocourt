package chat

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strings"
)

// Where the client address comes from — the decision every other defence in this
// package rests on, and the one most easily got wrong in both directions.
//
// Get it wrong by trusting RemoteAddr behind a proxy and every visitor shares one
// address: the throttle becomes global and the first kick kicks everybody. Get it
// wrong by trusting X-Forwarded-For unconditionally and the header is
// attacker-controlled: every kick is evaded by sending one, and anyone can get
// anyone else kicked by forging theirs.
//
// So it is explicit configuration with a safe default, and a refusal to start in
// the one combination that cannot be made safe.
type IPPolicy struct {
	// BehindProxy false — the default — means RemoteAddr and nothing else.
	// X-Forwarded-For is not consulted at all, so a direct-listening server
	// cannot be spoofed by sending the header.
	BehindProxy bool

	// Trusted are the peers permitted to speak for someone else.
	Trusted []netip.Prefix
}

var (
	ErrNoTrustedProxy = errors.New("--behind-proxy needs at least one --trusted-proxy CIDR")
	ErrUntrustedPeer  = errors.New("connection did not come from a trusted proxy")

	// ErrNoClientHop is the case the peer fallback used to swallow.
	//
	// Walking right to left, the first hop that is not a trusted proxy is the client. If EVERY hop
	// is one of ours, the client's address was never recorded — and returning the peer then gives
	// every such request one identity, which is the "127.0.0.1 for everybody" failure §3 opens
	// with: the throttle goes global and the first kick kicks the internet.
	//
	// Measured: twenty thousand hops of 127.0.0.1 came back as 127.0.0.1 with no error. The walk
	// itself is cheap — 644µs at that size, so no denial of service — but the ANSWER was wrong.
	//
	// Reached by a trusted range that is too wide rather than by an attacker: a proxy that appends
	// puts the real client rightmost, where it wins at once. List a whole VPC as trusted and the
	// clients arriving from inside it are all "ours", so nobody in the chain is a client.
	//
	// Refused rather than merged, for the same reason the untrusted peer above is refused rather
	// than treated as ordinary traffic. A 403 tells an operator their trusted range is wrong;
	// silently bucketing everyone together tells them nothing until the first kick.
	ErrNoClientHop = errors.New("every X-Forwarded-For hop is a trusted proxy, so no client was recorded")
)

// Validate refuses the configuration that looks safe and is not: proxy mode with
// nothing to check the peer against, which would trust the header from anyone.
func (p IPPolicy) Validate() error {
	if p.BehindProxy && len(p.Trusted) == 0 {
		return ErrNoTrustedProxy
	}
	return nil
}

func (p IPPolicy) trusts(a netip.Addr) bool {
	for _, pre := range p.Trusted {
		if pre.Contains(a) {
			return true
		}
	}
	return false
}

// ClientIP resolves the address to hold responsible for a request.
//
// In proxy mode the header is walked RIGHT TO LEFT and the first hop that is not
// a trusted proxy wins. Right-to-left is the only correct direction: everything
// to the left of the first untrusted hop was written by someone we do not
// control, so the leftmost entry — the one most tutorials use — is precisely the
// attacker-chosen one.
func (p IPPolicy) ClientIP(remoteAddr, xff string) (netip.Addr, error) {
	peer, err := parseHostPort(remoteAddr)
	if err != nil {
		return netip.Addr{}, err
	}
	if !p.BehindProxy {
		return peer, nil
	}
	if !p.trusts(peer) {
		// Someone reached the origin directly, bypassing the proxy. Their header
		// must not be believed, and neither should their traffic be treated as
		// though it arrived the normal way.
		return netip.Addr{}, fmt.Errorf("%w: %s", ErrUntrustedPeer, peer)
	}
	parts := strings.Split(xff, ",")
	usable := false
	for i := len(parts) - 1; i >= 0; i-- {
		a, err := netip.ParseAddr(strings.TrimSpace(parts[i]))
		if err != nil {
			continue // a malformed hop is not evidence of anything
		}
		usable = true
		a = a.Unmap()
		if !p.trusts(a) {
			return a, nil
		}
	}
	if usable {
		// There WAS a chain and every hop in it was ours, so the client was never recorded. See
		// ErrNoClientHop: returning the peer here merged every such request into one identity.
		return netip.Addr{}, fmt.Errorf("%w", ErrNoClientHop)
	}
	// No usable header at all — a request from the proxy itself, a health check, an operator's own
	// curl. The peer IS the client in that case, and this is the branch that must keep working.
	return peer, nil
}

func parseHostPort(remoteAddr string) (netip.Addr, error) {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		host = remoteAddr // some callers pass a bare address
	}
	a, err := netip.ParseAddr(strings.Trim(host, "[]"))
	if err != nil {
		return netip.Addr{}, fmt.Errorf("cannot parse client address %q: %w", remoteAddr, err)
	}
	return a.Unmap(), nil
}

// Prefix reduces an address to the unit a consequence applies to: the whole
// address for IPv4, the /64 for IPv6.
//
// The v6 choice is forced. Residential IPv6 clients get a delegated prefix and
// can pick any of 2^64 host addresses within it at will, so a consequence keyed
// on the full address expires the moment they want it to. /64 is the smallest
// unit that means anything.
//
// It is also the reason automated consequences here are bounded kicks and never
// permanent bans: a /64 can be a household, and a shared IPv4 address can be a
// campus or an entire mobile carrier. See EscalateKick.
// UNMAPPED FIRST, in here rather than at the call sites, because a caller that
// forgets produces a confident wrong answer instead of an error.
//
// An IPv4-mapped address — "::ffff:203.0.113.7", which is how a dual-stack log or
// some proxies spell an IPv4 client — is not Is4(), so it used to take the /64
// branch. Two things went wrong at once, measured:
//
//	hash of ::ffff:203.0.113.7    1689b677c286   prefix ::/64
//	hash of 203.0.113.7           3cb5bdc7c74a   prefix 203.0.113.7/32
//
// The ingest path already called Unmap, so the server stored the second. An
// operator pasting the mapped form from a log into `kourtchatctl hash` got the
// first, banned it, was told the consequence was recorded, and the person kept
// posting. A ban that reports success and does nothing is the worst failure this
// tool has.
//
// And the /64 of any IPv4-mapped address is "::/64" — every one of them collapses
// to a single prefix, so that one hash nominally covered all of IPv4.
//
// Unmapping here makes both impossible from any call site. It is idempotent, so
// the ingest path is unaffected.
func Prefix(a netip.Addr) netip.Prefix {
	a = a.Unmap()
	if a.Is4() {
		return netip.PrefixFrom(a, 32)
	}
	p, _ := a.Prefix(64)
	return p
}

// Hasher turns an address into the opaque key everything else stores.
//
// What this protects against, stated exactly, because the first draft of this
// comment overclaimed: a stray copy of the database file alone. It does NOT
// protect against a host compromise or a whole-data-directory backup, because
// IPv4 is 2^32 — anyone holding both the key and the table recovers every
// address in seconds. That is why the key BELONGS outside the data directory — and
// "belongs" is the honest verb, because nothing here enforces it. The default is
// worse than the case this warns about: with no --secret-file the key is a row in
// the database itself, so one file carries the hashes and the means to reverse them.
// kourtchat now says so at startup rather than leaving it to whoever reads §9, which
// is the only reason this comment can afford to be a recommendation.
type Hasher struct{ key []byte }

func NewHasher(key []byte) (*Hasher, error) {
	if len(key) < 32 {
		return nil, errors.New("ip secret must be at least 32 bytes")
	}
	return &Hasher{key: key}, nil
}

// Hash returns the stored identifier for an address.
func (h *Hasher) Hash(a netip.Addr) string {
	mac := hmac.New(sha256.New, h.key)
	mac.Write([]byte(Prefix(a).String()))
	return hex.EncodeToString(mac.Sum(nil)[:16])
}

// HashNet is the same key for the NETWORK an address sits in: /24 for IPv4, /48
// for IPv6.
//
// It exists because two other decisions collide. Automated consequences are
// capped and permanent bans are manual only, which puts every class-stopping
// action on a human; and hashing the address destroyed the subnet structure that
// human would need to act on a range. Without this an operator facing an attacker
// who rotates a delegated prefix can only ban one address at a time, for ever,
// against someone generating fresh ones for free.
//
// No new privacy is lost: a /24 is LESS identifying than a full address, and §2 of
// CHAT.md already concedes both are recoverable by anyone holding the key.
// NetPrefix is the NETWORK an address sits in for range consequences: /24 for IPv4,
// /48 for IPv6. Exported so that an operator tool can LABEL a network hash with the
// range it covers — the definition used to be inline in HashNet, and the first version
// of `kourtchatctl hash` labelled its network hash with Prefix instead, printing
// "203.0.113.7/32" beside a hash that actually covers 203.0.113.0/24. One definition,
// so a label cannot disagree with the hash it describes.
//
// Distinct from Prefix, which is the SINGLE HOST (/32, or /64 for v6 because the host
// half is free to change).
func NetPrefix(a netip.Addr) netip.Prefix {
	a = a.Unmap() // see Prefix: a mapped address is not Is4() and took the /48 branch
	bits := 48
	if a.Is4() {
		bits = 24
	}
	p, err := a.Prefix(bits)
	if err != nil {
		return netip.Prefix{}
	}
	return p
}

func (h *Hasher) HashNet(a netip.Addr) string {
	p := NetPrefix(a)
	if !p.IsValid() {
		return ""
	}
	mac := hmac.New(sha256.New, h.key)
	mac.Write([]byte("net\x00" + p.String()))
	return hex.EncodeToString(mac.Sum(nil)[:16])
}

// PublicSuffix is the short tag shown beside a moniker so two people using the
// same name are usually distinguishable.
//
// "Usually" is doing real work in that sentence. Six hex is 16.7M buckets, so
// accidental collisions are rare in any plausible room — but posting a message
// and reading your own tag back is a free oracle, and an attacker with a
// delegated IPv6 prefix has effectively unlimited addresses to grind against it.
// The daily, per-court salt is what makes a ground collision expire rather than
// last: it is a nuisance defence, not an identity system, and nothing may be
// built on top of it.
func (h *Hasher) PublicSuffix(a netip.Addr, court string, dayUnix int64) string {
	mac := hmac.New(sha256.New, h.key)
	fmt.Fprintf(mac, "suffix\x00%s\x00%d\x00%s", court, dayUnix/86400, Prefix(a).String())
	return hex.EncodeToString(mac.Sum(nil)[:3])
}

// MustParsePrefixes parses a comma-separated CIDR list for the command line.
func MustParsePrefixes(s string) ([]netip.Prefix, error) {
	var out []netip.Prefix
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		p, err := netip.ParsePrefix(part)
		if err != nil {
			return nil, fmt.Errorf("bad CIDR %q: %w", part, err)
		}
		out = append(out, p)
	}
	return out, nil
}
