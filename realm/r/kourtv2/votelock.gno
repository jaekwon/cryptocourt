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
// IT BLOCKS DISPOSAL, NOT STAKING, and that distinction is deliberate. Every path
// gated by mustSpendable moves coin OUT of the holder's balance except Stake,
// which is a pure lock that leaves the coin where it is and keeps it voting. There
// is no reason a pending vote should stop someone staking, and plenty of reason it
// should stop them handing the coin back to a lender. So Stake keeps its own
// stake-only check and everything else respects both locks. The default direction
// is the safe one: a site nobody remembers to move stays over-restrictive.
//
// RELEASE IS LAZY. voteLockedOf sums only the rows whose question is still open,
// so nothing iterates a whole electorate at resolution — that would put an
// O(voters) cost on a permissionless call, which is a griefing surface of its own.
// Resolved rows are pruned when the same address next votes, bounding the rows per
// address by the number of questions it has open at once.
//
// THE QUALITY LANE IS DELIBERATELY NOT LOCKED. Its tally ACCUMULATES across rounds
// — reaskQualityTally re-asks exactly once and every later round votes the same
// running total — so there is no single instant a lock could release at. That was
// flagged as an owner decision before this was built and it remains one; see
// VOTEFLOOR.md. It is also the hardest lane to rent into, because the anchor is
// the ANSWERER's: using it means answering the claim yourself and voting from a
// second address.

const (
	voteLockDispute  = "d"
	voteLockElection = "e"
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
	}
	return false
}

// voteLockedOf is the CC this address voted with in questions that have not yet
// resolved, and therefore may not dispose of.
func voteLockedOf(c *Court, who address) int64 {
	if c.voteLocks == nil {
		return 0
	}
	var sum int64
	pre := string(who)
	c.voteLocks.Iterate(pre, pre+"\xff", func(k string, v any) bool {
		if voteLockOpen(c, who, k) {
			sum = mustAdd(sum, v.(int64))
		}
		return false
	})
	return sum
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
	// Collect first: the tree must not be modified during iteration.
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
	c.voteLocks.Set(voteLockKey(who, kind, uint64(id), uint64(sub)), amount)
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

// VoteLockedOf is the CC this address cannot dispose of because it voted with it
// in a question that has not resolved. Quoted because a holder who cannot transfer
// deserves to know why, and how much.
func VoteLockedOf(courtSlug string, who address) int64 {
	return voteLockedOf(mustCourt(courtSlug), who)
}
