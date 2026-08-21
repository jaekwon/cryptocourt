// The moderator-replacement election (MODERATION.md §3.1) — textbook approval
// voting, specified carefully.
//
// This mechanism broke in FOUR consecutive audit rounds (latch-camp →
// per-proposer-sybil → bond-auction ballot-veto → majority-gate + candidate-
// cap). Every break had the same shape: a SCARCE EXCLUDABLE SLOT that capital
// could win in order to keep a proposal off the vote. The converged design has
// none:
//
//   - the ballot is UNCAPPED — bonds ADD candidates and can never exclude one;
//   - "retain the current set" is an EXPLICIT APPROVABLE LINE, not a silent
//     zero-approval default (an absolute bps threshold is meaningless in
//     approval voting, which has no yes+no denominator, and it made abstention
//     a vote for the incumbent: a 31% captured minority beat a 69% majority);
//   - install is argmax-approval OVER RETAIN plus a margin and a quorum;
//   - the bond refunds ONLY on install, so self-approving junk always costs;
//   - β is frozen below the quorum floor AND the bond is clamped to that floor
//     at runtime, so affording the bond is never tighter than winning the vote.
//
// Resolution is deliberately TWO-PASS: pass 1 finds the max and retain, pass 2
// picks the earliest-nominated candidate within the margin of the max. A
// single-pass running argmax gets the tie-break wrong and would let a whale
// install a late one-address-swapped DECOY of an honest set.
package kourtv2

import (
	"chain"
	"strconv"

	grc20votes "gno.land/p/kourt/grc20votes/v0"
	bptree "gno.land/p/nt/bptree/v0"
)

const (
	// nominationWindow is load-bearing (round-7 R4): the per-court latch makes
	// it a temporal-griefing surface, so it must be long enough that a defender
	// can always nominate INTO a griefer's open election rather than having to
	// win a race. One day.
	nominationWindow = int64(17_280)

	// maxBallotLines bounds the work ResolveElection must do in ONE transaction.
	// Without it the failure mode is permanent, not merely slow: the bond is
	// pinned at OpenElection while the curve keeps selling for the whole
	// nomination window, so an attacker can fund far more lines than the bond
	// implied, and a resolve that cannot fit in a tx leaves `resolved == false`
	// — which refuses every future election on that court forever AND strands
	// every poster's bond. The cap is deliberately far above honest use, and it
	// is NOT the r6 "excludable slot": a shut-out nominator opens the next
	// election themselves rather than being kept off a vote that proceeds.
	maxBallotLines = 64

	// electionBondBps is β: the per-candidate bond as a fraction of supply,
	// floored at flagMinCC. Frozen — never an owner knob. Its ceiling is
	// checked against the quorum floor at deploy (mustElectionInvariants).
	electionBondBps = int64(50) // 0.5% of supply, vs the 5% quorum floor
)

// mustElectionInvariants is the two-sided deploy gate on β (round-7 R1): a
// floor keeping the bond meaningful, and a ceiling keeping it strictly below
// the quorum floor — so any coalition that can clear quorum can trivially
// afford to field one nominator, and no court is ever challenge-proof by price.
//
// A constant gate can only police the RATIO arm, and only if both sides are
// measured on the same base. Two runtime terms escape it entirely — the
// absolute flagMinCC minimum, and (before this fix) a bond quoted on raw
// supply against a floor quoted on votable weight. electionBond now closes
// both at runtime; see its comment. This gate is the ratio arm alone.
//
// ITS THREE PANICS ARE IN NO MUTATION BATCH, AND THAT IS DELIBERATE. Each
// compares package CONSTANTS, and init() calls this function on every package
// load — including every test load — so the relationship is already enforced on
// every run by the guard itself: violate it and the package does not load.
// Deleting a panic here is unobservable precisely BECAUSE the constants satisfy
// it, so the mutation survives correctly rather than revealing a gap, and a test
// restating the same comparison would duplicate init() instead of adding a
// check. It is not in known-gaps either: that file asserts a gap a test could
// someday close, and this one never can — v0.40's rule, the same one that keeps
// ResetModSet's clear out of both batches. If you change electionBondBps,
// quorumSupplyBps or nominationWindow, THIS is what stops you.
func mustElectionInvariants() {
	if electionBondBps <= 0 {
		panic("kourtv2: the election bond must be positive")
	}
	if electionBondBps >= quorumSupplyBps {
		panic("kourtv2: the election bond must stay below the quorum floor — else affording the ballot is harder than winning the vote (incumbency lock by price)")
	}
	if nominationWindow < 17_280 {
		panic("kourtv2: the nomination window must be at least a day")
	}
}

func init() { mustElectionInvariants() }

// modCandidate is a pre-registered candidate moderator set. Registration is
// separate from nomination so the appeal/ballot carries a short ID rather than
// an address list, and so the SAME primitive serves the meta court's
// `mod:setmods` verb (the peer install path).
type modCandidate struct {
	id      uint64
	members []address // canonical: sorted and deduped
	m       int
	by      address
	at      int64
}

// ballotLine is one candidate's line on an open ballot.
type ballotLine struct {
	candID uint64
	weight int64
	nomAt  int64
	bond   int64
	poster address
}

// election is one court's open ballot.
type election struct {
	seq         uint64
	epoch       uint32 // weights pinned at nomination-window open
	openedAt    int64
	nominateEnd int64
	voteEnd     int64
	floor       int64 // quorum floor AND margin floor (escrow-netted 5%)
	bond        int64 // per-candidate bond, fixed at open
	lines       *bptree.BPTree
	retainW     int64
	nominators  *bptree.BPTree // addr -> true (one nomination per address)
	voters      *bptree.BPTree // addr -> the weight it voted at (see approve)
	approvals   *bptree.BPTree // be64(candID)|addr -> true (per-line dedup)
	turnout     int64
	resolved    bool
}

// electionFloor is the quorum AND margin floor: 5% of VOTABLE weight, netting
// out the escrow. Netting matters — on an active court most CC sits in escrow
// as stake/bonds, and a floor of 5% of RAW supply can exceed all votable weight,
// making the electorate's own remedy unreachable exactly where it is needed.
func electionFloor(c *Court, at uint32) int64 {
	f := mulDiv128(votableAt(c, at), quorumSupplyBps, grc20votes.Bps)
	if f < 1 {
		f = 1
	}
	return f
}

// votableAt is supply net of the escrow — the base BOTH the floor and the bond
// must be measured on. Quoting one on raw supply and the other on votable is
// not a rounding difference: it multiplies the bond/floor ratio by
// supply/votable, which on a busy court is unbounded.
func votableAt(c *Court, at uint32) int64 {
	v := c.coin.PastTotal(at) - c.coin.PastVotes(c.escrow, at)
	if v < 0 {
		v = 0
	}
	return v
}

// electionBond is β of VOTABLE weight, then clamped to never exceed the
// election floor. Both clamps repair a break in the deploy invariant that
// mustElectionInvariants structurally cannot see:
//
//   - BASE MISMATCH. The bond used to be quoted on raw supply while the floor
//     nets the escrow, making the true ratio (β/q)·(supply/votable). β/q is
//     1/10, so the invariant inverted on any court holding more than 90% of its
//     CC as stake and bonds — i.e. exactly the mature, active courts whose
//     electorate most needs the remedy, and only those. Same base now.
//   - ABSOLUTE FLOOR. flagMinCC (1 CC) is a constant, so on a court with less
//     than 20 CC votable it is the binding term and exceeds 5% of votable
//     outright. The clamp lets the floor win: a spam bar priced above winning
//     the vote is the incumbency-lock-by-price the invariant forbids, and the
//     bar is not needed there anyway — filling all 64 ballot lines at 5% of
//     votable each costs 3.2× the court's entire votable weight.
func electionBond(c *Court, at uint32) int64 {
	b := mulDiv128(votableAt(c, at), electionBondBps, grc20votes.Bps)
	if b < flagMinCC {
		b = flagMinCC
	}
	if f := electionFloor(c, at); b > f {
		b = f
	}
	return b
}

// RegisterModCandidate stores a candidate moderator set and returns its id.
// Permissionless (it is only a named address list; nominating it costs the
// bond). Members are canonicalized — sorted and deduped — so a mere reordering
// is not a distinct candidate, which is half of the anti-decoy rule.
func RegisterModCandidate(cur realm, courtSlug string, m int, members ...address) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	canon := canonicalMembers(members)
	if len(canon) == 0 {
		panic("kourtv2: a candidate set may not be empty")
	}
	if m < 1 || m > len(canon) {
		panic("kourtv2: the m-of-n threshold must be in 1..n")
	}
	if cm.candidates == nil {
		cm.candidates = bptree.NewBPTree32()
	}
	cm.candSeq++
	id := cm.candSeq
	cm.candidates.Set(beClaimKey(id), &modCandidate{
		id: id, members: canon, m: m, by: who, at: heightNow(),
	})
	return id
}

// canonicalMembers sorts and dedupes an address list (insertion sort — a
// moderator set is small, and gno needs determinism, not speed).
func canonicalMembers(in []address) []address {
	// The size cap is enforced HERE because this is the one chokepoint both
	// entry points share (AppointMods and RegisterModCandidate). Uncapped, a
	// set could be grown until currentSetID — which concatenates every member
	// into one string and therefore costs O(n²) — no longer fits in a
	// transaction. currentSetID sits on the SUSPEND path, so that is not merely
	// slow: it would blunt the global DAO's and the meta court's emergency
	// hammer against exactly the set that made itself too big to suspend.
	if len(in) > maxModSetSize {
		panic("kourtv2: a moderator set is at most 32 members")
	}
	out := []address{}
	for _, a := range in {
		if a == "" {
			panic("kourtv2: a moderator address may not be zero")
		}
		// The zero check above is kept SEPARATE and FIRST because it names the
		// commonest mistake precisely. This one catches everything else: the
		// argument conversion that turns a transaction's strings into VM values
		// does NOT validate bech32 — its string arm simply sets the value — so a
		// mistyped address arrives here intact, gets canonicalised, and is SEATED
		// as a moderator. The set then carries a member nobody holds the key to,
		// and its m-of-n threshold counts that member: an m-of-2 set with one
		// typo can never reach its own threshold again, which is the same
		// permanent-freeze shape the {A,A,B} m=3 case produces one guard below.
		// Both entry points funnel through here, so this is the only place it has
		// to be said.
		if !a.IsValid() {
			panic("kourtv2: not a valid address for a moderator set")
		}
		dup := false
		for _, b := range out {
			if b == a {
				dup = true
				break
			}
		}
		if dup {
			continue
		}
		pos := len(out)
		out = append(out, a)
		for pos > 0 && out[pos-1].String() > a.String() {
			out[pos] = out[pos-1]
			pos--
		}
		out[pos] = a
	}
	return out
}

func (cm *courtMod) mustCandidate(id uint64) *modCandidate {
	if cm.candidates == nil {
		panic("kourtv2: no such candidate")
	}
	v := cm.candidates.Get(beClaimKey(id))
	if v == nil {
		panic("kourtv2: no such candidate")
	}
	return v.(*modCandidate)
}

// OpenElection opens the ballot AND nominates the opener's candidate in one
// call. Opening is deliberately NOT free: a free open would let a griefer burn
// a court's governance for ~15 days a cycle (1d nomination + 7d vote + 7d
// cooldown) at zero cost. Every election therefore starts with one bonded
// candidate.
func OpenElection(cur realm, courtSlug string, candidateID uint64) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	if cm.election != nil && !cm.election.resolved {
		panic("kourtv2: an election is already open for this court")
	}
	now := heightNow()
	if now < cm.electionCooldownUntil {
		panic("kourtv2: this court is in its post-election cooldown")
	}
	cand := cm.mustCandidate(candidateID)
	at := c.coin.Epoch() - 1
	cm.electionSeq++
	e := &election{
		seq:         cm.electionSeq,
		epoch:       at,
		openedAt:    now,
		nominateEnd: now + nominationWindow,
		voteEnd:     now + nominationWindow + c.params.votingBlocks,
		floor:       electionFloor(c, at),
		bond:        electionBond(c, at),
		lines:       bptree.NewBPTree32(),
		nominators:  bptree.NewBPTree32(),
		voters:      bptree.NewBPTree32(),
		approvals:   bptree.NewBPTree32(),
	}
	cm.election = e
	addNomination(c, cm, e, cand, who)
	return e.seq
}

// NominateCandidate adds a candidate to the OPEN ballot. There is no cap: a
// bond ADDS a line and can never keep one off. One nomination per address, so
// a single key cannot spam the page; sybil keys can, but each pays the bond.
func NominateCandidate(cur realm, courtSlug string, candidateID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	e := cm.mustOpenElection()
	if heightNow() >= e.nominateEnd {
		panic("kourtv2: the nomination window has closed")
	}
	cand := cm.mustCandidate(candidateID)
	addNomination(c, cm, e, cand, who)
}

func addNomination(c *Court, cm *courtMod, e *election, cand *modCandidate, who address) {
	if e.lines.Size() >= maxBallotLines {
		panic("kourtv2: this ballot is full; open the next election instead")
	}
	if e.nominators.Has(who.String()) {
		panic("kourtv2: one nomination per address per election")
	}
	if e.lines.Has(beClaimKey(cand.id)) {
		panic("kourtv2: that candidate is already on the ballot")
	}
	mustSpendable(c, who, e.bond)
	c.coin.Transfer(who, c.escrow, e.bond) // the poster's own CC (the I2 carve-out)
	e.nominators.Set(who.String(), true)
	e.lines.Set(beClaimKey(cand.id), &ballotLine{
		candID: cand.id, nomAt: heightNow(), bond: e.bond, poster: who,
	})
}

func (cm *courtMod) mustOpenElection() *election {
	if cm.election == nil || cm.election.resolved {
		panic("kourtv2: no election is open")
	}
	return cm.election
}

// ApproveCandidate approves one candidate line. A voter may approve ANY number
// of lines including retain — that is what makes adding an honest candidate
// unable to split a majority.
func ApproveCandidate(cur realm, courtSlug string, candidateID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	approve(cur.Previous().Address(), courtSlug, candidateID, false)
}

// ApproveRetain approves keeping the current moderator set. Retain is a real
// ballot line judged by approvals, never a silent default.
func ApproveRetain(cur realm, courtSlug string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	approve(cur.Previous().Address(), courtSlug, 0, true)
}

func approve(who address, courtSlug string, candidateID uint64, retain bool) {
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	e := cm.mustOpenElection()
	now := heightNow()
	if now < e.nominateEnd {
		panic("kourtv2: voting opens when the nomination window closes")
	}
	if now >= e.voteEnd {
		panic("kourtv2: voting has closed")
	}
	// Weighed at the epoch OpenElection pinned, floored by what the voter still
	// holds, and computed ONCE PER ELECTION — at the voter's first approval, then
	// reused for every later line on the same ballot.
	//
	// THE REUSE IS NOT AN OPTIMISATION, it is what keeps the tally arithmetic.
	// The floor is a LIVE read and a ballot spans many transactions, so a
	// re-derived figure can move between two of one voter's approvals: approve
	// line A holding little, top up, approve line B at the full snapshot, and
	// line B now carries weight ABOVE the turnout recorded back at approval A.
	// install compares maxW against e.turnout and e.floor, so a line heavier than
	// the turnout meant to bound it is a candidate installing on weight the
	// election never counted — measured, before the freeze, at a line carrying 10x
	// the whole turnout. Freezing at first approval makes max(line.weight) <=
	// turnout arithmetic instead of a hope.
	//
	// It is also why e.voters holds the WEIGHT rather than a presence bool. "This
	// address has voted" and "at what weight" have to be one fact in one place, or
	// they can disagree.
	//
	// This was the lane most exposed to rented weight — the opener chooses the
	// anchor and a coup is court-wide rather than one claim, measured at 12x this
	// floor from a one-epoch rental on a 500 B court. The floor is what closes it:
	// the renter must return the coin to repay, and then there is nothing to vote.
	var w int64
	if prior := e.voters.Get(who.String()); prior != nil {
		w = prior.(int64)
	} else {
		var snapshot int64
		w, snapshot = votingWeight(c, who, e.epoch)
		if snapshot <= 0 {
			panic("kourtv2: no voting weight at the pinned epoch")
		}
		if w <= 0 {
			panic("kourtv2: you no longer hold the coin you would vote with")
		}
	}
	key := beClaimKey(candidateID) + who.String()
	if retain {
		key = "retain" + who.String()
	}
	if e.approvals.Has(key) {
		panic("kourtv2: already approved that line")
	}
	if !retain {
		v := e.lines.Get(beClaimKey(candidateID))
		if v == nil {
			panic("kourtv2: that candidate is not on the ballot")
		}
		line := v.(*ballotLine)
		line.weight += w
	} else {
		e.retainW += w
	}
	e.approvals.Set(key, true)
	// Turnout is DISTINCT-VOTER weight, not the sum of approvals — a voter who
	// approves five lines is one voter, not five (round-7 R2).
	if !e.voters.Has(who.String()) {
		e.voters.Set(who.String(), w)
		e.turnout += w
		// Committed until the election resolves. Taken HERE, on the first approval,
		// for the same reason the weight is frozen here: one voter is one
		// commitment, and approving five lines must not lock five times the coin.
		// See votelock.gno.
		lockVote(c, who, voteLockElection, int64(e.seq), 0, w)
	}
}

// ResolveElection closes the ballot and installs the winner, or retains.
// Permissionless once the voting window has passed.
func ResolveElection(cur realm, courtSlug string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	e := cm.mustOpenElection()
	now := heightNow()
	if now < e.voteEnd {
		panic("kourtv2: the voting window has not closed")
	}
	e.resolved = true

	// PASS 1 — the maximum candidate approval (retain is read directly).
	maxW := int64(0)
	e.lines.Iterate("", "", func(_ string, v any) bool {
		if l, ok := v.(*ballotLine); ok && l.weight > maxW {
			maxW = l.weight
		}
		return false
	})

	// The install condition: a challenger must WIN and beat retain by at least
	// the margin, on at least quorum turnout. Otherwise the current set stands
	// (fail-safe on indecision — the right direction for governance).
	install := maxW > 0 && e.turnout >= e.floor && maxW-e.retainW >= e.floor

	// PASS 2 — among candidates within the margin of the max, the EARLIEST
	// NOMINATED wins. A decoy clone of an honest set is necessarily nominated
	// later, so it can never displace the original inside the margin.
	var winner *ballotLine
	if install {
		e.lines.Iterate("", "", func(_ string, v any) bool {
			l, ok := v.(*ballotLine)
			// Both tests matter. The first keeps the tie-break inside the margin
			// band; the SECOND re-applies the install condition to the line that
			// actually wins. Without it the band is `weight >= maxW - floor`, so
			// when maxW is near the floor the band reaches down to ZERO and the
			// earliest-nominated line installs on no approvals at all — and the
			// election opener is always the earliest line, so a griefer's puppet
			// set would beat a genuinely-approved challenger for free.
			if !ok || l.weight < maxW-e.floor || l.weight-e.retainW < e.floor {
				return false
			}
			if winner == nil || l.nomAt < winner.nomAt ||
				(l.nomAt == winner.nomAt && l.candID < winner.candID) {
				winner = l
			}
			return false
		})
	}

	// Bond dispositions: refunded ONLY to an installed candidate's poster;
	// every other line half-burns. Refunding an "above quorum" loser would let
	// a ≥5%-holder self-approve junk to reach the floor and spam the ballot for
	// free (round-6 F3).
	e.lines.Iterate("", "", func(_ string, v any) bool {
		l, ok := v.(*ballotLine)
		if !ok || l.bond <= 0 {
			return false
		}
		if winner != nil && l.candID == winner.candID {
			c.coin.Transfer(c.escrow, l.poster, l.bond)
		} else {
			half := l.bond / 2
			if half > 0 {
				c.coin.Transfer(c.escrow, l.poster, half)
			}
			if burn := l.bond - half; burn > 0 {
				c.coin.Burn(c.escrow, burn)
			}
		}
		l.bond = 0
		return false
	})

	if winner != nil {
		cand := cm.mustCandidate(winner.candID)
		installModSet(c, cm, cand, now, true)
		chain.Emit("ModSetInstalled",
			"court", c.id, "by", "election",
			"candidate", strconv.FormatUint(cand.id, 10),
			"height", strconv.FormatInt(now, 10),
		)
		return
	}
	// A fully-failed election starts this court's OWN cooldown slot (the
	// flagCooldownBlocks DURATION is reused; the per-claim flag field is not).
	cm.electionCooldownUntil = now + flagCooldownBlocks
}

// installModSet is the shared primitive both peers use to replace a court's
// moderator set, so last-writer-wins is well defined. It always replaces the
// members/threshold, stamps setActHeight, and CLEARS the suspension — a freshly
// installed set starts ARMED, because a suspension is a judgment about the set
// that was judged, not a property of the court; carrying it onto an unjudged
// set would punish a party no authority evaluated and would make the verb inert
// in the very case that motivates it (negligent mods).
//
// Two effects are ELECTION-ONLY (the setmods vet's consensus). A meta install
// must not:
//   - stamp lastElectionAt, or one cheap meta appeal would poison every other
//     in-flight appeal on that court (including restorative unhides, whose
//     staleness reads exactly that field — M-A40 through the back door); nor
//   - burn creatorUnseated, or one cheap meta appeal would permanently destroy
//     the free, instant AppointMods repair path of a court that has never held
//     an election.
//
// The local electorate's own verdict is a different thing: it legitimately ends
// the creator's appointment power and legitimately stamps the election clock.
func installModSet(c *Court, cm *courtMod, cand *modCandidate, at int64, byElection bool) {
	fresh := bptree.NewBPTree32()
	for _, a := range cand.members {
		fresh.Set(a.String(), true)
	}
	cm.members = fresh
	cm.n = len(cand.members)
	cm.m = cand.m
	// THE hole (found independently by three reviewers). This is the shared
	// install primitive for BOTH peers that replace a set — the court's own
	// election and the meta court's `mod:setmods` verdict — and it was the only
	// membership change that left the old set's approvals standing. Old set at
	// m-1 on a hide, electorate throws them out, one new member fires it on the
	// deposed signatures: exactly the "a lone puppet installed into a set can
	// act on nothing" bound (§3.1), broken in the scenario the election IS the
	// remedy for, and reachable through permissionless ResolveElection.
	clearPendingOnMembershipChange(&cm.pending)
	cm.setActHeight = at
	cm.installedByMeta = !byElection
	// Clear the suspension UNLESS this install re-seats the very set that was
	// judged: always-clearing would make suspension escapable by re-installing
	// the same addresses, while never-clearing would deliver a pre-disarmed
	// remedy. A one-address swap still escapes — that is the accepted decoy
	// residual, and it costs a real membership change.
	//
	// THE THRESHOLD IS NOT A MEMBERSHIP CHANGE (v0.52, 3-0 consensus). The
	// identity used to be `m + ":" + members` compared whole, so a 2-of-2 {A,B}
	// could re-install itself as 1-of-2 {A,B} and walk out of its own
	// suspension: the same people, not one seat surrendered, and strictly EASIER
	// to act than the body that was judged. The election route could not even
	// see it — a ballot exposes members and not m — so the membership diff
	// voters are asked to perform was blind to a threshold-only clone.
	//
	// So membership is compared on its own, and an unchanged membership lifts a
	// suspension only by TIGHTENING. Raising m is de-escalatory: it hands the
	// judged actors strictly less unilateral power, which is a real remedy and
	// worth rewarding. Holding or lowering it is not. Nothing is stranded
	// either way — `mod:unsuspend` and the global DAO's ClearCourtSuspension
	// remain explicit re-arm paths that answer to their own authority.
	if currentSetID(cm) != cm.suspendedSetID || cm.m > cm.suspendedM {
		cm.suspended = false
		cm.suspendedSetID = ""
		cm.suspendedM = 0
	}
	if byElection {
		cm.lastElectionAt = at
		cm.creatorUnseated = true
	}
}

// mustModRead is the READ-ONLY counterpart of ensureMod: a query must never
// allocate and persist a courtMod as a side effect of being asked a question.
func mustModRead(courtSlug string) *courtMod {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		panic("kourtv2: this court has no moderation state yet")
	}
	return c.mod
}

// ---- reads ----------------------------------------------------------------

// ElectionOpen reports whether a court has a live ballot.
func ElectionOpen(courtSlug string) bool {
	c := mustCourt(courtSlug)
	return c.mod != nil && c.mod.election != nil && !c.mod.election.resolved
}

// ElectionWindows returns (nominateEnd, voteEnd) of the open ballot.
func ElectionWindows(courtSlug string) (int64, int64) {
	e := mustModRead(courtSlug).mustOpenElection()
	return e.nominateEnd, e.voteEnd
}

// ElectionFloorOf is the quorum/margin floor pinned at open.
func ElectionFloorOf(courtSlug string) int64 {
	return mustModRead(courtSlug).mustOpenElection().floor
}

// ElectionBondOf is the per-candidate bond pinned at open.
func ElectionBondOf(courtSlug string) int64 {
	return mustModRead(courtSlug).mustOpenElection().bond
}

// ElectionTally exposes a line's approving weight and retain's, for render.
func ElectionTally(courtSlug string, candidateID uint64) (candW, retainW, turnout int64) {
	e := mustModRead(courtSlug).mustOpenElection()
	if v := e.lines.Get(beClaimKey(candidateID)); v != nil {
		candW = v.(*ballotLine).weight
	}
	return candW, e.retainW, e.turnout
}

// CandidateMembers returns a copy of a candidate's canonical address list, so
// render can DIFF it against the incumbent (the other half of the anti-decoy
// rule: a one-address swap must be visible, not just flagged).
func CandidateMembers(courtSlug string, candidateID uint64) []address {
	cand := mustModRead(courtSlug).mustCandidate(candidateID)
	out := make([]address, len(cand.members))
	copy(out, cand.members)
	return out
}

// CandidateThreshold reports how many of a candidate set's members would have to
// agree. Voters need it standing next to CandidateMembers: the addresses alone
// do not say how many must sign, so a candidate that keeps every incumbent and
// only LOOSENS the rule is otherwise invisible on the ballot — and that is
// precisely the change the suspension rule refuses to treat as a remedy. The
// meta court's appeal page has shown this since the setmods vet (writeAppeal);
// the election ballot had no equivalent.
func CandidateThreshold(courtSlug string, candidateID uint64) int {
	return mustModRead(courtSlug).mustCandidate(candidateID).m
}

// ElectionCooldownUntil is the height a failed election blocks a new one until.
func ElectionCooldownUntil(courtSlug string) int64 {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return 0
	}
	return c.mod.electionCooldownUntil
}
