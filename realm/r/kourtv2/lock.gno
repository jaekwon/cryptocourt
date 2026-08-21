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

// disposable is what an address may let LEAVE its balance: the balance less
// whichever claim on it is larger. MAX, not sum, and this is the whole subtlety —
// a stake lock and a vote lock can cover the same coins (staked CC still votes, so
// a staker who votes is holding one pile answering to two claims). Adding them
// would refuse a transfer the holder can honestly make; taking the max refuses
// exactly the coins that either claim reaches.
func disposable(c *Court, who address) int64 {
	claim := lockedOf(c, who)
	if v := voteLockedOf(c, who); v > claim {
		claim = v
	}
	d := c.coin.BalanceOf(who) - claim
	if d < 0 {
		return 0
	}
	return d
}

// mustSpendable refuses a commitment that would dip into locked stake OR into coin
// committed by voting. Called by every path that moves a user's CC OUT of their
// balance — into the escrow or to another holder.
//
// NOT called by Stake, which uses mustStakable below. Staking moves nothing: the
// coin stays in the balance and keeps voting, so a pending vote is no reason to
// refuse it. Every other caller disposes of coin, and disposal is exactly what the
// vote lock exists to prevent. The default here is the conservative one on purpose
// — a new call site that nobody thinks about gets the stricter check.
func mustSpendable(c *Court, who address, amount int64) {
	if disposable(c, who) >= amount {
		return
	}
	// NAME THE CONSTRAINT THAT ACTUALLY BINDS. One merged message would make every
	// refusal read as a stake problem — including the ones that are not — and a
	// holder cannot act on "something is locked". Three existing tests assert the
	// stake wording and they were right to: in their fixtures the stake IS what
	// binds, so a merged message would have made them fail for no defect.
	if voteLockedOf(c, who) > lockedOf(c, who) {
		panic("kourtv2: not enough uncommitted CC — coin you voted with stays in " +
			"your balance and keeps voting, but it is committed until that " +
			"question resolves and cannot also back a deposit, a bond, or a " +
			"transfer")
	}
	panic("kourtv2: not enough unstaked CC — " +
		"staked coins stay in your balance and keep voting, but they are " +
		"committed and cannot also back a deposit, a bond, or another stake")
}

// mustStakable refuses a stake that would dip into locked stake, and deliberately
// ignores the vote lock. See mustSpendable for why the two differ.
func mustStakable(c *Court, who address, amount int64) {
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

// TransferCC moves court coin between two holders of the same court.
//
// COURT COINS ARE TRANSFERABLE (owner decision, 2026-08-20). They were soulbound
// in V1 and V2 from the start — mint-only, escrow-only, burn-only, with a one-way
// curve and no exit — and MODERATION.md had recorded transferability as an open
// owner call the whole time. This closes it in favour of transferable.
//
// GATED ON spendable(), WHICH IS THE WHOLE SAFETY ARGUMENT. spendable() is
// BalanceOf minus lockedOf, so committed capital cannot be sold out from under
// the thing it is committed to: a live stake, an answer bond, a dispute bond, a
// flag bond, a claim deposit or an election bond. Without this gate a staker
// could sell the coins backing a position and keep both the proceeds and the
// position — the same double-commit hazard mustSpendable exists to prevent, from
// the other direction.
//
// WHAT THIS DOES NOT MAKE TRANSFERABLE:
//
//   - REPUTATION. answerRecord is keyed by address, has no Remove, and no path
//     assigns one address's record to another. That property stands on its own
//     and is not a side effect of the coin having been soulbound. It is now
//     enforced by check-nontransferable.py, which was inverted in the same commit
//     to forbid reputation-moving entrypoints instead of coin-moving ones.
//   - A CLAIM POSITION. stakePos is keyed (address, side) and only Stake, Unstake
//     and the settlement withdrawal move `stake`. Selling coin does not carry
//     conviction, which accrues to whoever held the position over time.
//   - GNOT. The curve stays one-way and its payment stays burned. This adds a
//     SECONDARY market between holders, not a redemption; no treasury appears and
//     no real money exits.
//
// Known and accepted, recorded rather than hidden: several safety bars in this
// realm are denominated in % of court supply (the quorum floor, both quality
// bars, the credential bar, the election floor, the supplyFloor lid). Their
// prices were set when the only way to acquire supply was the curve, which burns
// GNOT at a monotonically rising price. A secondary market can clear below that,
// so those bars may be cheaper to reach than when they were calibrated. The
// owner has taken that trade deliberately.
func TransferCC(cur realm, courtSlug string, to address, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	if amount <= 0 {
		panic("kourtv2: transfer amount must be positive")
	}
	from := cur.Previous().Address()
	if from == to {
		panic("kourtv2: cannot transfer to yourself")
	}
	c := mustCourt(courtSlug)
	// The escrow is the realm's own account: bonds and deposits live there and
	// are disposed only by the lanes that own them. It must never be a transfer
	// endpoint in either direction.
	if to == c.escrow || from == c.escrow {
		panic("kourtv2: the court escrow is not a transfer endpoint")
	}
	touch(c)
	mustSpendable(c, from, amount)
	c.coin.Transfer(from, to, amount)
}

// ApproveCC lets a spender move some of the caller's court coin.
//
// This exists for one reason: to make the coin integrable by things this realm
// does not import and must not have to trust. A DEX pool, an escrow, a wrapper —
// each needs to pull coin from a user who has agreed to it, and approve /
// transferFrom is the interface every one of them already speaks. Exposing that
// pair is what lets `r/kourt/ccwrap` exist as a separate, untrusted realm rather
// than as a privileged hole in this one. Nothing here is granted any authority:
// an approved spender can do strictly less than the owner could do themselves
// with TransferCC.
//
// DELIBERATELY NOT GATED ON spendable(). An allowance grants nothing until it is
// spent, and gating here would be both useless and wrong — useless because the
// balance can change freely between approve and spend, so an approve-time check
// proves nothing about spend time; wrong because approving future coin is a
// normal thing to do. The gate belongs at the spend, and TransferFromCC has it.
//
// The consequence, stated so nobody reads a granted allowance as available
// capital: an allowance can exceed spendable(), in which case the spend simply
// fails. Approving does not reserve, and does not lock.
func ApproveCC(cur realm, courtSlug string, spender address, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	if amount < 0 {
		panic("kourtv2: negative allowance")
	}
	c := mustCourt(courtSlug)
	owner := cur.Previous().Address()
	// Symmetric with TransferCC: the escrow is not an endpoint, so it must not
	// be reachable as a spender either. Otherwise an allowance naming it would
	// sit there looking like a claim on escrowed coin.
	if spender == c.escrow || owner == c.escrow {
		panic("kourtv2: the court escrow is not a transfer endpoint")
	}
	touch(c)
	c.coin.Approve(owner, spender, amount)
}

// TransferFromCC spends an allowance the owner granted the caller.
//
// Every guard TransferCC applies applies here, keyed on `from` rather than on
// the caller — mustSpendable in particular. An allowance is not a lock and never
// outranks one: if the owner has since committed the coin to a stake, a bond or
// a deposit, the spend fails, and it fails for the spender exactly as it would
// have failed for the owner. That is the property that makes the allowance safe
// to hand out at all, and it is why the check is on `from`: gating on the spender
// would gate the wrong balance and leave the owner's lock unenforced.
func TransferFromCC(cur realm, courtSlug string, from, to address, amount int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	if amount <= 0 {
		panic("kourtv2: transfer amount must be positive")
	}
	if from == to {
		panic("kourtv2: cannot transfer to yourself")
	}
	c := mustCourt(courtSlug)
	if to == c.escrow || from == c.escrow {
		panic("kourtv2: the court escrow is not a transfer endpoint")
	}
	touch(c)
	mustSpendable(c, from, amount)
	c.coin.TransferFrom(cur.Previous().Address(), from, to, amount)
}

// AllowanceCC reports what `spender` may still move of `owner`'s court coin.
//
// Read it as a ceiling, not as a balance: the spend is additionally capped by
// spendable(owner) at the moment it happens, so the amount actually movable is
// min(AllowanceCC, SpendableOf).
func AllowanceCC(courtSlug string, owner, spender address) int64 {
	return mustCourt(courtSlug).coin.Allowance(owner, spender)
}
