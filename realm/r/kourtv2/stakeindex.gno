package kourtv2

// THE ADDRESS-FIRST STAKE INDEX — "which claims do I hold a position on", in one read.
//
// THE PROBLEM IT REMOVES. cs.stakers is keyed addr|side INSIDE each claimState
// (claim.gno), so it answers "who stakes this claim" and cannot answer "which claims
// does this address stake". A client had to visit every claim and look: web/index.html
// probed four reads per claim id over a window of the newest SCAN_DEPTH = 100 claims per
// court, and then told the holder "older positions and older pulls are not found
// either". On a court with more claims than that window, a holder could not see their
// own position at all. That is not a slow page, it is a page that cannot answer the
// question — about their own money.
//
// WHY A PACKED BUCKET AND NOT A ROW PER POSITION. Measured, on this tree: a row per
// (holder, claim, side) costs ~465 bytes and ~60,195 gas; the packed form costs ~57
// bytes and ~36,190 gas, so the naive shape is 8x the storage for a worse read. The
// mechanic is checkpoint.gno's, which argues it in writing: gno stores a []int64 as
// TypedValues at ~40 bytes an element and a string at one byte each, and appending to a
// *struct's field dirties exactly one object instead of doing a tree Set. It is also
// cheaper to READ — one object load rather than k lazily-loaded leaf values.
//
// This matters more than it sounds because the three expensive-looking writes a stake
// already makes are free in storage terms: observePools rebuilds 2,688 bytes of twap
// rings IN PLACE at zero net bytes, and advancePools, touch and accrue are int64 fields
// on objects already dirty. The only permanent storage a marginal position pays is its
// own stakers row, so an index row would have been +30% on it rather than the "marginal"
// the first draft of this claimed. The packed bucket is +6%.
//
// BUCKETED BY CLAIM ID so no single value grows without bound, exactly as
// checkpoint.gno pages by epoch. A holder with ten thousand positions would otherwise
// carry one 90 kB string that every stake loads whole.
//
// COMPLETE BY CONSTRUCTION, which is why there is no backfill and no coverage flag. The
// tree is created eagerly in the Court literal beside claims, records, locked and
// voteLocks, so every court has it from birth; claimState's own header records that this
// is fresh code with no live state. An index that only covered positions opened after
// some height would reproduce the failure above one layer down, and invisibly.
//
// ONE SPELLING OF SIDE. The entry's side byte is posKey's 'y'/'n' (stake.gno), not a
// second 0/1 encoding, because two encodings of one fact in two structures that must
// agree is the shape this design has spent a dozen commits pinning against.

// stakeIdxPage is how many claim ids share one packed bucket.
const stakeIdxPage = 64

// stakeIdxEntry is 8 big-endian bytes of claim id then one side byte.
const stakeIdxEntry = 9

// stakePageMax caps a single read, on the house rule that no read's cost may grow
// without bound with attacker-priced writes (stakeseries.gno's seriesRowCap, audit N3).
// The cap is on the HOLDER'S OWN positions rather than on all claims, which is the
// difference between this and the client scan it replaces.
const stakePageMax = 200

// stakeRow is one packed bucket of one holder's positions, in the order they were
// opened.
//
// APPEND-ONLY, WHICH IS A CONTRACT AND NOT AN ACCIDENT. Entries are never reordered or
// removed, so any prefix of a holder's list is stable across reads and an `offset` a
// client held from an earlier page still points at the same entry. Keeping each bucket
// sorted by claim id was the first design and it is worse: inserting a lower id shifts
// everything after it, so a client paging through positions would silently re-read or
// skip entries whenever the holder opened a position on an older claim. Buckets are
// visited in claim-id order; entries within a bucket are in the order they arrived.
type stakeRow struct {
	packed string // [claimID:8 BE][side:1 'y'|'n'] entries, 9 bytes each
}

func stakeIdxKey(who address, claimID uint64) string {
	return string(who) + beClaimKey(claimID/stakeIdxPage)
}

func sideByte(side int) string {
	if side == sideYES {
		return "y"
	}
	return "n"
}

// stakeIdxMine reports whether a key the prefix scan matched is one this code actually
// wrote for `who`.
//
// ONE DEFINITION, TWO CALLERS, and it exists because the second caller was written as a
// copy of the first: `address` is a bare string type with no length invariant, so a
// caller-supplied `who` can prefix-match every holder's buckets, and a walk that trusts
// the match reads other people's state. pruneVoteLocks learned the same lesson worse — it
// read an unparseable match as permission to DELETE. Two copies of that check is how the
// second one comes to disagree with the first.
func stakeIdxMine(pre, k string) bool { return len(k) == len(pre)+8 }

// indexPosition records that `who` has opened a position on this claim's side.
//
// Called from getPos's CREATION branch only, which fires exactly once per
// (holder, claim, side) — so entries are unique by construction and this needs no
// dedup and no read-before-write beyond finding the bucket.
func indexPosition(c *Court, claimID uint64, who address, side int) {
	k := stakeIdxKey(who, claimID)
	entry := beClaimKey(claimID) + sideByte(side)
	if v := c.stakeIdx.Get(k); v != nil {
		// Appending to the struct's field dirties one object; a tree Set here would
		// rewrite the leaf. checkpoint.gno's page does the same and says why.
		r := v.(*stakeRow)
		r.packed += entry
		return
	}
	c.stakeIdx.Set(k, &stakeRow{packed: entry})
}

// stakeIdxWalk calls fn for each of this holder's positions: buckets in claim-id order,
// entries within a bucket in the order they were opened. Returning true stops the walk.
func stakeIdxWalk(c *Court, who address, fn func(claimID uint64, side int) bool) {
	if c.stakeIdx == nil {
		return
	}
	pre := string(who)
	c.stakeIdx.Iterate(pre, pre+"\xff", func(k string, v any) bool {
		if !stakeIdxMine(pre, k) {
			return false
		}
		r, ok := v.(*stakeRow)
		if !ok {
			return false
		}
		for i := 0; i+stakeIdxEntry <= len(r.packed); i += stakeIdxEntry {
			side := sideNO
			if r.packed[i+8] == 'y' {
				side = sideYES
			}
			if fn(beClaimID(r.packed[i:i+8]), side) {
				return true
			}
		}
		return false
	})
}

// stakeIdxCount is how many entries a holder has, counted from the packed LENGTHS
// rather than by visiting entries.
//
// The house's *Size readers are O(1) tree Size() calls (strips.gno's StripSize), which
// this cannot be — c.stakeIdx.Size() counts BUCKETS, not positions. Summing len/9 per
// bucket is the next best thing and the reason the packed form pays off twice: the cost
// is O(the holder's own buckets), one object load per 64 claim ids, so a holder with a
// thousand positions costs sixteen loads rather than a thousand callbacks. The first
// version of StakedSize walked every entry, which made the one reader that exists to
// report completeness the one read whose cost grew with the holder's history.
func stakeIdxCount(c *Court, who address) int {
	if c.stakeIdx == nil {
		return 0
	}
	n, pre := 0, string(who)
	c.stakeIdx.Iterate(pre, pre+"\xff", func(k string, v any) bool {
		if !stakeIdxMine(pre, k) {
			return false
		}
		if r, ok := v.(*stakeRow); ok {
			n += len(r.packed) / stakeIdxEntry
		}
		return false
	})
	return n
}

// StakedSize is how many positions this holder has ever opened in this court.
//
// Positions are never removed — there is no stakers.Remove anywhere in this realm, and
// the persistence is deliberate: the row IS the participant test, and conviction
// survives a full unstake so a claim with an unpaid reward must stay findable. So this
// counts LIFETIME positions, and StakedPage reports each one's live stake beside it so a
// client can tell an open position from a settled one without a second read.
func StakedSize(courtSlug string, who address) int {
	if !who.IsValid() {
		return 0
	}
	return stakeIdxCount(mustCourt(courtSlug), who)
}

// StakedPage lists this holder's positions in the stable order described on stakeRow —
// bucket by claim id, then arrival within a bucket.
//
//	"c:<claimID>:<side>:<liveStake>;c:<claimID>:<side>:<liveStake>;…"
//
// side is 0 for YES and 1 for NO, matching sideYES/sideNO. liveStake is what is staked
// NOW, which is zero for a position withdrawn in full — the entry is still listed
// because its conviction may still be owed.
//
// Read with StakedSize to tell a partial page from a complete one. limit is clamped to
// stakePageMax; a limit of zero or less means "the cap".
//
// CONVICTION IS NOT HERE, and the reason on record was wrong, so here is the measured
// one. The old note said including it would cost extra work; it would not. ConvictionOf
// already settles to now WITHOUT mutating — a transient copy against a preview of the
// era integral, which its own comment explains — so inside this walk the marginal cost
// per position is arithmetic on a claimState and a stakePos this function has ALREADY
// loaded. It is the client's alternative that is expensive: web/index.html's
// positionOf() is four reads per claim (two StakeOf, two ConvictionOf), each re-doing
// the court, claim and position lookups this page did once. Counted for a holder with N
// positions in one court: 2 + 4N reads today against 2 with conviction here, and TWO of
// those four already duplicate the liveStake this page returns and the me-page throws
// away.
//
// What actually blocks it is the FORMAT CONTRACT, not the cost. parseStaked skips any
// record whose arity is not four, so appending a fifth field would make the deployed
// overlay drop every row and show a holder nothing — a blank me-page is a worse failure
// than a few extra reads. The compatible shape is a second record type ("v:<claimID>:
// <side>:<conv>") which today's parser ignores by design, and that is a coordinated
// realm+client change: worth doing, not worth doing half, and not worth shipping the
// realm half alone since nothing improves until the client reads it.
func StakedPage(courtSlug string, who address, offset, limit int) string {
	if !who.IsValid() {
		return ""
	}
	if limit <= 0 || limit > stakePageMax {
		limit = stakePageMax
	}
	c := mustCourt(courtSlug)
	out, seen, sent := "", 0, 0
	stakeIdxWalk(c, who, func(claimID uint64, side int) bool {
		if seen < offset {
			seen++
			return false
		}
		seen++
		// cs.stakers.Get, never getPos — getPos ALLOCATES a position on access, and a
		// read that persists lets anyone grow the realm for free.
		var live int64
		if cv := c.claims.Get(beClaimKey(claimID)); cv != nil {
			if pv := cv.(*claimState).stakers.Get(posKey(who, side)); pv != nil {
				live = pv.(*stakePos).stake
			}
		}
		out += ";c:" + itoa(int64(claimID)) + ":" + itoa(int64(side)) + ":" + itoa(live)
		sent++
		return sent >= limit
	})
	if out == "" {
		return ""
	}
	return out[1:]
}
