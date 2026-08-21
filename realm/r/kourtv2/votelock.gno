package kourtv2

import "gno.land/p/nt/bptree/v0"

// THE VOTE LOCK — coin you voted with cannot leave your balance until the question
// it decided has resolved.
//
// WHY, AND THIS WAS MEASURED ON THE SHIPPED FLOOR RATHER THAN ARGUED. The floor
// (w = min(snapshot, BalanceOf)) requires holding at the MOMENT of voting and says
// nothing about the moment after. A cast ballot is never undone, so the rental
// survived as a reorder: borrow, wait one epoch to seal, open the dispute
// yourself, VOTE WHILE STILL HOLDING, and repay in the very next call. Probed on
// the committed floor at 599x the quorum floor with a final balance of zero —
// against the 600x the original characterization measured. The floor moved the
// attack one step to the right; it did not price it.
//
// This is what prices it. A renter must now carry the position across the whole
// voting-and-resolution window rather than one epoch — roughly a week instead of
// an hour, and the price of the attack is the risk of holding that long.
//
// THREE CORRECTIONS from the reverted first attempt, each from a panel finding:
//
//  1. UNTIL RESOLUTION, not the ballot close. The reverted version ended at
//     p.closes, so a voter could sell before ResolveDispute applied the verdict
//     they had caused. The predicate below reads the claim's own disputeOpen.
//  2. THE AMOUNT VOTED, not the address. The reverted version was a bare height
//     comparison on the address, so one dust abstain froze a voter's entire future
//     inventory for a round.
//  3. NO BOND CREDIT. The reverted version credited a nominator's own ballot-line
//     bond as weight, which at votable <= 20 CC made bond == floor and handed out
//     a zero-cost moderator coup. Escrowed coin does not vote — which is what
//     votableAt already says.
//
// IT BLOCKS DISPOSAL, NOT STAKING, and that distinction is deliberate. All SEVEN
// mustSpendable call sites move coin OUT of the holder's balance — the claim
// deposit, the answer bond, the dispute bond, the flag bond, the election
// nomination bond, and the two transfer paths in lock.gno — so all seven respect
// both locks. Stake is the single exemption and does not go through mustSpendable
// at all: it calls mustStakable, because staking is a pure lock that leaves the
// coin where it is and keeps it voting, and a pending vote is no reason to refuse
// it.
//
// mustStakable therefore has EXACTLY ONE caller, and that is a safety invariant
// rather than a fact about today's code: a second site reaching for it would be a
// second path escaping the vote lock. check-epoch-coherence arm 6 pins the count.
// The default direction is the safe one — a site nobody remembers to move stays
// over-restrictive, never under.
//
// RELEASE IS LAZY. voteLockedOf sums only the rows whose question is still open,
// so nothing iterates a whole electorate at resolution — that would put an
// O(voters) cost on a permissionless call, which is a griefing surface of its own.
// Resolved rows are pruned when the same address next votes, bounding the rows per
// address by the number of questions it has open at once.
//
// THE QUALITY LANE IS LOCKED TOO, and the shape of its lock is the answer to what
// looked like an unanswerable question.
//
// The problem, as it appeared: the quality tally ACCUMULATES. reaskQualityTally
// bumps the seq on every round while nothing has been adjudicated, then re-asks
// EXACTLY ONCE after the first adjudication and never again — so from that point
// the seq is frozen, every later round votes the same running total, and each
// address is pinned to the one vote it already cast. There is no single "round
// resolved" instant to release at, which is why this was written off as an owner
// decision.
//
// The answer is to stop looking for an instant and state the actual principle: THE
// COMMITMENT LASTS EXACTLY AS LONG AS THE INFLUENCE. A quality vote stops
// influencing anything the moment its tally is superseded — qVoted keys on
// qVoteSeq|addr, so once openQualityTally bumps the seq, the old vote counts toward
// nothing. And if the seq never moves again, the vote keeps deciding every
// remaining round, so the commitment should last until the claim itself is over.
//
// One predicate covers both:
//
//	open  iff  the claim is not terminal  AND  cs.qVoteSeq == the seq voted in
//
// which is cheap, exact, and pleasantly self-tuning. In the common
// pre-adjudication case each round re-asks, so the seq moves and the lock releases
// almost immediately — no 12-week freeze for voting on an ordinary flag. In the
// frozen-accumulating case, which is precisely where a divested address was
// measured deciding rounds it never held through, the coin stays committed for as
// long as that vote is still being counted.
//
// It is also the hardest lane to rent into regardless, because the anchor is the
// ANSWERER's: using it means answering the claim yourself and voting from a second
// address.

const (
	voteLockDispute  = "d"
	voteLockElection = "e"
	voteLockQuality  = "q"
)

// voteLockKey is addr|kind|id|sub, with both ids fixed-width big-endian so that
// one address's rows are a contiguous range and can be scanned without touching
// anyone else's.
func voteLockKey(who address, kind string, id, sub uint64) string {
	return string(who) + kind + beClaimKey(id) + beClaimKey(sub)
}

// voteLockOpen decodes one row's key and asks whether the question it names has
// resolved. A row whose question cannot be found at all is treated as RESOLVED:
// the alternative is coin locked forever by a claim that no longer exists.
func voteLockOpen(c *Court, who address, key string) bool {
	tail := key[len(string(who)):]
	if len(tail) != 1+8+8 {
		return false // not a shape this code wrote; do not hold coin on it
	}
	kind := tail[0:1]
	id := beClaimID(tail[1:9])
	sub := beClaimID(tail[9:17])
	switch kind {
	case voteLockDispute:
		v := c.claims.Get(beClaimKey(id))
		if v == nil {
			return false
		}
		cs := v.(*claimState)
		// The SAME round, not merely any open dispute on the claim. A later round
		// is a different question, and the ballot this row is holding coin for was
		// already applied when its own round resolved.
		return cs.disputeOpen && cs.proposalID == int64(sub)
	case voteLockElection:
		if c.mod == nil || c.mod.election == nil {
			return false
		}
		e := c.mod.election
		return e.seq == id && !e.resolved
	case voteLockQuality:
		v := c.claims.Get(beClaimKey(id))
		if v == nil {
			return false
		}
		cs := v.(*claimState)
		// Superseded tallies count toward nothing (qVoted keys on qVoteSeq|addr),
		// so a vote whose seq has moved on holds no coin. A tally whose seq is
		// still live holds it until the claim itself is over — which is the only
		// honest release point for an accumulating tally, because that is how long
		// the vote keeps deciding rounds.
		if cs.verdictAt != 0 || cs.closed {
			return false
		}
		return cs.qVoteSeq == sub
	}
	return false
}

// voteLockedOf is the CC this address must keep in its balance because it voted
// with it in a question that has not resolved.
//
// THE MAX ACROSS OPEN QUESTIONS, NOT THE SUM, and this was a shipped bug found by
// probing rather than reading. Each row is a floor — "at least this much of your
// balance must stay put" — and one pile of size max(rows) satisfies every row at
// once, because the same coins can honour more than one commitment. Summing
// double-counts them.
//
// It was not a corner case. P11 makes the quality ride its own transaction, so
// voting a verdict and then its quality question is the ORDINARY thing an engaged
// holder does — and measured, that holder ended up with 40 B committed against a
// 20 B balance and could move nothing at all, having committed one pile once. This
// is the same sum-vs-max error as between the stake lock and the vote lock in
// lock.gno's disposable(), one level down, and the lesson is that a "total locked"
// quantity built by addition is worth distrusting on sight.
func voteLockedOf(c *Court, who address) int64 {
	if c.voteLocks == nil {
		return 0
	}
	var most int64
	pre := string(who)
	c.voteLocks.Iterate(pre, pre+"\xff", func(k string, v any) bool {
		if w := v.(int64); w > most && voteLockOpen(c, who, k) {
			most = w
		}
		return false
	})
	return most
}

// lockVote records that `amount` of who's balance is committed to a question, and
// prunes any of that address's rows whose questions have since resolved.
//
// Idempotent per (address, question): a second call for the same key OVERWRITES
// rather than adding, because a voter votes a question once and a re-entry would
// otherwise double-lock them. The three call sites each refuse a second vote
// before reaching here, so this is a belt on top of a brace.
func lockVote(c *Court, who address, kind string, id, sub, amount int64) {
	if amount <= 0 {
		return
	}
	if c.voteLocks == nil {
		c.voteLocks = bptree.NewBPTree32()
	}
	pruneVoteLocks(c, who)
	c.voteLocks.Set(voteLockKey(who, kind, uint64(id), uint64(sub)), amount)
}

// pruneVoteLocks drops the rows whose questions have resolved, and returns how
// many it dropped.
//
// IT CANNOT CHANGE ANY BALANCE OR ANY COMMITMENT, which is what makes the exported
// wrapper safe to leave permissionless. It removes exactly the rows voteLockedOf
// already skips — the predicate is the same voteLockOpen in both — so the committed
// figure before a prune and after it are equal by construction, and
// TestPruningDropsDeadRowsWithoutMovingTheCommitment asserts that rather than
// trusting it.
//
// WHY IT NEEDS AN ENTRYPOINT AT ALL. lockVote prunes, so the common case cleans
// itself: an address that keeps voting never carries dead rows. An address that
// votes in several simultaneously-open questions and then STOPS carries one row per
// question, forever. Measured: six open disputes voted, all six resolved, six rows
// still there with ZERO coin committed, and every mustSpendable on that address
// walking all six. Bounded only by how many questions were open at once, which a
// court with many live claims does not bound usefully — and each row is persistent
// state paying a storage deposit for nothing.
//
// Collect before removing: the tree must not be modified during iteration.
func pruneVoteLocks(c *Court, who address) int {
	if c.voteLocks == nil {
		return 0
	}
	var stale []string
	pre := string(who)
	c.voteLocks.Iterate(pre, pre+"\xff", func(k string, _ any) bool {
		if !voteLockOpen(c, who, k) {
			stale = append(stale, k)
		}
		return false
	})
	for _, k := range stale {
		c.voteLocks.Remove(k)
	}
	return len(stale)
}

// beClaimID is beClaimKey's inverse, for reading an id back out of a composite
// key. Kept next to nothing else: the only reason it exists is that voteLockOpen
// has to know which question a row belongs to.
func beClaimID(s string) uint64 {
	var v uint64
	for i := 0; i < 8; i++ {
		v = v<<8 | uint64(s[i])
	}
	return v
}

// PruneVoteLocks drops `who`'s resolved lock rows and returns the count, so an
// address that voted in several questions and then stopped is not left walking dead
// rows on every transfer.
//
// PERMISSIONLESS, and deliberately so: it removes only rows that voteLockedOf
// already ignores, so it cannot free committed coin or change what anyone may
// spend. A third party paying gas to shrink someone else's state is doing them and
// the chain a favour, and there is nothing for a griefer to gain — the worst
// available move is cleaning up.
//
// Takes `who` rather than acting on the caller for the same reason: it is
// maintenance, not a privilege.
func PruneVoteLocks(cur realm, courtSlug string, who address) int {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	return pruneVoteLocks(mustCourt(courtSlug), who)
}

// VoteLockedOf is the CC this address cannot dispose of because it voted with it
// in a question that has not resolved. Quoted because a holder who cannot transfer
// deserves to know why, and how much.
func VoteLockedOf(courtSlug string, who address) int64 {
	return voteLockedOf(mustCourt(courtSlug), who)
}
