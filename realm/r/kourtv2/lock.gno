package kourtv2

// Staked CC is LOCKED IN PLACE, not taken into custody.
//
// Stake used to be `Transfer(who, escrow, amount)`. That bought nothing: stake
// principal is never slashed and never burned, and WithdrawStake returns it 1×
// whichever way the verdict went. What it cost was the staker's vote — and not
// on the claim they staked, which would be defensible, but COURT-WIDE, on every
// election and every quality poll in that court for as long as their coins sat
// in the escrow. The design only ever wanted the claim-scoped exclusion, and it
// already has one that works by RULE rather than by custody (isParticipant).
//
// So the coins stay in the holder's own balance and this file records a claim on
// them instead. The deposit and the five bonds are NOT locks and are still
// transferred: the realm has to be able to burn or redirect those on a loss, so
// it must actually hold them.
//
// WHAT CUSTODY WAS ENFORCING FOR FREE, AND WHY THIS FILE IS THE RISK
//
// Custody made double-committing arithmetically impossible. The coins physically
// left the balance, so the LEDGER refused the second spend, automatically and on
// every path, including paths nobody thought about. A lock does not: the coins
// are still there, the ledger will happily let them be spent again, and the
// second spend is one this realm cannot honour. Stake 100, then post a 100 bond
// against the same 100 — the bond transfer succeeds, and at unstake the realm
// owes 100 CC it does not hold and would have to MINT to return, which breaks
// supply conservation. That is the one invariant a token cannot lose.
//
// The check therefore moved out of the ledger, where it was total, into this
// realm, where it is a list — and a list can be short one entry. Hence: every
// path that moves a user's CC into the escrow sizes itself against `spendable`,
// never against `BalanceOf`, and there is a test that stakes a whole balance and
// then tries to bond it (TestLockedStakeCannotBeSpentTwice). If a new spend path
// is ever added, it belongs in that test too.

import (
	bptree "gno.land/p/nt/bptree/v0"
)

// lockedOf is the CC this address has staked in this court, and therefore may
// not spend. This is the ONLY reader of the tree: a second one is a second place
// for the nil-tree and missing-key branches to disagree with the write path.
func lockedOf(c *Court, who address) int64 {
	if c.locked == nil { // pre-lock court, or a fixture that built one by hand
		return 0
	}
	if v := c.locked.Get(string(who)); v != nil {
		return v.(int64)
	}
	return 0
}

// spendable is what an address may commit in this court: its balance less what
// it has staked. Locked CC is still in the holder's balance and still votes, so
// BalanceOf overstates what is available by exactly the staked amount.
func spendable(c *Court, who address) int64 {
	s := c.coin.BalanceOf(who) - lockedOf(c, who)
	if s < 0 {
		// Only reachable if a burn ever took coins out from under a lock. It
		// does not today (nothing burns a user's balance), and clamping is the
		// conservative reading if it ever does: refuse the spend rather than
		// let a negative wrap into a large allowance.
		return 0
	}
	return s
}

// mustSpendable refuses a commitment that would dip into locked stake. Called by
// every path that transfers a user's CC into the escrow, and by Stake itself —
// the same coins cannot back two positions in one court.
func mustSpendable(c *Court, who address, amount int64) {
	if s := spendable(c, who); s < amount {
		panic("kourtv2: not enough unstaked CC — " +
			"staked coins stay in your balance and keep voting, but they are " +
			"committed and cannot also back a deposit, a bond, or another stake")
	}
}

// lockStake records a claim on `amount` of who's balance. Paired with exactly one
// releaseStake per unit: the three sites that move stakePos.stake are Stake,
// Unstake and the settlement withdrawal, and no other path may touch this tree.
func lockStake(c *Court, who address, amount int64) {
	if amount <= 0 {
		return
	}
	if c.locked == nil {
		c.locked = bptree.NewBPTree32()
	}
	c.locked.Set(string(who), mustAdd(lockedOf(c, who), amount))
}

// releaseStake drops a claim previously recorded. Panics rather than clamping if
// asked to release more than is locked: that would mean stakePos.stake and this
// tree had already diverged, and continuing would hand back CC the holder never
// committed. The panic is the conservation check.
func releaseStake(c *Court, who address, amount int64) {
	if amount <= 0 {
		return
	}
	l := lockedOf(c, who)
	if amount > l {
		panic("kourtv2: releasing more stake than is locked")
	}
	if amount == l {
		c.locked.Remove(string(who)) // no row for a zero — state costs rent
		return
	}
	c.locked.Set(string(who), l-amount)
}

// LockedOf is the read for clients and for the position page: how much of an
// address's CC is committed as stake in this court. The complement, what they
// can still commit, is SpendableOf.
func LockedOf(courtSlug string, who address) int64 {
	return lockedOf(mustCourt(courtSlug), who)
}

// SpendableOf is the balance an address may still commit in this court.
func SpendableOf(courtSlug string, who address) int64 {
	return spendable(mustCourt(courtSlug), who)
}
