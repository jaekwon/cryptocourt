// Package kourtv2 is kourt V2: no-loss conviction staking. Each court is
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
// V1 realm at realm/r/kourtv1 is untouched and remains the audited reference.
package kourtv2

import (
	"strings"

	checkpoint "gno.land/p/kourt/checkpoint/v0"
	curve "gno.land/p/kourt/curve/v0"
	governor "gno.land/p/kourt/governor/v0"
	grc20votes "gno.land/p/kourt/grc20votes/v0"
	bptree "gno.land/p/nt/bptree/v0"
)

const errStaleRealm = "kourtv2: stale realm; call through a crossing function"

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
	// answer bond = 6%·X̄ (min 1), capped by params, and the collateralization
	// floor in PostAnswer raises it toward 1.6× the destroyable draw — which is
	// where the real pricing now lives. 600 = slashXBps*4/3, HARDCODED rather
	// than derived: deriving it turns the slashXBps coupling below into `X > X`,
	// and TestEconomicConstantsAreTheCalibratedValues is already the alarm that
	// fires if slashXBps moves. Why not 450: at exactly slashXBps the settle
	// refund is zero (the whole bond is retained as the slash reserve) and at 449
	// the realm refuses to deploy; 600 returns 25% at settle and leaves margin.
	answerBondBps = int64(600)
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
	depositFeeBps   = int64(1000)  // 10% of the deposit, conditionally refunded

	// Answer priority (records.gno): difficulty-weighted net record ≥ 3 earns a
	// 24h priority window; gate off until 3 addresses qualify; one active
	// priority claim per address.
	priorityNetRecord    = 3
	priorityColdStartN   = 3
	priorityWindowBlocks = int64(17_280) // 24h

	settleDelay      = int64(51_840)    // 72h before an undisputed answer settles
	deadClaimTimeout = int64(1_451_520) // 12 weeks: unanswered claims close

	// Moderation build constants (MODERATION.md §9, §2). metaSlug is reserved so
	// only realm init can create the meta court; the public StartCourt path
	// refuses it. maxStakeOpenDelay caps the polish window at 24h.
	metaSlug = "meta"
	// Meta's emission is a FIXED ABSOLUTE weekly budget, never S_live × bps
	// (§13.8, unanimous). Meta's supply tracks platform-wide burn, so a
	// supply-proportional budget would size the appeals court's emission off
	// unrelated courts' volume — inflating the prize for junk appeals and
	// attaching a platform-growth yield story to the one token that must not
	// have one. Absolute keeps the SENIOR lane (comp/bounty/carrot) funded, so
	// the deployer's +EV junk-appeal policing survives, while the lifetime bound
	// stays provably tiny: 100 CC × Σ2^(−n/104) ≈ 15,000 CC, four orders under
	// the tally ceiling.
	metaWeeklyBudget = int64(100_000_000) // 100 CC/week, stepped down
	// Meta's answerability and deposit floors scale with ITS OWN supply, because
	// that supply grows with platform burn and Params have no retune path after
	// deploy: fixed constants would decay to nothing as the platform grew, and
	// §5.3's flood-deposit argument would decay with them.
	//
	// v0.15 (3-agent panel, MODERATION.md §14): the previous 0.01% arm needed
	// ~5e8 GNOT of CLAIMED burn to overtake the 100 CC constant, so it never
	// bound and both floors were fixed in practice. Worse, the panel found the
	// constant is wrong at BOTH ends. A ~500–1,000 GNOT genesis buy puts launch
	// meta supply near 1,000 CC, where a 100 CC answerability floor is ~10% of
	// supply and the full filing cost (stake + the worst-case bond) is ~15% — so
	// FILING AN APPEAL COST 2–3× MORE THAN DECIDING ONE, the same
	// incumbency-lock-by-price that mustElectionInvariants already forbids in
	// the election lane, unguarded here. The fixed arms are therefore demoted
	// to anti-dust floors and the relative arms carry the policy.
	// TWO LANES, deliberately not unified (3-agent panel, unanimous). The meta
	// pair prices a FRANCHISE-SCOPED act: an appeal's verdict installs or
	// suspends moderator sets, so pinning it to the franchise is dimensionally
	// right, and meta's claim count is O(1) forever.
	answerXFloorBps = int64(50) // 0.50% of META supply — the audited β from modvote
	depositFloorBps = int64(2)  // 0.02% — sized by §5.3's pending-list flood rule
	// The ORDINARY pair is a tenth of it, because an ordinary court's claims are
	// the product and the floors SUM. Stake is custodial (Stake transfers into
	// escrow), so CC backing claim A cannot back claim B, and each answered
	// claim locks the stake plus the bond, worst case (1+maxBondBps/Bps)×floor. Aggregate demand is
	// N × 1.5 × bps, a pure number independent of supply, so the fraction is
	// what decides how many claims a court may run at once:
	//
	//	50 bps → ~40 concurrent answered claims at realistic staking
	//	10 bps → ~200
	//
	// Meta never feels that because N stays O(1); an ordinary court's N grows
	// with its own success. Worse, escrowed CC cannot vote while quorumFloor's
	// dominant arm reads RAW supply, so a high floor starves the dispute quorum
	// in the same motion — at 50 bps the dispute machine jams near 127 claims.
	//
	// And the number that settles it: 50 bps overtakes a flat 100 CC at only
	// 20,000 CC of supply, so applying meta's fraction here would be MORE
	// expensive than the constant this change exists to remove, for every court
	// above that. 10 bps reproduces the old 100 CC almost exactly at 100,000 CC
	// and fixes both tails.
	ordAnswerXFloorBps = int64(10) // 0.10% of an ordinary court's own supply
	ordDepositFloorBps = int64(1)  // 0.01% — §5.3's rule is meta-only; opening a
	//                                claim is the product here, so keep the door
	//                                a tenth of the answer it opens.
	maxCourtNameLen = 100
	// maxSlugLen keeps uppercase(slug) inside GRC20's symbol-length bound.
	maxSlugLen        = 11
	maxStakeOpenDelay = int64(17_280) // 24h
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
		panic("kourtv2: curveCap × emission growth bound exceeds the tally-safe supply ceiling")
	}
	// §13.8 — the meta franchise does NOT need a new supply bound, and this
	// assertion is what makes that claim checkable rather than asserted. The
	// franchise mint routes through meta's OWN curve, so every unit of meta
	// primary issuance is still bounded by curveCap exactly as a purchased unit
	// is; the only NEW term is meta's absolute lifetime emission, the geometric
	// sum of a stepped-down weekly budget (Σ2^(−n/104) < 151). If a future
	// change ever mints the franchise outside the curve, this check is the one
	// that must be revisited — and `mustInvariants` would otherwise keep
	// certifying a property that had quietly stopped holding.
	if metaLifetimeEmission := metaWeeklyBudget * 151; curveCap > maxSupply-metaLifetimeEmission {
		panic("kourtv2: curveCap + meta's lifetime emission exceeds the tally-safe supply ceiling")
	}
	// THE DRAW CAP MUST BE INERT AT THE ORDINARY TIER. crystallize.gno caps a
	// claim's draw at answerBond0 minus the carrot, and PostAnswer's floor gives
	// answerBond0 >= (slashDrawBps/1e4)·mg_max >= (slashDrawBps/1e4)·mg_win, so
	// capd >= (slashDrawBps/1e4 − splitCarrot/100)·mg_win. Requiring that to cover
	// tierMidX·mg_win is exactly slashDrawBps >= 10700 — and it is the only
	// deploy-time certificate that the published MID rate is a promise rather than
	// a calibration. Above MID the cap is DESIGNED to bind, which is why the bound
	// is tierMidX and not tierHighX.
	//
	// NOT a leverage bound, and saying so matters. The cap already gives
	// destroyed <= answerBond0, so L <= 1 holds at every tier without this line;
	// justifying it as "L <= 1 at MID" would make it certify something already
	// true, which is precisely the defect the check below had for years. Constants
	// only, no runtime term — its premises are unconditional facts in answer.gno
	// and crystallize.gno, not a falsifiable model. Verified by mutation in this
	// form: it fires on slashDrawBps AND on splitCarrot.
	//
	// This replaces a check on answerBondBps, and note it contains no bond term at
	// all: with the bond keyed to the destroyable draw, the thing worth certifying
	// is the SLASH multiple, not the base.
	if slashDrawBps < (tierMidX*100+splitCarrot)*100 {
		panic("kourtv2: the slash multiple does not cover the mid draw plus the carrot — the draw cap would cut the published MID rate")
	}
	// The dispute bond's own-answer arm keeps round 1 at q > 1/3 everywhere:
	// 2 × min(20%·X̄, 40%·A) ≤ 80%·A.
	//
	// THE SHARED answerBondBps FACTOR IS DROPPED, for two reasons. It cancelled,
	// so the check was a tautology dressed as an invariant; worse, it could
	// TRUNCATE both sides to zero and pass a real violation (at answerBondBps
	// <= 1928 an own-answer arm of 4001 breaks the property and the old form did
	// not fire).
	//
	// AND THIS LINE IS NOW LOAD-BEARING. At 5000 bps the two arms of the min TIED
	// at 20%·X̄, so the X̄ arm shadowed this property; at 600 the ANSWER arm binds
	// on every claim, and nothing else holds the round-1 bar at q > 1/3.
	if 2*disputeBondOfAnswerBps > compOfBurnBps {
		panic("kourtv2: dispute bond arm breaks the round-1 honest-dispute bar")
	}
	// 20%/yr ceiling honesty: 52 weeks of the weekly budget may not exceed
	// 2000 bps of supply.
	if budgetWeeklyBps*52 > 2000 {
		panic("kourtv2: the weekly budget exceeds the 20%/yr inflation ceiling")
	}
	// The split must sum to ≤ 100 tier-scaled points (the carrot is separate,
	// mid-weight and senior — see emission.gno).
	if splitWinners+splitAuthor+splitAnswerer != 93 {
		panic("kourtv2: the tier-scaled split must sum to 93 points")
	}
	// CALIBRATION, NOT A SAFETY PROOF — read before trusting this (audit round 2).
	// A check over CONSTANTS can only make a constant-space claim: on a pool
	// roughly CONSTANT over a ≤12-week life, the draw arm k·midGross lands under
	// the base bond, i.e. PostAnswer's collateralization floor would stay a NO-OP on
	// the honest path. THAT PREMISE IS NOW DELIBERATELY FALSE — the floor binding is
	// the design, and the check below asserts it can. Kept as history because the
	// reasoning about what a constant-space check can and cannot claim still holds.
	// It does NOT prove the
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
	// INVERTED, deliberately, and the direction is the whole change. The floor
	// BINDING is now the design — it is what keys the bond to the pool a wrong
	// answer could destroy, instead of to a flat fraction of X̄. So this asserts
	// the PREMISE still holds: that the draw arm can outgrow the base arm at all.
	// It is a premise tripwire rather than a safety bound (it only fires above
	// 3083 bps, so a revert to 2000 would pass it), and it is deliberately kept as
	// the one remaining answerBondBps coupling so the constant stays greppable.
	if slashDrawBps*maxMidGrossBps/10000 <= answerBondBps {
		panic("kourtv2: the draw arm never reaches the base bond — the collateralization floor is inert and the max-keying prices nothing")
	}
	// The worst-case bond in bps of X̄. After the floor became the sizer this is
	// the DRAW arm, not the base, so anything pricing against "the bond" must use
	// this and not answerBondBps. Without it the supplyFloor lid below admits
	// filing at 6.17% of supply against the 5% turnout bar — a 23.4% overshoot of
	// the very incumbency-lock-by-price invariant it exists to hold, reachable on
	// a small sealed court with a claim aged toward the hot 12-week extremal. At
	// 5000 bps this was impossible because the floor never exceeded the base.
	maxBondBps := slashDrawBps * maxMidGrossBps / 10000
	if maxBondBps < answerBondBps {
		maxBondBps = answerBondBps
	}
	// The flat arm's twin coupling: the base bond must cover the 4.5%·X̄ arm with
	// MARGIN. The bare `slashXBps > answerBondBps` form passed at exactly 450 —
	// which is precisely the value that zeroes the settle refund, since the whole
	// bond is then retained as the slash reserve. The margined form is what makes
	// 600 the enforced floor rather than a convention.
	if slashXBps*4/3 > answerBondBps {
		panic("kourtv2: the flat slash arm leaves the base answer bond no settle-refund margin")
	}
	// The deploy check and the runtime lid must price off the SAME worst case, or
	// one of them is wrong. Pin it here rather than duplicating the arithmetic.
	if maxAnswerBondBps() != maxBondBps {
		panic("kourtv2: maxAnswerBondBps drifted from the deploy-time worst-case bond")
	}
	// META APPEALS LANE (v0.15). mustElectionInvariants has long carried this
	// ratio gate for the election lane; the appeals lane never had one, which is
	// how a 100 CC constant came to price filing above deciding at launch scale.
	// Filing costs (Bps+answerBondBps)/Bps × X̄, and X̄ floors at answerXFloorBps
	// of supply, so the whole filing cost must stay strictly under the 5% bar.
	// BOTH lanes, all three checks. A gate that certifies one of two constant
	// pairs certifies nothing about the other, and the ordinary pair is the one
	// every court uses.
	for _, l := range []struct {
		name    string
		floor   int64
		deposit int64
	}{
		{"meta", answerXFloorBps, depositFloorBps},
		{"ordinary", ordAnswerXFloorBps, ordDepositFloorBps},
	} {
		filing := l.floor * (grc20votes.Bps + maxBondBps) / grc20votes.Bps
		if filing >= quorumSupplyBps {
			panic("kourtv2: the " + l.name + " answerability floor prices filing above winning the vote — incumbency lock by price")
		}
		if 50*l.deposit < filing {
			panic("kourtv2: a 50-row flood is cheaper than the self-answer escape from it (§5.3), " + l.name + " lane")
		}
		if l.deposit >= l.floor {
			panic("kourtv2: the " + l.name + " deposit floor exceeds its answerability floor")
		}
	}
}

func init() { mustInvariants() }

// Params are the per-court knobs, frozen at StartCourt through mustSane exactly
// as V1: no retune entrypoint exists.
type Params struct {
	disputeThresholdBps  int64 // overturn bar; > 5000 so a tie never overturns
	votingBlocks         int64 // dispute vote length
	graceBlocks          int64 // governor slot-free grace
	minAnswerX           int64 // min trailing total stake (CC base) to answer
	answerBondCapCC      int64 // 0 = uncapped (V1 convention)
	minClaimDepositCC    int64 // never zero
	escrowMinBlocks      int64 // 1 week
	escrowMaxBlocks      int64 // 3 weeks
	stakeOpenDelayBlocks int64 // polish window: staking closed for this long after OpenClaim (0 = none)
}

func defaultParams() Params {
	return Params{
		disputeThresholdBps:  5001,
		votingBlocks:         120_960,
		graceBlocks:          17_280,
		minAnswerX:           1_000_000, // 1 CC — a DUST arm; the fraction carries policy
		answerBondCapCC:      0,
		minClaimDepositCC:    1_000_000, // 1 CC
		escrowMinBlocks:      120_960,
		escrowMaxBlocks:      362_880,
		stakeOpenDelayBlocks: 0, // default: no polish window (opt in via StartCourtP)
	}
}

// mustSane refuses params no bound can rescue, V1-style.
func (p Params) mustSane() Params {
	if p.disputeThresholdBps < 5001 || p.disputeThresholdBps > 10000 {
		panic("kourtv2: the overturn threshold must be in [5001, 10000]")
	}
	if p.votingBlocks < 1 || p.graceBlocks < 1 {
		panic("kourtv2: vote and grace windows must be positive")
	}
	if p.minAnswerX < 1 {
		panic("kourtv2: minAnswerX must be positive")
	}
	if p.minClaimDepositCC < 1 {
		panic("kourtv2: the claim deposit must never be zero")
	}
	if p.escrowMinBlocks < 1 || p.escrowMaxBlocks < p.escrowMinBlocks {
		panic("kourtv2: the escrow window is malformed")
	}
	// A DEFAULTED VERDICT'S LADDER MUST FIT. ResolveDispute floors the reopen window
	// at ladderWindow when the standing verdict is a quorum-less default, and that
	// floor is applied with a max() — so it OVERRIDES escrowMaxBlocks, and a ceiling
	// below it would be silently ignored rather than respected. Checking the ceiling
	// is what gives this a firing input at all: the obvious form, comparing against
	// votingBlocks*(maxFailedRounds-2), is UNSATISFIABLE, since ladderWindow exceeds
	// that by construction for every graceBlocks >= 1 — swept over 1.8M legal param
	// sets and it fires only at maxFailedRounds = 0.
	//
	// mustSane rather than mustInvariants, and for a sharper reason than "these are
	// all params": maxFailedRounds is a package CONSTANT, so the relation is two
	// params against a constant. mustInvariants sees only constants and no
	// params-only gate existed, which is exactly why neither saw this coupling.
	if ladderWindow(p) > p.escrowMaxBlocks {
		panic("kourtv2: the escrow ceiling cannot fit the failed-round ladder a defaulted verdict must walk")
	}
	if p.answerBondCapCC < 0 {
		panic("kourtv2: answerBondCapCC must be non-negative")
	}
	if p.stakeOpenDelayBlocks < 0 || p.stakeOpenDelayBlocks > maxStakeOpenDelay {
		panic("kourtv2: the polish window must be in [0, 24h]")
	}
	return p
}

// Court is one court instance. Every field is unexported and no method returns
// a /p/ pointer (borrow rule #2). Emission state lives on the court so each
// coin's reservoir is isolated with its ledger.
type Court struct {
	id   string
	name string
	// One paragraph saying what this court is for and what it will not take.
	// Empty on every court that predates it, which reads as "no description" —
	// the same "zero on pre-upgrade" shape claimState.openedAtTime uses, so there
	// is no migration and no version field.
	//
	// EDITABLE, unlike a claim's body, and the asymmetry is the design. A claim's
	// body is fixed at creation because a revisable one lets an author take a
	// position, watch the market, then rewrite the framing until their side is the
	// true one (COURTS_STRUCTURE.md §4) — the body is part of the thing being
	// adjudicated. A court description is a signpost over a docket, adjudicates
	// nothing, and gates nothing: no money path reads it. When it goes wrong the
	// remedy is the one that already exists for bad curation — the moderators who
	// wrote it are elected, and replaceable by the same vote.
	desc string
	tier uint8
	admin address // creator; recorded, unused — no retune path exists

	coin *grc20votes.Ledger // the court coin (CC)
	gov  *governor.Governor // the dispute arbiter; electorate = coin
	crv  curve.Curve        // one-way GNOT -> CC; proceeds are burned

	// escrow holds deposits and bonds — NOT stake, since v0.34 — and it never
	// votes, because those coins are physically here rather than with their
	// owners. It holds them because it has to be able to burn or redirect them
	// on a loss; that is what makes them custodial and stake not.
	//
	// It is NOT "netted out of the quorum floor", which this comment used to
	// claim (v0.29). quorumFloor and qualityBars net the escrow only on their X̄
	// arm; the 5%-of-supply arm that usually dominates reads RAW supply, and the
	// max() between them escapes the votable/3 ceiling the first arm imposed.
	// That sentence is how the arrangement came to be read as a simple oversight
	// one lane over from electionFloor, which genuinely does net. Both bars now
	// carry a total reachability clamp instead; the netting still does not happen
	// and should not be assumed.
	//
	// STAKE IS NO LONGER HERE (v0.34, lock.gno). It used to be, and it bought
	// exactly one thing: disenfranchisement. Stake principal is never slashed and
	// never burned — WithdrawStake returns it 1× on both sides — so custody
	// secured nothing, while removing the staker's vote COURT-WIDE when the design
	// only ever wanted it CLAIM-SCOPED, which the next clause already does
	// properly: participants of a claim are excluded from that claim's quality
	// lane BY RULE (isParticipant), not by where their coins sit.
	//
	// Stake is a lock recorded against the holder's own balance now, so the coins
	// stay put and keep voting. What custody had been doing invisibly was making
	// double-commitment impossible — the ledger refused a second spend of coins
	// that had left — so that check now lives in this realm, on every path that
	// moves a user's CC in here. See lock.gno; it is the whole risk of the change.
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
	// Argument edges (argument.gno, COURTS_STRUCTURE.md §5). Two indexes over ONE
	// edge object so both directions are a prefix scan. Nil until the first edge
	// exists — every read tests for nil rather than allocating, because a query
	// carries no storage deposit.
	argOut          *bptree.BPTree // be(from)|be(to) -> *argEdge
	argIn           *bptree.BPTree // be(to)|be(from) -> the SAME *argEdge
	// locked is addr -> staked CC still sitting in that holder's own balance
	// (lock.gno). Created eagerly with the others: it is a money-path read on
	// every deposit and bond, and a lazily-built tree would give each of those
	// a second branch that has to agree with the write path.
	locked         *bptree.BPTree // addr -> int64 (lock.gno)
	voteLocks      *bptree.BPTree // addr|kind|id|sub -> int64 (votelock.gno)
	stakeIdx       *bptree.BPTree // addr|be(claimID/page) -> *stakeRow (stakeindex.gno)
	qualifiedCount int            // addresses at score ≥ priorityNetRecord

	// Moderation state (moderation.gno) — render-layer only; no money path
	// reads it. Lazily created on first moderation touch (ensureMod), so a
	// court that is never moderated carries a single nil pointer. See
	// MODERATION.md §2 (the constitution) and §4 (state homes).
	mod *courtMod

	// Per-claim stake-history pages (stakeseries.gno) — one shared archive for
	// all this court's claims, keys "cs:<id>:yh|nh|yd|nd". Lazily created on
	// the first recorded stake move, so old courts carry a nil until touched.
	// Separate from the coin's own archive (inside the Ledger) by construction.
	csArch *checkpoint.Archive

	// Policing surfaces (strips.gno, MODERATION.md §5.3). Deliberately NOT on
	// courtMod: the money path writes them at lifecycle transitions, and going
	// through ensureMod would give PostAnswer a moderator-set side effect.
	// Lazily created; keyed so ascending iteration IS nearest-deadline-first.
	stripIdx   *bptree.BPTree // be(deadline)|be(claimID) -> claimID
	pendingIdx *bptree.BPTree // be(openedAt)|be(claimID) -> claimID

	// Directory ordering (modrender.gno): cumulative GNOT burned into this
	// court's curve — the un-sybil-able front-page rank — plus this court's
	// current key in the burn index and its creation sequence.
	burnedGNOT int64
	burnKey    string
	createdSeq uint64

	// absBudget: when > 0 this court's weekly emission is a FIXED ABSOLUTE
	// amount (stepped down like every other budget) instead of S_live × bps.
	// Only the meta court uses it — see metaWeeklyBudget (§13.8).
	absBudget int64
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
	return startCourtUser(cur.Previous().Address(), cur.Address(), slug, name, 0)
}

// StartCourtP is StartCourt with an opt-in polish window (§9): staking is
// closed for stakeOpenDelayBlocks after each OpenClaim, giving the author and
// moderators a pre-stake window to fix wording before anyone bets. The default
// StartCourt uses 0 (no window), which preserves every existing caller — so no
// fixture sweep is forced by adding the field (the audit's concern is moot when
// the default is 0 and the window is opt-in).
func StartCourtP(cur realm, slug, name string, stakeOpenDelay int64) string {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	return startCourtUser(cur.Previous().Address(), cur.Address(), slug, name, stakeOpenDelay)
}

// startCourtUser is the public creation path: it refuses the reserved `meta`
// slug (only realm init may create the meta court, via startCourt directly),
// then delegates to startCourt.
func startCourtUser(admin, escrowAddr address, slug, name string, delay int64) string {
	if slug == metaSlug {
		panic("kourtv2: the 'meta' slug is reserved")
	}
	return startCourt(admin, escrowAddr, slug, name, delay)
}

// startCourt creates a court: its coin, governor, curve, and claim book. It is
// the reusable core — realm init calls it directly (with the realm address as
// escrow) to deploy the meta court, which is why it takes admin/escrow as
// arguments rather than reading a crossing realm. No payment is collected
// (court-count floods are storage-deposit-priced, MODERATION.md §2/§13.5).
func startCourt(admin, escrowAddr address, slug, name string, delay int64) string {
	mustSlug(slug)
	mustCourtName(name)
	if courts.Has(slug) {
		panic("kourtv2: that slug is taken")
	}
	p := defaultParams()
	p.stakeOpenDelayBlocks = delay
	// The symbol is DERIVED from the slug, never a shared literal. Every court
	// used to mint its ledger as "COURT", which grc20votes also adopts as the
	// ledger id — so every court's coin was identically labelled AND identically
	// identified. Wallets, explorers and indexers key their display on the
	// symbol rather than the package path, so a malicious court's coin rendered
	// pixel-identical to the flagship's, while the two are non-fungible and
	// backed by entirely separate one-way curves. Deriving from the slug makes
	// the symbol a bijection with an already-unique, deposit-priced name.
	// The ledger reads THIS realm's height, so a fast-forwarded test chain
	// moves vote epochs with everything else. On an ordinary chain heightNow()
	// is exactly runtime.ChainHeight().
	coin := grc20votes.NewLedgerWithClock(name, courtSymbol(slug), coinDecimals, epochBlocks, realmClock{})
	c := &Court{
		id:             slug,
		name:           name,
		tier:           tierListed,
		admin:          admin,
		coin:           coin,
		gov:            governor.New(coin, coin),
		crv:            curve.New(curveDenom, curveCap),
		escrow:         escrowAddr,
		claims:         bptree.NewBPTree32(),
		queue:          bptree.NewBPTree32(),
		records:        bptree.NewBPTree32(),
		locked:         bptree.NewBPTree32(),
		voteLocks:      bptree.NewBPTree32(),
		stakeIdx:       bptree.NewBPTree32(),
		params:         p.mustSane(),
		createdAt:      heightNow(),
		curBudgetBpsFP: budgetBpsFPStart,
	}
	c.lastAccrual = c.createdAt
	if slug == metaSlug {
		c.absBudget = metaWeeklyBudget // §13.8: never S_live × bps
	}
	c.gov.Adopt(disputeKind{}, disputeRules(c.params))
	courts.Set(slug, c)
	indexNewCourt(c) // directory ordering (burn-desc / creation-newest)
	if directoryAdmin == "" {
		directoryAdmin = admin
	}
	return slug
}

// mustCourtName: 1..maxCourtNameLen. Capped so a purge-worthy name is bounded
// and render stays predictable (MODERATION.md §2 user-text inventory).
// maxCourtDescLen matches the overlay's own curation schema, which has validated
// exactly this for as long as the description has been a browser-side field: 240
// characters, and no newline. Single paragraph is not fussiness — the description
// renders inline beside a court name in list rows, where a newline forges a row.
const maxCourtDescLen = 240

// SetCourtDesc writes the court's description. One active moderator, the same
// authority every other curation write takes and for the same reason recorded in
// folders.gno: zero economic weight, instantly reversible, so the m-of-n ceremony
// would tax routine curation for no security gain.
func SetCourtDesc(cur realm, courtSlug, desc string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	requireFolderMod(c, who)
	mustCourtDesc(desc)
	c.desc = desc
	emitModAct(c.id, 0, "court-desc", who)
}

func mustCourtDesc(desc string) {
	if len(desc) > maxCourtDescLen {
		panic("kourtv2: a court description is at most 240 characters")
	}
	for i := 0; i < len(desc); i++ {
		if desc[i] == '\n' || desc[i] == '\r' {
			panic("kourtv2: a court description is a single paragraph")
		}
	}
}

func mustCourtName(name string) {
	if len(name) == 0 || len(name) > maxCourtNameLen {
		panic("kourtv2: a court name is 1..100 characters")
	}
}

// ------------------------------------------------------------------ reads --

// CourtDesc is the court's description, gated the way its name is. Empty for a
// court that has none and for a purged one.
func CourtDesc(courtSlug string) string {
	return courtDescFor(mustCourt(courtSlug))
}

// CourtCount is how many courts have been started.
func CourtCount() int { return courts.Size() }

// Exists reports whether a slug names a court.
func Exists(slug string) bool { return courts.Has(slug) }

func CourtName(slug string) string { return mustCourt(slug).name }

// CourtSymbol is a court coin's ticker — unique per court, derived from its
// slug. Display it namespaced (KOURT:<SYMBOL>) anywhere outside its own court.
func CourtSymbol(slug string) string { return mustCourt(slug).coin.Symbol() }

// CoinDecimals is the scale every court coin uses. Exported because anything
// quoting a court coin against another asset has to agree on it — a wrapper, a
// pool, an indexer — and a hardcoded 6 elsewhere is a mispricing waiting for the
// day this moves.
func CoinDecimals() int { return coinDecimals }
func CoinSupply(slug string) int64   { return mustCourt(slug).coin.TotalSupply() }

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

// effMinAnswerX / effMinDeposit are the LIVE floors: a fraction of the court's
// OWN supply, with each court's frozen params serving as the dust arm.
//
// TWO LANES. v0.15 made this supply-relative for META. v0.27 extends it to every
// court — the premise that ordinary courts were safe was wrong, since StartCourt
// lets a creator set `stakeOpenDelayBlocks` and nothing else — but at a TENTH of
// meta's fraction, because the two are not the same kind of price. See the
// constant block: an ordinary court's claims are the product and their floors
// SUM out of one custodial escrow, so the fraction decides how many claims the
// court may run at once; meta's claim count is O(1) forever.
//
// The params are the dust arm rather than a separate constant, which keeps
// `minAnswerX` alive and meaningful — a creator-chosen anti-rounding floor,
// exactly as `minClaimDepositCC` already serves effMinDeposit — instead of
// leaving it read only by mustSane.
func effMinAnswerX(c *Court) int64 {
	if c.id == metaSlug {
		return supplyFloor(c, answerXFloorBps, c.params.minAnswerX)
	}
	return supplyFloor(c, ordAnswerXFloorBps, c.params.minAnswerX)
}

func effMinDeposit(c *Court) int64 {
	// Unpegged from effMinAnswerX/100 (which failed §5.3 arithmetically: a
	// 50-row flood parked half of ONE self-answer escape). Its own fraction now,
	// sized by the deploy invariant `50·depositFloorBps ≥ 1.5·answerXFloorBps`.
	if c.id == metaSlug {
		return supplyFloor(c, depositFloorBps, c.params.minClaimDepositCC)
	}
	return supplyFloor(c, ordDepositFloorBps, c.params.minClaimDepositCC)
}

// supplyFloor is max(dust, bps·supply), clamped so the resulting filing cost
// can never exceed the turnout bar. Three deliberate choices:
//
//   - RAW supply, not votable. Votable is deflatable for free — anyone parking
//     no-loss stake in the escrow shrinks it — so a votable base would let an
//     attacker lower the appeals bar at zero cost, and would make each new
//     appeal cheapen the next.
//   - The LAST SEALED epoch, not TotalSupply(). Live supply is atomically
//     griefable: PostAnswer reads this floor (answer.gno), ClaimMetaFranchise
//     mints into supply, so a whale sitting on unclaimed franchise could
//     front-run an honest answer in the same block, push the floor above the
//     appellant's X̄, and revert it — repeatably, for free, keeping coins they
//     were owed anyway. A sealed read closes that for nothing.
//   - CLAMPED, the v0.14 lesson applied to this lane. The deploy invariant
//     covers the ratio arm, but no constant can see the dust arm: below ~30 CC
//     of supply the 1 CC dust floor prices filing above the 5% turnout bar and
//     inverts the guarantee, exactly as flagMinCC did to the election bond.
// maxAnswerBondBps is the largest bond PostAnswer can demand, in bps of X̄ — the
// draw arm at the hot-rate 12-week maximum, or the base arm if that is larger.
//
// It exists because "the bond" stopped meaning answerBondBps. PostAnswer's floor
// raises the bond toward 1.6× the destroyable draw, so anything pricing a cost
// against the bond must use the worst case or it under-prices by up to 5×.
// mustInvariants pins this against its own copy of the arithmetic so the two
// cannot drift.
func maxAnswerBondBps() int64 {
	maxRateBpsFP := 255 * (r0WeeklyBps*1_000_000 + budgetBpsFPStart) / 100
	maxMidGrossBps := maxRateBpsFP * (deadClaimTimeout / periodBlocks) / 1_000_000
	if arm := slashDrawBps * maxMidGrossBps / 10000; arm > answerBondBps {
		return arm
	}
	return answerBondBps
}

func supplyFloor(c *Court, bps, dust int64) int64 {
	// Epoch() is 1-based and epoch 0 means "before this token existed", which
	// PastTotal refuses rather than reporting as zero. Unlike quorumFloor, this
	// runs at OpenClaim — reachable in meta's very first epoch — so the
	// pre-history case is real and resolves to the dust arm.
	var supply int64
	if at := c.coin.Epoch(); at > 1 {
		supply = c.coin.PastTotal(at - 1)
	}
	v := mulDiv128(supply, bps, grc20votes.Bps)
	if v < dust {
		v = dust
	}
	// Filing costs (Bps+bond)/Bps × X̄; hold that STRICTLY under the 5% bar. The
	// obvious lid — 5%·supply × Bps/(Bps+bond) — makes filing exactly EQUAL the
	// bar at every supply, so the runtime clamp admitted the very equality
	// mustInvariants rejects on the constants. One bps of slack restores the
	// strict inequality, and it matters precisely where the lid binds: the
	// low-supply case the dust arm reaches.
	//
	// PRICED OFF THE WORST-CASE BOND, not the base. PostAnswer's floor can raise
	// the bond to the draw arm's 3083 bps, so pricing this off answerBondBps alone
	// admitted filing at 6.17% of supply against the 5% bar — a 23.4% overshoot of
	// this exact invariant, on a small sealed court with an aged claim. Harmless
	// at 5000 bps, where the floor never exceeded the base; live at 600.
	if lid := mulDiv128(supply, quorumSupplyBps, grc20votes.Bps) *
		(grc20votes.Bps - 1) / (grc20votes.Bps + maxAnswerBondBps()); lid > 0 && v > lid {
		v = lid
	}
	if v < 1 {
		v = 1
	}
	return v
}

// mustCourt fetches a court or panics. Never exported.
func mustCourt(slug string) *Court {
	v := courts.Get(slug)
	if v == nil {
		panic("kourtv2: no such court")
	}
	return v.(*Court)
}

// courtSymbol is the per-court coin symbol: the slug upper-cased, hyphens kept.
// Keeping hyphens matters — stripping them would break injectivity ("ab-c" and
// "abc" would collide) and silently reintroduce the shared-symbol problem.
// Render namespaces it as KOURT:<SYMBOL>; a bare symbol appears only inside its
// own court, so a court coin can never read as the platform token.
func courtSymbol(slug string) string { return strings.ToUpper(slug) }

// reservedSlugs may never be registered: each would let a court impersonate the
// platform token or a well-known asset in any wallet that shows only symbols.
// (metaSlug is deliberately NOT listed: init must be able to create it, and the
// PUBLIC path refuses it separately in startCourtUser.)
// "court" is reserved alongside "kourt": it is a homophone of the platform
// ticker, and a court coin symbol is the upper-cased slug, so leaving it open
// would let someone mint COURT and have wallets show it beside KOURT.
var reservedSlugs = []string{
	"kourt", "court", "gno", "gnot", "ugnot",
	"btc", "eth", "usdc", "usdt",
}

// mustSlug: 1..maxSlugLen of [a-z0-9-] — URL- and markdown-safe by
// construction, and short enough that courtSymbol always satisfies GRC20's
// symbol-length bound.
func mustSlug(slug string) {
	if len(slug) == 0 || len(slug) > maxSlugLen {
		panic("kourtv2: a slug is 1..11 characters")
	}
	for _, r := range reservedSlugs {
		if slug == r {
			panic("kourtv2: that slug is reserved")
		}
	}
	for i := 0; i < len(slug); i++ {
		ch := slug[i]
		ok := (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-'
		if !ok {
			panic("kourtv2: a slug is lowercase letters, digits, and hyphens only")
		}
	}
}
