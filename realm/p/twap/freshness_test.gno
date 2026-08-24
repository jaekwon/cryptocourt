package twap

import "testing"

// mustPanicWith is shouldPanic with teeth: it reads the recovered value and fails
// unless it CONTAINS want. Use it wherever the message is what distinguishes one
// refusal from another — Load has five validation branches and shouldPanic cannot
// tell them apart, so three arms named for three branches were satisfied by any
// panic at all. It lived as a closure inside TestConstructorsRejectInsaneGeometry,
// where no other file could reach it.
//
// shouldPanic is still right where there is exactly ONE way for the call to fail;
// then a message match adds nothing and couples the test to wording.
func mustPanicWith(t *testing.T, want string, fn func()) {
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

func shouldPanic(t *testing.T, name string, fn func()) {
	t.Helper()
	defer func() {
		if recover() == nil {
			t.Fatalf("%s should have panicked", name)
		}
	}()
	fn()
}

// TestFutureCarryForwardIsNotMature kills a surviving mutant: the `filled >= want`
// conjunct in the maturity test. Reading one bucket AHEAD of the last observation
// carries the last value forward into the future bucket, so `count` reaches `want`
// with only 2 PHYSICAL observations. maturity must still be false — otherwise a
// series drifting one bucket past a 2-observation history would report a full window
// mature, silently re-weakening the court's anti-flash-answer gate. Deleting the
// conjunct flips this to (50, true), which this test now catches.
func TestFutureCarryForwardIsNotMature(t *testing.T) {
	r := New(1, 3, 1) // width 1, three one-block buckets
	r = r.Observe(0, 30)
	r = r.Observe(1, 60)
	avg, mature := r.Average(2, 3) // read at height 2 — one bucket past the last write
	if avg != 50 {
		t.Fatalf("average over {carry 60, 60, 30} should be 50, got %d", avg)
	}
	if mature {
		t.Fatal("count reached want via FUTURE carry-forward but only 2 real observations exist — must be immature")
	}
}

// TestNewValidates and TestLoadValidates cover the shape-validation panics (untested).
func TestNewValidates(t *testing.T) {
	shouldPanic(t, "zero width", func() { New(0, 168, 1) })
	shouldPanic(t, "zero buckets", func() { New(1, 0, 1) })
	shouldPanic(t, "zero bytes-per-bucket", func() { New(1, 168, 0) })
	shouldPanic(t, "bytes-per-bucket over 8", func() { New(1, 168, 9) })
}

func TestLoadValidates(t *testing.T) {
	// A valid ring here is n*bpp = 4*1 = 4 bytes.
	// The MESSAGES, not the labels: Load checks width, n and bpp before either of
	// these, so a label-only assertion passes on any of five panics. head and
	// filled share one branch and therefore one message — two inputs to the same
	// guard, which is coverage rather than duplication.
	mustPanicWith(t, "buf length does not match n*bpp",
		func() { Load(1, 4, 1, 0, 0, 0, 0, "ABC") })
	mustPanicWith(t, "head or filled out of range",
		func() { Load(1, 4, 1, 4, 0, 0, 0, "ABCD") })
	mustPanicWith(t, "head or filled out of range",
		func() { Load(1, 4, 1, 0, 0, 0, 5, "ABCD") })
}
