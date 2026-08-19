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
