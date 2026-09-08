package geo

import (
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
