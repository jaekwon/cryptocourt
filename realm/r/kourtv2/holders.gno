package kourtv2

// The holder leaderboard: who holds a court's coin, largest first.
//
// WHAT IT RANKS, AND WHAT IT LEAVES OUT. This is COIN HELD — the ledger balance,
// which is the coin sitting in a holder's own account. Coin that has been staked
// on a claim is not in that balance: staking moves it to the court's custody
// until the claim resolves. So the most committed holder in a court can rank
// below somebody who has never staked anything, and the caller has to say so.
// TopHoldersNote carries that sentence rather than leaving every surface to
// invent its own.
//
// Ranking by held-plus-staked would be the truer figure and is not offered,
// because it is not cheap: the stake index is keyed by address, so totalling a
// holder's stake means walking their positions, and doing that for every holder
// turns one read into a walk of the whole court. A leaderboard that costs the
// node a full traversal is a denial-of-service surface with a friendly name.
//
// NO NEW STATE. The ledger's accounts tree already holds every balance; this
// reads it through WalkAccounts. The alternative — a ranked index maintained at
// every mint, burn and transfer — would be a second copy of a fact the ledger
// already stores, and a second copy is a thing that can disagree.
//
// THE COURT'S OWN ESCROW IS NOT A HOLDER. It carries deposits and bonds held on
// everyone's behalf, so leaving it in would put the court itself at the top of
// its own leaderboard, above every person in it.

// topHoldersMax bounds one page. The walk is over every account, so the cap
// bounds the RESPONSE rather than the work — the work is the court's holder
// count either way, which is why this is not a paging API: an offset would cost
// the same full walk and invite somebody to page through it repeatedly.
const topHoldersMax = 50

// HolderCount is how many addresses hold any of this court's coin — the
// denominator a rank is out of. Zero balances are not counted: an account can
// sit in the ledger at zero because the balance path never removes it (removal
// would drop the delegate and the vote history with it), and "holders: 40" when
// 12 of them hold nothing is a wrong number, not a subtle one.
func HolderCount(courtSlug string) int {
	c := mustCourt(courtSlug)
	esc := c.escrow
	n := 0
	c.coin.WalkAccounts(func(who address, bal int64) bool {
		if bal > 0 && who != esc {
			n++
		}
		return false
	})
	return n
}

// TopHolders is the leaderboard, largest balance first, as rows of
//
//	address:balance
//
// separated by ";". Balance is in the coin's smallest unit, the same figure
// CoinBalanceOf returns. limit is capped at topHoldersMax; zero or less means
// that cap. Returns the empty string for a court with no holders.
//
// TIES ARE BROKEN BY ADDRESS, ascending, because WalkAccounts walks in address
// order and the insertion below is stable. That matters for a leaderboard: two
// holders with equal balances must not swap places between two reads of the
// same state, or the page appears to move while nothing happened.
func TopHolders(courtSlug string, limit int) string {
	if limit <= 0 || limit > topHoldersMax {
		limit = topHoldersMax
	}
	c := mustCourt(courtSlug)
	esc := c.escrow

	// A fixed-size insertion sort over the top `limit`. The alternative is
	// collecting every holder and sorting, which allocates the whole court to
	// return ten rows.
	who := make([]address, 0, limit)
	bal := make([]int64, 0, limit)
	c.coin.WalkAccounts(func(a address, b int64) bool {
		if b <= 0 || a == esc {
			return false
		}
		// STRICTLY GREATER, so an equal balance does not displace the holder
		// already there — the walk is address-ascending, so the earlier address
		// keeps the higher rank and the order is total.
		pos := len(who)
		for pos > 0 && b > bal[pos-1] {
			pos--
		}
		if pos >= limit {
			return false
		}
		if len(who) < limit {
			who = append(who, address(""))
			bal = append(bal, 0)
		}
		for i := len(who) - 1; i > pos; i-- {
			who[i], bal[i] = who[i-1], bal[i-1]
		}
		who[pos], bal[pos] = a, b
		return false
	})

	out := ""
	for i := range who {
		if bal[i] <= 0 {
			continue
		}
		out += ";" + string(who[i]) + ":" + itoa(bal[i])
	}
	if out == "" {
		return ""
	}
	return out[1:]
}

// TopHoldersNote is the sentence a surface showing TopHolders has to print, kept
// here so the realm and every client say the same thing about the same figure.
// See the file header: staked coin is in the court's custody, not the holder's
// balance, so this ranks what is held and not what is committed.
func TopHoldersNote() string {
	return "Ranked by coin held. Coin staked on a claim sits in the court's custody until the claim resolves, so it is not counted here."
}
