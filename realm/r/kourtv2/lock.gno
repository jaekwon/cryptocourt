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

// DisposableOf is what an address may actually let LEAVE its balance in this court —
// a bond, a claim deposit, a transfer, a wrap. The balance less whichever claim on it
// is larger, stake or vote.
//
// EXPORTED BECAUSE NOTHING EXPOSED IT, and that was a real gap rather than an
// omission of convenience: every client had SpendableOf, which is stake-only, and no
// way at all to read the figure the realm actually enforces. A handoff note asking a
// web client to "use the binding limit, not SpendableOf" was unactionable until this
// existed.
//
// Pairs with SpendableOf, and the two differ exactly when a holder has voted. Quote
// both or quote this one; quoting only SpendableOf over-promises.
func DisposableOf(courtSlug string, who address) int64 {
	return disposable(mustCourt(courtSlug), who)
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
	// FOUR CASES, not two, and the two that were missing each told the holder
	// something false. disposable() subtracts the MAX of the two locks, so on a TIE
	// neither lock is the constraint by itself — releasing either one frees nothing,
	// which is the opposite of what naming one of them implies. And with NO lock at
	// all this fell through to the stake wording, so a holder who has never staked
	// was told their stake was in the way when the plain fact is that the balance is
	// short. Both were reachable: a transfer above the balance takes the second, and
	// staking exactly one's own snapshot and then voting takes the first.
	vl, sl := voteLockedOf(c, who), lockedOf(c, who)
	switch {
	case vl <= 0 && sl <= 0:
		panic("kourtv2: not enough CC — none of your balance is staked or " +
			"committed by voting, so this is simply more than you hold")
	case vl > sl:
		panic("kourtv2: not enough uncommitted CC — coin you voted with stays in " +
			"your balance and keeps voting, but it is committed until that " +
			"question resolves and cannot also back a deposit, a bond, or a " +
			"transfer")
	case sl > vl:
		panic("kourtv2: not enough unstaked CC — " +
			"staked coins stay in your balance and keep voting, but they are " +
			"committed and cannot also back a deposit, a bond, or another stake")
	default:
		panic("kourtv2: not enough free CC — you have as much staked as you have " +
			"committed by voting, and the two overlap, so releasing either one on " +
			"its own frees nothing: the coin stays in your balance and keeps " +
			"voting, but it cannot also back a deposit, a bond, or a transfer")
	}
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
// address's CC is committed as stake in this court. The complement — what they can
// still STAKE — is SpendableOf. What they can still bond, deposit, transfer or wrap
// is DisposableOf, which is a different and usually smaller number.
func LockedOf(courtSlug string, who address) int64 {
	return lockedOf(mustCourt(courtSlug), who)
}

// SpendableOf is what an address may still STAKE. It is NOT what they may spend, and
// the name predates the vote lock.
//
// Only Stake draws on this figure, through mustStakable. Every other commitment — a
// bond, a claim deposit, a transfer, a wrap — draws on DisposableOf through
// mustSpendable, which nets out the vote lock as well as the stake lock. So a client
// showing this as "what you can commit" over-promises to any holder who has voted,
// and the realm will refuse at signing.
//
// That is not hypothetical: render.gno's wallet panel printed exactly this figure
// under "what a new stake, deposit or bond draws on" until it was split into two
// rows. A single number cannot answer two gates.
func SpendableOf(courtSlug string, who address) int64 {
	return spendable(mustCourt(courtSlug), who)
}

// TransferCC moves court coin from the caller to another holder of the same
// court. courtSlug names the court, `to` is the recipient, `amount` is in CC
// base units.
//
// ONLY UNCOMMITTED COIN MOVES. The ceiling is DisposableOf(courtSlug, caller):
// the balance less whichever claim on it is larger, the stake lock or the vote
// lock. Coin behind a live stake, an answer bond, a dispute bond, a flag bond,
// a claim deposit, an election bond, or a vote still in flight cannot be sold
// out from under the commitment it is backing. LockedOf, VoteLockedOf and
// CommitmentsOf say which lock binds and by how much.
//
// Refused when the court does not exist, `amount` is zero or negative, `to` is
// the caller, either end is the court escrow — the court's own account, never a
// transfer endpoint in either direction — or `amount` exceeds DisposableOf.
//
// WHAT A TRANSFER DOES NOT CARRY. Reputation stays with the address that earned
// it. A claim position stays too: conviction accrues to whoever held the stake
// over time, so buying coin buys no position. And this is a market between
// holders, not a redemption — no GNOT is paid out, the curve stays one-way, and
// its payment stays burned.
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

// ApproveCC lets `spender` move up to `amount` of the caller's coin in this
// court, through TransferFromCC. `amount` is in CC base units.
//
// SETS the allowance, it does not add to it: the new figure replaces whatever
// was there, and 0 revokes.
//
// APPROVING RESERVES NOTHING AND LOCKS NOTHING. There is no balance check here.
// The gate is at the spend: TransferFromCC caps the move at DisposableOf(owner)
// as it stands at that moment. So an allowance may exceed what the owner can
// actually move, and the spend then simply fails. Read a granted allowance as a
// ceiling, never as available capital — AllowanceCC returns that ceiling.
//
// A spender can do strictly less than the owner could do with TransferCC. No
// authority is granted, only permission to move coin the owner could have moved
// themselves.
//
// Refused when the court does not exist, `amount` is negative, `spender` is not
// a valid address, or either the caller or `spender` is the court escrow.
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
// disposable(owner) at the moment it happens, so the amount actually movable is
// min(AllowanceCC, DisposableOf).
//
// NOT SpendableOf, which this comment named until it was checked. SpendableOf is
// stake-only, so quoting it here over-promises by the whole of a vote commitment —
// the exact over-promise the SpendableOf doc thirty lines above warns against.
// TestAnAllowanceCannotOutrunAVoteCommitment pins the spender being refused for that
// reason, with the uncommitted remainder still moving.
func AllowanceCC(courtSlug string, owner, spender address) int64 {
	return mustCourt(courtSlug).coin.Allowance(owner, spender)
}
