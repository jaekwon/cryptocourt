package twap

import "testing"

// The ring is what makes a spike expensive: kourtv2 reads it for open interest and for
// X-bar, the answerability floor that gates PostAnswer and sizes a flag bond. It carried
// 8 mutation rows against 161 lines, and a sweep of its comparisons left two survivors —
// both in Observe, both about what the ring holds after a gap. These pin them.

// THE FILL COUNT NEVER EXCEEDS THE RING. `if r.filled < r.n { r.filled++ }` guards a
// counter that two other things read: Average's floor for "older than the ring has ever
// held" (`bkt <= r.base - filled`) and its maturity test (`r.filled >= want`). Widening it
// to `<=` lets the count reach n+1, which pushes that floor one bucket too far back and
// declares maturity one observation early — a window that is one sample short reporting
// itself as full is exactly what the average exists to prevent.
//
// Asserted on Filled() directly, because it is exported and because the two derived
// effects are downstream of this one number.
func TestTheFillCountStopsAtTheRingSize(t *testing.T) {
	const width = int64(10)
	const n = 4
	r := New(width, n, 8)
	// Well past full: every observation lands in its own bucket.
	for i := 0; i < n+3; i++ {
		r = r.Observe(int64(i)*width, int64(100+i))
	}
	if got := r.Filled(); got != n {
		t.Fatalf("a ring of %d buckets can never hold more, Filled() = %d", n, got)
	}
	// The ring is genuinely full rather than never having filled, or the assertion
	// above would hold for a ring that recorded nothing.
	if avg, mature := r.Average(int64(n+2)*width, width*int64(n)); !mature || avg <= 0 {
		t.Fatalf("setup: a full ring must answer a full window, avg=%d mature=%v",
			avg, mature)
	}
}

// AFTER A GAP THE NEW VALUE GOES IN THE NEWEST BUCKET, and the skipped ones carry the old
// one forward. Observe steps the head once per elapsed bucket and fills each with
// `r.last`, EXCEPT the final step which takes the new value — `if i == steps-1`. Point
// that at `i == 0` instead and the new value lands in the OLDEST stepped bucket while the
// newest holds the stale one, so a one-bucket read of the freshest data answers with the
// value that has just been superseded. Nothing failed.
//
// The forward fill is asserted too, because it is the other half of the same statement:
// the gap is not empty, it holds what the series held while nobody observed it.
func TestAGapPutsTheNewValueInTheNewestBucket(t *testing.T) {
	const width = int64(10)
	r := New(width, 8, 8)
	r = r.Observe(0, 100)
	// Three buckets later. Buckets 1 and 2 forward-fill 100; bucket 3 takes 999.
	r = r.Observe(3*width, 999)

	// A one-bucket window reads the NEWEST bucket alone.
	if avg, _ := r.Average(3*width, width); avg != 999 {
		t.Fatalf("the newest bucket must hold the value just observed, got %d", avg)
	}
	// A window spanning the gap averages the forward fill with the new value: two
	// buckets of 100 and one of 999.
	if avg, _ := r.Average(3*width, 3*width); avg != (100+100+999)/3 {
		t.Fatalf("the skipped buckets must carry the old value forward, window avg %d",
			avg)
	}
	// And the bucket before the gap still holds what it held.
	if avg, _ := r.Average(0, width); avg != 100 {
		t.Fatalf("the pre-gap bucket must be unchanged, got %d", avg)
	}
}
