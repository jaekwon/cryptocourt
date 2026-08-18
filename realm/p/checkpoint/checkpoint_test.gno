package checkpoint

import (
	"testing"
)

// The series is the whole design in miniature: two points inline, the rest
// paged into an archive, and a floor query that usually never reaches it.
func TestSeriesAnswersAsOf(t *testing.T) {
	arch := NewArchive()
	var s Series

	s.SetAt(arch, "k", 3, 100)
	s.SetAt(arch, "k", 5, 250)

	if got := s.ValueAt(arch, "k", 5); got != 250 {
		t.Errorf("at the newest epoch = %d, want 250", got)
	}
	if got := s.ValueAt(arch, "k", 4); got != 100 {
		t.Errorf("between the two points = %d, want 100 — a query must read as "+
			"of that epoch, not the latest", got)
	}
	// Below everything ever recorded. Zero is exact rather than a miss: the
	// account held nothing then.
	if got := s.ValueAt(arch, "k", 2); got != 0 {
		t.Errorf("before the first point = %d, want 0", got)
	}

	// Two changes in one epoch collapse. This is the whole gas argument: the
	// second one must not add a key.
	s.SetAt(arch, "k", 5, 999)
	if got := s.ValueAt(arch, "k", 5); got != 999 {
		t.Errorf("same-epoch update = %d, want 999", got)
	}
	if got := s.ValueAt(arch, "k", 4); got != 100 {
		t.Errorf("a same-epoch update rewrote history: %d, want 100", got)
	}
}

// Once a third point arrives the oldest falls out of the inline slots, and the
// archive has to answer for it.
func TestTheArchiveAnswersForOlderEpochs(t *testing.T) {
	arch := NewArchive()
	var s Series
	for e := uint32(1); e <= 100; e++ {
		s.SetAt(arch, "k", e, int64(e)*10)
	}
	for _, at := range []uint32{1, 7, 31, 32, 33, 64, 98, 99, 100} {
		if got, want := s.ValueAt(arch, "k", at), int64(at)*10; got != want {
			t.Errorf("epoch %d = %d, want %d", at, got, want)
		}
	}
}

// The package advertises int64 and be64 documents that a NEGATIVE value round-
// trips through rd64 (it packs the uint64 bit pattern). Every other test uses
// non-negative values, so the negative half of the range was unexercised — a
// "simplification" of be64 to a sign-losing shift would pass all of them and
// silently corrupt a signed series. Drive negatives, -1 (all ones), and MinInt64
// (the extreme bit pattern) through BOTH inline slots and the archive.
func TestNegativeValuesRoundTripThroughTheArchive(t *testing.T) {
	arch := NewArchive()
	var s Series
	const minI64 = int64(-9223372036854775808)
	vals := map[uint32]int64{}
	for e := uint32(1); e <= 50; e++ { // 50 distinct epochs → epochs 1..48 roll into the archive
		v := int64(e) - 100 // negative across the whole stretch
		switch e {
		case 10:
			v = minI64 // archived; the extreme two's-complement pattern
		case 20:
			v = -1 // archived; all ones
		case 49:
			v = minI64 // the inline prev slot
		}
		s.SetAt(arch, "k", e, v)
		vals[e] = v
	}
	for at := uint32(1); at <= 50; at++ {
		if got := s.ValueAt(arch, "k", at); got != vals[at] {
			t.Errorf("epoch %d = %d, want %d", at, got, vals[at])
		}
	}
}

// One key's history must never be read for another's. The keys share a tree,
// so this is the property that keeps that safe.
func TestOneKeysHistoryIsNotAnothers(t *testing.T) {
	arch := NewArchive()
	var a, b Series
	for e := uint32(1); e <= 40; e++ {
		a.SetAt(arch, "aaa", e, 1)
		b.SetAt(arch, "bbb", e, 2)
	}
	if got := a.ValueAt(arch, "aaa", 5); got != 1 {
		t.Errorf("aaa at 5 = %d, want 1", got)
	}
	if got := b.ValueAt(arch, "bbb", 5); got != 2 {
		t.Errorf("bbb at 5 = %d, want 2", got)
	}
	// A key with no history at all reads zero rather than its neighbour's.
	var c Series
	if got := c.ValueAt(arch, "aab", 5); got != 0 {
		t.Errorf("a key with no history read %d, want 0", got)
	}
}

// A key whose own history starts late must not read its neighbour's.
//
// The archive is one tree shared by every account, and the floor query walks
// DOWNWARDS from the page it wants. Without a lower bound at this key's own
// prefix it keeps walking past the bottom of its own range, straight into the
// pages of whatever key sorts below, and answers with a stranger's balance.
//
// It takes three points to see this at all, which is why the neighbour test
// above passes with the bound removed. A series with fewer answers from its
// inline slots for every epoch below itself — prev is zero and zero is the
// right answer — so the archive is never consulted and the bug stays hidden
// behind a correct answer arrived at by a different route.
func TestAKeyReadsZeroBeforeItsOwnHistoryNotItsNeighbours(t *testing.T) {
	arch := NewArchive()
	var below, late Series

	// The neighbour sorts lower and is long and dense.
	for e := uint32(1); e <= 40; e++ {
		below.SetAt(arch, "aaa", e, 77)
	}
	// The victim sorts higher and does not exist until much later. Three
	// points, so both inline slots are full and a query below them has no
	// choice but to reach the archive.
	late.SetAt(arch, "aab", 50, 5)
	late.SetAt(arch, "aab", 60, 6)
	late.SetAt(arch, "aab", 70, 7)

	if got := late.ValueAt(arch, "aab", 5); got != 0 {
		t.Errorf("a key read %d for an epoch before it held anything, want 0 — "+
			"that is the neighbouring key's balance, read across the boundary "+
			"between them", got)
	}
	// And its own archived history still answers, so the bound is not simply
	// refusing everything.
	if got := late.ValueAt(arch, "aab", 55); got != 5 {
		t.Errorf("aab at 55 = %d, want 5", got)
	}
}

// The separator in a PAGE key, which is a different claim from the one the key
// check makes — and the only one of the three separator mutations that is not an
// equivalent mutant.
//
// Below 2^24 a page key needs no separator at all, because a big-endian page
// number BEGINS with 0x00 and that leading zero does the separator's job by
// accident. Every test above runs there, so removing Sep from pageKey changes
// nothing any of them can see. Past 2^24 the first byte is no longer zero, the
// two keys' page ranges interleave, and a query answers with a stranger's value.
//
// It is reachable with legal inputs rather than a theoretical limit: epochs are
// a caller-supplied uint32 and this package deliberately never asks what one
// means ("the clock is policy"), so nothing here bounds them to the small
// numbers a 720-block epoch produces. A caller checkpointing per block, or per
// second, gets here. Cryptocourt's own ledger never would.
//
// The two mutations that ARE equivalent, recorded so they are not mistaken for
// gaps: lowering the scan's start bound from key+Sep to key admits only the
// point `key` itself, and no page is ever stored there; and widening its end
// bound from page at/PageEpochs to page `at` only makes the descent read more
// pages, since a page newer than at/PageEpochs holds no epoch <= at and the
// inner floor test skips what it finds.
func TestAPageKeyIsSeparatedFromTheNextKeysPages(t *testing.T) {
	// The bucket where a page number's leading byte stops being 0x00, plus one:
	// the range has to reach strictly past the neighbour's page-0 key.
	const leakPage = uint32(1)<<24 + 1
	const leakEpoch = leakPage * PageEpochs

	arch := NewArchive()
	var above, victim Series

	// "a\x01" sorts directly above "a" — a legal key, since only Sep is refused —
	// and its page keys begin with the same 0x01 a large page number does.
	for e := uint32(1); e <= 3; e++ {
		above.SetAt(arch, "a\x01", e, 77)
	}
	// The victim's own history is newer than the epoch it will ask about, so the
	// query has no choice but to reach the archive. Three points, so both inline
	// slots are full and the oldest has rolled.
	victim.SetAt(arch, "a", leakEpoch+56, 5)
	victim.SetAt(arch, "a", leakEpoch+1056, 6)
	victim.SetAt(arch, "a", leakEpoch+2056, 7)

	if got := victim.ValueAt(arch, "a", leakEpoch); got != 0 {
		t.Errorf("a key read %d for an epoch before it held anything, want 0 — that "+
			"is the NEXT key's value, reached because the page key stopped "+
			"separating the two ranges once the page number's leading byte was "+
			"no longer zero", got)
	}
	// And the bound is not simply refusing everything: its own archived point
	// still answers.
	if got := victim.ValueAt(arch, "a", leakEpoch+100); got != 5 {
		t.Errorf("the key's own archived history reads %d, want 5", got)
	}
}

// The second inline slot has to earn its keep.
//
// A holder who has changed twice must answer entirely from their own record,
// with nothing written to the archive at all. That is what two slots are for
// and it is the overwhelmingly common case; keeping only the newest value
// would push a point into the archive on every change after the first, which
// is a new key for most of the accounts that will ever exist.
func TestTwoChangesNeverReachTheArchive(t *testing.T) {
	arch := NewArchive()
	var s Series
	s.SetAt(arch, "k", 3, 100)
	s.SetAt(arch, "k", 9, 250)

	if got := arch.Size(); got != 0 {
		t.Fatalf("two changes bought %d archive keys, want 0 — the second slot "+
			"is not holding anything and every holder pays for history at their "+
			"second transfer", got)
	}
	// Both points still answer, which is the half that makes the saving real
	// rather than a saving made by forgetting.
	if got := s.ValueAt(arch, "k", 9); got != 250 {
		t.Errorf("newest = %d, want 250", got)
	}
	if got := s.ValueAt(arch, "k", 8); got != 100 {
		t.Errorf("between the points = %d, want 100", got)
	}
	if got := s.ValueAt(arch, "k", 2); got != 0 {
		t.Errorf("before either = %d, want 0", got)
	}

	// The third change is the one that pays for a key.
	s.SetAt(arch, "k", 12, 400)
	if got := arch.Size(); got != 1 {
		t.Errorf("the third change bought %d archive keys, want 1", got)
	}
}

// Page keys have to sort the way the numbers do.
//
// The floor query is a range scan over these keys and nothing else puts them
// in order. Little-endian passes every other test in this file, because pages
// 0, 1 and 2 sort correctly either way; it comes apart at 256, which is over
// eight thousand epochs of history — the better part of a year at an hour an
// epoch, and long after anybody would think to look here.
func TestPageKeysSortLikeTheNumbersThey(t *testing.T) {
	pairs := [][2]uint32{{0, 1}, {1, 2}, {2, 3}, {255, 256}, {256, 257}, {65535, 65536}}
	for _, p := range pairs {
		if lo, hi := be32(p[0]), be32(p[1]); !(lo < hi) {
			t.Errorf("be32(%d) does not sort below be32(%d), so beyond that "+
				"point the archive walks its pages out of order and a floor "+
				"query stops finding the floor", p[0], p[1])
		}
	}
}

// The clock only moves forward, and setAt says so rather than trusting it.
//
// A checkpoint written below the newest one pushes a stale value into the
// previous slot and moves e0 backwards, after which every historical query
// returns a plausible wrong number. Silence is the worst available option
// here: nothing fails, and the ledger is quietly wrong from then on.
func TestACheckpointCannotBeWrittenInThePast(t *testing.T) {
	arch := NewArchive()
	var s Series
	s.SetAt(arch, "k", 10, 100)

	// recover rather than uassert: setAt is called directly here, so this is
	// an ordinary panic and not the abort a crossing call would produce.
	defer func() {
		r := recover()
		if r == nil {
			t.Error("a checkpoint below the newest one was accepted, and from " +
				"here every historical answer this series gives is wrong")
		}
	}()
	s.SetAt(arch, "k", 9, 50)
}

// A page with nothing old enough in it is not the end of the search.
//
// Pages are buckets of EPOCHS, not buckets of checkpoints, so a holder who was
// inactive for a stretch has pages that are empty of anything early — and the
// page a query lands in may hold only points ABOVE the epoch being asked
// about. The scan has to keep walking down to an older page.
//
// Every other archive test in this file writes a checkpoint in every epoch,
// which makes every page dense and means the first page examined always
// answers. None of them can see a scan that gives up after one page.
func TestAQuietStretchKeepsTheScanWalking(t *testing.T) {
	arch := NewArchive()
	var s Series
	// Active, a long silence, then active again. Epoch 70 and epoch 90 share a
	// page; epoch 10 is two pages below.
	s.SetAt(arch, "k", 10, 111)
	s.SetAt(arch, "k", 90, 222)
	s.SetAt(arch, "k", 100, 333)
	s.SetAt(arch, "k", 110, 444)

	if got := s.ValueAt(arch, "k", 70); got != 111 {
		t.Errorf("during the quiet stretch = %d, want 111 — the scan stopped at "+
			"the first page it looked in, which held only later points, and "+
			"reported that the holder had nothing", got)
	}
	if got := s.ValueAt(arch, "k", 95); got != 222 {
		t.Errorf("just after the silence = %d, want 222", got)
	}
	if got := s.ValueAt(arch, "k", 5); got != 0 {
		t.Errorf("before anything at all = %d, want 0", got)
	}
}

// Every page holds one bucket and only that bucket.
//
// This is the thing that bounds the size of a single archive object, and no
// query can see it. Collapsing every checkpoint for a key into one page
// answers correctly — the scan still finds the floor — so the difference is
// invisible from outside. What it costs is that the object grows for as long
// as the account lives, and a query about one epoch deserialises a lifetime
// of them.
//
// Stated as a property of the contents rather than as a count of pages, so it
// means the same thing whatever PageEpochs is set to.
func TestEachPageHoldsOneBucket(t *testing.T) {
	arch := NewArchive()
	var s Series
	for e := uint32(1); e <= 100; e++ {
		s.SetAt(arch, "k", e, int64(e))
	}

	pages := 0
	arch.t.Iterate("", "", func(_ string, v any) bool {
		s := v.(*page).packed
		pages++
		first := rd32(s, 0)
		bucket := first / PageEpochs
		for i := 0; i < len(s)/12; i++ {
			e := rd32(s, i*12)
			if e/PageEpochs != bucket {
				t.Errorf("one page holds epoch %d alongside epoch %d, which "+
					"belong to different buckets — pages are not bounded, and "+
					"one archive object grows for as long as the account does",
					first, e)
				return true
			}
		}
		return false
	})
	// Without this the assertion above is satisfied by a single page holding
	// a single bucket, which is exactly what the bug looks like at small
	// sizes.
	if pages < 2 {
		t.Errorf("a hundred epochs of history produced %d archive page(s), so "+
			"either paging is not happening or this test never reached it", pages)
	}
}

// A key that contains the separator is refused rather than silently sharing a
// keyspace with its neighbour.
//
// This is the one rule this package puts on its callers, and it exists because
// breaking it is invisible: "a\x00b" and "a" would write pages into the same
// range, and a scan bounded by "a" would walk straight through both. The realm
// this came out of could not violate it — its keys are bech32 addresses — but
// a package does not get to assume the next caller has that property.
func TestAKeyMayNotContainTheSeparator(t *testing.T) {
	arch := NewArchive()
	var s Series

	func() {
		defer func() {
			if recover() == nil {
				t.Error("a key containing the separator was accepted for writing")
			}
		}()
		s.SetAt(arch, "a"+Sep+"b", 1, 100)
	}()

	// Reads too. A caller that got a bad key past the writer would otherwise
	// read a neighbour's history rather than being told.
	var real_ Series
	real_.SetAt(arch, "a", 1, 1)
	real_.SetAt(arch, "a", 2, 2)
	real_.SetAt(arch, "a", 3, 3)
	defer func() {
		if recover() == nil {
			t.Error("a key containing the separator was accepted for reading")
		}
	}()
	real_.ValueAt(arch, "a"+Sep+"b", 1)
}

// Value and Since report the newest point.
//
// Tested here rather than through the realm that calls them, which is exactly
// the gap a package with its own tests exists to close. A reusable package
// whose accessors are only covered by one caller is covered by accident.
//
// Since is the one worth pinning: it is how a caller asks whether an operation
// wrote anything, and a Since that reported the OLDER epoch would make a
// redundant write look like a no-op instead of catching it.
func TestValueAndSinceReportTheNewestPoint(t *testing.T) {
	arch := NewArchive()
	var s Series

	if got := s.Value(); got != 0 {
		t.Errorf("an untouched series holds %d, want 0", got)
	}
	if got := s.Since(); got != 0 {
		t.Errorf("an untouched series dates from epoch %d, want 0", got)
	}

	s.SetAt(arch, "k", 4, 100)
	if got, since := s.Value(), s.Since(); got != 100 || since != 4 {
		t.Errorf("after one point: %d from epoch %d, want 100 from 4", got, since)
	}

	// A second change inside the same epoch moves the value and not the epoch.
	s.SetAt(arch, "k", 4, 150)
	if got, since := s.Value(), s.Since(); got != 150 || since != 4 {
		t.Errorf("after a same-epoch update: %d from epoch %d, want 150 from 4",
			got, since)
	}

	// A later epoch moves both, and the point it displaced is still answerable.
	s.SetAt(arch, "k", 9, 200)
	if got, since := s.Value(), s.Since(); got != 200 || since != 9 {
		t.Errorf("after a later point: %d from epoch %d, want 200 from 9", got, since)
	}
	if got := s.ValueAt(arch, "k", 4); got != 150 {
		t.Errorf("the displaced point reads %d, want 150", got)
	}
}

// Epoch zero is refused, because zero already means something else.
//
// It is the sentinel for an unused second slot, and the two readings cannot
// both be true. A value written at epoch 0 leaves e1 == 0 after the next
// change; the roll after that reads that as an empty slot and drops the point
// instead of archiving it. Nothing fails at the time. Two changes later the
// archive is empty and every query below the newest two points answers zero,
// which for voting weight means a holder who was there from the start reads as
// having held nothing.
//
// The realm this package came out of could never have hit it — its clock is
// 1-based and says so. That assumption did not travel with the code, which is
// the hazard of moving code into a package and the reason this is a panic and
// not a sentence in a doc comment.
func TestEpochZeroIsRefused(t *testing.T) {
	arch := NewArchive()
	var s Series

	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("epoch 0 was accepted; the checkpoint it writes is " +
					"dropped two changes later without anything failing")
			}
		}()
		s.SetAt(arch, "k", 0, 100)
	}()

	// The same sequence one epoch higher, where it is the ordinary case and
	// every answer survives the roll.
	s.SetAt(arch, "k", 1, 100)
	s.SetAt(arch, "k", 4, 250)
	s.SetAt(arch, "k", 8, 400)
	for _, c := range []struct {
		at   uint32
		want int64
	}{{1, 100}, {2, 100}, {3, 100}, {4, 250}, {7, 250}, {8, 400}} {
		if got := s.ValueAt(arch, "k", c.at); got != c.want {
			t.Errorf("epoch %d = %d, want %d", c.at, got, c.want)
		}
	}
	if arch.Size() == 0 {
		t.Error("three changes archived nothing, so the roll this is about " +
			"never happened and the assertions above prove less than they look")
	}

	// Reading at zero is still meaningful and still allowed: it is the epoch
	// before anything, and the answer is that the series held nothing.
	if got := s.ValueAt(arch, "k", 0); got != 0 {
		t.Errorf("before the series existed = %d, want 0", got)
	}
}

// A key is bounded, and cannot be empty.
//
// The length matters more than it looks: a key is not stored once but is the
// prefix of every page key the series ever writes, so it multiplies by the
// pages a long-lived value accumulates — against a design whose whole argument
// is what a page costs.
//
// The empty key is the other end of the same rule about ranges. Its scan range
// is a prefix of every other key's, so it would walk into whatever sorts first
// and answer with somebody else's history — the same failure the separator
// rule exists to prevent, reached by supplying nothing rather than too much.
func TestAKeyIsBoundedAndNotEmpty(t *testing.T) {
	arch := NewArchive()

	long := ""
	for len(long) <= MaxKey {
		long += "k"
	}
	for _, c := range []struct {
		name string
		key  string
		want string
	}{
		{"too long", long, "too long"},
		{"empty", "", "empty"},
	} {
		func() {
			defer func() {
				r := recover()
				if r == nil {
					t.Errorf("a %s key was accepted", c.name)
					return
				}
				if msg, ok := r.(string); ok && !contains(msg, c.want) {
					t.Errorf("a %s key was refused with %q, want something "+
						"mentioning %q", c.name, msg, c.want)
				}
			}()
			var s Series
			s.SetAt(arch, c.key, 1, 1)
		}()
	}

	// Exactly at the bound is a key like any other, so this is a bound and not
	// an off-by-one that quietly costs a byte.
	at := ""
	for len(at) < MaxKey {
		at += "k"
	}
	var s Series
	s.SetAt(arch, at, 1, 100)
	if got := s.ValueAt(arch, at, 1); got != 100 {
		t.Errorf("a key of exactly MaxKey holds %d, want 100", got)
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// One key buys many checkpoints. That is the whole reason pages exist.
//
// TestEachPageHoldsOneBucket holds the UPWARD bound — a page cannot span more
// than one bucket — and says so as a property, which makes it true whatever
// PageEpochs is set to. That leaves the downward bound unguarded: set
// PageEpochs to 1 and every page holds exactly one checkpoint, every checkpoint
// buys its own key, and the property test still passes because one epoch
// trivially shares a bucket with itself.
//
// One key per checkpoint is the design this package was written to avoid. It is
// what OpenZeppelin's array-append costs on the EVM, and the reason that shape
// does not have to be inherited here.
//
// Deliberately NOT expressed in terms of PageEpochs. Dividing by the constant
// on both sides makes the expectation scale with the bug, which is how this
// class of test passes while measuring nothing — the realm's paging test
// carries the same warning for the same reason.
func TestOneKeyBuysManyCheckpoints(t *testing.T) {
	arch := NewArchive()
	var s Series
	const changes = 100
	for e := uint32(1); e <= changes; e++ {
		s.SetAt(arch, "k", e, int64(e))
	}

	pages := arch.Size()
	if pages == 0 {
		t.Fatal("a hundred checkpoints archived nothing, so this measures nothing")
	}
	// Eight times fewer keys than checkpoints is far below the thirty-two the
	// design intends and far above the one-for-one a broken one gives.
	if pages*8 >= changes {
		t.Errorf("%d checkpoints bought %d archive keys — a key is meant to buy "+
			"many, and this is close to buying one each", changes, pages)
	}

	// And the history is all still there, which is what makes the saving real
	// rather than a saving made by forgetting.
	for _, at := range []uint32{1, 17, 32, 33, 64, 99, 100} {
		if got, want := s.ValueAt(arch, "k", at), int64(at); got != want {
			t.Errorf("epoch %d reads %d, want %d", at, got, want)
		}
	}
}

// MaxKey is a hundred and twenty-eight, and the literal is the point.
//
// TestAKeyIsBoundedAndNotEmpty builds its over-long key from MaxKey itself, so
// it holds that A bound exists and follows wherever the constant goes. This
// holds WHERE. A key is the prefix of every page key its series ever writes, so
// raising it multiplies into all of them, and that is a decision somebody
// should have to make on purpose — including by editing this line.
func TestMaxKeyIsWhereItSays(t *testing.T) {
	if MaxKey != 128 {
		t.Errorf("MaxKey is %d. That may be right, but it is a change to what "+
			"every page key of every series costs, so it needs this line "+
			"changed with it rather than following along quietly", MaxKey)
	}
}

// ---------------------------------------------------------------- Trim -----

// trimFixture writes one change per given epoch under key, hot path included:
// the two NEWEST land in the inline slots, everything older pages out.
func trimFixture(t *testing.T, arch *Archive, key string, epochs []uint32) *Series {
	t.Helper()
	var s Series
	for i, e := range epochs {
		s.SetAt(arch, key, e, int64(i+1)*10)
	}
	return &s
}

func TestTrimDeletesOnlyWholePagesBelowTheHorizon(t *testing.T) {
	arch := NewArchive()
	// Pages: 0 (epochs 5, 20), 1 (40), 3 (100), plus inline (130, 140).
	s := trimFixture(t, arch, "k", []uint32{5, 20, 40, 100, 130, 140})
	if got := arch.Size(); got != 3 {
		t.Fatalf("fixture pages = %d, want 3 (0, 1, 3)", got)
	}
	// Horizon 170 (page 5): candidates are pages 0, 1, 3. The newest candidate
	// (page 3) is the floor for kept-window queries and must survive.
	if got := s; got == nil {
		t.Fatal("unreachable")
	}
	removed := arch.Trim("k", 170, 10)
	if removed != 2 {
		t.Errorf("removed = %d, want 2 (pages 0 and 1; page 3 spared)", removed)
	}
	if got := arch.Size(); got != 1 {
		t.Errorf("pages after trim = %d, want 1", got)
	}
	// Floor preservation: epoch 120 is INSIDE the kept window (>= horizon
	// would be 170; 120 is below — but the spared page must still answer the
	// kept-window floor). The value set at 100 and unchanged until 130 must
	// still answer for any at in [100, 129].
	if got := s.ValueAt(arch, "k", 120); got != 40 {
		t.Errorf("floor across the spared page = %d, want 40", got)
	}
	// Below the deleted pages the tier no longer answers: zero, the routing
	// signal — the caller asks the coarser tier there.
	if got := s.ValueAt(arch, "k", 30); got != 0 {
		t.Errorf("below the trimmed horizon = %d, want 0 (ask the daily tier)", got)
	}
}

func TestTrimKeepsAStraddlingPageWhole(t *testing.T) {
	arch := NewArchive()
	// Page 1 holds epochs 40 and 50; the horizon lands between them.
	s := trimFixture(t, arch, "k", []uint32{40, 50, 100, 110})
	if removed := arch.Trim("k", 45, 10); removed != 0 {
		t.Errorf("removed = %d, want 0 — page 1 straddles the horizon (45/32 == 40/32)", removed)
	}
	if got := s.ValueAt(arch, "k", 41); got != 10 {
		t.Errorf("entry below keepFrom inside a straddling page = %d, want 10", got)
	}
}

func TestTrimIsIdempotentAndBounded(t *testing.T) {
	arch := NewArchive()
	// Changes every 32 epochs: pages 1..6 filled one entry each, inline holds
	// the two newest.
	epochs := []uint32{32, 64, 96, 128, 160, 192, 224, 256}
	s := trimFixture(t, arch, "k", epochs)
	if got := arch.Size(); got != 6 {
		t.Fatalf("fixture pages = %d, want 6", got)
	}
	_ = s
	// maxPages=1 removes exactly the oldest candidate per call.
	if removed := arch.Trim("k", 300, 1); removed != 1 {
		t.Errorf("bounded trim removed = %d, want 1", removed)
	}
	if removed := arch.Trim("k", 300, 1); removed != 1 {
		t.Errorf("second bounded trim removed = %d, want 1", removed)
	}
	// Converges: repeated calls stop at the spared newest-below page.
	total := 0
	for i := 0; i < 10; i++ {
		total += arch.Trim("k", 300, 3)
	}
	if got := arch.Size(); got != 1 {
		t.Errorf("pages after convergence = %d, want exactly the spared one", got)
	}
	if total != 3 {
		t.Errorf("converged removals = %d, want 3 (5 candidates, 1 spared, 1+1 already gone)", total)
	}
	// Idempotent at the fixed point.
	if removed := arch.Trim("k", 300, 5); removed != 0 {
		t.Errorf("trim at the fixed point removed = %d, want 0", removed)
	}
}

func TestTrimIsolatesOtherKeys(t *testing.T) {
	arch := NewArchive()
	a := trimFixture(t, arch, "aa", []uint32{5, 40, 100, 130})
	b := trimFixture(t, arch, "ab", []uint32{5, 40, 100, 130})
	sizeBefore := arch.Size()
	arch.Trim("aa", 1000, 10)
	if got := b.ValueAt(arch, "ab", 60); got != 20 {
		t.Errorf("neighbour key's floor after trimming aa = %d, want 20", got)
	}
	if got := arch.Size(); got != sizeBefore-1 {
		// aa archived pages 0 and 1 (the two newest points are inline); the
		// newest candidate is spared, so exactly one page went. ab untouched.
		t.Errorf("pages after trimming aa = %d, want %d", got, sizeBefore-1)
	}
	_ = a
}

func TestTrimDegenerates(t *testing.T) {
	arch := NewArchive()
	var s Series
	// Never-archived series (inline only): nothing to remove.
	s.SetAt(arch, "k", 10, 1)
	s.SetAt(arch, "k", 20, 2)
	if removed := arch.Trim("k", 1000, 10); removed != 0 {
		t.Errorf("inline-only trim removed = %d, want 0", removed)
	}
	// Zero/low horizons and zero budget: no-ops.
	if removed := arch.Trim("k", 0, 10); removed != 0 {
		t.Errorf("keepFrom=0 removed = %d, want 0", removed)
	}
	if removed := arch.Trim("k", 1000, 0); removed != 0 {
		t.Errorf("maxPages=0 removed = %d, want 0", removed)
	}
	// A key that was never written: nothing, no panic.
	if removed := arch.Trim("ghost", 1000, 10); removed != 0 {
		t.Errorf("ghost-key trim removed = %d, want 0", removed)
	}
	defer func() {
		if recover() == nil {
			t.Error("Trim on a Sep-bearing key must panic like every entrypoint")
		}
	}()
	arch.Trim("bad\x00key", 10, 1)
}

// ------------------------------------------------------------- WalkDesc ----

func TestWalkDescVisitsArchivedNewestFirst(t *testing.T) {
	arch := NewArchive()
	s := trimFixture(t, arch, "k", []uint32{5, 40, 100, 130, 140})
	// Inline: 130, 140. Archived: 5, 40, 100.
	got := []uint32{}
	arch.WalkDesc("k", func(e uint32, v int64) bool {
		got = append(got, e)
		return false
	})
	want := []uint32{100, 40, 5}
	if len(got) != len(want) {
		t.Fatalf("visited %d entries, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("visit %d = epoch %d, want %d", i, got[i], want[i])
		}
	}
	// Early stop.
	n := 0
	arch.WalkDesc("k", func(e uint32, v int64) bool { n++; return true })
	if n != 1 {
		t.Errorf("early-stop visited %d, want 1", n)
	}
	// Values ride along and the inline points are the caller's to merge.
	if s.Value() != 50 {
		t.Errorf("inline cur = %d, want 50", s.Value())
	}
	// Key isolation: a neighbour's walk sees nothing of k.
	seen := 0
	arch.WalkDesc("kk", func(e uint32, v int64) bool { seen++; return false })
	if seen != 0 {
		t.Errorf("neighbour walk visited %d entries, want 0", seen)
	}
}
