package chat

import (
	"errors"
	"net/netip"
	"testing"
)

// hasherForTest is a fixed key: these fixtures compare hashes to each OTHER, so the
// key only has to be stable within a run.
func hasherForTest(t *testing.T) *Hasher {
	t.Helper()
	key := make([]byte, 32)
	for i := range key {
		key[i] = byte(i)
	}
	h, err := NewHasher(key)
	if err != nil {
		t.Fatal(err)
	}
	return h
}

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

// THE OPERATOR'S HASH MUST EQUAL THE ONE THE SERVER STORED, however the address is spelled.
//
// This is the whole contract of `kourtchatctl hash`: an operator reads an address from somewhere,
// asks for its hash, and bans it. If the two sides disagree the ban is recorded, reported as
// successful, and does nothing — the worst failure this tool has, because the person keeps posting
// and every indicator says they were dealt with.
//
// They disagreed. An IPv4-mapped address — "::ffff:203.0.113.7", which is how a dual-stack access
// log and some proxies spell an IPv4 client — is not Is4(), so Prefix took the /64 branch:
//
//	hash of ::ffff:203.0.113.7    1689b677c286   prefix ::/64
//	hash of 203.0.113.7           3cb5bdc7c74a   prefix 203.0.113.7/32
//
// ClientIP already unmapped, so the server stored the second and the CLI printed the first. Worse,
// the /64 of ANY mapped address is "::/64", so every IPv4 client collapsed onto one hash.
//
// Fixed in Prefix and NetPrefix rather than at the call site, since a caller that forgets gets a
// confident wrong answer rather than an error.
func TestEverySpellingOfOneAddressHashesTheSame(t *testing.T) {
	h := hasherForTest(t)
	for _, c := range []struct {
		label, canonical string
		forms            []string
	}{
		{"IPv4", "203.0.113.7", []string{
			"203.0.113.7", "::ffff:203.0.113.7", "::ffff:cb00:7107",
		}},
		{"IPv6", "2001:db8::1", []string{
			"2001:db8::1", "2001:DB8::1", "2001:db8:0:0:0:0:0:1", "2001:0db8::1",
		}},
	} {
		t.Run(c.label, func(t *testing.T) {
			want, err := netip.ParseAddr(c.canonical)
			if err != nil {
				t.Fatal(err)
			}
			wantHash, wantNet := h.Hash(want), h.HashNet(want)
			for _, f := range c.forms {
				a, err := netip.ParseAddr(f)
				if err != nil {
					t.Fatalf("%q: %v", f, err)
				}
				if got := h.Hash(a); got != wantHash {
					t.Errorf("%-22q hashes to %s, but %q hashes to %s — an operator pasting "+
						"the first form bans nothing", f, got[:12], c.canonical, wantHash[:12])
				}
				if got := h.HashNet(a); got != wantNet {
					t.Errorf("%-22q net-hashes to %s, want %s", f, got[:12], wantNet[:12])
				}
			}
		})
	}
}

// THE PAIRED POSITIVE, and it is not decoration: the bug made every IPv4-mapped address share one
// prefix, so a fixture asserting only "all spellings agree" would pass for a Prefix that collapsed
// the entire internet onto one hash.
//
// The granularities are DIFFERENT by design and the fixture has to respect that, which the first
// version did not: IPv4 is hashed per address (/32) and IPv6 per /64, because a single IPv6 host is
// normally delegated a whole /64 and rotating inside it is free. So two addresses in one /64
// SHARING a hash is correct, and that is asserted below rather than treated as a collision — an
// operator banning an IPv6 "address" is banning its /64, and needs to know it.
func TestDifferentAddressesStillHashDifferently(t *testing.T) {
	h := hasherForTest(t)
	seen := map[string]string{}
	for _, s := range []string{
		// IPv4: distinct addresses, distinct hashes.
		"203.0.113.7", "203.0.113.8", "203.0.114.7", "198.51.100.7",
		"::ffff:203.0.113.9", "::ffff:198.51.100.9",
		// IPv6: one per /64, so distinct hashes.
		"2001:db8::1", "2001:db8:0:1::1", "2001:db8:1::1", "2001:db9::1",
	} {
		a, err := netip.ParseAddr(s)
		if err != nil {
			t.Fatal(err)
		}
		got := h.Hash(a)
		if prev, dup := seen[got]; dup {
			t.Errorf("%q and %q hash to the same value %s", prev, s, got[:12])
		}
		seen[got] = s
	}

	// The deliberate sharing, stated so it cannot be mistaken for the bug above.
	for _, pair := range [][2]string{
		{"2001:db8::1", "2001:db8::2"},
		{"2001:db8::1", "2001:db8::ffff:ffff:ffff:ffff"},
	} {
		a := netip.MustParseAddr(pair[0])
		b := netip.MustParseAddr(pair[1])
		if h.Hash(a) != h.Hash(b) {
			t.Errorf("%q and %q are one /64 and must share a hash: IPv6 is hashed per /64 "+
				"because a host is delegated the whole thing", pair[0], pair[1])
		}
	}
	// IPv4 is NOT collapsed that way — neighbours in a /24 are separate addresses.
	if h.Hash(netip.MustParseAddr("203.0.113.7")) == h.Hash(netip.MustParseAddr("203.0.113.8")) {
		t.Error("IPv4 is hashed per address; two hosts in a /24 must not share a hash, or every " +
			"automated kick would take the neighbours with it")
	}

	// And the prefix labels the operator reads must name the range actually hashed.
	for _, c := range []struct{ in, prefix, net string }{
		{"203.0.113.7", "203.0.113.7/32", "203.0.113.0/24"},
		{"::ffff:203.0.113.7", "203.0.113.7/32", "203.0.113.0/24"},
		{"2001:db8::1", "2001:db8::/64", "2001:db8::/48"},
	} {
		a, err := netip.ParseAddr(c.in)
		if err != nil {
			t.Fatal(err)
		}
		if got := Prefix(a).String(); got != c.prefix {
			t.Errorf("Prefix(%q) = %s, want %s — the label beside a hash is how an operator "+
				"checks the scope before acting", c.in, got, c.prefix)
		}
		if got := NetPrefix(a).String(); got != c.net {
			t.Errorf("NetPrefix(%q) = %s, want %s", c.in, got, c.net)
		}
	}
}

// End to end: what ClientIP derives from a request and what an operator types must meet.
func TestTheHashAnOperatorTypesMatchesTheOneIngestStored(t *testing.T) {
	h := hasherForTest(t)
	pol := IPPolicy{BehindProxy: true, Trusted: prefixes(t, "127.0.0.0/8")}
	for _, c := range []struct{ remote, xff, typed string }{
		{"127.0.0.1:5555", "203.0.113.7", "203.0.113.7"},
		{"127.0.0.1:5555", "::ffff:203.0.113.7", "203.0.113.7"},
		{"127.0.0.1:5555", "203.0.113.7", "::ffff:203.0.113.7"},
		{"127.0.0.1:5555", "2001:db8::1", "2001:DB8::1"},
	} {
		ingested, err := pol.ClientIP(c.remote, c.xff)
		if err != nil {
			t.Fatalf("ClientIP(%q, %q): %v", c.remote, c.xff, err)
		}
		typed, err := netip.ParseAddr(c.typed)
		if err != nil {
			t.Fatal(err)
		}
		if h.Hash(ingested) != h.Hash(typed) {
			t.Errorf("a client seen as %q stores %s, but an operator typing %q gets %s",
				c.xff, h.Hash(ingested)[:12], c.typed, h.Hash(typed)[:12])
		}
	}
}
