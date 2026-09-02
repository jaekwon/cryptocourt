// Standing: the non-transferable participation record that will price posting on
// a claim's board (docs/CLAIM_BOARDS.md §2). It is NOT the answer record, and the
// separation is load-bearing — see the two-ledger note below.
//
// TWO RULES, AND EVERY CREDIT IN THIS FILE OBEYS BOTH.
//
//  1. CONSERVED UNDER SPLITTING. n addresses sharing one holder's weight must
//     never earn more than that holder would have earned undivided. A per-event
//     credit ("you voted: +1") is sybil-linear for free — a whale becomes twenty
//     keys, each does a twentieth of the work, and all twenty are paid in full.
//     So every credit here is PROPORTIONAL to a capital quantity, and the two
//     that are per-claim (author, dispute) are unsplittable by construction: a
//     claim has one author, and a decided round has one winner — the answerer it
//     upheld or the disputer stamped in overturnBy.
//
//  2. INHERIT AN EXISTING WEIGHT GATE. Where this realm already built a bar for
//     "this actor did the real thing", the credit hangs off THAT bar and not off
//     a cheaper cousin one branch over. Three earlier drafts of this file each
//     picked the cheaper cousin and each was a farm:
//
//     - the flag credit on "conclusive low" instead of slashGrade. Conclusive
//     low needs only demotionBar (a QUARTER of the full bar), and on that
//     branch ResolveFlag returns the flagger's bond WHOLE and mints a bounty
//     on top — so the credit would have cost negative CC.
//     - the dispute credit on "prevailed" instead of credEligible. That is
//     verbatim the argument audit M2-1 rejected: OpenDispute's own comment
//     says the sybil-wallet check is "hygiene only… the REAL credential
//     defense is the credEligible weight bar".
//     - an authorship credit on MID. Default-mid is what an unlooked-at claim
//     gets; crediting it is the author-mill's habitat (PLAN §3.4 F1), and it
//     is the same mistake A18 already corrected for the answer record.
//
// WHY STANDING IS DENOMINATED IN CC BASE UNITS. The alternative was a
// dimensionless point per act, which cannot satisfy rule 1 and cannot be summed
// across categories that measure different things. Every credit here converts to
// the CC magnitude of the capital that earned it, scaled by one bps RATE per
// category (creditRates — a realm default a court may override), so the sum is a
// single int64 in one unit.
//
// satAdd guards it, NOT mustAdd, and the difference is deliberate: these credits
// run inside settlement, where a checked-overflow panic would strand a verdict.
// See satAdd's own note.
//
// The consequence, stated rather than implied: STANDING IS CAPITAL-WEIGHTED.
// That is not a defect that survived review, it is the only class of defence
// MODERATION.md admits — "address-keyed defenses fall to sybils; only
// capital-keyed, deadline-keyed, or residency-keyed defenses hold". An earlier
// design tried to blunt it with throughput tiers and inverted itself: a tier
// ladder is concave, so twenty-five small keys out-post one large one, and the
// ceiling bound the honest single identity while costing the whale nothing.
//
// MONOTONE. Nothing in this file reduces a score. Standing does not decay and
// does not sleep — warmth decays because it is a BAR whose staleness would make
// a dormant court undecidable, and a posting rate allocates nothing scarce.
//
// THAT JUSTIFICATION IS NARROWER THAN IT WAS, and the narrowing is recorded
// rather than quietly dropped. Once standing also weights an upvote, it buys a
// position on a page, and a position IS scarce — so monotone-and-permanent means
// the earliest cohort ranks above later arrivals for good. Two orderings (Top and
// Newest) bound that to a preference rather than an exclusion, because nothing
// can be pushed off Newest; it does not erase it. docs/CLAIM_BOARDS.md §2.3
// carries the full argument and the owner's decision to accept it.
//
// The one downward path is a logged m-of-n moderator slash, which lands with the
// board's moderation lane and not here. highWater is what makes that slash
// reversible.

package kourtv2

import (
	"chain"
	"strconv"
	"strings"

	bptree "gno.land/p/nt/bptree/v0"
)

// The per-category scales, in bps of the capital that earned the credit.
// CALIBRATION, not structure: the ordering (policing ≥ authorship > staking)
// is the part that must not move, because it is what stops standing becoming a
// yield on holding rather than a record of work.
const (
	// A flag whose slash SETTLED — full bar, two-thirds low, and the answerer's
	// counter-window spent without a rescue. Scaled on what the act destroyed
	// (dust burns + the slash), which is the same base the bounty is capped
	// against. NOT on the bond: on the slashGrade branch the bond comes back
	// whole, so "the bond risked" — which this comment used to claim — is zero.
	standingFlagBps = int64(10_000)
	// A dispute that produced a decided verdict against real opposition. Scaled
	// on the POSTED ANSWER BOND (answerBond0), which is the stable magnitude of
	// the fight: it is never zeroed as bonds are disposed, and the disputer's own
	// bond is min(20%·X̄, 40%×answerBond), i.e. derived from the same number.
	standingDisputeBps = int64(10_000)
	// An authored claim the court adjudicated HIGH — two-thirds at the full bar,
	// seeded excluded. Scaled on the AUTHOR'S OWN time-averaged stake on the
	// winning side.
	//
	// It reads the author's own capital and not the claim's X̄, which is what it
	// read first. X̄ is the crowd's money: keying the row to it made authorship
	// the one row whose base the earner did not supply, and it was measured
	// minting 2.5 units of standing per CC anyone burned — against a claim whose
	// deposit and fee both refund, so the author's own outlay was gas.
	//
	// TWICE the conviction rate (owner call). Authorship is the strictly harder
	// gate — two-thirds at the full bar against no gate at all — so on a shared
	// base it must pay more, and standing.gno's stated ordering
	// "policing ≥ authorship > staking" is only true if it does. At the previous
	// 500 against conviction's 1,000 the ordering inverted the moment the bases
	// were unified, which is why the two changes land together.
	standingAuthorHighBps = int64(2_000)
	// Winning conviction, linear and uncapped, on the staker's own TIME-AVERAGED
	// STAKE. Linear is the unique splitting-neutral rule (PLAN §3.5 F8): any
	// clamp or per-claim cap is concave, and a concave credit pays a split
	// position more than a whole one — the defect the carrot's P2 per-voter
	// clamp note in crystallize.gno records.
	//
	// It reads time-averaged stake and not convCC, which is what it read first.
	// convCC is a FLOW — stake x rate x time — and the other three rows are
	// stocks, so the ratio between this row and its neighbours was a function of
	// how long the claim happened to run: measured at ~15,000x out of proportion
	// on a short claim, ~50x at two weeks, ~8x at twelve. No single constant can
	// calibrate a row whose units differ from the ones it is ordered against.
	standingConvictionBps = int64(1_000)
	// What an UNDISPUTED claim's winners earn, as a fraction of the adjudicated
	// rate. Half (owner call).
	//
	// The first version of this gate paid them nothing, on the reasoning that a
	// default mid is what a claim NOBODY LOOKED AT receives. That reasoning is
	// sound about the mill and wrong about everyone else, because it makes the
	// credit turn on whether somebody chose to dispute you — and a dispute is
	// partly noise. Anyone may open one to grief. Requiring one before a correct
	// position counts punishes a staker for not having been attacked, and since
	// most claims settle undisputed BY DESIGN it would have made the row pay
	// almost never.
	//
	// So an undisputed stand is worth something, and worth less: a quality vote
	// that actually concluded is the stronger evidence and pays double.
	//
	// WHAT PRICES THE MILL HERE IS THE FLAG LANE, not this gate. Anyone may flag
	// a junk claim; a conclusive low zeroes the tier, and the tier arm above then
	// pays its winners nothing at all. That is the same lane the money side
	// already leans on for the same attacker, which is why standing does not need
	// a second, stricter gate of its own — and it is why the residual is a
	// flag-probability question (ECONOMICS.md's q) rather than a new one.
	standingUnadjudicatedBps = int64(5_000)
)

// ---- the credit rates: a realm default a court may override -------------
//
// NAMED creditRates AND NOT standingRates, because check-nontransferable.py
// refused the latter and was right to. Its verb census forbids
// `Set…Standing…(cur realm` precisely so that "an entrypoint called
// AssignRecord, MigrateCredential, SetStanding, Bequeath or MoveScore" cannot
// sail through while doing the one thing that must never be possible. These set
// what a credit is WORTH, never anyone's score — and a name that reads like the
// second is a name worth changing rather than a guard worth exempting.
//
// The five constants above are the LAUNCH CALIBRATION and the realm-wide
// default; a court's moderators may override them for their own court. Same two
// places, same reasoning, as association.gno's bond: the realm default so a new
// court is never unpriced, the override so a court need not wait on a realm
// upgrade to reprice its own speech layer.
//
// WHY THESE MAY MOVE WHEN THE EMISSION CONSTANTS MAY NOT. PLAN.md §0 forbids
// runtime knobs and court.gno says the absence of a retune path is load-bearing
// for every overflow and capture bound in the audit — and that is about the
// TOKENOMICS constants, which those bounds rest on. Standing is not money: no
// audit bound depends on these, no arithmetic overflow turns on them, and
// standing is per-court, so a court that sets them badly harms its own board and
// nobody else's. That is COURTS_TOKENOMICS §9a's test — "could a founder who set
// this maliciously harm someone who did not read the charter?" — answered no.
//
// SET AS A TUPLE, NEVER ONE AT A TIME, and this is the whole reason for the
// struct. The bound that matters is not a range on any single number, it is the
// ORDERING policing >= authorship > staking, which this file calls the part that
// must not move. Five independent setters would leave a window between two calls
// where the ordering is violated and credits are being paid through it. One
// setter, one check, no window.
type creditRates struct {
	flag, dispute, authorHigh, conviction, unadjudicated int64
}

var creditRatesDefault = creditRates{
	flag:          standingFlagBps,
	dispute:       standingDisputeBps,
	authorHigh:    standingAuthorHighBps,
	conviction:    standingConvictionBps,
	unadjudicated: standingUnadjudicatedBps,
}

// creditRatesFor resolves the two places. A nil override means inherit — not
// "all zero", which for a five-tuple would be indistinguishable from a court
// that deliberately zeroed its own board.
func creditRatesFor(c *Court) creditRates {
	if c.creditRates != nil {
		return *c.creditRates
	}
	return creditRatesDefault
}

// mustCreditRates refuses a set that breaks the ordering or leaves the range
// scaleBps can honour.
//
// THE ORDERING IS CHECKED ON RATES, NOT ON REALIZED CREDITS, and the two can
// differ — measured, on a launch court an overturner earns 1.2 CC-equiv against
// an author's 2.0, so policing lands BELOW authorship in practice while the bps
// still satisfy policing >= authorship. That is not a defect in the check: the
// rows read different bases (a party's own bond against a staker's own
// time-averaged stake), and how big anyone's bond is relative to anyone's stake
// is their choice, not a settable parameter. The rate ordering is the only form
// of the rule a setter can enforce. Read the file header's ordering claim as
// being about the rates, because that is what is guarded.
//
// The upper bound is a REFUSAL rather than a clamp on purpose: scaleBps clamps
// at 10_000 too, but silently, so a court that set 12_000 would get 10_000 and
// no indication its intent had been discarded. A setter should say no.
func mustCreditRates(r creditRates) {
	for _, v := range []int64{r.flag, r.dispute, r.authorHigh, r.conviction, r.unadjudicated} {
		if v < 0 || v > 10_000 {
			panic("kourtv2: a standing rate is 0..10000 bps")
		}
	}
	if r.flag < r.authorHigh || r.dispute < r.authorHigh {
		panic("kourtv2: policing must credit at least as much as authorship")
	}
	if r.authorHigh <= r.conviction {
		panic("kourtv2: authorship must credit more than staking — it is the harder gate")
	}
	if r.unadjudicated <= 0 || r.unadjudicated >= 10_000 {
		panic("kourtv2: the unadjudicated rate must be a real fraction of the adjudicated one")
	}
}

// SetCreditRatesDefault sets the realm-wide default every court inherits.
func SetCreditRatesDefault(cur realm, flag, dispute, authorHigh, conviction, unadjudicated int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin sets the default standing rates")
	}
	r := creditRates{flag, dispute, authorHigh, conviction, unadjudicated}
	mustCreditRates(r)
	creditRatesDefault = r
	// See SetLadderDefault: realm-wide, so the event is the only record.
	chain.Emit(globalActEvent,
		"court", "*",
		"claim", "0",
		"act", "set-rates-default:"+creditRatesKey(r),
		"by", cur.Previous().Address().String(),
		"height", eventHeight(),
	)
}

// SetCourtCreditRates overrides the default for one court.
func SetCourtCreditRates(cur realm, courtSlug string, flag, dispute, authorHigh, conviction, unadjudicated int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	// An ACTIVE moderator, as repricing association is: setting what work is
	// worth is not one of the de-escalatory acts a suspended set may still take.
	cm := ensureMod(c)
	requireActiveMod(cm, who)
	r := creditRates{flag, dispute, authorHigh, conviction, unadjudicated}
	mustCreditRates(r)
	// speechM-of-n, logged, and clearable by the global DAO, for the reason
	// SetCourtLadder's note gives at length: this shipped as a single-member,
	// unlogged, permanent lever. SetCourtCreditRates(slug, 2, 2, 2, 1, 1) passes
	// mustCreditRates — the ordering holds — and cuts every earning rate by
	// ~5000x, so nobody in the court ever climbs off level 0 again. The values go
	// in the action key so two members cannot approve different tuples into one
	// threshold.
	if fire, _ := approveAction(cm.pending, "setrates:"+creditRatesKey(r), who, "",
		speechM(cm)); !fire {
		return
	}
	c.creditRates = &r
	cm.appendCourtLog(who, "setrates:"+creditRatesKey(r), "")
	emitModAct(c.id, 0, "setrates", who)
}

// creditRatesKey is the tuple as one string — the thing voted on and the thing
// logged, from one definition.
func creditRatesKey(r creditRates) string {
	return strconv.FormatInt(r.flag, 10) + ":" + strconv.FormatInt(r.dispute, 10) +
		":" + strconv.FormatInt(r.authorHigh, 10) + ":" +
		strconv.FormatInt(r.conviction, 10) + ":" +
		strconv.FormatInt(r.unadjudicated, 10)
}

// ClearCourtCreditRates returns a court to the realm default.
func ClearCourtCreditRates(cur realm, courtSlug string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	// requireMod: returning to the realm default is de-escalation, so it must
	// survive a suspension. See ClearCourtLadder.
	requireMod(cm, who)
	if c.creditRates == nil {
		panic("kourtv2: this court has no standing-rate override")
	}
	if fire, _ := approveAction(cm.pending, "clearrates:"+c.id, who, "",
		speechM(cm)); !fire {
		return
	}
	c.creditRates = nil
	cm.appendCourtLog(who, "clearrates", "")
	emitModAct(c.id, 0, "clearrates", who)
}

// StandingRates is what this court currently pays, packed:
//
//	flag:<n>;dispute:<n>;author:<n>;conviction:<n>;unadjudicated:<n>;inherited:<0|1>
func CreditRates(courtSlug string) string {
	c := mustCourt(courtSlug)
	r := creditRatesFor(c)
	inherited := "1"
	if c.creditRates != nil {
		inherited = "0"
	}
	return "flag:" + strconv.FormatInt(r.flag, 10) +
		";dispute:" + strconv.FormatInt(r.dispute, 10) +
		";author:" + strconv.FormatInt(r.authorHigh, 10) +
		";conviction:" + strconv.FormatInt(r.conviction, 10) +
		";unadjudicated:" + strconv.FormatInt(r.unadjudicated, 10) +
		";inherited:" + inherited
}

// The four categories, as an ORDERED LIST rather than four named constants and
// four named fields.
//
// The shape is what stops a whole class of defect. An earlier version validated
// the category in one switch and applied it in a second, and nothing made the
// two agree: add a fifth category to the first and forget the second, and the
// score rises with no subtotal — the breakdown silently stops summing, which is
// the one property the page rests on, and no test would see it. Indexing one
// array through one lookup makes the divergence unrepresentable.
//
// The strings stay wire tokens the page and the overlay parse, so the ORDER of
// this list is part of that wire and adding to the middle would renumber every
// stored row. Append only.
var standingCats = [standingCatN]string{"flag", "dispute", "author", "conviction"}

const (
	standingCatFlag = iota
	standingCatDispute
	standingCatAuthor
	standingCatConv
	standingCatN
)

// standingRow is one address's participation record in one court.
//
// The four subtotals are not decoration and not a log. They exist because the
// page has to be able to say HOW a score was earned — a single opaque number
// that gates what you may say is exactly the shape nobody can argue with, and
// "learn how to earn it, then see where yours came from" is the whole point of
// the page. Four int64s is the cheapest form of that; a per-event log would be
// unbounded state on a surface an attacker can drive.
type standingRow struct {
	score int64 // the sum; monotone in this file

	// highWater is the largest score this address has ever held, and it is what
	// makes a slash REVERSIBLE — which is the property the whole authority model
	// now rests on, because there is no appeals lane. A successor moderator set's
	// remedy for a bad slash is to raise `score` back toward this number, and
	// without it a successor has no way to know what to put back, so "restore"
	// would be a mint rather than a repair.
	//
	// It rises ONLY here, from the earning table, and never from a moderator act
	// — that asymmetry is the whole of its safety. A slash lowers `score` and
	// leaves this untouched; a restore raises `score` and may never pass it.
	// The invariant is `score <= highWater`, always, and it holds by
	// construction rather than by check: the one place score rises is the one
	// place this rises with it.
	highWater int64

	// passHeld is set by BuyCommentPass. It floors the posting level at 1
	// (posting.gno) and is NOT standing — buying it credits no score, or the
	// record would be purchasable.
	//
	// ONE THING CLEARS IT: a slash all the way to level 0 (boardmod.gno). The
	// burn is never refunded — the entitlement is forfeit, not reversed. This
	// field was documented as never-cleared, and that made the slash defeatable
	// for 0.1 CC: an address slashed to zero standing still posted at entry rate
	// forever, leaving only the 12h freeze against a persistent abuser.
	passHeld bool

	// The posting bucket (posting.gno). Here rather than in a second tree
	// because every post reads the level, which reads this row already.
	tokens     int64
	lastRefill int64 // unix seconds; 0 = never posted

	// The board freeze (boardmod.gno): the height it lifts, and the court
	// sanction epoch it was stamped under. A freeze is live only while the epoch
	// still matches, which is what lets one write clear every freeze in a court.
	// Expiry is LAZY — nothing sweeps, exactly as every other clock here.
	//
	// It bars BOARD WRITES ONLY. A frozen address still stakes, votes, answers,
	// disputes, flags, opens claims, withdraws, draws emission and takes every
	// election action; the election is the remedy for a capturing set, so a
	// freeze that reached any of those could silence the vote that removes it.
	frozenUntil int64
	frozenEpoch int64

	// frozenGapUntil is the height before which this address may not be frozen
	// AGAIN, and it is deliberately a separate stamp from frozenUntil.
	//
	// The gap used to be computed from frozenUntil, and two things defeated it.
	// UnfreezeBoard sets frozenUntil = 0, so freeze -> unfreeze -> freeze slipped
	// the gap for the price of one extra speechM round, letting a set hold an
	// address frozen indefinitely in 12h increments — the exact outcome
	// freezeMaxBlocks exists to prevent. And the gap test also required a
	// matching sanction epoch, so GlobalClearBoardBits — a RECOVERY verb — handed
	// the set an immediate re-freeze.
	//
	// This stamp is therefore cleared by neither: not by the undo, because
	// de-escalating must not buy the set a fresh window, and not by the epoch,
	// because the backstop exists to protect the address rather than to re-arm
	// the power against it.
	frozenGapUntil int64

	// from[i] is what category standingCats[i] contributed. An ARRAY, not four
	// fields and not a slice: fixed width persists inline and cannot be nil, so
	// a row read back always has four subtotals that sum to the score.
	from [standingCatN]int64
}

// getStanding is the ALLOCATING accessor: write paths only. It is named in
// check-read-purity.py's ALLOCATORS for that reason — a read that reached for it
// would let the first caller change what the second one sees, and a query
// carries no storage deposit, so it would be unpaid state growth.
//
// Tolerates a nil tree for the same reason lockedOf does: a fixture that built a
// Court by hand has one, and a defensive branch here is cheaper than a fixture
// sweep. startCourt creates it, so the branch is dead on every real court.
func getStanding(c *Court, who address) *standingRow {
	if c.standings == nil {
		c.standings = bptree.NewBPTree32()
	}
	if v := c.standings.Get(string(who)); v != nil {
		return v.(*standingRow)
	}
	r := &standingRow{}
	c.standings.Set(string(who), r)
	return r
}

// lookupStanding is the NON-allocating twin, and the only one a read may call.
// The split mirrors getRecord/AnswerRecord in records.gno; keeping it explicit
// here rather than reusing one function is what makes the read path checkable.
func lookupStanding(c *Court, who address) *standingRow {
	if c.standings == nil {
		return nil
	}
	if v := c.standings.Get(string(who)); v != nil {
		return v.(*standingRow)
	}
	return nil
}

// creditStanding adds to a score and to exactly one subtotal.
//
// ZERO AND NEGATIVE ARE NO-OPS, not panics, and that is deliberate: every caller
// sits on a money path at a lifecycle transition, and MODERATION.md's rule for
// calls in that direction is that they must never be able to abort one. A claim
// with no conviction on the winning side, a seeded claim, a court whose
// arithmetic floors to nothing — each reaches here with a zero and must leave
// the transition untouched.
//
// VALIDATE, THEN ALLOCATE, THEN ADD — the order is the whole correctness of this
// function, and it is written this way because an earlier version was written
// the other way round. That one added to the score first and undid the add in a
// switch's default arm with `r.score -= amount`, which failed twice at the
// edges: satAdd is the one operation here that is NOT invertible, so at the
// ceiling the add saturated and the subtraction then took back the full amount,
// leaving the score BELOW where it started — a silent monotonicity break on the
// exact input satAdd exists to survive; and it called getStanding first, so a
// miscategorised credit persisted a row for an address that ended up with
// nothing.
//
// Nothing to undo means nothing to get wrong. The category is now an INDEX
// rather than a string, so "miscategorised" is a range check rather than a
// second switch that could drift out of step with the first.
func creditStanding(c *Court, who address, amount int64, cat int) {
	if amount <= 0 || who == "" || cat < 0 || cat >= standingCatN {
		return
	}
	r := getStanding(c, who)
	r.score = satAdd(r.score, amount)
	r.from[cat] = satAdd(r.from[cat], amount)
	// The high-water mark tracks the MAX, not the latest: after a slash, score
	// sits below it and a later credit must climb back rather than reset the
	// ceiling to wherever the score happens to have landed.
	if r.score > r.highWater {
		r.highWater = r.score
	}
}

// satAdd SATURATES where every pool total in this realm uses the checked
// mustAdd, and the difference is the whole reason this function exists.
//
// mustAdd panics, and a panic here would land inside WithdrawBonus, Crystallize,
// Finalize or settleSlash — the four money paths this file's credits actually
// hang off, each of them a lifecycle transition. MODERATION.md's rule
// for calls in that direction is absolute: a moderation-side invariant must
// never be able to block a lifecycle transition. So an unreachable arithmetic
// edge must not be able to strand a settlement, and this is the same call econ
// vet F4 already made about the per-claim draw: "checked-abort on a shared path
// is a settlement DoS — clamp instead."
//
// Saturating is safe here in a way it would NOT be for a pool total, because
// this number is a record rather than a claim on anything: a saturated score
// over-states standing at the ceiling and over-states nothing else. No coin, no
// draw and no vote is derived from it. Reaching the ceiling would need roughly
// ten thousand maximum-supply claims, so it is unreachable — the point is what
// happens if it is ever reached, not how likely that is.
func satAdd(a, b int64) int64 {
	const maxInt64 = int64(9223372036854775807)
	if b > 0 && a > maxInt64-b {
		return maxInt64
	}
	return a + b
}

// scaleBps is the one multiply every credit goes through, on the audited 128-bit
// path rather than mustMul for the reason satAdd saturates: at the top of the
// range a CC magnitude times 10,000 bps exceeds int64, and mustMul's answer to
// that is a panic on a settlement path. mulDiv128 carries the product in 128
// bits, so the multiply cannot overflow at any supply this realm can reach.
//
// THE BPS CLAMP is not defensive noise: mulDiv128's surviving panic arm is
// `q > MaxInt64`, and the only thing that makes it unreachable here is
// bps <= 10_000, which bounds q by base. The block above is labelled
// CALIBRATION — i.e. those constants are expected to move — so a bump to 12_000
// would arm a panic inside Finalize and settleSlash, the exact outcome
// satAdd and this function exist to prevent. Clamping keeps the guarantee
// unconditional instead of resting it on a constant someone may retune.
func scaleBps(base, bps int64) int64 {
	if base <= 0 || bps <= 0 {
		return 0
	}
	if bps > 10_000 {
		bps = 10_000
	}
	return mulDiv128(base, bps, 10_000)
}

// ------------------------------------------------------------- the credits --

// creditFlagSlash pays the beneficiary of a slash that actually SETTLED.
//
// CALLED FROM settleSlash, never from ResolveFlag. Three things were wrong with
// paying it at the slashGrade branch instead, and each is a separate rule:
//
//   - THE ACT WAS NOT FINAL. ResolveFlag only reserves; ResolveCounter can still
//     rescue the slash. A credit paid at reservation survived a repudiation the
//     money lane reverses, leaving the flagger paid for a flag a larger,
//     full-bar electorate threw out.
//   - THE BENEFICIARY WAS WRONG. cs.flagger can be the zero address on a
//     ride-levied slash, or a stale flagger from an earlier cycle. slashFlagger
//     is recorded at origination for exactly this reason.
//   - THE BASE WAS PUMPABLE. Scaling on the posted bond was doubly wrong: on the
//     slashGrade branch the bond is returned WHOLE (the half-burn arm requires
//     !slashGrade), so nothing was risked, and flagBondFor multiplied by
//     flagCycles, which an inconclusive-LOW advanced while returning the bond
//     whole — two free cycles, four times the credit. (flagBondFor and
//     flagCycles went with the quality lane; this paragraph is kept because the
//     REASON the base is what it is outlives the mechanism that forced it, but
//     nothing here is a function you can still go and read.)
//
// So the base is what the act DESTROYED, which is also what the bounty is
// capped against.
func creditFlagSlash(c *Court, who address, burned int64) {
	creditStanding(c, who, scaleBps(burned, creditRatesFor(c).flag), standingCatFlag)
}

// creditDisputeResolved pays whichever party a DECIDED round vindicated.
//
// It rides the same predicate the answer record already uses (dispute.gno), and
// deliberately so: an uphold earns only when it was credEligible — i.e. the
// overturn side carried at least a quarter of the credential weight floor —
// because otherwise ~20% of a dispute bond buys standing on any trivially-true
// claim. An OVERTURN needs no such gate: it had to clear quorum and the verdict
// threshold to happen at all, so it is weight-gated by construction.
// NEVER cs.disputer. That field is the CURRENT round's disputer and is
// overwritten by every OpenDispute, while a failed reopen leaves an earlier
// overturn's `provisional` standing — so reading it here paid whoever opened the
// last round, measured as a profitable theft that also denied the honest
// overturner. cs.overturnBy is stamped at the round that won.
// THE decidedRounds GUARD IS REDUNDANT TODAY, AND IS KEPT ANYWAY. Verified
// against every writer rather than assumed: `cs.provisional` differs from
// `cs.answer` only where dispute.gno's OVERTURN branch sets it, two lines above
// its own `decidedRounds++`; and `cs.credEligible` is written in exactly one
// place, inside the UPHELD branch, likewise above `decidedRounds++`. So both
// arms below already imply a decided round and this cannot change behaviour.
//
// It stays because the redundancy lives in ANOTHER FILE: it holds only while
// those two fields keep their current writers, and nothing enforces that from
// here. It is recorded as a permanent mutation gap rather than papered over —
// no test can kill it, and a corpus row that always survives is one people
// learn to skim past.
func creditDisputeResolved(c *Court, cs *claimState) {
	if cs.decidedRounds <= 0 {
		return
	}
	// EACH SIDE ON ITS OWN BOND. answerBond0 IS the answerer's own posted
	// magnitude, but the disputer's is min(20%·X̄, 40%·answerBond0) and the
	// answer arm always binds, so paying both on answerBond0 gave the disputer
	// 2.5x the capital they actually risked.
	if cs.provisional != cs.answer {
		creditStanding(c, cs.overturnBy, scaleBps(cs.overturnBond, creditRatesFor(c).dispute), standingCatDispute)
		return
	}
	if cs.credEligible {
		creditStanding(c, cs.answerer, scaleBps(cs.answerBond0, creditRatesFor(c).dispute), standingCatDispute)
	}
}


// creditWinConviction pays a winning staker in proportion to the conviction they
// actually drew on — linear, uncapped, and taken from the same convCC the draw
// itself is computed from, so the two can never disagree about what was held.
//
// TWO RATES, NOT A GATE. The rate turns on whether the COURT decided this claim
// or a deadline did; see standingUnadjudicatedBps and `adjudicated` below.
//
// THE TIER ARM IS GONE WITH THE TIER, and what it did is worth keeping on the
// record because it is the deterrent this row no longer has. It refused a claim
// the court had adjudicated LOW: tier 0 multiplied the winners' slice to
// nothing, and before the arm existed every winning staker was still credited in
// full anyway. Measured against the mill's total money punishment on that branch
// — the deposit and the fee, and nothing else — the standing take was 4.5× the
// burn on a young court and 22.7× on a mature one. So the flag lane's entire
// deterrent reached the money and left the record untouched, which was A18's
// lesson unapplied to the newer ledger.
//
// With no tier there is no LOW to refuse, so every winning staker is credited
// and the adjudicated rate is the only thing that still varies. The 4.5×/22.7×
// figures above are what that costs on the mill branch, and they are the reason
// this paragraph is a record rather than a deletion.
//
// provClose needs no arm of its own, and the arm it once had was wrong.
// crystallize says it plainly — "provClose now DRAWS. Only a dead claim has no
// draw" — so an earlier comment here, that provClose has "no draw and no
// verdict", was false in every clause and withheld a credit on a path that pays
// MID emission. It resolves without being named: a provClose carries whatever
// tier and slotConsumed it ended up with, and is rated on those like anything
// else.
func creditWinConviction(c *Court, cs *claimState, who address, p *stakePos) {
	// The tier arm is gone with the tier. It refused a conclusive LOW, which
	// drew nothing — "the record follows the money" — and with no tier there is
	// no low to refuse. Every winning staker is credited; the adjudicated rate
	// below is the only thing that still varies.
	r := creditRatesFor(c)
	bps := r.conviction
	if !adjudicated(cs) {
		bps = bps * r.unadjudicated / 10_000
	}
	creditStanding(c, who, scaleBps(timeAvgStake(cs, p.rawHi, p.rawLo), bps), standingCatConv)
}

// adjudicated reports whether the COURT decided this claim, rather than a
// deadline deciding it by nobody turning up.
//
// ONE DEFINITION, and the reason is the same one qualityQuestionOpen exists for:
// a sentence this load-bearing spelled two ways is how two callers come to mean
// different things by it. check-epoch-coherence counts that pattern.
//
// IT WAS `!cs.slotConsumed`, which was set in exactly two places, both of them a
// quality tally that reached a conclusion. That field is going away with the
// quality lane, and the surviving thing that means "the court actually decided
// something here" is a dispute round that reached a verdict — decidedPID is set
// at dispute.gno's two decide sites and nowhere else.
//
// WHAT MOVES, stated rather than discovered later: a claim whose quality was
// adjudicated by a FLAG but which was never disputed used to earn the full
// conviction rate and now earns half. That population is exactly the one the
// flag lane existed to reach, and it is being removed on purpose. Nothing else
// changes hands — a dispute-decided claim was full-rate before and is full-rate
// now, and an untouched claim was half before and is half now.
func adjudicated(cs *claimState) bool { return cs.decidedPID != 0 }

// ------------------------------------------------------------------ reads --

// Standing is an address's participation score in one court, in CC base units.
//
// It is NOT the answer record, and a page showing one as the other would be
// wrong in a way nobody could see: AnswerRecord is adjudicated and no moderator
// can change it, while this number is slashable for abuse. Quote both or say
// which one this is.
func Standing(courtSlug string, who address) int64 {
	if r := lookupStanding(mustCourt(courtSlug), who); r != nil {
		return r.score
	}
	return 0
}

// StandingBreakdown is the score and its four subtotals, packed:
//
//	score:<n>;flag:<n>;dispute:<n>;author:<n>;conviction:<n>
//
// Packed rather than five reads for the reason ClaimSeries and
// ClaimAssociations are: one round trip, and a shape the overlay already parses.
// Every field is always present, so a client never has to distinguish "absent"
// from "zero" — an address that has never participated reads as all zeroes
// rather than as an error, because having no standing is a normal state and not
// a missing record.
func StandingBreakdown(courtSlug string, who address) string {
	var row standingRow
	if r := lookupStanding(mustCourt(courtSlug), who); r != nil {
		row = *r
	}
	var b strings.Builder
	b.WriteString("score:" + strconv.FormatInt(row.score, 10))
	b.WriteString(";highwater:" + strconv.FormatInt(row.highWater, 10))
	for i, name := range standingCats {
		b.WriteString(";" + name + ":" + strconv.FormatInt(row.from[i], 10))
	}
	return b.String()
}
