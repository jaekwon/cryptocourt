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
//   - β is frozen below the quorum floor, so affording the bond is never
//     tighter than winning the vote.
//
// Resolution is deliberately TWO-PASS: pass 1 finds the max and retain, pass 2
// picks the earliest-nominated candidate within the margin of the max. A
// single-pass running argmax gets the tie-break wrong and would let a whale
// install a late one-address-swapped DECOY of an honest set.
package courtv2

import (
	"chain"
	"chain/runtime"
	"strconv"

	grc20votes "gno.land/p/cryptocourt/grc20votes/v0"
	bptree "gno.land/p/nt/bptree/v0"
)

const (
	// nominationWindow is load-bearing (round-7 R4): the per-court latch makes
	// it a temporal-griefing surface, so it must be long enough that a defender
	// can always nominate INTO a griefer's open election rather than having to
	// win a race. One day.
	nominationWindow = int64(17_280)

	// electionBondBps is β: the per-candidate bond as a fraction of supply,
	// floored at flagMinCC. Frozen — never an owner knob. Its ceiling is
	// checked against the quorum floor at deploy (mustElectionInvariants).
	electionBondBps = int64(50) // 0.5% of supply, vs the 5% quorum floor
)

// mustElectionInvariants is the two-sided deploy gate on β (round-7 R1): a
// floor keeping the bond meaningful, and a ceiling keeping it strictly below
// the quorum floor — so any coalition that can clear quorum can trivially
// afford to field one nominator, and no court is ever challenge-proof by price.
func mustElectionInvariants() {
	if electionBondBps <= 0 {
		panic("courtv2: the election bond must be positive")
	}
	if electionBondBps >= quorumSupplyBps {
		panic("courtv2: the election bond must stay below the quorum floor — else affording the ballot is harder than winning the vote (incumbency lock by price)")
	}
	if nominationWindow < 17_280 {
		panic("courtv2: the nomination window must be at least a day")
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
	voters      *bptree.BPTree // addr -> true (distinct-voter turnout)
	approvals   *bptree.BPTree // be64(candID)|addr -> true (per-line dedup)
	turnout     int64
	resolved    bool
}

// electionFloor is the quorum AND margin floor: 5% of VOTABLE weight, netting
// out the escrow. Netting matters — on an active court most CC sits in escrow
// as stake/bonds, and a floor of 5% of RAW supply can exceed all votable weight,
// making the electorate's own remedy unreachable exactly where it is needed.
func electionFloor(c *Court, at uint32) int64 {
	supply := c.coin.PastTotal(at)
	votable := supply - c.coin.PastVotes(c.escrow, at)
	if votable < 0 {
		votable = 0
	}
	f := mulDiv128(votable, quorumSupplyBps, grc20votes.Bps)
	if f < 1 {
		f = 1
	}
	return f
}

func electionBond(c *Court, at uint32) int64 {
	b := mulDiv128(c.coin.PastTotal(at), electionBondBps, grc20votes.Bps)
	if b < flagMinCC {
		b = flagMinCC
	}
	return b
}

// RegisterModCandidate stores a candidate moderator set and returns its id.
// Permissionless (it is only a named address list; nominating it costs the
// bond). Members are canonicalized — sorted and deduped — so a mere reordering
// is not a distinct candidate, which is half of the anti-decoy rule.
func RegisterModCandidate(cur realm, courtSlug string, members []address, m int) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	canon := canonicalMembers(members)
	if len(canon) == 0 {
		panic("courtv2: a candidate set may not be empty")
	}
	if m < 1 || m > len(canon) {
		panic("courtv2: the m-of-n threshold must be in 1..n")
	}
	if cm.candidates == nil {
		cm.candidates = bptree.NewBPTree32()
	}
	cm.candSeq++
	id := cm.candSeq
	cm.candidates.Set(beClaimKey(id), &modCandidate{
		id: id, members: canon, m: m, by: who, at: runtime.ChainHeight(),
	})
	return id
}

// canonicalMembers sorts and dedupes an address list (insertion sort — a
// moderator set is small, and gno needs determinism, not speed).
func canonicalMembers(in []address) []address {
	out := []address{}
	for _, a := range in {
		if a == "" {
			panic("courtv2: a moderator address may not be zero")
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
		panic("courtv2: no such candidate")
	}
	v := cm.candidates.Get(beClaimKey(id))
	if v == nil {
		panic("courtv2: no such candidate")
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
		panic("courtv2: an election is already open for this court")
	}
	now := runtime.ChainHeight()
	if now < cm.electionCooldownUntil {
		panic("courtv2: this court is in its post-election cooldown")
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
	if runtime.ChainHeight() >= e.nominateEnd {
		panic("courtv2: the nomination window has closed")
	}
	cand := cm.mustCandidate(candidateID)
	addNomination(c, cm, e, cand, who)
}

func addNomination(c *Court, cm *courtMod, e *election, cand *modCandidate, who address) {
	if e.nominators.Has(who.String()) {
		panic("courtv2: one nomination per address per election")
	}
	if e.lines.Has(beClaimKey(cand.id)) {
		panic("courtv2: that candidate is already on the ballot")
	}
	c.coin.Transfer(who, c.escrow, e.bond) // the poster's own CC (the I2 carve-out)
	e.nominators.Set(who.String(), true)
	e.lines.Set(beClaimKey(cand.id), &ballotLine{
		candID: cand.id, nomAt: runtime.ChainHeight(), bond: e.bond, poster: who,
	})
}

func (cm *courtMod) mustOpenElection() *election {
	if cm.election == nil || cm.election.resolved {
		panic("courtv2: no election is open")
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
	now := runtime.ChainHeight()
	if now < e.nominateEnd {
		panic("courtv2: voting opens when the nomination window closes")
	}
	if now >= e.voteEnd {
		panic("courtv2: voting has closed")
	}
	w := c.coin.PastVotes(who, e.epoch)
	if w <= 0 {
		panic("courtv2: no voting weight at the pinned epoch")
	}
	key := beClaimKey(candidateID) + who.String()
	if retain {
		key = "retain" + who.String()
	}
	if e.approvals.Has(key) {
		panic("courtv2: already approved that line")
	}
	if !retain {
		v := e.lines.Get(beClaimKey(candidateID))
		if v == nil {
			panic("courtv2: that candidate is not on the ballot")
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
		e.voters.Set(who.String(), true)
		e.turnout += w
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
	now := runtime.ChainHeight()
	if now < e.voteEnd {
		panic("courtv2: the voting window has not closed")
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
			if !ok || l.weight < maxW-e.floor {
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
		installModSet(c, cm, cand, now)
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

// installModSet is the shared primitive: it replaces a court's moderator set,
// stamps the membership height, clears the suspension (a freshly installed set
// starts ARMED — otherwise the remedy would deliver a pre-disarmed set), and
// permanently unseats the creator's appointment power. The meta court's
// `mod:setmods` peer path reuses this exact function, so both peers write
// identical state and last-writer-wins is well defined.
func installModSet(c *Court, cm *courtMod, cand *modCandidate, at int64) {
	fresh := bptree.NewBPTree32()
	for _, a := range cand.members {
		fresh.Set(a.String(), true)
	}
	cm.members = fresh
	cm.n = len(cand.members)
	cm.m = cand.m
	cm.suspended = false
	cm.setActHeight = at
	cm.lastElectionAt = at
	cm.creatorUnseated = true
}

// ---- reads ----------------------------------------------------------------

// ElectionOpen reports whether a court has a live ballot.
func ElectionOpen(courtSlug string) bool {
	c := mustCourt(courtSlug)
	return c.mod != nil && c.mod.election != nil && !c.mod.election.resolved
}

// ElectionWindows returns (nominateEnd, voteEnd) of the open ballot.
func ElectionWindows(courtSlug string) (int64, int64) {
	e := ensureMod(mustCourt(courtSlug)).mustOpenElection()
	return e.nominateEnd, e.voteEnd
}

// ElectionFloorOf is the quorum/margin floor pinned at open.
func ElectionFloorOf(courtSlug string) int64 {
	return ensureMod(mustCourt(courtSlug)).mustOpenElection().floor
}

// ElectionBondOf is the per-candidate bond pinned at open.
func ElectionBondOf(courtSlug string) int64 {
	return ensureMod(mustCourt(courtSlug)).mustOpenElection().bond
}

// ElectionTally exposes a line's approving weight and retain's, for render.
func ElectionTally(courtSlug string, candidateID uint64) (candW, retainW, turnout int64) {
	e := ensureMod(mustCourt(courtSlug)).mustOpenElection()
	if v := e.lines.Get(beClaimKey(candidateID)); v != nil {
		candW = v.(*ballotLine).weight
	}
	return candW, e.retainW, e.turnout
}

// CandidateMembers returns a copy of a candidate's canonical address list, so
// render can DIFF it against the incumbent (the other half of the anti-decoy
// rule: a one-address swap must be visible, not just flagged).
func CandidateMembers(courtSlug string, candidateID uint64) []address {
	cand := ensureMod(mustCourt(courtSlug)).mustCandidate(candidateID)
	out := make([]address, len(cand.members))
	copy(out, cand.members)
	return out
}

// ElectionCooldownUntil is the height a failed election blocks a new one until.
func ElectionCooldownUntil(courtSlug string) int64 {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return 0
	}
	return c.mod.electionCooldownUntil
}
