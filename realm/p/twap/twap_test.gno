package twap

import "testing"

// A week of hourly buckets, in a world where a bucket is one height-unit.
const (
	hour    = int64(1)
	buckets = 168
	week    = int64(168)
)

func newHourly() Ring { return New(hour, buckets, 1) }

func TestConstantSeriesAveragesToItself(t *testing.T) {
	r := newHourly()
	for h := int64(0); h < week; h++ {
		r = r.Observe(h, 42)
	}
	avg, mature := r.Average(week-1, week)
	if !mature {
		t.Fatal("a full week of observations should be mature")
	}
	if avg != 42 {
		t.Fatalf("constant 42 should average 42, got %d", avg)
	}
}

func TestImmatureUntilWindowFilled(t *testing.T) {
	r := newHourly()
	for h := int64(0); h < 100; h++ {
		r = r.Observe(h, 50)
	}
	if _, mature := r.Average(99, week); mature {
		t.Fatal("100 of 168 buckets should not be mature for a week window")
	}
	// A shorter window it does cover is mature.
	if _, mature := r.Average(99, 50); !mature {
		t.Fatal("a 50-bucket window over 100 buckets should be mature")
	}
}

func TestOneBlockSpikeBarelyMoves(t *testing.T) {
	r := newHourly()
	for h := int64(0); h < week; h++ {
		r = r.Observe(h, 50)
	}
	base, _ := r.Average(week-1, week)
	// Slam the last bucket to the top of the range for one observation.
	r = r.Observe(week-1, 100)
	spiked, _ := r.Average(week-1, week)
	// One bucket of 168 moved from 50 to 100: the mean rises by 50/168 < 1.
	if spiked-base > 1 {
		t.Fatalf("a one-bucket spike moved the week average by %d (expected <=1)", spiked-base)
	}
}

func TestSustainedMoveIsNeededToShiftTheAverage(t *testing.T) {
	r := newHourly()
	for h := int64(0); h < week; h++ {
		r = r.Observe(h, 20)
	}
	// Hold 80 for a quarter of the window.
	for h := week; h < week+week/4; h++ {
		r = r.Observe(h, 80)
	}
	avg, _ := r.Average(week+week/4-1, week)
	// 42 buckets at 80, 126 at 20 -> (42*80 + 126*20)/168 = 35.
	if avg != 35 {
		t.Fatalf("a quarter-window hold of 80 over 20 should average 35, got %d", avg)
	}
}

func TestGapCarriesLastForward(t *testing.T) {
	r := newHourly()
	r = r.Observe(0, 70)
	// Nothing for 10 hours, then a read: the empty buckets hold 70.
	r = r.Observe(10, 70)
	avg, _ := r.Average(10, 10)
	if avg != 70 {
		t.Fatalf("a gap should carry the last value; got %d", avg)
	}
}

func TestReadBeyondLastObservationPersists(t *testing.T) {
	r := newHourly()
	for h := int64(0); h < week; h++ {
		r = r.Observe(h, 60)
	}
	// Read a day later with no new observations: still 60.
	avg, mature := r.Average(week+24, week)
	if !mature || avg != 60 {
		t.Fatalf("value should persist beyond the last observation; got %d mature=%v", avg, mature)
	}
}

func TestBigJumpLapsTheRingCleanly(t *testing.T) {
	r := newHourly()
	r = r.Observe(0, 30)
	// Jump far past the ring's span, more than n buckets.
	r = r.Observe(1000, 90)
	avg, mature := r.Average(1000, week)
	// Everything before 1000 was 30 (carried), the newest is 90; but a jump of
	// 1000 > 168 laps the whole ring, so all buckets carry 30 except the newest.
	// (167*30 + 90)/168 = 30.
	if !mature {
		t.Fatal("after a full lap the ring is mature")
	}
	if avg != 30 {
		t.Fatalf("a lapped ring should read the carried value; got %d", avg)
	}
}

func TestWideValuesRoundTrip(t *testing.T) {
	// OI-shaped: 8 bytes per sample, values near the court supply cap.
	r := New(hour, 8, 8)
	big := int64(9223372036854775807) / 10000 // maxSupply-ish
	for h := int64(0); h < 8; h++ {
		r = r.Observe(h, big)
	}
	avg, mature := r.Average(7, 8)
	if !mature || avg != big {
		t.Fatalf("wide values should round-trip; got %d want %d", avg, big)
	}
}

func TestLoadRoundTrips(t *testing.T) {
	r := newHourly()
	for h := int64(0); h < 50; h++ {
		r = r.Observe(h, int64(h%100))
	}
	r2 := Load(hour, buckets, 1, r.Head(), r.Base(), r.Last(), r.Filled(), r.Bytes())
	a1, m1 := r.Average(49, 24)
	a2, m2 := r2.Average(49, 24)
	if a1 != a2 || m1 != m2 {
		t.Fatalf("reloaded ring diverged: (%d,%v) vs (%d,%v)", a1, m1, a2, m2)
	}
}

func TestBackwardsHeightPanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("a backwards height should panic")
		}
	}()
	r := newHourly()
	r = r.Observe(100, 1)
	r.Observe(50, 1) // below the newest bucket
}

func TestValueTooWideForSamplePanics(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("a value wider than bpp should panic, not truncate")
		}
	}()
	r := New(hour, 4, 1) // 1 byte per sample: 0..255
	r.Observe(0, 256)
}

// The regression the review found: a market is created at a real height and its
// first observation lands there, not at bucket 0.
func TestFirstObservationAtRealHeightNotFabricated(t *testing.T) {
	r := newHourly()
	r = r.Observe(1000000, 50) // first and only observation, far from 0
	avg, mature := r.Average(1000000, week)
	if mature {
		t.Fatal("one observation is not a week of history; must be immature")
	}
	if avg != 50 {
		t.Fatalf("the only value seen was 50; got %d (fabricated zeros?)", avg)
	}
	// A one-bucket window over that single datum is its value and mature.
	if a, m := r.Average(1000000, hour); a != 50 || !m {
		t.Fatalf("single-bucket read should be 50 mature; got %d %v", a, m)
	}
}

func TestWindowWiderThanRingIsImmature(t *testing.T) {
	// New promises a window larger than n*width reads immature; a full ring must
	// not stamp its own shorter average as the wider one requested.
	r := newHourly() // n = 168
	for h := int64(0); h < buckets; h++ {
		r = r.Observe(h, 50)
	}
	if _, mature := r.Average(buckets-1, 2*week); mature { // 336 > 168
		t.Fatal("a window wider than the ring can hold must be immature")
	}
	if _, mature := r.Average(buckets-1, week); !mature {
		t.Fatal("an exactly-covered window should be mature")
	}
	if _, mature := r.Average(buckets-1, week+hour); mature {
		t.Fatal("one bucket beyond the ring must be immature")
	}
}

func TestOverflowingSumIsRefused(t *testing.T) {
	// A window sum that would wrap int64 must panic, not silently return a
	// negative "average" to a quorum.
	r := New(hour, 4, 8) // 8 bytes/sample: full int64 values
	big := int64(9223372036854775807)
	r = r.Observe(0, big)
	r = r.Observe(1, big)
	r = r.Observe(2, big)
	defer func() {
		if recover() == nil {
			t.Fatal("a window sum overflowing int64 must panic")
		}
	}()
	r.Average(2, 3*hour) // three MaxInt64 buckets overflow
}

func TestStaleTailIsFlaggedByStaleBy(t *testing.T) {
	// The flash-resistance gap: a spike as the LAST observation persists forward,
	// so the average climbs to it and stays mature. StaleBy exposes the drift so a
	// caller can refuse; observing at the read height clears it.
	r := newHourly()
	for h := int64(0); h < week; h++ {
		r = r.Observe(h, 50)
	}
	r = r.Observe(week-1, 100) // spike, as the last observation
	far := week - 1 + week     // a full week later, no new observations
	avg, mature := r.Average(far, week)
	if !mature {
		t.Fatal("the window is still covered, so mature stays true — this is the trap")
	}
	if avg <= 60 {
		t.Fatalf("without freshness the persisted spike dominates; got %d", avg)
	}
	if r.StaleBy(far) < week {
		t.Fatalf("StaleBy should reveal a full-window drift, got %d", r.StaleBy(far))
	}
	// Observing at the read height clears staleness.
	r2 := r.Observe(far, 50)
	if r2.StaleBy(far) != 0 {
		t.Fatal("observing at the read height should clear staleness")
	}
}

func TestOldRingUnchangedAfterObserveOnCopy(t *testing.T) {
	// A Ring is a value: mutating a derived copy must not touch the original's
	// backing bytes.
	r := newHourly()
	for h := int64(0); h < 10; h++ {
		r = r.Observe(h, h)
	}
	snapshot := r.Bytes()
	_ = r.Observe(10, 99) // derive and discard (99 fits the 1-byte sample)
	if r.Bytes() != snapshot {
		t.Fatal("observing on a derived ring mutated the original's bytes")
	}
	if a, _ := r.Average(9, 10); a != 4 { // mean of 0..9 is 4
		t.Fatalf("original ring's average changed; got %d", a)
	}
}

func TestWidthGreaterThanOneBuckets(t *testing.T) {
	// Every other test uses width=1; exercise real height/width bucketing.
	r := New(10, 8, 1) // width 10
	r = r.Observe(0, 20)
	r = r.Observe(5, 40)  // same bucket 0 -> overwrites to 40
	r = r.Observe(10, 60) // bucket 1
	avg, mature := r.Average(19, 20)
	if !mature || avg != 50 { // (40 + 60) / 2
		t.Fatalf("width-10 bucketing should average 50 mature; got %d %v", avg, mature)
	}
}

func TestSeedThenFillIsMatureWithRealData(t *testing.T) {
	r := newHourly()
	start := int64(500000)
	for i := int64(0); i < week; i++ {
		r = r.Observe(start+i, 40)
	}
	avg, mature := r.Average(start+week-1, week)
	if !mature || avg != 40 {
		t.Fatalf("a full week from a real start should be 40 mature; got %d %v", avg, mature)
	}
}

// mustSane guards BOTH constructors (New and Load) and no test asserted any of its
// three panics — a gap a previous audit named as "the New/Load guards" and that was
// never closed. It matters because the ring's geometry is trusted everywhere after
// construction: `put`/`get` index into buf by bpp with no bounds re-check, and the
// courts size their answerability window off `n`. A zero width would divide by zero
// on the bucket index; a bpp outside 1..8 would slice past a sample.
//
// Each case is checked on New AND Load, since Load takes the same geometry from
// persisted state and a caller that reconstructs a ring from bad bytes must be
// refused just as loudly as one that builds a fresh one.
func TestConstructorsRejectInsaneGeometry(t *testing.T) {
	mustPanicWith := func(want string, fn func()) {
		t.Helper()
		defer func() {
			r := recover()
			if r == nil {
				t.Fatalf("expected a panic saying %q; nothing panicked", want)
			}
			if got, ok := r.(string); !ok || !contains(got, want) {
				t.Fatalf("panic %v, want one saying %q", r, want)
			}
		}()
		fn()
	}

	// width must be positive: it is the divisor for the bucket index.
	mustPanicWith("width must be positive", func() { New(0, buckets, 1) })
	mustPanicWith("width must be positive", func() { New(-1, buckets, 1) })
	mustPanicWith("width must be positive", func() { Load(0, buckets, 1, 0, 0, 0, 0, "") })

	// n must be positive: a zero-bucket ring has no slot to write.
	mustPanicWith("n must be positive", func() { New(hour, 0, 1) })
	mustPanicWith("n must be positive", func() { New(hour, -1, 1) })
	mustPanicWith("n must be positive", func() { Load(hour, 0, 1, 0, 0, 0, 0, "") })

	// bpp must be 1..8: outside that, put/get would slice past a sample.
	mustPanicWith("bpp must be 1..8", func() { New(hour, buckets, 0) })
	mustPanicWith("bpp must be 1..8", func() { New(hour, buckets, 9) })
	mustPanicWith("bpp must be 1..8", func() { New(hour, buckets, -1) })
	mustPanicWith("bpp must be 1..8", func() { Load(hour, buckets, 9, 0, 0, 0, 0, "") })

	// And the boundaries are ACCEPTED, so the guard is not off by one at either end.
	_ = New(1, 1, 1)
	_ = New(hour, buckets, 8)
}

// contains is strings.Contains; twap imports no stdlib and a test should not be the
// first thing to.
func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
