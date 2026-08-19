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
//	        Costs nothing, needs no data file, and is what the server uses.
//	Table   a local MaxMind GeoLite2-Country database.
//
// What is deliberately absent is a call to a third-party geolocation API. That
// would ship every visitor's address to somebody else's service, forever, for a
// decoration — and this package exists inside a design whose whole argument about
// addresses is that they are not disclosed.
package geo

import (
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

// Table is a sorted prefix table, searched by bisection.
type Table struct {
	v4, v6 []entry
}

type entry struct {
	pre netip.Prefix
	cc  string
}

func (t *Table) Country(a netip.Addr) string {
	a = a.Unmap()
	rows := t.v6
	if a.Is4() {
		rows = t.v4
	}
	// The last prefix whose base is at or below the address is the only candidate,
	// because MaxMind's blocks do not overlap.
	i := sort.Search(len(rows), func(i int) bool {
		return rows[i].pre.Addr().Compare(a) > 0
	})
	if i == 0 {
		return ""
	}
	if e := rows[i-1]; e.pre.Contains(a) {
		return e.cc
	}
	return ""
}

// Len reports how many prefixes were loaded, so a caller can log it and notice a
// file that parsed to almost nothing.
func (t *Table) Len() int { return len(t.v4) + len(t.v6) }

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
	sort.Slice(t.v4, func(i, j int) bool { return t.v4[i].pre.Addr().Compare(t.v4[j].pre.Addr()) < 0 })
	sort.Slice(t.v6, func(i, j int) bool { return t.v6[i].pre.Addr().Compare(t.v6[j].pre.Addr()) < 0 })
	if t.Len() == 0 {
		// Fail loudly. A geo table that silently loaded nothing looks exactly like
		// a world with no countries in it.
		return nil, errors.New("geo: the files parsed to zero prefixes")
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
		e := entry{pre: pre.Masked(), cc: cc}
		if e.pre.Addr().Is4() {
			t.v4 = append(t.v4, e)
		} else {
			t.v6 = append(t.v6, e)
		}
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
