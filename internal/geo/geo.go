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
	"bufio"
	"bytes"
	"compress/gzip"
	"encoding/csv"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"os"
	"regexp"
	"sort"
	"strconv"
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

	// cells counts spans that carry a grid cell, so HasCells can answer without
	// walking eight million of them.
	cells int
}

// A CELL COSTS NOTHING HERE, which is worth saying because the comment above is
// about bytes. span4 was 4+4+2 and padded to 12 by alignment; the cell fills the
// padding, so a table that can place a connection within ~550km is the same
// resident size as one that can only name its country. See cell.go for why the
// coordinate itself is not kept.
type span4 struct {
	lo, hi uint32
	cc     uint16
	cell   uint16
}

type span6 struct {
	lo, hi [16]byte
	cc     uint16
	cell   uint16
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
	return t.addCell(lo, hi, cc, 0)
}

// addCell is add with a grid cell attached. Zero means the file had no usable
// coordinate for the row, which every country-only file is by definition — so a
// table loaded from one answers Cell with 0 everywhere and HasCells is false.
func (t *Table) addCell(lo, hi netip.Addr, cc string, cell uint16) bool {
	lo, hi = lo.Unmap(), hi.Unmap()
	if lo.Is4() != hi.Is4() || hi.Less(lo) {
		return false
	}
	i, ok := t.intern(cc)
	if !ok {
		return false
	}
	if cell != 0 {
		t.cells++
	}
	if lo.Is4() {
		t.v4 = append(t.v4, span4{lo: be32(lo.As4()), hi: be32(hi.As4()), cc: i, cell: cell})
	} else {
		t.v6 = append(t.v6, span6{lo: lo.As16(), hi: hi.As16(), cc: i, cell: cell})
	}
	return true
}

// Cell is the coarse grid cell an address falls in, or 0 when this table cannot
// place it — a country-only file, or a row the vendor had no coordinate for.
//
// SAME BISECTION AS Country, deliberately not merged with it. A caller that
// wants both pays for two searches, and that caller is the presence gauge, which
// does one lookup per long poll rather than one per request.
func (t *Table) Cell(a netip.Addr) uint16 {
	a = a.Unmap()
	if a.Is4() {
		v := be32(a.As4())
		i := sort.Search(len(t.v4), func(i int) bool { return t.v4[i].lo > v })
		if i == 0 {
			return 0
		}
		if e := t.v4[i-1]; v <= e.hi {
			return e.cell
		}
		return 0
	}
	b := a.As16()
	i := sort.Search(len(t.v6), func(i int) bool { return bytes.Compare(t.v6[i].lo[:], b[:]) > 0 })
	if i == 0 {
		return 0
	}
	if e := t.v6[i-1]; bytes.Compare(b[:], e.hi[:]) <= 0 {
		return e.cell
	}
	return 0
}

// HasCells reports whether this table can place anything at all. The service
// asks so it can publish cells or fall back to countries, rather than shipping a
// map with nothing on it and no way to tell that apart from an empty room —
// which is the healthy-looks-like-broken trap GeoKnown already exists for.
func (t *Table) HasCells() bool { return t.cells > 0 }

// Cells reports how many spans carry one, for the same reason Countries exists:
// a file that loaded eight million rows and placed none of them parsed wrong in
// a way Len cannot see.
func (t *Table) Cells() int { return t.cells }

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
	return loadRangesFrom(f)
}

func loadRangesFrom(in io.Reader) (*Table, error) {
	r := csv.NewReader(in)
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

// LoadCity reads DB-IP's city-lite CSV: first address, last address, continent,
// country, region, city, latitude, longitude. Same span shape as LoadRanges,
// four more columns.
//
// WHAT IT KEEPS AND WHAT IT THROWS AWAY. The country and a grid cell. The city
// name and the region name are read and dropped on the floor, and the
// coordinate is turned into a cell and dropped too — see cell.go. Nothing in
// this table can answer "which city", because nothing in it knows.
//
// COALESCED AS IT GOES, and this is what makes the file usable at all rather
// than an optimisation. MEASURED: the city file is 7,748,993 v4 spans against
// the country file's 717,000, and at 12 bytes a span that is a hundred megabytes
// on a box the deploy notes has 1.1GB free with a chain node already on it.
// Adjacent spans that resolve to the same country AND the same cell are
// indistinguishable to every question this table can be asked, so they are
// stored once.
//
// ONLY WHEN THEY TOUCH. A gap between two spans is address space the file says
// nothing about, and merging across it would claim a location for addresses the
// vendor did not place. So the merge requires hi+1 == next lo.
//
// THE ROWS MUST ARRIVE IN ORDER for the merge to catch anything, and DB-IP's do.
// If they ever stop, this degrades to storing every row — slower and fatter, not
// wrong — and Len will say so.
func LoadCity(path string) (*Table, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("geo: city: %w", err)
	}
	defer f.Close()
	return loadCityFrom(f)
}

func loadCityFrom(in io.Reader) (*Table, error) {
	r := csv.NewReader(in)
	r.FieldsPerRecord = -1
	r.ReuseRecord = true

	t := &Table{}
	// The run being accumulated: nothing until the first parsable row.
	var haveRun bool
	var runLo, runHi netip.Addr
	var runCC string
	var runCell uint16

	flush := func() {
		if haveRun {
			t.addCell(runLo, runHi, runCC, runCell)
			haveRun = false
		}
	}
	for {
		rec, err := r.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		if len(rec) < 8 {
			continue
		}
		lo, err1 := netip.ParseAddr(strings.TrimSpace(strings.Trim(rec[0], "\ufeff")))
		hi, err2 := netip.ParseAddr(strings.TrimSpace(rec[1]))
		if err1 != nil || err2 != nil {
			continue
		}
		cc := strings.ToUpper(strings.TrimSpace(rec[3]))
		if !ccRe.MatchString(cc) || cc == "ZZ" {
			continue
		}
		// THE LAST TWO FIELDS, NOT FIELDS 7 AND 8. A city name is quoted and may
		// carry a comma — "Washington, D.C." — and csv gives it back as one
		// field, so the coordinate is at the end rather than at a fixed index
		// only when nothing upstream has re-quoted it. Counting from the end is
		// right either way.
		lat, e1 := strconv.ParseFloat(strings.TrimSpace(rec[len(rec)-2]), 64)
		lon, e2 := strconv.ParseFloat(strings.TrimSpace(rec[len(rec)-1]), 64)
		cell := uint16(0)
		if e1 == nil && e2 == nil {
			cell = CellOf(lat, lon)
		}

		if haveRun && runCC == cc && runCell == cell && nextTo(runHi, lo) {
			runHi = hi
			continue
		}
		flush()
		haveRun, runLo, runHi, runCC, runCell = true, lo, hi, cc, cell
	}
	flush()

	t.sortSpans()
	if t.Len() == 0 {
		return nil, errors.New("geo: the city file parsed to zero spans")
	}
	return t, nil
}

// nextTo reports whether b is the very next address after a, which is the only
// case two spans may be merged in. Same family only: the v4 and v6 halves of
// this table are separate and a run must never straddle them.
func nextTo(a, b netip.Addr) bool {
	a, b = a.Unmap(), b.Unmap()
	if a.Is4() != b.Is4() {
		return false
	}
	return a.Next() == b
}

// Load opens a geo file and picks the parser for it, decompressing on the way
// if it is gzipped.
//
// SNIFFED RATHER THAN FLAGGED, because the alternative is an operator flag that
// can disagree with the file on disk — and the failure then is a table that
// parsed to nothing while the flag insisted it was fine. The shape is
// unambiguous: DB-IP's country rows are three fields and its city rows are
// eight, so the first parsable line decides.
//
// GZIPPED IS THE NORMAL CASE FOR THE CITY FILE. It is 82MB compressed and 658MB
// expanded, measured, and expanding it onto a box whose free space the deploy
// notes as 1.1GB is a bad trade for three seconds of load time. So it is kept as
// downloaded and read through a decompressor.
func Load(path string) (*Table, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("geo: %w", err)
	}
	defer f.Close()

	var src io.Reader = bufio.NewReaderSize(f, 1<<20)
	// The gzip magic, checked by peeking rather than by trusting the extension:
	// the file is named by whoever downloaded it.
	br := src.(*bufio.Reader)
	if head, err := br.Peek(2); err == nil && head[0] == 0x1f && head[1] == 0x8b {
		zr, err := gzip.NewReader(br)
		if err != nil {
			return nil, fmt.Errorf("geo: gzip: %w", err)
		}
		defer zr.Close()
		src = bufio.NewReaderSize(zr, 1<<20)
	}

	// The first non-empty line decides the format. Read it, then put it back in
	// front of the stream so the parser sees the whole file.
	sniff := src.(*bufio.Reader)
	first, err := sniff.ReadString('\n')
	if err != nil && err != io.EOF {
		return nil, fmt.Errorf("geo: %w", err)
	}
	city := strings.Count(first, ",") >= 7
	all := io.MultiReader(strings.NewReader(first), sniff)
	if city {
		return loadCityFrom(all)
	}
	return loadRangesFrom(all)
}
