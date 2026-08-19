package chat

import (
	"errors"
	"net/netip"
	"testing"
)

func prefixes(t *testing.T, s string) []netip.Prefix {
	t.Helper()
	p, err := MustParsePrefixes(s)
	if err != nil {
		t.Fatalf("fixture: %v", err)
	}
	return p
}

// The two ways to get this wrong are opposites, so both directions are asserted
// against the same header. A policy that always returned the peer would pass
// half this table; one that always trusted the header would pass the other half.
func TestClientIP(t *testing.T) {
	trusted := prefixes(t, "10.0.0.0/8,192.168.0.0/16")

	cases := []struct {
		name        string
		behindProxy bool
		remote, xff string
		want        string
		err         error
	}{
		{
			// The default. A direct listener must not be spoofable by anyone who
			// simply sends the header.
			name:   "direct listener ignores a forged header",
			remote: "203.0.113.9:5555", xff: "1.2.3.4",
			want: "203.0.113.9",
		},
		{
			name:        "proxy mode takes the hop before the proxy",
			behindProxy: true, remote: "10.0.0.7:443",
			xff:  "203.0.113.9",
			want: "203.0.113.9",
		},
		{
			// The attack the right-to-left walk exists for: the client prepends
			// whatever it likes, and everything left of the first untrusted hop
			// is attacker-authored.
			name:        "a forged prefix cannot displace the real hop",
			behindProxy: true, remote: "10.0.0.7:443",
			xff:  "9.9.9.9, 203.0.113.9",
			want: "203.0.113.9",
		},
		{
			name:        "several trusted proxies are walked through",
			behindProxy: true, remote: "10.0.0.7:443",
			xff:  "203.0.113.9, 10.0.0.3, 192.168.1.5",
			want: "203.0.113.9",
		},
		{
			// Bypassing the proxy must not be a way to be treated as ordinary
			// traffic, or the header rules can simply be sidestepped.
			name:        "a peer that is not the proxy is refused",
			behindProxy: true, remote: "203.0.113.9:5555", xff: "1.2.3.4",
			err: ErrUntrustedPeer,
		},
		{
			name:        "all hops trusted falls back to the peer",
			behindProxy: true, remote: "10.0.0.7:443", xff: "10.0.0.3",
			want: "10.0.0.7",
		},
		{
			name:        "no header at all falls back to the peer",
			behindProxy: true, remote: "10.0.0.7:443", xff: "",
			want: "10.0.0.7",
		},
		{
			name:        "a malformed hop is skipped, not believed",
			behindProxy: true, remote: "10.0.0.7:443",
			xff:  "not-an-ip, 203.0.113.9",
			want: "203.0.113.9",
		},
		{
			name: "ipv6 peer", remote: "[2001:db8::1]:443",
			want: "2001:db8::1",
		},
		{
			// An IPv4-mapped v6 address and the v4 address are the same client
			// and must produce the same key.
			name: "ipv4-mapped is unmapped", remote: "[::ffff:203.0.113.9]:443",
			want: "203.0.113.9",
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := IPPolicy{BehindProxy: c.behindProxy, Trusted: trusted}
			got, err := p.ClientIP(c.remote, c.xff)
			if c.err != nil {
				if !errors.Is(err, c.err) {
					t.Fatalf("want %v, got %v (%v)", c.err, err, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got.String() != c.want {
				t.Fatalf("want %s, got %s", c.want, got)
			}
		})
	}
}

// The configuration that cannot be made safe must not start. Paired with the two
// that can, so a Validate that always failed would not pass.
func TestPolicyValidate(t *testing.T) {
	if err := (IPPolicy{BehindProxy: true}).Validate(); !errors.Is(err, ErrNoTrustedProxy) {
		t.Fatalf("proxy mode with no trusted CIDR must refuse to start, got %v", err)
	}
	if err := (IPPolicy{}).Validate(); err != nil {
		t.Fatalf("the direct-listen default must be valid: %v", err)
	}
	if err := (IPPolicy{BehindProxy: true, Trusted: prefixes(t, "10.0.0.0/8")}).Validate(); err != nil {
		t.Fatalf("a configured proxy must be valid: %v", err)
	}
}

func TestPrefix(t *testing.T) {
	// IPv4: the address itself is the unit.
	if got := Prefix(netip.MustParseAddr("203.0.113.9")).String(); got != "203.0.113.9/32" {
		t.Fatalf("ipv4 unit: %s", got)
	}
	// IPv6: everything in one /64 is one unit, because the host half is free to
	// change. Two addresses in the same /64 must collapse; a different /64 must
	// not — the pairing is the point.
	a := Prefix(netip.MustParseAddr("2001:db8:1:2::1"))
	b := Prefix(netip.MustParseAddr("2001:db8:1:2:ffff:ffff:ffff:ffff"))
	c := Prefix(netip.MustParseAddr("2001:db8:1:3::1"))
	if a != b {
		t.Fatalf("same /64 must be one unit: %s vs %s", a, b)
	}
	if a == c {
		t.Fatal("a different /64 must be a different unit")
	}
}

func TestHash(t *testing.T) {
	key := make([]byte, 32)
	for i := range key {
		key[i] = byte(i)
	}
	h, err := NewHasher(key)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := NewHasher([]byte("short")); err == nil {
		t.Fatal("a short secret must be refused")
	}

	v4 := netip.MustParseAddr("203.0.113.9")
	other := netip.MustParseAddr("203.0.113.10")
	if h.Hash(v4) == h.Hash(other) {
		t.Fatal("different addresses must not share a key")
	}
	if h.Hash(v4) != h.Hash(v4) {
		t.Fatal("hashing must be stable")
	}
	// Same /64, different host half: one identity.
	if h.Hash(netip.MustParseAddr("2001:db8::1")) != h.Hash(netip.MustParseAddr("2001:db8::2")) {
		t.Fatal("the host half of an IPv6 address must not change the key")
	}
	// A different key must produce a different table, or rotating the secret
	// would not actually be the amnesty it is documented to be.
	key2 := make([]byte, 32)
	h2, _ := NewHasher(key2)
	if h.Hash(v4) == h2.Hash(v4) {
		t.Fatal("the key must affect the hash")
	}
}

// The public tag rotates daily and per court, so a ground collision expires.
func TestPublicSuffix(t *testing.T) {
	key := make([]byte, 32)
	h, _ := NewHasher(key)
	a := netip.MustParseAddr("203.0.113.9")
	const day = 86400

	if h.PublicSuffix(a, "orem", 0) != h.PublicSuffix(a, "orem", day-1) {
		t.Fatal("the tag must be stable within a day")
	}
	if h.PublicSuffix(a, "orem", 0) == h.PublicSuffix(a, "orem", day) {
		t.Fatal("the tag must change across days")
	}
	if h.PublicSuffix(a, "orem", 0) == h.PublicSuffix(a, "ipsum", 0) {
		t.Fatal("the tag must differ between courts")
	}
	if len(h.PublicSuffix(a, "orem", 0)) != 6 {
		t.Fatalf("want 6 hex, got %q", h.PublicSuffix(a, "orem", 0))
	}
	// It must not be the stored key: showing that in public would hand out the
	// join key for every message a person ever posted.
	if h.PublicSuffix(a, "orem", 0) == h.Hash(a)[:6] {
		t.Fatal("the public tag must not be a prefix of the stored hash")
	}
}

// A NETWORK HASH AND ITS LABEL MUST NOT DISAGREE.
//
// HashNet computes its own prefix; NetPrefix exists so an operator tool can say which
// range a hash covers. If those two ever diverge, `kourtchatctl hash` prints a range
// that is not the range it hashed, and somebody bans the wrong scope — which is the
// bug this pins, because the first version of that command labelled the network hash
// with Prefix (a /32) instead.
func TestNetPrefixIsTheRangeHashNetActuallyHashes(t *testing.T) {
	h, err := NewHasher(make([]byte, 32))
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct{ addr, wantNet, wantHost string }{
		{"203.0.113.7", "203.0.113.0/24", "203.0.113.7/32"},
		{"203.0.113.255", "203.0.113.0/24", "203.0.113.255/32"},
		{"2001:db8:1:2:3:4:5:6", "2001:db8:1::/48", "2001:db8:1:2::/64"},
	} {
		t.Run(c.addr, func(t *testing.T) {
			a := netip.MustParseAddr(c.addr)
			if got := NetPrefix(a).String(); got != c.wantNet {
				t.Fatalf("NetPrefix: want %s, got %s", c.wantNet, got)
			}
			if got := Prefix(a).String(); got != c.wantHost {
				t.Fatalf("Prefix: want %s, got %s", c.wantHost, got)
			}
			// The label and the hash must describe the same range: hashing the
			// network's own base address must give the identical network hash.
			base := NetPrefix(a).Addr()
			if h.HashNet(a) != h.HashNet(base) {
				t.Fatal("HashNet is not constant across the range NetPrefix names")
			}
			// And the two scopes must be different values, or a range ban would be
			// indistinguishable from a single-address one.
			if h.HashNet(a) == h.Hash(a) {
				t.Fatal("the address and network hashes must not collide")
			}
		})
	}
	// Two addresses in one /24 share a network hash; two in different /24s do not.
	same := []string{"203.0.113.7", "203.0.113.200"}
	if h.HashNet(netip.MustParseAddr(same[0])) != h.HashNet(netip.MustParseAddr(same[1])) {
		t.Fatal("addresses in one /24 must share a network hash")
	}
	if h.HashNet(netip.MustParseAddr("203.0.113.7")) ==
		h.HashNet(netip.MustParseAddr("203.0.114.7")) {
		t.Fatal("addresses in different /24s must not share a network hash")
	}
}
