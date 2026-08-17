// Package twap is a fixed-window trailing average of an integer series: cheap to
// keep, cheap to read, and hard to move with a one-block spike.
//
// It answers one question — "what has this number averaged over the last W?" —
// which is what an on-chain market wants from a price oracle and what a token
// vote wants from a supply-or-turnout figure: a value that a flash spike cannot
// shift, because moving the average requires HOLDING the pushed value for a real
// fraction of the window.
//
// # Not checkpoint
//
// The sibling p/kourt/checkpoint answers a different question — "what was
// this value at sealed epoch N?" — from unbounded, paged history. This is a
// bounded rolling window with no archive: the last N buckets and nothing older.
// Different query, different structure, no overlap.
//
// # A value, not an object
//
// A Ring is a plain value the caller stores inline on a record it was going to
// write anyway — a market's own row. It is never a heap object of its own, and
// never held by pointer in realm state: every method takes a Ring by value and
// returns an updated one. The reason to keep it a value is purely GAS, not
// safety: gno charges per object touched, so a Ring that rides its host's write
// costs nothing extra to keep, whereas a *Ring would be a second object (a second
// key) — and it would buy nothing, since every method is a value receiver that
// hands back a copy anyway. There is no mutator to borrow and so no security
// question here at all; the value shape is a cost decision.
//
//	r = r.Observe(height, price)   // store r back onto your own record
//	avg, ok := r.Average(height, window)
//
// # Buckets, and why a spike does not move the average
//
// Time is quantised into fixed-width buckets. Each bucket remembers the last
// value seen in it; a bucket with no observation carries the previous value
// forward, so a quiet series reads as "unchanged", not as a gap. The average
// over a window of W is the mean of the W/width most recent buckets.
//
// A spike therefore lands in at most one bucket — one part in W/width of the
// average — and only if it is still the last value in that bucket when the bucket
// closes. To move the average by a fraction f of the series' range you must keep
// it moved across about f·(W/width) buckets, i.e. hold the pushed value for f of
// the whole window against everyone trading back. One block is ~1/(W/width) of
// that, which for a week of hourly buckets is under a thousandth of a spike.
//
// # The freshness contract
//
// That guarantee holds only while observations keep arriving. An empty bucket
// carries the last value forward, so if the caller STOPS observing, the last
// value — a spike included — persists across the whole window and the average
// becomes that single value, still reported mature. So the caller must Observe on
// every change to the tracked quantity, OR Observe at the height it later reads.
// StaleBy reports how far a read has drifted from the newest observation, for a
// caller that cannot guarantee the former. `mature` means "the window is
// covered", never "the data is recent".
package twap

import "math/overflow"

// Ring is a fixed-window trailing average. The zero value is not usable; build
// one with New.
//
// bpp is bytes per sample: 1 for a 0..255 value such as a percentage price, up
// to 8 for a full int64. Samples are packed big-endian into buf so the whole
// history is one []byte-shaped field rather than N times the 40 bytes gno spends
// on a slice element of any wider type.
type Ring struct {
	width  int64  // bucket width, in the caller's height units
	n      int    // number of buckets
	bpp    int    // bytes per sample
	head   int    // ring index of the newest bucket
	base   int64  // bucket number (height/width) at head
	last   int64  // most recent value, carried across empty buckets
	filled int    // buckets ever written, for maturity
	buf    string // n*bpp packed big-endian samples
}

// New builds an empty ring of n buckets, each width height-units wide, storing
// bpp bytes per sample.
//
// The window a caller later asks Average for must be at most n*width, or the ring
// cannot cover it and the read is reported immature. Size n to the longest window
// you will read.
//
// width is the resolution-versus-cost trade: a finer width puts more buckets in a
// window (more storage, a longer Average scan) but resists a spike that is held
// for less real time; a coarser width is cheaper and blunter. n*width fixes the
// span, so the two are chosen together — e.g. a week resisted at hourly grain is
// width=1h, n=168.
func New(width int64, n, bpp int) Ring {
	mustSane(width, n, bpp)
	return Ring{
		width: width, n: n, bpp: bpp,
		head: 0, base: 0, last: 0, filled: 0,
		buf: string(make([]byte, n*bpp)),
	}
}

// Load reconstructs a ring from a previously stored header and its buf.
//
// The three shape numbers are the caller's own constants; only buf is data, so a
// caller that keeps width/n/bpp as package constants stores just the head fields
// and the bytes.
//
// Load validates SHAPE — buf length, and head/filled in range — and panics on a
// mismatch. It TRUSTS base and last: a wrong value there only skews a later
// average (never reads out of bounds), so pass back exactly what the accessors
// returned rather than hand-built numbers.
func Load(width int64, n, bpp int, head int, base, last int64, filled int, buf string) Ring {
	mustSane(width, n, bpp)
	if len(buf) != n*bpp {
		panic("twap: buf length does not match n*bpp")
	}
	if head < 0 || head >= n || filled < 0 || filled > n {
		panic("twap: head or filled out of range")
	}
	return Ring{width: width, n: n, bpp: bpp, head: head, base: base, last: last, filled: filled, buf: buf}
}

// Observe records value as of height and returns the updated ring.
//
// Height must not go backwards below the newest bucket already written; a chain
// height only ever increases, and a caller that resets it (a test harness) is the
// one case this refuses, loudly, because a backwards write would corrupt every
// later average.
func (r Ring) Observe(height, value int64) Ring {
	if r.n == 0 {
		panic("twap: zero-value ring; use New")
	}
	bn := height / r.width
	b := []byte(r.buf)
	if r.filled == 0 {
		// Seed on the FIRST real observation, wherever it lands. A market is
		// created at some height H and its first Observe is at H, not at 0 — so
		// base must start at H's bucket, not at zero. Seeding at zero and then
		// advancing to H would carry the zero-value `last` into every bucket in
		// between and count them in `filled`, and the ring would then report a
		// week of history averaging zero as mature and true when the only value
		// ever seen was, say, 50. That is a wrong average handed to a quorum, and
		// it is exactly the case no test with a height-0 start ever reaches.
		r.base = bn
		put(b, r.head*r.bpp, r.bpp, value)
		r.filled, r.last, r.buf = 1, value, string(b)
		return r
	}
	if bn < r.base {
		panic("twap: height went backwards")
	}
	if bn == r.base {
		// Same bucket: overwrite its representative value.
		put(b, r.head*r.bpp, r.bpp, value)
		r.last = value
		r.buf = string(b)
		return r
	}
	// Advance across the gap, carrying `last` into every skipped bucket and
	// `value` into the newest. More than n steps just laps the ring, so cap the
	// work at n — the older laps are overwritten anyway.
	steps := bn - r.base
	if steps > int64(r.n) {
		steps = int64(r.n)
	}
	for i := int64(0); i < steps; i++ {
		r.head++
		if r.head == r.n {
			r.head = 0
		}
		fill := r.last
		if i == steps-1 {
			fill = value
		}
		put(b, r.head*r.bpp, r.bpp, fill)
		if r.filled < r.n {
			r.filled++
		}
	}
	r.base = bn
	r.last = value
	r.buf = string(b)
	return r
}

// Average returns the trailing average over [height-window, height] and whether
// the ring held enough history to cover the whole window.
//
// mature means the window is COVERED by real buckets — not that those buckets are
// RECENT. An empty tail carries the last value forward (see StaleBy and the
// freshness contract), so a lone spike that is the last observation before a quiet
// spell fills the window and still reads mature. A caller acting on the average
// against manipulation — gating a vote, pricing a payout — must BOTH refuse to act
// while mature is false AND keep the read fresh: Observe at (or near) the height
// it reads, or gate on StaleBy. Reading is pure — a transient decode, no object
// touched — so it is safe inside a Render.
func (r Ring) Average(height, window int64) (avg int64, mature bool) {
	if r.n == 0 {
		panic("twap: zero-value ring; use New")
	}
	if window < r.width {
		window = r.width
	}
	// want is how many buckets the window asks for, UNCAPPED. Maturity is measured
	// against it, so a window wider than the ring can ever hold (want > n) reads
	// immature — rather than silently returning the ring's shorter average stamped
	// as the requested one. k is want capped to what the ring can scan.
	want := int(window / r.width)
	k := want
	if k > r.n {
		k = r.n
	}
	bn := height / r.width
	var sum int64
	count := 0
	for i := 0; i < k; i++ {
		bkt := bn - int64(i)
		if bkt < 0 || bkt <= r.base-int64(r.filled) {
			break // older than the ring has ever held real data
		}
		var v int64
		if bkt > r.base {
			v = r.last // beyond the last observation: value has persisted
		} else {
			idx := r.head - int(r.base-bkt)
			for idx < 0 {
				idx += r.n
			}
			v = get(r.buf, idx*r.bpp, r.bpp) // read the string directly; no []byte copy
		}
		// Checked, not assumed. Values are non-negative, so a wrapped sum goes
		// negative and would hand a quorum a negative "average"; refuse loudly
		// instead. Trips only when the ring holds more large buckets than fit in
		// int64 (e.g. per-minute buckets at the supply cap) — size the ring or
		// narrow the value range.
		next, ok := overflow.Add64(sum, v)
		if !ok {
			panic("twap: window sum overflowed int64")
		}
		sum = next
		count++
	}
	if count == 0 {
		return 0, false
	}
	return sum / int64(count), count == want && r.filled >= want
}

// Head, Base, Last, Filled, Bytes expose the fields a caller stores alongside buf
// to reconstruct the ring with Load.
func (r Ring) Head() int     { return r.head }
func (r Ring) Base() int64   { return r.base }
func (r Ring) Last() int64   { return r.last }
func (r Ring) Filled() int   { return r.filled }
func (r Ring) Bytes() string { return r.buf }

// StaleBy reports how many buckets the read height lies beyond the newest
// observation. Zero means the newest real value sits in height's own bucket; a
// larger number means the window a caller is about to Average is that many buckets
// of carried-forward value rather than fresh data. Because `mature` only says the
// window is covered, a caller acting against manipulation should require StaleBy
// to be small — ideally 0, i.e. Observe at the height it reads (see the freshness
// contract on the package).
func (r Ring) StaleBy(height int64) int64 {
	if r.n == 0 {
		panic("twap: zero-value ring; use New")
	}
	bn := height / r.width
	if bn <= r.base {
		return 0
	}
	return bn - r.base
}

func mustSane(width int64, n, bpp int) {
	if width <= 0 {
		panic("twap: width must be positive")
	}
	if n <= 0 {
		panic("twap: n must be positive")
	}
	if bpp < 1 || bpp > 8 {
		panic("twap: bpp must be 1..8")
	}
}

// put writes v big-endian into b[off:off+bpp]. The caller guarantees v fits in
// bpp bytes; a value wider than the sample width is a caller bug, and truncating
// it silently is the one behaviour this must not have — so the top bytes are
// asserted zero.
func put(b []byte, off, bpp int, v int64) {
	if v < 0 {
		panic("twap: negative value")
	}
	if bpp < 8 && v>>(uint(bpp)*8) != 0 {
		panic("twap: value does not fit in bpp bytes")
	}
	for i := bpp - 1; i >= 0; i-- {
		b[off+i] = byte(v & 0xff)
		v >>= 8
	}
}

// get reads a big-endian sample straight from the buf STRING, so a read never
// allocates a []byte copy. Only Observe needs the mutable []byte (for put); a
// read (Average) is the hot path and stays allocation-free.
func get(s string, off, bpp int) int64 {
	var v int64
	for i := 0; i < bpp; i++ {
		v = (v << 8) | int64(s[off+i])
	}
	return v
}
