// Emission: the only mint besides the curve (PLAN §3.3, pins P5/P8/P10).
//
// Accrual: each block accrues b = B_period / periodBlocks with the remainder
// carried exactly (Σ accrued over a period == the period's budget, to the
// unit). B_period = S_live × the stepped-down budget bps, read once at each
// period boundary — the OWNER's 20%/yr worst-case ceiling.
//
// Two lanes, one accrual line (P5):
//   SENIOR — conduct comps, flag bounties, voter carrots: entitlements reserve
//   intervals [start, start+amount) on the cumulative-accrual number line at
//   enqueue time and are payable as accrual covers them — full amount, possibly
//   time-delayed, never scaled (2A-T1).
//   JUNIOR — the tier-scaled claim draws: D = min(Σg, R) where R is accrual
//   past the senior tail minus prior junior reservations; scaled once at
//   crystallize, then pulled.
//
// The R_max pause (ceiling-not-floor): accrual stops while the junior pool is
// full AND every senior is covered; the skipped budget is forgone forever.
package courtv2

import (
	"chain/runtime"
)

// entitlement is one senior claim on future accrual.
type entitlement struct {
	to      address
	amount  int64
	start   int64 // position on the cumulative-accrual line (reservedTail at enqueue)
	paid    int64
	purpose string // "comp" | "bounty" | "carrot" — render/audit label
}

// touch advances a court's emission clock to now: walks period segments,
// accruing with the carried remainder at each segment's budget, and rolls the
// period (budget step-down, d_eff repricing) at each boundary. Every
// state-changing entrypoint calls it first.
func touch(c *Court) {
	now := runtime.ChainHeight()
	for c.lastAccrual < now {
		boundary := c.createdAt + (c.periodIndex+1)*periodBlocks
		segEnd := now
		if boundary < segEnd {
			segEnd = boundary
		}
		accrueSegment(c, segEnd-c.lastAccrual)
		advanceRateAcc(c, segEnd-c.lastAccrual)
		c.lastAccrual = segEnd
		if segEnd == boundary {
			rollPeriod(c)
		}
	}
}

// accrueSegment accrues `blocks` at the current period's budget, remainder
// carried in units of 1/periodBlocks (P10: flooring never loses a unit across
// a period). Skipped entirely while the R_max pause holds.
func accrueSegment(c *Court, blocks int64) {
	if blocks <= 0 || c.curPeriodBudget <= 0 {
		return
	}
	if c.reservoirR() >= c.rMax() && c.cumAccrual >= c.reservedTail {
		return // full and no senior waits: the budget is forgone (ceiling, not floor)
	}
	num := mustAdd(mustMul(c.curPeriodBudget, blocks), c.accrualRem)
	c.cumAccrual = mustAdd(c.cumAccrual, num/periodBlocks)
	c.accrualRem = num % periodBlocks
}

// advanceRateAcc extends the era integral by one segment at the segment's own
// rate (audit H1): rateAcc is what conviction settles against — no position is
// ever priced at a rate that wasn't live while it accrued.
func advanceRateAcc(c *Court, blocks int64) {
	if blocks <= 0 {
		return
	}
	c.rateAccFP = mustAdd(c.rateAccFP, mustMul(rateBpsFP(c), blocks))
}

// rollPeriod steps the budget down and reprices d_eff from realized dilution
// (audit-15 P1): d_eff = min(budget ceiling, 4-period EMA of minted/supply).
func rollPeriod(c *Court) {
	c.periodIndex++
	c.curBudgetBpsFP = c.curBudgetBpsFP * stepDownNum / stepDownDen

	minted := c.emittedTotal - c.emittedAtRoll
	c.emittedAtRoll = c.emittedTotal
	c.emaMinted = (3*c.emaMinted + minted) / 4

	s := c.coin.TotalSupply()
	if s > 0 {
		if c.emaMinted < 0 {
			panic("courtv2: negative realized mint") // emittedTotal is monotone; defensive
		}
		// 128-bit both ways (audit C1: the naive uint64 product wraps at
		// ~485k CC of supply — a silent 34× under-budget on any real court).
		dReal := mulDiv128(c.emaMinted, 10_000*1_000_000, s)
		if dReal < c.curBudgetBpsFP {
			c.dEffBpsFP = dReal
		} else {
			c.dEffBpsFP = c.curBudgetBpsFP
		}
		// The period's budget: S_live × bps, floored (P10).
		c.curPeriodBudget = mulDiv128(s, c.curBudgetBpsFP, 10_000*1_000_000)
	} else {
		c.dEffBpsFP = 0
		c.curPeriodBudget = 0
	}
}

// reservoirR is the junior pool: accrual past the senior tail, minus junior
// reservations already made. Never negative.
func (c *Court) reservoirR() int64 {
	past := c.cumAccrual - c.reservedTail
	if past < 0 {
		past = 0
	}
	r := past - c.juniorReserved
	if r < 0 {
		r = 0
	}
	return r
}

// rMax banks at most rMaxPeriods of the CURRENT period's budget.
func (c *Court) rMax() int64 { return rMaxPeriods * c.curPeriodBudget }

// enqueueSenior reserves a senior entitlement (comp/bounty/carrot). Internal:
// later modules call it at their decision points; nothing user-facing enqueues.
func enqueueSenior(c *Court, to address, amount int64, purpose string) uint64 {
	if amount <= 0 {
		panic("courtv2: a senior entitlement must be positive")
	}
	// The start cursor must clear BOTH the prior senior tail AND every junior
	// draw already minted (audit M3-CRITICAL-1): juniors mint eagerly and
	// occupy accrual at [reservedTail, reservedTail+juniorReserved), but
	// reserveJunior does not advance reservedTail. A senior placed at the bare
	// reservedTail would overlap that stretch and PullSenior would re-pay
	// accrual the junior already minted, driving emittedTotal past cumAccrual
	// and breaking the ceiling. Placing it past juniorReserved keeps the whole
	// number line disjoint: seniors and juniors tile [0, reservedTail+juniorReserved)
	// without overlap. (Pre-crystallize, juniorReserved==0 → unchanged.)
	start := mustAdd(c.reservedTail, c.juniorReserved)
	e := &entitlement{to: to, amount: amount, start: start, purpose: purpose}
	c.reservedTail = mustAdd(c.reservedTail, amount)
	c.seniorOwed = mustAdd(c.seniorOwed, amount)
	c.queueSeq++
	c.queue.Set(beClaimKey(c.queueSeq), e)
	return c.queueSeq
}

// reserveJunior reserves D from the junior pool at crystallize time (later
// modules). Clamps to R — never aborts a shared settlement path (F4).
func reserveJunior(c *Court, want int64) int64 {
	touch(c)
	r := c.reservoirR()
	if want > r {
		want = r
	}
	if want < 0 {
		want = 0
	}
	c.juniorReserved = mustAdd(c.juniorReserved, want)
	return want
}

// mintEmission is the ONLY emission mint: bounds-checked against the court's
// own ledger and counted into emittedTotal (which feeds d_eff).
func mintEmission(c *Court, to address, amount int64) {
	if amount <= 0 {
		return
	}
	c.coin.Mint(to, amount)
	c.emittedTotal = mustAdd(c.emittedTotal, amount)
}

// PullSenior pays a senior entitlement as far as accrual covers it. Anyone may
// crank it; payment always goes to the entitlement's address. Returns the
// amount paid this call.
func PullSenior(cur realm, courtSlug string, seq uint64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	touch(c)
	v := c.queue.Get(beClaimKey(seq))
	if v == nil {
		panic("courtv2: no such entitlement")
	}
	e := v.(*entitlement)
	covered := c.cumAccrual - e.start
	if covered > e.amount {
		covered = e.amount
	}
	pay := covered - e.paid
	if pay <= 0 {
		return 0
	}
	e.paid += pay
	c.seniorOwed -= pay
	c.seniorPaid = mustAdd(c.seniorPaid, pay)
	mintEmission(c, e.to, pay)
	return pay
}

// ------------------------------------------------------------------ reads --

// Reservoir is the junior pool R; SeniorOwed is the queue's unpaid mass —
// together the "when do I get paid" legibility the UX needs (§11).
func Reservoir(courtSlug string) int64  { return mustCourt(courtSlug).reservoirR() }
func SeniorOwed(courtSlug string) int64 { return mustCourt(courtSlug).seniorOwed }

// SeniorEntitlement reads one entitlement: recipient, total, paid, and what is
// payable right now.
func SeniorEntitlement(courtSlug string, seq uint64) (to address, amount, paid, payable int64) {
	c := mustCourt(courtSlug)
	v := c.queue.Get(beClaimKey(seq))
	if v == nil {
		panic("courtv2: no such entitlement")
	}
	e := v.(*entitlement)
	covered := c.cumAccrual - e.start
	if covered > e.amount {
		covered = e.amount
	}
	p := covered - e.paid
	if p < 0 {
		p = 0
	}
	return e.to, e.amount, e.paid, p
}

// Poke advances the emission clock without any other action — a public crank
// so accrual (and thus payability) never depends on trading activity.
func Poke(cur realm, courtSlug string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	touch(mustCourt(courtSlug))
}
