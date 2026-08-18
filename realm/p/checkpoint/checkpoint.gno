// Package checkpoint remembers what a number used to be.
//
// A Series is one value's history. It answers what that value held during a
// past epoch, which is the question governance asks: voting weight has to be
// read as of the moment a question was put, or it can be borrowed for the
// length of one transaction and voted twice.
//
// It was written for a token's balances and its total supply, and there is
// nothing about it that knows what a token is. Anything a realm wants to look
// back at — a fee, a quorum, a member count — is a Series.
//
// # What it costs
//
// One fact about gno shapes the whole thing: storage deposit is charged per
// OBJECT, on the DELTA of its encoded size (gnovm/pkg/gnolang/store.go,
// LastObjectSize, at 100ugnot/byte). A field added to a record that was going
// to be written anyway is paid for once, at creation, and costs nothing on
// every write after. On the EVM every extra word touched is a fresh SSTORE
// forever, which is the entire reason OpenZeppelin's ERC20Votes appends to an
// array per block — and the reason that shape does not have to be inherited.
//
// So: two points inline, the rest paged into an archive. The overwhelmingly
// common query is answered without touching the archive at all, and a value
// that changes several times within one epoch coalesces into a single update
// of a record already being written.
//
// # Epochs, not blocks
//
// The caller supplies the epoch and this package never asks what one is. That
// is deliberate — the clock is policy. Quantising to something coarser than a
// block is what makes the cost work, because a checkpoint per block maximises
// the one thing gno charges dearly for, a brand new key.
//
// It also turns the anti-flash-loan property from a convention into an
// invariant, if the caller refuses to answer for the current epoch: a
// transaction cannot outlive its block and a block cannot outlive its epoch,
// so a borrowed balance cannot be voted and returned. This package cannot
// enforce that, because it does not know what time it is. It is the caller's
// half of the bargain and worth writing down where the caller will read it.
package checkpoint

import (
	"strings"

	bptree "gno.land/p/nt/bptree/v0"
)

// Sep separates a caller's key from this package's own suffix.
//
// Exported because a caller sharing one Archive between several keyspaces
// usually wants the same byte for its own compound keys, and two constants
// with the same value in different files eventually disagree.
//
// A key may not contain it. That is checked rather than documented, because
// the failure is silent: one key's range scan would reach into another's and
// return a plausible number belonging to somebody else.
const Sep = "\x00"

// MaxKey bounds a key.
//
// A key is not stored once. It is the prefix of every page key this series ever
// writes, so its length multiplies by the number of pages a long-lived value
// accumulates — and the pages are what the design buys with the deposit it
// saves elsewhere.
//
// Exported so a caller can check before calling rather than discover by
// panicking. A hundred and twenty-eight is room for a bech32 address twice over
// with a separator between, which is the largest sensible key the realm this
// came out of could form.
const MaxKey = 128

// PageEpochs is how many epochs one archive page covers.
//
// It bounds the archive in both directions, and both matter.
//
// Downwards: one new key buys this many checkpoints instead of one, which is
// what keeps the marginal cost of history near zero.
//
// Upwards: a page cannot grow past one bucket. Keeping every checkpoint for a
// key in a single page would be CHEAPER in keys — one per key, forever — and
// that is exactly its problem. Appending stays cheap, since the deposit is
// charged on the size delta, but the whole object is deserialised to answer
// anything about it. A key with years behind it would pay to load all of them
// to answer about one epoch.
const PageEpochs = uint32(32)

// Archive is the shared store the older points live in.
//
// One Archive can hold any number of Series, told apart by key. Bounding each
// scan to its own key's prefix is what keeps them apart, and it is the reason
// a key may not contain Sep.
type Archive struct {
	t *bptree.BPTree
}

// NewArchive returns an empty archive.
func NewArchive() *Archive { return &Archive{t: bptree.NewBPTree32()} }

// Size is the number of pages stored, across every key.
//
// Exported for the caller that wants to assert what its own history costs —
// the count is the number of KEYS bought, which is the expensive quantity.
func (a *Archive) Size() int { return a.t.Size() }

// page is one bucket of archived checkpoints for one key, ascending.
//
// One packed string, not slices: gno stores a []int64 or []uint32 as an array of
// TypedValues at ~40 bytes an element, but a string (like a []byte) at one byte
// each. So the entries pack big-endian into a single string — 4 bytes of epoch
// then 8 of value, 12 bytes per entry — which is ~3x smaller than the two-slice
// form and is what the archive's locked deposit is charged on. Appending
// reassigns this *page's field (no tree Set), so a write still dirties exactly one
// object.
type page struct {
	packed string // ascending [epoch:4 BE][value:8 BE] entries, 12 bytes each
}

// Series is one value's history: the two most recent points inline, everything
// older in the archive.
//
//	at >= e0        -> cur
//	e1 <= at < e0   -> prev
//	at < e1         -> the archive
//
// e1 == 0 means the second slot was never used, and prev is then zero, which
// is the correct answer for every epoch below e0 — so a key that has held a
// steady value since it was created never touches the archive at all. That
// case is the overwhelming majority of queries.
//
// That sentinel is why epochs are 1-BASED and SetAt refuses zero. Zero has to
// mean "before this series existed" and cannot also be an epoch somebody wrote
// in, or the two readings collide: a value written at epoch 0 leaves e1 == 0
// after the next change, the roll after that reads it as an empty slot, and the
// point is dropped instead of archived. Silently — the archive stays empty and
// every query below the newest two points answers zero.
//
// The realm this came out of never could have hit it, because its clock is
// 1-based for exactly this reason. The assumption did not travel with the code,
// which is the whole hazard of moving code into a package.
//
// Hold it as a VALUE field in whatever record the caller already persists.
// Mutating it then dirties only that record. A pointer would make it a second
// object, which is a second key, which is the cost this design exists to
// avoid.
type Series struct {
	cur  int64
	prev int64
	e0   uint32
	e1   uint32
}

// Value is what the series holds now, without consulting anything.
func (s *Series) Value() int64 { return s.cur }

// Prev is the older of the two inline points: its epoch and value. A zero
// epoch means that slot was never used (the series has at most one point).
// Callers assembling a full history read the archive, then Prev, then
// Since/Value — ascending by construction, since points only roll outward.
func (s *Series) Prev() (uint32, int64) { return s.e1, s.prev }

// Since is the epoch the current value has held from.
//
// Useful for asserting that something did NOT write — a caller that expects an
// operation to be free can check this did not move.
func (s *Series) Since() uint32 { return s.e0 }

// SetAt records v from epoch e onward, rolling whatever falls out of the two
// inline slots into the archive.
//
// e must be at least 1, and must not be below the newest epoch already
// recorded. Callers pass a chain height quantised to an epoch, which only ever
// increases.
func (s *Series) SetAt(a *Archive, key string, e uint32, v int64) {
	mustBeUsable(key)
	if e == 0 {
		// Refused rather than documented, because the damage is silent and
		// arrives two changes later. See the note on Series: zero is the
		// sentinel for an unused slot, so a real checkpoint written there is
		// read as an empty one and dropped on the roll after next.
		panic("checkpoint: epochs are 1-based; 0 means before the series existed")
	}
	if e < s.e0 {
		// The clock went backwards. Impossible on a chain, so this means the
		// caller is not on one — a test harness that resets the height between
		// cases produces exactly this.
		//
		// Worth a panic rather than a comment because the failure it prevents
		// is invisible: a checkpoint written below the newest one pushes a
		// stale value into the previous slot and moves e0 backwards, and every
		// later query returns a plausible, wrong number.
		panic("checkpoint: the clock went backwards")
	}
	if e == s.e0 {
		// The second and later change within one epoch. No new key, and the
		// object was going to be written anyway: free, in the sense that
		// matters.
		s.cur = v
		return
	}
	if s.e1 != 0 {
		a.append(key, s.e1, s.prev)
	}
	s.prev, s.e1 = s.cur, s.e0
	s.cur, s.e0 = v, e
}

// ValueAt answers what the series held during epoch at.
//
// Zero for an epoch before the series began, which is exact rather than a
// miss: the key held nothing then.
func (s *Series) ValueAt(a *Archive, key string, at uint32) int64 {
	if at >= s.e0 {
		return s.cur
	}
	// Covers e1 == 0 as well, where prev is zero and zero is exact.
	if at >= s.e1 {
		return s.prev
	}
	mustBeUsable(key)
	out := int64(0)
	// Bounded below by this key's own prefix so the descent cannot walk back
	// into the previous key's pages. ReverseIterate is [start, end] descending
	// with end inclusive (bptree tree.gno, "ReverseIterate calls cb"), which is
	// the floor query — no binary search of our own.
	a.t.ReverseIterate(key+Sep, pageKey(key, at/PageEpochs), func(_ string, pv any) bool {
		s := pv.(*page).packed
		for i := len(s)/12 - 1; i >= 0; i-- {
			off := i * 12
			if rd32(s, off) <= at {
				out = rd64(s, off+4)
				return true
			}
		}
		// Pages bucket EPOCHS, not checkpoints, so the page a query lands in
		// may hold only points later than the epoch being asked about. Keep
		// walking down; the answer is in an older page.
		return false
	})
	return out
}

func (a *Archive) append(key string, e uint32, v int64) {
	pk := pageKey(key, e/PageEpochs)
	entry := be32(e) + be64(v) // 12 bytes: epoch then value
	if pv := a.t.Get(pk); pv != nil {
		p := pv.(*page)
		// Reassign the field on the pointer the tree already holds. No Set, so the
		// leaf and its whole inner path stay clean and the write dirties only this
		// *page. Entries arrive ascending by construction, so there is nothing to
		// sort.
		p.packed += entry
		return
	}
	a.t.Set(pk, &page{packed: entry})
}

// mustBeUsable refuses a key that would collide with another key's pages.
//
// A p/ package's callers are not the people who wrote it, so this is a case
// that can happen rather than defensive decoration. The cost is a scan of a
// short key against the tree operations it precedes, which is nothing.
func mustBeUsable(key string) {
	if strings.Contains(key, Sep) {
		panic("checkpoint: a key may not contain checkpoint.Sep")
	}
	if len(key) > MaxKey {
		panic("checkpoint: that key is too long")
	}
	if key == "" {
		// An empty key is not wrong so much as unusable: its page range is a
		// prefix of every other key's, so it would scan into whatever sorts
		// first. Refused for the same reason as one containing the separator.
		panic("checkpoint: a key may not be empty")
	}
}

// be32 is big-endian and fixed width, so byte order is numeric order.
//
// The floor query is a range scan over these keys and nothing else puts them
// in order. Little-endian would sort pages 0, 1 and 2 correctly and come apart
// at 256.
func be32(u uint32) string {
	b := [4]byte{byte(u >> 24), byte(u >> 16), byte(u >> 8), byte(u)}
	return string(b[:])
}

// be64 packs an int64 value big-endian (via its uint64 bit pattern, so a negative
// value round-trips through rd64). Together with be32 it forms a page's 12-byte
// entry.
func be64(v int64) string {
	u := uint64(v)
	var b [8]byte
	for i := 7; i >= 0; i-- {
		b[i] = byte(u & 0xff)
		u >>= 8
	}
	return string(b[:])
}

// rd32 and rd64 read a packed entry's epoch and value back from a page string.
func rd32(s string, off int) uint32 {
	return uint32(s[off])<<24 | uint32(s[off+1])<<16 | uint32(s[off+2])<<8 | uint32(s[off+3])
}

func rd64(s string, off int) int64 {
	var u uint64
	for i := 0; i < 8; i++ {
		u = (u << 8) | uint64(s[off+i])
	}
	return int64(u)
}

func pageKey(key string, page uint32) string { return key + Sep + be32(page) }

// Trim deletes archive pages of key that lie entirely below keepFrom — except
// the newest such page — oldest-first, at most maxPages per call. It returns
// how many pages were removed.
//
// The exception is the floor-preservation invariant: a value set below the
// horizon and unchanged since is still the correct answer for epochs INSIDE
// the kept window, and its floor entry lives in the newest all-below page.
// Sparing that one page keeps ValueAt exact at and above keepFrom through
// every intermediate state of a bounded, multi-call trim. A page straddling
// the horizon is never a candidate (it is not entirely below), so up to
// PageEpochs-1 epochs of over-retention are kept deliberately.
//
// Deletion frees the page object's bytes; on chains with storage deposits the
// locked amount is released by the same mechanism that charged it. Trim never
// touches the two inline points — recent reads stay exact by construction.
//
// The walk is collect-then-remove because the tree forbids mutation from an
// iteration callback, and it is bounded to maxPages+1 keys of collection, so
// a call's cost is a constant of the caller's choosing.
func (a *Archive) Trim(key string, keepFrom uint32, maxPages int) int {
	mustBeUsable(key)
	if maxPages <= 0 {
		return 0
	}
	// Candidates are pages strictly below the horizon's own page: page P
	// covers epochs [P*PageEpochs, P*PageEpochs+PageEpochs-1], so P <
	// keepFrom/PageEpochs puts every epoch in P below keepFrom. Iterate is
	// [start, end) ascending, which is exactly the candidate range.
	end := pageKey(key, keepFrom/PageEpochs)
	keys := []string{}
	a.t.Iterate(key+Sep, end, func(k string, _ any) bool {
		keys = append(keys, k)
		return len(keys) >= maxPages+1
	})
	var del []string
	if len(keys) == maxPages+1 {
		// The budget's worth, oldest-first. The newest collected candidate —
		// and anything beyond it the bounded walk never reached — survives,
		// so the newest all-below page survives.
		del = keys[:maxPages]
	} else if len(keys) > 0 {
		// The walk exhausted the candidates: the last one collected IS the
		// newest all-below page. Spare it.
		del = keys[:len(keys)-1]
	}
	for _, k := range del {
		a.t.Remove(k)
	}
	return len(del)
}

// WalkDesc visits key's ARCHIVED checkpoints newest-first, stopping when fn
// returns true. The two inline points are the Series' own fields and are not
// visited — a caller assembling a history appends them itself (they are always
// newer than anything archived, because points only ever roll OUT of the
// inline slots). Bounded by the key's page prefix like every other walk here.
func (a *Archive) WalkDesc(key string, fn func(e uint32, v int64) bool) {
	mustBeUsable(key)
	a.t.ReverseIterate(key+Sep, pageKey(key, ^uint32(0)), func(_ string, pv any) bool {
		s := pv.(*page).packed
		for i := len(s)/12 - 1; i >= 0; i-- {
			off := i * 12
			if fn(rd32(s, off), rd64(s, off+4)) {
				return true
			}
		}
		return false
	})
}
