package geo

import (
	"math"
	"sort"
)

// A COARSE GRID, AND THE ONLY LOCATION THIS PACKAGE WILL EVER HAND OUT FINER
// THAN A COUNTRY.
//
// ASKED FOR AS "US isn't enough, don't we have more position information from
// the ip?" — and yes: the vendor's city file carries a latitude and a longitude
// per span. Publishing those, or the city name beside them, would invert what
// the presence page is built on. hereFloor exists because a country with one
// reader in it is a public statement that one particular person is in that
// country, and two connections in a small town is closer to naming somebody
// than two connections in a country ever gets.
//
// SO THE COORDINATES ARE CONSUMED AT LOAD AND NEVER STORED. A span keeps a cell
// index and nothing else, which makes the guarantee structural rather than a
// policy someone could later relax by reading a field that was lying around:
// this process cannot report a position finer than a cell because it does not
// have one. Cost is two bytes a span.
//
// EQUAL AREA, NOT A 5-DEGREE LATTICE. Five degrees of longitude is 556km at the
// equator and 278km at 60N, so a plain lattice quietly halves the cell — and
// therefore the protection — for readers in northern Europe and Canada, which
// is where a lot of them are. Bands of 5 degrees of latitude with the number of
// longitude cells scaled by the cosine of the band's own centre keeps every
// cell about 550km on a side wherever it is, so the bound this package offers
// can be stated as one number and be true everywhere.
//
// WHAT THAT BOUND IS, PLAINLY: a published cell says "at least hereFloor
// connections are somewhere inside this ~550km square". It does not say where
// in it, and it never says which city, which region, or which network.
const (
	// CellLatStep is the height of a band, in degrees.
	CellLatStep = 5.0
	// CellBands is how many bands cover -90..90.
	CellBands = int(180 / CellLatStep)
	// CellLonCells is how many longitude cells a band at the equator gets. 72
	// of them is 5 degrees each, which is the ~556km that sets the scale.
	CellLonCells = 72
)

// cellLon is how many longitude cells each band has, and cellBase is the index
// the band starts at. Built once: the arithmetic is trivial but it is on the
// path that resolves every held connection, and a table is clearer than a
// cosine per lookup.
var (
	cellLon  [CellBands]int
	cellBase [CellBands]int
	cellMax  int
)

func init() {
	n := 0
	for b := 0; b < CellBands; b++ {
		mid := -90 + CellLatStep*float64(b) + CellLatStep/2
		// AT LEAST ONE, which is what the polar bands collapse to: cos(87.5) is
		// 0.044, so 72 of them would be three cells 120 degrees wide and the
		// rounding is what decides between three and one. Either is coarser than
		// a country and nobody is holding a chat open there.
		k := int(math.Round(CellLonCells * math.Cos(mid*math.Pi/180)))
		if k < 1 {
			k = 1
		}
		cellLon[b] = k
		cellBase[b] = n
		n += k
	}
	cellMax = n
}

// CellCount is how many cells the grid has. Small — about 1650 — which is why a
// cell index fits a uint16 with room to spare and why 0 can mean "unknown".
func CellCount() int { return cellMax }

// CellOf snaps a coordinate to its cell, 1-based. Zero means the coordinate was
// not usable, which the loaders treat the same as a row they could not parse.
//
// 0,0 IS TREATED AS ABSENT, deliberately. The vendor's file writes 0,0 for the
// rows it has no position for — including the ZZ span at the very front of the
// file — and a reader placed at the origin appears in the Gulf of Guinea, which
// is both wrong and the classic sign of exactly this bug.
func CellOf(lat, lon float64) uint16 {
	if math.IsNaN(lat) || math.IsNaN(lon) || math.IsInf(lat, 0) || math.IsInf(lon, 0) {
		return 0
	}
	if lat == 0 && lon == 0 {
		return 0
	}
	if lat < -90 || lat > 90 || lon < -180 || lon > 180 {
		return 0
	}
	b := int((lat + 90) / CellLatStep)
	if b < 0 {
		b = 0
	}
	if b >= CellBands {
		b = CellBands - 1 // the north pole itself, which lands one past the last band
	}
	k := cellLon[b]
	j := int((lon + 180) / (360 / float64(k)))
	if j < 0 {
		j = 0
	}
	if j >= k {
		j = k - 1 // longitude exactly 180
	}
	return uint16(cellBase[b] + j + 1)
}

// CellCentre is where a cell is drawn: the middle of it, never the middle of the
// connections inside it.
//
// THE CENTRE IS THE WHOLE POINT. A centroid of the addresses in a cell would
// leak most of what the cell was built to hide — with two connections it is
// their midpoint — so every dot in a cell sits at the same place regardless of
// where in it the readers are. The visible cost is that dots land on a lattice
// rather than on cities, which is the honest picture of what is known.
func CellCentre(cell uint16) (lat, lon float64, ok bool) {
	if cell == 0 || int(cell) > cellMax {
		return 0, 0, false
	}
	i := int(cell) - 1
	// The last band starting at or below i, by bisection over cellBase.
	b := sort.Search(CellBands, func(x int) bool { return cellBase[x] > i }) - 1
	if b < 0 {
		b = 0
	}
	k := cellLon[b]
	j := i - cellBase[b]
	step := 360 / float64(k)
	return -90 + CellLatStep*float64(b) + CellLatStep/2,
		-180 + (float64(j)+0.5)*step, true
}
