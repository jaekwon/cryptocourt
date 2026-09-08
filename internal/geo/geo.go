// Package geo answers "which country is this address in", for the little flag
// beside a moniker.
//
// WHAT THE FLAG IS WORTH, stated up front because the rest of this package is only
// justified by it being small: it is decoration. Any VPN defeats it, mobile
// carriers route through the wrong country routinely, and it attaches a coarse
// location to a name nobody owns. It exists so a reader has some sense of who is in
// the room, and nothing may be built on top of it.
//
// Three implementations, in the order a deployment should reach for them:
//
//	Null    no flags at all, and everything else works. The honest default.
//	Header  the country a trusted CDN already computed (CF-IPCountry and friends).
//	        Costs nothing and needs no data file. NOT a type in this package, which is
//	        worth saying because this list used to imply it was: the header is read by
//	        internal/chat's Server, the only place that holds the request — and so the
//	        only place that can check the peer is a trusted proxy before believing a
//	        header the client could have written itself.
//	Table   a local country file, read from either a MaxMind GeoLite2-Country
//	        export (LoadMaxMind) or a first/last-address range file such as
//	        DB-IP's free IP-to-Country Lite (LoadRanges). The second needs no
//	        account, which is why the flags were never once switched on until it
//	        existed.
//
// What is deliberately absent is a call to a third-party geolocation API. That
// would ship every visitor's address to somebody else's service, forever, for a
// decoration — and this package exists inside a design whose whole argument about
// addresses is that they are not disclosed.
package geo

import (
	"bytes"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"os"
	"regexp"
	"sort"
	"strings"
)

// Lookup answers the country question. Two letters, ISO-3166-1 alpha-2, or "" for
// "no idea" — which callers must render as no flag rather than as a guess.
type Lookup interface {
	Country(netip.Addr) string
}

// Null knows nothing, which is a perfectly good answer.
type Null struct{}

func (Null) Country(netip.Addr) string { return "" }

var ccRe = regexp.MustCompile(`^[A-Z]{2}$`)

// Table is a sorted table of address SPANS, searched by bisection.
//
// SPANS RATHER THAN PREFIXES, because the two formats worth reading disagree
// about which they are: MaxMind publishes CIDR blocks, and DB-IP publishes
// first/last pairs that are usually not expressible as one prefix. A prefix
// converts to a span exactly and a span does not convert back, so the span is
// the shape both loaders can meet in — the alternative was splitting every
// DB-IP range into covering prefixes, which turns 717,000 rows into millions.
//
// STORED COMPACTLY, AND THAT IS NOT PREMATURE. A real country file is ~717,000
// rows. Held as two netip.Addr and a string per row that is 40MB resident, on a
// box with 1.1GB free and a chain node already using most of it — for a
// decoration. As a uint32 pair for v4, a 16-byte pair for v6 and a uint16 index
// into a table of 251 country codes, the same data is ~17MB.
type Table struct {
	v4 []span4
	v6 []span6

	// ccs is the interned country codes; a span holds an index into it. Small
	// enough (251 in the real file) that a uint16 is never in danger.
	ccs []string
	idx map[string]uint16 // load time only, so a code is stored once
}

type span4 struct {
	lo, hi uint32
	cc     uint16
}

type span6 struct {
	lo, hi [16]byte
	cc     uint16
}

func (t *Table) Country(a netip.Addr) string {
	a = a.Unmap()
	if a.Is4() {
		v := be32(a.As4())
		// The last span starting at or below the address is the only candidate,
		// because neither format's rows overlap. A file whose rows DID overlap
		// would resolve to the later-starting one, which is a coherent answer to
		// an incoherent file.
		i := sort.Search(len(t.v4), func(i int) bool { return t.v4[i].lo > v })
		if i == 0 {
			return ""
		}
		if e := t.v4[i-1]; v <= e.hi {
			return t.ccs[e.cc]
		}
		return ""
	}
	b := a.As16()
	i := sort.Search(len(t.v6), func(i int) bool { return bytes.Compare(t.v6[i].lo[:], b[:]) > 0 })
	if i == 0 {
		return ""
	}
	if e := t.v6[i-1]; bytes.Compare(b[:], e.hi[:]) <= 0 {
		return t.ccs[e.cc]
	}
	return ""
}

// Len reports how many spans were loaded, so a caller can log it and notice a
// file that parsed to almost nothing.
func (t *Table) Len() int { return len(t.v4) + len(t.v6) }

// Countries reports how many distinct country codes the table holds. A file that
// loaded a million rows and three countries parsed wrong in a way Len cannot see.
func (t *Table) Countries() int { return len(t.ccs) }

// intern maps a country code to its index, adding it if new.
func (t *Table) intern(cc string) (uint16, bool) {
	if t.idx == nil {
		t.idx = map[string]uint16{}
	}
	if i, ok := t.idx[cc]; ok {
		return i, true
	}
	if len(t.ccs) >= 1<<16 {
		return 0, false // unreachable with ISO codes; not a silent wrap
	}
	i := uint16(len(t.ccs))
	t.ccs = append(t.ccs, cc)
	t.idx[cc] = i
	return i, true
}

// add files one span, whichever family it belongs to. lo and hi must be the same
// family and in order; callers that cannot promise that are rejected here.
func (t *Table) add(lo, hi netip.Addr, cc string) bool {
	lo, hi = lo.Unmap(), hi.Unmap()
	if lo.Is4() != hi.Is4() || hi.Less(lo) {
		return false
	}
	i, ok := t.intern(cc)
	if !ok {
		return false
	}
	if lo.Is4() {
		t.v4 = append(t.v4, span4{lo: be32(lo.As4()), hi: be32(hi.As4()), cc: i})
	} else {
		t.v6 = append(t.v6, span6{lo: lo.As16(), hi: hi.As16(), cc: i})
	}
	return true
}

// sortSpans puts both families in ascending order of start, which is what
// Country's bisection requires. Called once per load, never per lookup.
func (t *Table) sortSpans() {
	sort.Slice(t.v4, func(i, j int) bool { return t.v4[i].lo < t.v4[j].lo })
	sort.Slice(t.v6, func(i, j int) bool { return bytes.Compare(t.v6[i].lo[:], t.v6[j].lo[:]) < 0 })
	t.idx = nil // the interning map is load-time scaffolding; do not keep it resident
}

func be32(b [4]byte) uint32 {
	return uint32(b[0])<<24 | uint32(b[1])<<16 | uint32(b[2])<<8 | uint32(b[3])
}

// lastOf is the highest address a prefix contains — the other end of the span a
// CIDR block describes.
//
// The shifts look like they need a guard for a full-width count and do not: Go
// defines an unsigned shift at or past the operand's width as zero, so a /32
// gives a host mask of 0 and a span of one address.
func lastOf(p netip.Prefix) netip.Addr {
	p = p.Masked()
	if p.Addr().Is4() {
		return netip.AddrFrom4(u32be(be32(p.Addr().As4()) | (^uint32(0) >> p.Bits())))
	}
	b := p.Addr().As16()
	for i := range b {
		switch n := p.Bits() - i*8; {
		case n >= 8: // wholly inside the prefix
		case n <= 0:
			b[i] = 0xFF
		default:
			b[i] |= 0xFF >> n
		}
	}
	return netip.AddrFrom16(b)
}

func u32be(v uint32) [4]byte {
	return [4]byte{byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v)}
}

// LoadMaxMind reads a GeoLite2-Country CSV export.
//
// The format is TWO files that must be joined: the blocks file carries a network
// and a geoname_id, and only the locations file knows that geoname_id 2921044 is
// "DE". A loader that reads the blocks alone — which is the obvious mistake, since
// that is the file with the addresses in it — produces a table with no country
// codes in it.
//
// The data itself is not committed and never should be: it needs a MaxMind account,
// it is licence-restricted, and it goes stale. The operator supplies the path.
func LoadMaxMind(locationsPath string, blockPaths ...string) (*Table, error) {
	if len(blockPaths) == 0 {
		return nil, errors.New("geo: no block files given")
	}
	locs, err := loadLocations(locationsPath)
	if err != nil {
		return nil, err
	}
	t := &Table{}
	for _, p := range blockPaths {
		if err := t.loadBlocks(p, locs); err != nil {
			return nil, err
		}
	}
	t.sortSpans()
	if t.Len() == 0 {
		// Fail loudly. A geo table that silently loaded nothing looks exactly like
		// a world with no countries in it.
		return nil, errors.New("geo: the files parsed to zero prefixes")
	}
	return t, nil
}

// LoadRanges reads a first-address/last-address country file: three columns,
// `start,end,CC`, one row per span, no header. DB-IP's free IP-to-Country Lite
// export is this shape and is what this was written for.
//
// WHY A SECOND FORMAT AT ALL, when LoadMaxMind already worked: the MaxMind
// export needs an account and a licence key before anybody can download a byte
// of it, so the feature it feeds had been built, tested, and never once switched
// on — no file on the box, every country empty, and not a single flag rendered
// anywhere on the site since the day it was written. A file that can simply be
// fetched is the difference between a feature and a plan.
//
// THE DATA IS STILL NOT COMMITTED. It is 4.5MB compressed, it is licensed
// (CC-BY, so the attribution goes on the page that shows it), and a country file
// is stale the month after it is published. The operator supplies the path and
// the deploy fetches it; this only reads it.
//
// ZZ IS NOT A COUNTRY. The export tiles the whole address space and marks what
// it does not know as ZZ, which is a third of the rows. Storing them would turn
// "no idea" into a two-letter code that renders as a flag for a country that
// does not exist, so they are dropped here and the lookup's own "not found"
// answers for them.
func LoadRanges(path string) (*Table, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("geo: ranges: %w", err)
	}
	defer f.Close()

	r := csv.NewReader(f)
	r.FieldsPerRecord = -1
	r.ReuseRecord = true // 717k rows; one record buffer rather than 717k
	t := &Table{}
	for {
		rec, err := r.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		if len(rec) < 3 {
			continue
		}
		// NO HEADER IN THIS FORMAT, but a file that has picked one up on its way
		// through a spreadsheet must not fail — the row simply does not parse as
		// two addresses, which is the same treatment any malformed row gets.
		lo, err1 := netip.ParseAddr(strings.TrimSpace(strings.Trim(rec[0], "\ufeff")))
		hi, err2 := netip.ParseAddr(strings.TrimSpace(rec[1]))
		if err1 != nil || err2 != nil {
			continue
		}
		cc := strings.ToUpper(strings.TrimSpace(rec[2]))
		if !ccRe.MatchString(cc) || cc == "ZZ" {
			continue
		}
		t.add(lo, hi, cc)
	}
	t.sortSpans()
	if t.Len() == 0 {
		return nil, errors.New("geo: the file parsed to zero spans")
	}
	return t, nil
}

func loadLocations(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("geo: locations: %w", err)
	}
	defer f.Close()

	r := csv.NewReader(f)
	r.FieldsPerRecord = -1
	head, err := r.Read()
	if err != nil {
		return nil, fmt.Errorf("geo: locations header: %w", err)
	}
	idIdx, ccIdx := indexOf(head, "geoname_id"), indexOf(head, "country_iso_code")
	if idIdx < 0 || ccIdx < 0 {
		return nil, fmt.Errorf("geo: locations needs geoname_id and country_iso_code, got %v", head)
	}
	out := map[string]string{}
	for {
		rec, err := r.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		if idIdx >= len(rec) || ccIdx >= len(rec) {
			continue
		}
		cc := strings.ToUpper(strings.TrimSpace(rec[ccIdx]))
		if ccRe.MatchString(cc) {
			out[rec[idIdx]] = cc
		}
	}
	return out, nil
}

func (t *Table) loadBlocks(path string, locs map[string]string) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("geo: blocks: %w", err)
	}
	defer f.Close()

	r := csv.NewReader(f)
	r.FieldsPerRecord = -1
	head, err := r.Read()
	if err != nil {
		return fmt.Errorf("geo: blocks header: %w", err)
	}
	netIdx := indexOf(head, "network")
	idIdx := indexOf(head, "geoname_id")
	regIdx := indexOf(head, "registered_country_geoname_id")
	anonIdx := indexOf(head, "is_anonymous_proxy")
	if netIdx < 0 {
		return fmt.Errorf("geo: blocks needs a network column, got %v", head)
	}
	for {
		rec, err := r.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		if netIdx >= len(rec) {
			continue
		}
		pre, err := netip.ParsePrefix(strings.TrimSpace(rec[netIdx]))
		if err != nil {
			continue // a malformed row is not worth failing a 400k-row file over
		}
		// An address MaxMind marks as an anonymous proxy gets no flag rather than a
		// wrong one. The flag claims to say something about a person; a VPN exit
		// says something about a datacentre.
		if anonIdx >= 0 && anonIdx < len(rec) && rec[anonIdx] == "1" {
			continue
		}
		cc := ""
		if idIdx >= 0 && idIdx < len(rec) {
			cc = locs[rec[idIdx]]
		}
		if cc == "" && regIdx >= 0 && regIdx < len(rec) {
			// geoname_id is empty for a surprising number of blocks; the registered
			// country is the documented fallback.
			cc = locs[rec[regIdx]]
		}
		if cc == "" {
			continue
		}
		pre = pre.Masked()
		t.add(pre.Addr(), lastOf(pre), cc)
	}
	return nil
}

func indexOf(row []string, name string) int {
	for i, c := range row {
		if strings.TrimSpace(strings.Trim(c, "\ufeff")) == name {
			return i
		}
	}
	return -1
}
