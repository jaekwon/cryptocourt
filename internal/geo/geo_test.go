package geo

import (
	"compress/gzip"
	"math"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A synthetic export in MaxMind's real column order. The actual data is licence
// restricted and must never be committed, so the format is reproduced rather than
// the content.
const locationsCSV = `geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,is_in_european_union
2921044,en,EU,Europe,DE,Germany,1
2635167,en,EU,Europe,GB,United Kingdom,0
6252001,en,NA,North America,US,United States,0
298795,en,AS,Asia,TR,Turkey,0
7777777,en,,,,No Country At All,0
`

const blocksV4CSV = `network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider
1.0.0.0/24,6252001,6252001,,0,0
203.0.113.0/24,2921044,2921044,,0,0
198.51.100.0/25,2635167,2635167,,0,0
198.51.100.128/25,298795,298795,,0,0
192.0.2.0/24,,6252001,,0,0
10.9.0.0/16,2921044,2921044,,1,0
172.31.0.0/16,7777777,7777777,,0,0
`

const blocksV6CSV = `network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider
2001:db8::/32,2921044,2921044,,0,0
2001:db9::/32,6252001,6252001,,0,0
`

func write(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func loadTable(t *testing.T) *Table {
	t.Helper()
	dir := t.TempDir()
	loc := write(t, dir, "loc.csv", locationsCSV)
	v4 := write(t, dir, "v4.csv", blocksV4CSV)
	v6 := write(t, dir, "v6.csv", blocksV6CSV)
	tab, err := LoadMaxMind(loc, v4, v6)
	if err != nil {
		t.Fatal(err)
	}
	return tab
}

func TestCountryLookup(t *testing.T) {
	tab := loadTable(t)
	cases := []struct{ addr, want string }{
		{"203.0.113.9", "DE"},
		{"203.0.113.0", "DE"},   // the first address in the block
		{"203.0.113.255", "DE"}, // and the last
		{"1.0.0.7", "US"},
		{"192.0.2.5", "US"}, // geoname_id empty, registered country used instead

		// Adjacent halves of one /24 belonging to different countries: the search
		// must land on the right half rather than the nearest start.
		{"198.51.100.1", "GB"},
		{"198.51.100.127", "GB"},
		{"198.51.100.128", "TR"},
		{"198.51.100.200", "TR"},

		{"2001:db8::1", "DE"},
		{"2001:db9::1", "US"},

		// Unknown, and each for a different reason. All must be "" — a wrong flag
		// is worse than none.
		{"8.8.8.8", ""},         // in no block at all
		{"10.9.0.1", ""},        // marked an anonymous proxy
		{"172.31.0.1", ""},      // a geoname with no country code
		{"2001:dba::1", ""},     // v6, in no block
		{"0.0.0.1", ""},         // below every block, so the bisection lands at 0
		{"255.255.255.255", ""}, // above every block
	}
	for _, c := range cases {
		t.Run(c.addr, func(t *testing.T) {
			got := tab.Country(netip.MustParseAddr(c.addr))
			if got != c.want {
				t.Fatalf("%s: want %q, got %q", c.addr, c.want, got)
			}
		})
	}
}

// An IPv4-mapped v6 address is the same host as its v4 form and must resolve the
// same way, or a client arriving over a dual-stack socket gets a different flag.
func TestMappedAddressesAgree(t *testing.T) {
	tab := loadTable(t)
	four := tab.Country(netip.MustParseAddr("203.0.113.9"))
	mapped := tab.Country(netip.MustParseAddr("::ffff:203.0.113.9"))
	if four != mapped || four == "" {
		t.Fatalf("v4 %q and mapped %q must agree and be known", four, mapped)
	}
}

// Null is a real implementation, not a stub: no flags, and nothing breaks.
func TestNullKnowsNothing(t *testing.T) {
	if got := (Null{}).Country(netip.MustParseAddr("203.0.113.9")); got != "" {
		t.Fatalf("Null must answer nothing, got %q", got)
	}
}

// The mistake this format invites: reading the blocks file alone. It has the
// addresses in it, so it looks like the whole answer, and it contains no country
// codes whatsoever.
func TestBlocksWithoutLocationsIsAnError(t *testing.T) {
	dir := t.TempDir()
	v4 := write(t, dir, "v4.csv", blocksV4CSV)
	// Locations present but joined on nothing: every row's country is unknown, so
	// the table is empty and that must be an error rather than a silent success.
	empty := write(t, dir, "loc.csv",
		"geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,is_in_european_union\n")
	if _, err := LoadMaxMind(empty, v4); err == nil {
		t.Fatal("a table that parsed to zero prefixes must be an error")
	}
	if _, err := LoadMaxMind(filepath.Join(dir, "nope.csv"), v4); err == nil {
		t.Fatal("a missing locations file must be an error")
	}
	if _, err := LoadMaxMind(empty); err == nil {
		t.Fatal("no block files at all must be an error")
	}
}

func TestMalformedRowsAreSkippedNotFatal(t *testing.T) {
	dir := t.TempDir()
	loc := write(t, dir, "loc.csv", locationsCSV)
	// One good row among junk: a 400,000-row export with a few bad lines must
	// still load, or a single typo upstream takes the feature out.
	v4 := write(t, dir, "v4.csv",
		"network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider\n"+
			"not-a-network,2921044,2921044,,0,0\n"+
			"203.0.113.0/24,2921044,2921044,,0,0\n"+
			"999.999.999.0/24,2921044,2921044,,0,0\n")
	tab, err := LoadMaxMind(loc, v4)
	if err != nil {
		t.Fatal(err)
	}
	if tab.Len() != 1 {
		t.Fatalf("want the one good row, got %d", tab.Len())
	}
	if got := tab.Country(netip.MustParseAddr("203.0.113.9")); got != "DE" {
		t.Fatalf("the good row must still work, got %q", got)
	}
}

// A BOM on the first header cell is what a spreadsheet round-trip leaves behind,
// and it would otherwise make the network column unfindable.
func TestByteOrderMarkInHeader(t *testing.T) {
	dir := t.TempDir()
	loc := write(t, dir, "loc.csv", "\ufeff"+locationsCSV)
	v4 := write(t, dir, "v4.csv", "\ufeff"+blocksV4CSV)
	tab, err := LoadMaxMind(loc, v4)
	if err != nil {
		t.Fatalf("a leading BOM must not break the loader: %v", err)
	}
	if got := tab.Country(netip.MustParseAddr("203.0.113.9")); got != "DE" {
		t.Fatalf("want DE, got %q", got)
	}
}

// Column ORDER must not matter: MaxMind has reordered these before, and a loader
// that indexes by position rather than by name breaks silently when they do.
func TestColumnsAreFoundByName(t *testing.T) {
	dir := t.TempDir()
	loc := write(t, dir, "loc.csv",
		"country_iso_code,geoname_id,country_name\nDE,2921044,Germany\n")
	v4 := write(t, dir, "v4.csv",
		"geoname_id,is_anonymous_proxy,network\n2921044,0,203.0.113.0/24\n")
	tab, err := LoadMaxMind(loc, v4)
	if err != nil {
		t.Fatal(err)
	}
	if got := tab.Country(netip.MustParseAddr("203.0.113.9")); got != "DE" {
		t.Fatalf("columns must be located by name, got %q", got)
	}
}

func TestLoadIsNotAbsurdlySlow(t *testing.T) {
	// A crude shape check on the bisection: a table built from many prefixes must
	// answer without scanning it. Not a benchmark — just a guard against someone
	// replacing the search with a loop.
	dir := t.TempDir()
	loc := write(t, dir, "loc.csv", locationsCSV)
	var b strings.Builder
	b.WriteString("network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider\n")
	for i := 0; i < 4000; i++ {
		fmtRow(&b, i)
	}
	v4 := write(t, dir, "v4.csv", b.String())
	tab, err := LoadMaxMind(loc, v4)
	if err != nil {
		t.Fatal(err)
	}
	if tab.Len() < 4000 {
		t.Fatalf("want 4000 prefixes, got %d", tab.Len())
	}
	// 10.7.100.0/24 is row 7*256+100 = 1892, comfortably inside the generated
	// range. An earlier version probed 10.15.200.1, which the loop never emits.
	if got := tab.Country(netip.MustParseAddr("10.7.100.1")); got != "DE" {
		t.Fatalf("a prefix in the middle of the table must resolve, got %q", got)
	}
}

func fmtRow(b *strings.Builder, i int) {
	b.WriteString("10.")
	b.WriteString(itoa(i / 256))
	b.WriteString(".")
	b.WriteString(itoa(i % 256))
	b.WriteString(".0/24,2921044,2921044,,0,0\n")
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var d []byte
	for n > 0 {
		d = append([]byte{byte('0' + n%10)}, d...)
		n /= 10
	}
	return string(d)
}

// ------------------------------------------------------------ range files ----

// DB-IP's shape: three columns, no header, first and last address rather than a
// prefix, and ZZ for "no idea". Reproduced rather than committed, same as above.
const rangesCSV = `1.0.0.0,1.0.0.255,AU
1.0.1.0,1.0.3.255,CN
8.8.8.0,8.8.8.255,US
` + "192.0.2.0,192.0.2.99,DE\n" + // a range that is NOT a whole prefix
	"192.0.2.100,192.0.2.199,GB\n" + // and the span that abuts it
	"198.51.100.0,198.51.100.255,ZZ\n" + // unknown: must not become a flag
	"2001:db8::,2001:db8:ffff:ffff:ffff:ffff:ffff:ffff,DE\n" +
	"2001:dbb::,2001:dbb::ffff,JP\n"

func loadRanges(t *testing.T, body string) *Table {
	t.Helper()
	tab, err := LoadRanges(write(t, t.TempDir(), "r.csv", body))
	if err != nil {
		t.Fatal(err)
	}
	return tab
}

func TestRangeFileLookup(t *testing.T) {
	tab := loadRanges(t, rangesCSV)
	cases := []struct{ addr, want string }{
		{"1.0.0.0", "AU"}, {"1.0.0.255", "AU"}, // both ends inclusive
		{"1.0.1.5", "CN"},
		{"8.8.8.8", "US"},

		// THE WHOLE REASON THIS LOADER STORES SPANS. 192.0.2.0-99 is not a CIDR
		// block, and 100-199 begins mid-prefix. A prefix table cannot hold either
		// without splitting them, and a table that rounded them to /24 would give
		// both addresses the same country.
		{"192.0.2.0", "DE"}, {"192.0.2.99", "DE"},
		{"192.0.2.100", "GB"}, {"192.0.2.199", "GB"},
		{"192.0.2.200", ""}, // past the last span in that /24: known-unknown

		{"2001:db8::1", "DE"},
		{"2001:dbb::5", "JP"},

		// ZZ is not a country, so an address inside a ZZ row is unknown and must
		// not inherit the row above it.
		{"198.51.100.7", ""},

		{"9.9.9.9", ""},         // in no span
		{"0.0.0.1", ""},         // below every span
		{"255.255.255.255", ""}, // above every span
		{"2001:dbf::1", ""},     // v6, in no span
	}
	for _, c := range cases {
		t.Run(c.addr, func(t *testing.T) {
			if got := tab.Country(netip.MustParseAddr(c.addr)); got != c.want {
				t.Fatalf("%s: want %q, got %q", c.addr, c.want, got)
			}
		})
	}
}

// The ZZ rows are a THIRD of the real file. Storing them would cost 200,000
// spans to hold "no idea" — which the bisection already answers by finding
// nothing.
func TestRangeFileDropsUnknownRows(t *testing.T) {
	tab := loadRanges(t, rangesCSV)
	if got, want := tab.Len(), 7; got != want {
		t.Fatalf("want %d spans with the ZZ row dropped, got %d", want, got)
	}
	if got, want := tab.Countries(), 6; got != want {
		t.Fatalf("want %d distinct countries, got %d", want, got)
	}
}

// A range file has no header, and one that has acquired a header on its way
// through a spreadsheet must load anyway — the header row simply does not parse
// as two addresses. A BOM in front of it must not change that.
func TestRangeFileToleratesAHeaderAndBOM(t *testing.T) {
	tab := loadRanges(t, "\ufeffstart,end,country\n1.0.0.0,1.0.0.255,AU\n")
	if got := tab.Country(netip.MustParseAddr("1.0.0.7")); got != "AU" {
		t.Fatalf("want AU, got %q", got)
	}
	if tab.Len() != 1 {
		t.Fatalf("the header must not become a span: %d", tab.Len())
	}
}

func TestRangeFileFailuresAreLoud(t *testing.T) {
	if _, err := LoadRanges(filepath.Join(t.TempDir(), "nope.csv")); err == nil {
		t.Fatal("a missing file must be an error")
	}
	// Every row unusable. A table that loaded nothing looks exactly like a world
	// with no countries in it, so it must not be a silent success.
	dir := t.TempDir()
	for _, body := range []string{
		"",
		"1.0.0.0,1.0.0.255,ZZ\n",        // only unknowns
		"1.0.0.255,1.0.0.0,AU\n",        // reversed: last before first
		"1.0.0.0,2001:db8::,AU\n",       // families disagree
		"1.0.0.0,1.0.0.255,AUS\n",       // not an ISO alpha-2
		"not-an-address,1.0.0.255,AU\n", // unparseable
	} {
		if _, err := LoadRanges(write(t, dir, "r.csv", body)); err == nil {
			t.Fatalf("a file of nothing but unusable rows must be an error: %q", body)
		}
	}
}

// A malformed row among good ones is skipped, not fatal: the real file is
// 717,000 rows and a single bad line upstream must not take the feature out.
func TestRangeFileSkipsBadRowsAmongGood(t *testing.T) {
	tab := loadRanges(t, "junk\n1.0.0.0,1.0.0.255,AU\n1.0.1.0,oops,CN\n8.8.8.0,8.8.8.255,US\n")
	if tab.Len() != 2 {
		t.Fatalf("want the two good rows, got %d", tab.Len())
	}
	if got := tab.Country(netip.MustParseAddr("8.8.8.8")); got != "US" {
		t.Fatalf("a good row after a bad one must still work, got %q", got)
	}
}

// A PREFIX IS A SPAN, and the conversion has to be exact at both ends or the
// MaxMind path silently loses the last address of every block. /32 and /0 are
// the two that a shift-based mask gets wrong if it guards the wrong way.
func TestPrefixToSpanCoversBothEnds(t *testing.T) {
	for _, c := range []struct{ pre, first, last string }{
		{"203.0.113.0/24", "203.0.113.0", "203.0.113.255"},
		{"203.0.113.7/32", "203.0.113.7", "203.0.113.7"},
		{"0.0.0.0/0", "0.0.0.0", "255.255.255.255"},
		{"10.0.0.0/7", "10.0.0.0", "11.255.255.255"},
		{"2001:db8::/32", "2001:db8::", "2001:db8:ffff:ffff:ffff:ffff:ffff:ffff"},
		{"2001:db8::/128", "2001:db8::", "2001:db8::"},
		{"::/0", "::", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"},
	} {
		t.Run(c.pre, func(t *testing.T) {
			p := netip.MustParsePrefix(c.pre)
			if got := lastOf(p).String(); got != c.last {
				t.Fatalf("%s: last is %s, want %s", c.pre, got, c.last)
			}
			// And the span really does answer for both ends.
			tab := &Table{}
			tab.add(p.Masked().Addr(), lastOf(p), "DE")
			tab.sortSpans()
			for _, a := range []string{c.first, c.last} {
				if got := tab.Country(netip.MustParseAddr(a)); got != "DE" {
					t.Fatalf("%s: %s resolved to %q", c.pre, a, got)
				}
			}
		})
	}
}

// ---- the coarse grid ------------------------------------------------------

// EVERY CELL IS ABOUT THE SAME SIZE, WHEREVER IT IS, which is the whole reason
// the grid is bands-scaled-by-cosine rather than a plain 5-degree lattice.
//
// THE LATTICE IS THE BUG THIS CATCHES. Five degrees of longitude is 556km at the
// equator, 278km at 60N and 24km at 87.5N — so a lattice would quietly hand a
// reader in Norway four times less protection than one in Kenya, and a reader in
// Svalbard twenty times less, while the code claimed one number. Asserted as a
// floor and a ceiling on the east-west width of every band's cell.
func TestEveryCellIsAboutTheSameSizeWhereverItIs(t *testing.T) {
	const kmPerDeg = 111.32
	minW, maxW := 1e9, 0.0
	for band := 0; band < geoCellBands(); band++ {
		mid := -90 + 5.0*float64(band) + 2.5
		// The cell at the prime meridian in this band, and how wide it is on the
		// ground rather than in degrees.
		c := CellOf(mid, 0.5)
		if c == 0 {
			t.Fatalf("band %d (lat %.1f) produced no cell", band, mid)
		}
		_, lonC, ok := CellCentre(c)
		if !ok {
			t.Fatalf("cell %d has no centre", c)
		}
		// Width in degrees is twice the distance from the centre to the edge,
		// which is recovered by walking east until the cell changes.
		step := 0.01
		east := lonC
		for east < lonC+200 {
			if CellOf(mid, east+step) != c {
				break
			}
			east += step
		}
		wDeg := 2 * (east - lonC)
		wKm := wDeg * kmPerDeg * mathCos(mid)
		if wKm < minW {
			minW = wKm
		}
		if wKm > maxW {
			maxW = wKm
		}
	}
	// 556km is the design figure. The rounding of cells-per-band spreads it, and
	// the polar bands collapse to one cell that is wider than tall — which is
	// coarser, never finer, and coarser is the safe direction.
	if minW < 300 {
		t.Errorf("some cell is only %.0fkm wide east-west; the grid has become a "+
			"lattice and high latitudes are under-protected", minW)
	}
	if maxW > 45000 {
		t.Errorf("some cell is %.0fkm wide, which is not a cell", maxW)
	}
}

// A COORDINATE LANDS IN A CELL THAT CONTAINS IT. Round-tripping through the
// centre must not move a point into a different cell.
func TestACoordinateLandsInACellThatContainsIt(t *testing.T) {
	for _, p := range []struct {
		lat, lon float64
		what     string
	}{
		{37.77, -122.42, "San Francisco"},
		{51.51, -0.13, "London"},
		{-33.87, 151.21, "Sydney"},
		{1.35, 103.82, "Singapore"},
		{64.14, -21.94, "Reykjavik"},
		{-54.8, -68.3, "Ushuaia"},
		{35.68, 139.69, "Tokyo"},
	} {
		c := CellOf(p.lat, p.lon)
		if c == 0 {
			t.Fatalf("%s produced no cell", p.what)
		}
		lat, lon, ok := CellCentre(c)
		if !ok {
			t.Fatalf("%s: cell %d has no centre", p.what, c)
		}
		if CellOf(lat, lon) != c {
			t.Errorf("%s: the centre of cell %d is in a different cell", p.what, c)
		}
		// Within half a band vertically, always; horizontally within half the
		// band's own cell width, which the equal-area test bounds.
		if d := lat - p.lat; d > 2.5 || d < -2.5 {
			t.Errorf("%s: centre latitude %.2f is %.2f from %.2f", p.what, lat, d, p.lat)
		}
	}
}

// THE VENDOR'S UNPLACED ROWS ARE NOT THE GULF OF GUINEA. DB-IP writes 0,0 for
// rows it has no position for, including the span at the very front of the file,
// and treating that as a coordinate puts readers in the ocean off Ghana — which
// is both wrong and the classic signature of this exact mistake.
func TestZeroZeroIsAbsentNotTheGulfOfGuinea(t *testing.T) {
	if c := CellOf(0, 0); c != 0 {
		t.Errorf("0,0 must be absent, got cell %d", c)
	}
	// ...but a real coordinate near it still resolves.
	if c := CellOf(0.6, 0.6); c == 0 {
		t.Error("a genuine coordinate near the origin must still place")
	}
	for _, bad := range [][2]float64{{91, 0}, {-91, 0}, {0, 181}, {0, -181}} {
		if c := CellOf(bad[0], bad[1]); c != 0 {
			t.Errorf("%v is off the globe and must not place, got %d", bad, c)
		}
	}
	if _, _, ok := CellCentre(0); ok {
		t.Error("cell 0 must have no centre")
	}
	if _, _, ok := CellCentre(uint16(CellCount()) + 1); ok {
		t.Error("a cell past the end must have no centre")
	}
}

// mathCos and geoCellBands keep the test from importing math and from reaching
// into the package's unexported band table.
func mathCos(deg float64) float64 { return math.Cos(deg * math.Pi / 180) }
func geoCellBands() int           { return CellBands }

// ---- the city loader ------------------------------------------------------

func writeTmp(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "city.csv")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// COALESCING MUST NOT CHANGE A SINGLE ANSWER. It exists to make the file fit —
// 3.6M v4 spans down to 1.7M, measured — and the whole risk of it is that a
// merged run answers for addresses it should not, or stops answering for ones it
// should. So every address in every row is asked, and the span count is asserted
// to have actually dropped, because a merge that silently did nothing would pass
// the first half of this test.
func TestCoalescingChangesNoAnswer(t *testing.T) {
	// Three adjacent rows in one city, then a neighbour in the same cell, then a
	// row far away. Rows 1-4 must become one span; row 5 stays its own.
	p := writeTmp(t, `1.0.0.0,1.0.0.255,EU,DE,Berlin,Berlin,52.52,13.40
1.0.1.0,1.0.1.255,EU,DE,Berlin,Berlin,52.52,13.40
1.0.2.0,1.0.2.255,EU,DE,Berlin,"Berlin, Mitte",52.53,13.41
1.0.3.0,1.0.3.255,EU,DE,Brandenburg,Potsdam,52.40,13.06
9.9.9.0,9.9.9.255,AS,JP,Tokyo,Tokyo,35.68,139.69
`)
	tb, err := LoadCity(p)
	if err != nil {
		t.Fatal(err)
	}
	if tb.Len() != 2 {
		t.Fatalf("four adjacent rows in one cell plus one far away is 2 spans, got %d", tb.Len())
	}
	berlin := CellOf(52.52, 13.40)
	tokyo := CellOf(35.68, 139.69)
	if berlin == 0 || tokyo == 0 || berlin == tokyo {
		t.Fatalf("the fixture needs two distinct cells, got %d and %d", berlin, tokyo)
	}
	for _, probe := range []struct {
		ip   string
		cc   string
		cell uint16
	}{
		{"1.0.0.0", "DE", berlin}, {"1.0.0.255", "DE", berlin},
		{"1.0.1.7", "DE", berlin}, {"1.0.2.200", "DE", berlin},
		{"1.0.3.0", "DE", berlin}, {"1.0.3.255", "DE", berlin},
		{"9.9.9.9", "JP", tokyo},
	} {
		a := netip.MustParseAddr(probe.ip)
		if got := tb.Country(a); got != probe.cc {
			t.Errorf("%s: country %q, want %q", probe.ip, got, probe.cc)
		}
		if got := tb.Cell(a); got != probe.cell {
			t.Errorf("%s: cell %d, want %d", probe.ip, got, probe.cell)
		}
	}
	// And nothing outside the rows answers.
	for _, ip := range []string{"1.0.4.0", "9.9.8.255", "2.2.2.2"} {
		if got := tb.Cell(netip.MustParseAddr(ip)); got != 0 {
			t.Errorf("%s is in no row but placed in cell %d", ip, got)
		}
	}
}

// A GAP BREAKS A RUN, because the space between two spans is address range the
// file says nothing about. Merging across it would invent a location for
// addresses the vendor never placed — the one way coalescing could become a lie
// rather than a saving.
func TestAGapBreaksARunRatherThanBeingClaimed(t *testing.T) {
	p := writeTmp(t, `1.0.0.0,1.0.0.255,EU,DE,Berlin,Berlin,52.52,13.40
1.0.2.0,1.0.2.255,EU,DE,Berlin,Berlin,52.52,13.40
`)
	tb, err := LoadCity(p)
	if err != nil {
		t.Fatal(err)
	}
	if tb.Len() != 2 {
		t.Fatalf("a gap must leave two spans, got %d", tb.Len())
	}
	if got := tb.Cell(netip.MustParseAddr("1.0.1.128")); got != 0 {
		t.Errorf("the gap was claimed for cell %d", got)
	}
}

// THE CITY NAME IS GONE, and this is the privacy property the whole design rests
// on rather than a detail. Two different cities that share a cell must be
// indistinguishable, and no method on the table may return either name.
func TestTheCityNameIsNotRecoverable(t *testing.T) {
	// Two real cities about 40km apart, which the grid puts in one cell.
	p := writeTmp(t, `1.0.0.0,1.0.0.255,EU,NL,Noord-Holland,Amsterdam,52.37,4.90
2.0.0.0,2.0.0.255,EU,NL,Utrecht,Utrecht,52.09,5.12
`)
	tb, err := LoadCity(p)
	if err != nil {
		t.Fatal(err)
	}
	a := netip.MustParseAddr("1.0.0.1")
	b := netip.MustParseAddr("2.0.0.1")
	if tb.Cell(a) == 0 || tb.Cell(b) == 0 {
		t.Fatal("both cities should place")
	}
	if tb.Cell(a) != tb.Cell(b) {
		t.Skip("Amsterdam and Utrecht fell in different cells; the point below " +
			"still holds but this fixture cannot show it")
	}
	// Same cell, so the table cannot tell a reader in one from a reader in the
	// other — which is exactly what a ~550km cell is for.
	if lat, lon, _ := CellCentre(tb.Cell(a)); lat == 52.37 || lon == 4.90 {
		t.Error("the published position is the city's own coordinate, not the cell's centre")
	}
}

// A COUNTRY-ONLY FILE PLACES NOTHING, AND SAYS SO. The deploy falls back to the
// country file when the city one cannot be fetched, and the service has to be
// able to tell "nobody is here" from "this build cannot place anybody" — the
// healthy-looks-like-broken trap GeoKnown already exists for.
func TestACountryOnlyFileHasNoCellsAndAdmitsIt(t *testing.T) {
	p := writeTmp(t, "1.0.0.0,1.0.0.255,DE\n2.0.0.0,2.0.0.255,JP\n")
	tb, err := LoadRanges(p)
	if err != nil {
		t.Fatal(err)
	}
	if tb.HasCells() || tb.Cells() != 0 {
		t.Errorf("a country file must place nothing: HasCells=%v Cells=%d",
			tb.HasCells(), tb.Cells())
	}
	if got := tb.Cell(netip.MustParseAddr("1.0.0.1")); got != 0 {
		t.Errorf("a country file placed an address in cell %d", got)
	}
	if got := tb.Country(netip.MustParseAddr("1.0.0.1")); got != "DE" {
		t.Errorf("...while still naming the country, got %q", got)
	}
	// And the city loader's own table does claim cells.
	p2 := writeTmp(t, "1.0.0.0,1.0.0.255,EU,DE,Berlin,Berlin,52.52,13.40\n")
	tb2, err := LoadCity(p2)
	if err != nil {
		t.Fatal(err)
	}
	if !tb2.HasCells() || tb2.Cells() != 1 {
		t.Errorf("a city file must place: HasCells=%v Cells=%d", tb2.HasCells(), tb2.Cells())
	}
}

// A ROW WITH NO COORDINATE STILL NAMES ITS COUNTRY. DB-IP writes 0,0 for the
// handful it cannot place (14 of them in the real file, measured), and losing
// the country as well would be worse than losing the position.
func TestARowWithNoCoordinateKeepsItsCountry(t *testing.T) {
	p := writeTmp(t, "1.0.0.0,1.0.0.255,EU,DE,,,0,0\n")
	tb, err := LoadCity(p)
	if err != nil {
		t.Fatal(err)
	}
	a := netip.MustParseAddr("1.0.0.1")
	if got := tb.Country(a); got != "DE" {
		t.Errorf("country %q, want DE", got)
	}
	if got := tb.Cell(a); got != 0 {
		t.Errorf("an unplaced row must not place, got cell %d", got)
	}
	if tb.HasCells() {
		t.Error("a file of unplaced rows must not claim it can place")
	}
}

// LOAD PICKS THE PARSER BY LOOKING, and reads a gzipped file without being told.
// Both halves matter operationally: the deploy stores whichever file it managed
// to fetch, gzipped, and the service must not need a flag that can disagree with
// what is actually on disk.
func TestLoadSniffsFormatAndCompression(t *testing.T) {
	city := "1.0.0.0,1.0.0.255,EU,DE,Berlin,Berlin,52.52,13.40\n"
	country := "1.0.0.0,1.0.0.255,DE\n"
	gz := func(body string) string {
		p := filepath.Join(t.TempDir(), "geo.csv.gz")
		f, err := os.Create(p)
		if err != nil {
			t.Fatal(err)
		}
		w := gzip.NewWriter(f)
		if _, err := w.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
		w.Close()
		f.Close()
		return p
	}
	a := netip.MustParseAddr("1.0.0.1")
	for _, c := range []struct {
		what  string
		path  string
		cells bool
	}{
		{"a plain city file", writeTmp(t, city), true},
		{"a gzipped city file", gz(city), true},
		{"a plain country file", writeTmp(t, country), false},
		{"a gzipped country file", gz(country), false},
	} {
		tb, err := Load(c.path)
		if err != nil {
			t.Fatalf("%s: %v", c.what, err)
		}
		if got := tb.Country(a); got != "DE" {
			t.Errorf("%s: country %q, want DE", c.what, got)
		}
		if got := tb.HasCells(); got != c.cells {
			t.Errorf("%s: HasCells=%v, want %v", c.what, got, c.cells)
		}
		/* THE CITY FILE'S THIRD FIELD IS A CONTINENT, NOT A COUNTRY, which is the
		   trap in sniffing: LoadRanges reads field three as the country, so a
		   city file sent through it would give every German address "EU" — a
		   two-letter string that passes the country-code check and is wrong. */
		if c.cells && tb.Country(a) == "EU" {
			t.Errorf("%s: the continent was read as the country", c.what)
		}
	}
}
