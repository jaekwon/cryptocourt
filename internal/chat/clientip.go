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
	for i := len(parts) - 1; i >= 0; i-- {
		a, err := netip.ParseAddr(strings.TrimSpace(parts[i]))
		if err != nil {
			continue // a malformed hop is not evidence of anything
		}
		a = a.Unmap()
		if !p.trusts(a) {
			return a, nil
		}
	}
	// Every hop was a proxy we trust, so the peer itself is the closest thing to
	// a client we have.
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
func Prefix(a netip.Addr) netip.Prefix {
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
// address in seconds. That is why the key is required to live outside the data
// directory.
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
