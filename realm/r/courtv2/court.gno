// Package courtv2 is cryptocourt V2: no-loss conviction staking. Each court is
// its own coin, governor, and one-way bonding curve, with claims resolved by the
// V1 answer/dispute machine — but the market layer is gone. Stakers back YES or
// NO directly; losers always withdraw 1×; winners share a bounded, stepped-down
// emission of new CC weighted by conviction (stake × time) and an adjudicated
// quality tier. Real money (GNOT) enters once through the curve and is BURNED;
// no real money ever exits, and no value ever moves between adversaries
// ("forfeitures burn; compensation mints").
//
// This file is the backbone: Court and Params, the frozen realm constants and
// their deploy-checked invariants, the directory, and StartCourt. Mechanics land
// in sibling files (buy, stake, claim, answer, session, dispute, emission,
// quality, records, render). PLAN.md (v0.32, design-converged) is the spec; the
// V1 realm at realm/r/court is untouched and remains the audited reference.
package courtv2

import (
	"chain/runtime"

	curve "gno.land/p/cryptocourt/curve/v0"
	governor "gno.land/p/cryptocourt/governor/v0"
	grc20votes "gno.land/p/cryptocourt/grc20votes/v0"
	bptree "gno.land/p/nt/bptree/v0"
)

const errStaleRealm = "courtv2: stale realm; call through a crossing function"

// coinDecimals and epochBlocks fix every court's coin shape, exactly as V1: six
// decimals, 720 blocks (an hour) per checkpoint epoch.
const (
	coinDecimals = 6
	epochBlocks  = int64(720)

	// curveCap is HALF of V1's: emission grows total supply past what the curve
	// sold, provably < 1.784× (the geometric sum of the 20%-ceiling budget with
	// the amortized step-down), so halving the curve's own cap keeps
	// curve-sold × 1.784 under grc20votes.MaxSupply and every governor tally
	// overflow-safe. Checked in mustInvariants.
	curveCap   = (int64(9223372036854775807) / grc20votes.Bps) / 2
	curveDenom = int64(1_000_000_000)
)

// The frozen emission constants (PLAN §3.3/§4, v0.32). No runtime knob exists —
// the absence of a retune path is load-bearing for every overflow and capture
// bound in the audit.
const (
	periodBlocks = int64(120_960) // 1 week — the emission accounting period
	// budgetWeeklyBps: the OWNER's 20%/yr worst-case ceiling, per week, of live
	// supply (2000 bps / 52 ≈ 38 bps). The per-period budget is
	// B_n = S_live × budgetWeeklyBps/10000 × the amortized step-down.
	budgetWeeklyBps = int64(38)
	// stepDownPeriods: the budget multiplies by 2^(−1/stepDownPeriods) each
	// period — a 104-week half-life with no cliff to race (implemented as the
	// fixed-point factor stepDownNum/stepDownDen per period in emission.gno).
	stepDownPeriods = int64(104)
	rMaxPeriods     = int64(4) // the reservoir banks at most 4 quiet weeks

	// Tier multipliers (×1 units): low pays nothing tier-scaled, mid is par,
	// high doubles. The winner/author/answerer caps are tier/2 × their base.
	tierLowX, tierMidX, tierHighX = int64(0), int64(1), int64(2)

	// The split, in points of a claim's draw: winners 80, author 8, answerer 5
	// (tier-scaled, from the main reservoir); the voter carrot is 7 points of
	// the MID-weight gross — tier-invariant, senior-queued (emission.gno).
	splitWinners, splitAuthor, splitAnswerer, splitCarrot = int64(80), int64(8), int64(5), int64(7)
)

// The frozen conduct-economics constants (PLAN §3.4/§3.6, v0.25–v0.31).
const (
	answerBondBps = int64(5000) // answer bond = 50%·X̄ (min 1), capped by params
	// dispute bond = min(20%·X̄, 40% × the ACTUAL answer bond), doubling per
	// failed round (round-3 fix: keeps the round-1 honest bar at q > 1/3 on
	// every claim, including answer-bond-capped courts).
	disputeBondXBps, disputeBondOfAnswerBps = int64(2000), int64(4000)
	maxFailedRounds                         = 3

	// comp = min(2 × prevailing party's own bond, 80% × the loser's burned
	// bond), tier-invariant, senior-queued; the 80% arm FLOORS (v0.20/v0.25).
	compOwnX, compOfBurnBps = int64(2), int64(8000)

	// Flag lane: bond = max(flagMinCC, 2%·X̄); doubling per SLOT to a frozen
	// 4×; conclusive-low slash = max(4.5%·X̄ floor, 1.6× the mill's would-be mid
	// draw), only at the supply-floored full bar on UNDISPUTED answers, escrowed
	// one counter-flag window (v0.28–v0.31; draw-proportional arm v0.40).
	flagBondXBps    = int64(200)
	flagMinCC       = int64(1_000_000) // 1 CC
	flagFrozenMultX = int64(4)         // bond freezes at 4×b₀ = 8%·X̄ after 3 inconclusives
	flagFreezeAfter = 3
	slashXBps       = int64(450)   // 4.5%·X̄ answer-bond slash FLOOR (whale-gated; bounty 2% ≤ 80%×4.5% ✓)
	slashDrawBps    = int64(16000) // v0.40: draw-proportional arm — slash ≥ 1.6× the winning-pool mid draw (midGross), so a patient mill's punishment tracks its take, not just X̄; floored by slashXBps, clamped to the bond. k=1.6 lands the 12-wk (dead-claim) mill q* on the ~0.22 target and flattens the hold-time curve (three-designer convergence, v0.40)
	depositFeeBps   = int64(1000) // 10% of the deposit, conditionally refunded

	// Answer priority (records.gno): difficulty-weighted net record ≥ 3 earns a
	// 24h priority window; gate off until 3 addresses qualify; one active
	// priority claim per address.
	priorityNetRecord    = 3
	priorityColdStartN   = 3
	priorityWindowBlocks = int64(17_280) // 24h

	settleDelay      = int64(51_840)    // 72h before an undisputed answer settles
	deadClaimTimeout = int64(1_451_520) // 12 weeks: unanswered claims close
)

// mustInvariants is the deploy gate for the cross-constant couplings the audit
// froze (PLAN §10). It runs at init: a build whose constants violate an audited
// bound refuses to exist rather than shipping a weakened court.
func mustInvariants() {
	// Supply ceiling: curve-sold × the 1.784 emission growth bound must stay
	// under grc20votes.MaxSupply so yes×Bps never overflows a tally. 1.784 is
	// over-approximated as 1785/1000.
	maxSupply := int64(9223372036854775807) / grc20votes.Bps
	if curveCap > (maxSupply/1785)*1000 {
		panic("courtv2: curveCap × emission growth bound exceeds the tally-safe supply ceiling")
	}
	// Bond–tier coupling (§3.6): the answer bond must cover the maximum
	// undisputed extraction, tierMid/2 of the stake, in bps.
	if answerBondBps < tierMidX*10000/2 {
		panic("courtv2: answer bond below the undisputed-extraction bound")
	}
	// The dispute bond's own-answer arm keeps round 1 at q > 1/3 everywhere:
	// 2 × disputeBond ≤ 80% × answerBond ⇔ 2×min(20%, 40%×50%) ≤ 80%×50%.
	if 2*disputeBondOfAnswerBps*answerBondBps/10000 > compOfBurnBps*answerBondBps/10000 {
		panic("courtv2: dispute bond arm breaks the round-1 honest-dispute bar")
	}
	// 20%/yr ceiling honesty: 52 weeks of the weekly budget may not exceed
	// 2000 bps of supply.
	if budgetWeeklyBps*52 > 2000 {
		panic("courtv2: the weekly budget exceeds the 20%/yr inflation ceiling")
	}
	// The split must sum to ≤ 100 tier-scaled points (the carrot is separate,
	// mid-weight and senior — see emission.gno).
	if splitWinners+splitAuthor+splitAnswerer != 93 {
		panic("courtv2: the tier-scaled split must sum to 93 points")
	}
	// CALIBRATION, NOT A SAFETY PROOF — read before trusting this (audit round 2).
	// A check over CONSTANTS can only make a constant-space claim: on a pool
	// roughly CONSTANT over a ≤12-week life, the draw arm k·midGross lands under
	// the 50%·X̄ bond, i.e. PostAnswer's collateralization floor stays a NO-OP on
	// the honest path and the quoted bond stays legible. It does NOT prove the
	// slash is collateralized. Its premise (midGross/X̄ = rateBpsFP·T_c/1e10, with
	// X̄ standing in for the pool) is falsified AT RUNTIME two ways: by a DRAIN —
	// Unstake is free and keeps conviction by design (F9), measured at a 224×
	// shortfall — and by an over-aged claim, since nothing forced CloseDeadClaim.
	// The real guarantee is the runtime floor in PostAnswer, which prices the slash
	// with the SAME sizer ResolveFlag later draws with; the ≤12-week premise is now
	// enforced there by the dead-claim answerability gate.
	maxRateBpsFP := 255 * (r0WeeklyBps*1_000_000 + budgetBpsFPStart) / 100
	maxTcWeeks := deadClaimTimeout / periodBlocks
	maxMidGrossBps := maxRateBpsFP * maxTcWeeks / 1_000_000
	if slashDrawBps*maxMidGrossBps/10000 > answerBondBps {
		panic("courtv2: the draw arm exceeds the base bond at the hot-rate 12-week max — PostAnswer's collateralization floor would bind on HONEST claims, repricing every answer")
	}
	// The flat arm's twin coupling, previously unstated: the base bond covers the
	// 4.5%·X̄ arm too, so the floor is inert on BOTH arms while the cap is unset.
	if slashXBps > answerBondBps {
		panic("courtv2: the flat slash arm exceeds the base answer bond")
	}
}

func init() { mustInvariants() }

// Params are the per-court knobs, frozen at StartCourt through mustSane exactly
// as V1: no retune entrypoint exists.
type Params struct {
	disputeThresholdBps int64 // overturn bar; > 5000 so a tie never overturns
	votingBlocks        int64 // dispute vote length
	graceBlocks         int64 // governor slot-free grace
	minAnswerX          int64 // min trailing total stake (CC base) to answer
	answerBondCapCC     int64 // 0 = uncapped (V1 convention)
	minClaimDepositCC   int64 // never zero
	escrowMinBlocks     int64 // 1 week
	escrowMaxBlocks     int64 // 3 weeks
}

func defaultParams() Params {
	return Params{
		disputeThresholdBps: 5001,
		votingBlocks:        120_960,
		graceBlocks:         17_280,
		minAnswerX:          100_000_000, // 100 CC of trailing total stake
		answerBondCapCC:     0,
		minClaimDepositCC:   1_000_000, // 1 CC
		escrowMinBlocks:     120_960,
		escrowMaxBlocks:     362_880,
	}
}

// mustSane refuses params no bound can rescue, V1-style.
func (p Params) mustSane() Params {
	if p.disputeThresholdBps < 5001 || p.disputeThresholdBps > 10000 {
		panic("courtv2: the overturn threshold must be in [5001, 10000]")
	}
	if p.votingBlocks < 1 || p.graceBlocks < 1 {
		panic("courtv2: vote and grace windows must be positive")
	}
	if p.minAnswerX < 1 {
		panic("courtv2: minAnswerX must be positive")
	}
	if p.minClaimDepositCC < 1 {
		panic("courtv2: the claim deposit must never be zero")
	}
	if p.escrowMinBlocks < 1 || p.escrowMaxBlocks < p.escrowMinBlocks {
		panic("courtv2: the escrow window is malformed")
	}
	if p.answerBondCapCC < 0 {
		panic("courtv2: answerBondCapCC must be non-negative")
	}
	return p
}

// Court is one court instance. Every field is unexported and no method returns
// a /p/ pointer (borrow rule #2). Emission state lives on the court so each
// coin's reservoir is isolated with its ledger.
type Court struct {
	id    string
	name  string
	tier  uint8
	admin address // creator; recorded, unused — no retune path exists

	coin *grc20votes.Ledger // the court coin (CC)
	gov  *governor.Governor // the dispute arbiter; electorate = coin
	crv  curve.Curve        // one-way GNOT -> CC; proceeds are burned

	// escrow holds staked CC, deposits, and bonds. It never votes (the quorum
	// floor nets it out), and — new in V2 — participants of a claim are
	// excluded from that claim's quality lane by rule, not just by escrow.
	escrow address

	minted int64 // cumulative curve position (never decremented; prices mints)

	claims  *bptree.BPTree // claimID (be64) -> *claimState (claim.gno)
	nextID  uint64
	params  Params
	deposit int64 // sum of escrowed deposits+fees, for the conservation checks

	// Emission state (emission.gno): one cumulative-accrual line carries both
	// lanes — seniors reserve intervals on it, juniors draw what lies past the
	// senior tail (P5).
	cumAccrual      int64 // total budget ever accrued (monotone)
	accrualRem      int64 // carried remainder, units of 1/periodBlocks (P10)
	curPeriodBudget int64 // this period's B = S_live × bps at the last roll
	curBudgetBpsFP  int64 // budget CEILING, bps × 1e6 (stepped down at rolls)
	dEffBpsFP       int64 // effective d: min(ceiling, realized EMA) — audit-15 P1
	rateAccFP       int64 // cumulative Σ rate×blocks (bpsFP·block) — the era integral (audit C-H1)
	emaMinted       int64 // 4-period EMA of minted-per-period
	emittedAtRoll   int64 // emittedTotal at the last roll
	lastAccrual     int64 // height the accrual walk has reached
	periodIndex     int64 // completed periods (step-down n)
	createdAt       int64 // height at StartCourt
	reservedTail    int64 // Σ senior amounts ever enqueued (interval tail)
	juniorReserved  int64 // Σ junior reservations (crystallized draws)
	seniorOwed      int64 // enqueued − paid
	seniorPaid      int64
	emittedTotal    int64          // every CC ever minted via emission
	queue           *bptree.BPTree // entitlement seq (be64) -> *entitlement
	queueSeq        uint64
	records         *bptree.BPTree // addr -> *answerRecord (records.gno)
	qualifiedCount  int            // addresses at score ≥ priorityNetRecord
}

// courts is the directory: slug -> *Court, lexicographic by slug.
var courts = bptree.NewBPTree32()

// StartCourt creates a court: its coin, its governor (electorate = the coin),
// its curve, and its claim book. Anyone may start one; the directory admin (the
// first creator) may curate tiers. GNOT handling lives in buy.gno (burned).
func StartCourt(cur realm, slug, name string) string {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	mustSlug(slug)
	if courts.Has(slug) {
		panic("courtv2: that slug is taken")
	}
	admin := cur.Previous().Address()

	coin := grc20votes.NewLedger(name, "COURT", coinDecimals, epochBlocks)
	c := &Court{
		id:        slug,
		name:      name,
		tier:      tierListed,
		admin:     admin,
		coin:      coin,
		gov:       governor.New(coin, coin),
		crv:       curve.New(curveDenom, curveCap),
		escrow:    cur.Address(),
		claims:    bptree.NewBPTree32(),
		queue:     bptree.NewBPTree32(),
		records:   bptree.NewBPTree32(),
		params:    defaultParams().mustSane(),
		createdAt:      runtime.ChainHeight(),
		curBudgetBpsFP: budgetBpsFPStart,
	}
	c.lastAccrual = c.createdAt
	c.gov.Adopt(disputeKind{}, disputeRules(c.params))
	courts.Set(slug, c)
	if directoryAdmin == "" {
		directoryAdmin = admin
	}
	return slug
}

// ------------------------------------------------------------------ reads --

// CourtCount is how many courts have been started.
func CourtCount() int { return courts.Size() }

// Exists reports whether a slug names a court.
func Exists(slug string) bool { return courts.Has(slug) }

func CourtName(slug string) string { return mustCourt(slug).name }
func CoinSupply(slug string) int64 { return mustCourt(slug).coin.TotalSupply() }

// CoinPrice is the curve's marginal price for the next coin. There is no
// "backing" read in V2: burned GNOT backs nothing, and rendering one would
// imply a redemption value that does not exist (PLAN §3.8 pass 2).
func CoinPrice(slug string) int64 { return mustCourt(slug).crv.Price(mustCourt(slug).minted) }

// CourtEscrow is the address holding a court's staked CC, deposits, and bonds —
// the realm's own address; each court's coin ledger isolates its balances.
func CourtEscrow(slug string) address { return mustCourt(slug).escrow }

// EmittedTotal is every CC this court has minted through emission — the figure
// a holder audits dilution against.
func EmittedTotal(slug string) int64 { return mustCourt(slug).emittedTotal }

// mustCourt fetches a court or panics. Never exported.
func mustCourt(slug string) *Court {
	v := courts.Get(slug)
	if v == nil {
		panic("courtv2: no such court")
	}
	return v.(*Court)
}

// mustSlug: 1..64 of [a-z0-9-] — URL- and markdown-safe by construction.
func mustSlug(slug string) {
	if len(slug) == 0 || len(slug) > 64 {
		panic("courtv2: a slug is 1..64 characters")
	}
	for i := 0; i < len(slug); i++ {
		ch := slug[i]
		ok := (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-'
		if !ok {
			panic("courtv2: a slug is lowercase letters, digits, and hyphens only")
		}
	}
}
