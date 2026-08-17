// CRYSTALLIZE (PLAN §10.2 Q6-Q8): the one moment a claim's emission becomes
// concrete. Everything before it is principal (never gated) or reservation;
// everything after is pull-claims. The draw is WALK-FREE: the denominators are
// the side-level pool integrals (exact by construction — advancePools), so no
// step here iterates stakers, and every individual payment applies P10's
// scale-then-cap at ITS OWN pull. Cap-cut and rounding dust stays reserved
// and unminted — economically a burn, always on the conservative side of the
// 20% ceiling.
package courtv2

import (
	"chain/runtime"
	"math/bits"
)

// Crystallize computes a settled claim's draw D and opens the pull-claims.
// Gates (Q6): verdict final; every quality question closed and 24h quiet
// (flags pause THIS, never principal); participant-only for the first week
// of the verdict (A13 — a stranger must not pick the reservoir moment).
func Crystallize(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.crystallized {
		panic("courtv2: already crystallized")
	}
	if cs.verdictAt == 0 {
		panic("courtv2: no final verdict yet")
	}
	if cs.provClose || cs.closed {
		panic("courtv2: closed claims have no draw")
	}
	if cs.flagOpen || cs.counterOpen || cs.pendingSlash > 0 {
		panic("courtv2: a quality question is still open")
	}
	now := runtime.ChainHeight()
	if now < cs.lastFlagEventAt+priorityWindowBlocks {
		panic("courtv2: the 24h quiet window after the last flag event has not passed")
	}
	if now < cs.verdictAt+finalizeGraceBlocks && !isParticipant(cs, who) {
		panic("courtv2: Crystallize is participant-only for its first week")
	}
	touch(c)
	advancePools(c, cs) // settle the denominators to the freeze pin, exactly

	cs.tierFinal = true // whatever stands now (default mid if never voted) is it
	cs.crystallized = true
	cs.openBlocks = cs.frozenAt - cs.openedAt
	if cs.openBlocks < 1 {
		cs.openBlocks = 1
	}

	// The winning pool's conviction in CC units: the winner denominator AND
	// the mid-weight gross (the tier-invariant carrot base).
	var midGross int64
	if int(cs.provisional) == sideYES {
		midGross = convToCC(cs.yesConvHi, cs.yesConvLo)
	} else {
		midGross = convToCC(cs.noConvHi, cs.noConvLo)
	}
	cs.winPoolConvCC = midGross

	// D = min(tier × midGross, G_MAX, R): the per-claim clamp is one period's
	// budget (P8), then the junior reservation clamps to the reservoir —
	// never aborts (F4).
	//
	// INTENTIONAL (econ-vet P7): D is the WHOLE claim draw and the 80/8/5 split
	// is taken OUT of it — so a winner receives 80/93 = 0.860·midGross, NOT the
	// full midGross with author/answerer added on top. PLAN §3.5's "D = Σg·93/80"
	// prose describes that gross-up; the code deliberately does NOT do it. The
	// code is ~16% more conservative (lower emission per claim, ceiling-safer,
	// and it worsens every mill break-even q*). Do NOT "fix" toward §3.5 — it
	// would inflate every draw 16%. Consequence, accepted: the honest sole-staker
	// break-even is p ≈ 0.68, not the 0.59 an un-split rate would give.
	want := mustMul(cs.tier, midGross)
	if want > c.curPeriodBudget {
		want = c.curPeriodBudget
	}
	d := reserveJunior(c, want)
	cs.drawWinners = d * splitWinners / (splitWinners + splitAuthor + splitAnswerer)
	cs.drawAuthor = d * splitAuthor / (splitWinners + splitAuthor + splitAnswerer)
	cs.drawAnswerer = d * splitAnswerer / (splitWinners + splitAuthor + splitAnswerer)
	// An OVERTURNED answer never stood — the answerer was adjudicated wrong
	// (bond burned in full, record reset). They draw NO answerer slice, mirroring
	// the author slice's winning-side gate and PLAN Appendix B's overturn example
	// (audit-final MED). The unclaimed points stay unminted — conservative, under
	// the ceiling. The undisputed and upheld paths set provisional == answer, so
	// a standing answer is paid as before.
	if int(cs.provisional) != int(cs.answer) {
		cs.drawAnswerer = 0
	}

	// The carrot: 7 points of the MID-weight gross, tier-invariant (paid even
	// at low — F2), senior-lane, per-voter clamped at pull (P2). 128-bit: midGross
	// is conviction (stake×time), not supply-bounded, so a bare ×7 could wrap and
	// then panic PullCarrot at extreme scale (math-audit NOTE-2).
	cs.carrotTotal = mulDiv128(midGross, splitCarrot, 100)
	cs.carrotPool = cs.carrotTotal

	// N1 lands here: the deposit refunds unless a conclusive low already
	// burned it; the fee likewise. Exactly-once — both zero on disposition.
	if cs.deposit > 0 {
		c.coin.Transfer(c.escrow, cs.author, cs.deposit)
		c.deposit -= cs.deposit
		cs.deposit = 0
	}
	if cs.fee > 0 {
		c.coin.Transfer(c.escrow, cs.author, cs.fee)
		c.deposit -= cs.fee
		cs.fee = 0
	}

	// The slash reserve retained at SettleUndisputed (M3-HIGH-1) returns to the
	// answerer now if no conclusive-low slash consumed it. pendingSlash is 0
	// here (the gate above refuses while a slash is in its counter window), so
	// whatever remains in answerBond is un-slashed and owed back, exactly once.
	if cs.answerBond > 0 {
		c.coin.Transfer(c.escrow, cs.answerer, cs.answerBond)
		cs.answerBond = 0
	}
}

// WithdrawBonus pays a winning-side staker their accuracy reward: their share
// of the winners' slice, scaled by conviction then capped at (tier/2) × their
// time-averaged stake (F9 — flash-proof base). One shot per position.
func WithdrawBonus(cur realm, courtSlug string, claimID uint64, side int) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	mustSide(side)
	if !cs.crystallized {
		panic("courtv2: the draw has not crystallized")
	}
	if side != int(cs.provisional) {
		panic("courtv2: only the winning side draws (principal came back either way)")
	}
	v := cs.stakers.Get(posKey(who, side))
	if v == nil {
		panic("courtv2: no position on that side")
	}
	p := v.(*stakePos)
	if p.bonusPaid {
		panic("courtv2: this position's bonus was already drawn")
	}
	touch(c)
	accrue(c, cs, p, side) // settle to the freeze pin
	p.bonusPaid = true

	convCC := convToCC(p.convHi, p.convLo)
	if convCC <= 0 || cs.winPoolConvCC <= 0 {
		return 0
	}
	gross := mulDiv128(cs.drawWinners, convCC, cs.winPoolConvCC)
	pay := capBonus(cs, gross, p.rawHi, p.rawLo)
	mintEmission(c, who, pay)
	return pay
}

// AuthorBonus and AnswererBonus are the 8- and 5-point one-shot slices, each
// under its own (tier/2) cap: the author against their winning-side
// time-averaged stake (F1), the answerer against the posted bond (v0.8).
func AuthorBonus(cur realm, courtSlug string, claimID uint64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if !cs.crystallized {
		panic("courtv2: the draw has not crystallized")
	}
	if who != cs.author {
		panic("courtv2: only the author draws this slice")
	}
	if cs.authorPaid {
		panic("courtv2: the author slice was already drawn")
	}
	touch(c)
	cs.authorPaid = true
	var pay int64
	if v := cs.stakers.Get(posKey(who, int(cs.provisional))); v != nil {
		p := v.(*stakePos)
		accrue(c, cs, p, int(cs.provisional))
		pay = capBonus(cs, cs.drawAuthor, p.rawHi, p.rawLo)
	}
	mintEmission(c, who, pay)
	return pay
}

func AnswererBonus(cur realm, courtSlug string, claimID uint64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if !cs.crystallized {
		panic("courtv2: the draw has not crystallized")
	}
	if who != cs.answerer {
		panic("courtv2: only the answerer draws this slice")
	}
	if cs.answererPaid {
		panic("courtv2: the answerer slice was already drawn")
	}
	touch(c)
	cs.answererPaid = true
	pay := cs.drawAnswerer
	if bound := mustMul(cs.tier, cs.answerBond0) / 2; pay > bound {
		pay = bound
	}
	mintEmission(c, who, pay)
	return pay
}

// capBonus applies the F9 cap: (tier/2) × time-averaged stake, where the
// average is the raw ∫stake·dt over the claim's open life. Floors.
func capBonus(cs *claimState, gross int64, rawHi, rawLo uint64) int64 {
	rawAvg := div128(rawHi, rawLo, cs.openBlocks)
	bound := mustMul(cs.tier, rawAvg) / 2
	if gross > bound {
		gross = bound
	}
	if gross < 0 {
		gross = 0
	}
	return gross
}

// PullCarrot claims a voter's participation carrot: with-verdict dispute
// voters when a decided round resolved the claim, else all non-participant
// quality voters of the conclusive standalone tally (P14). Weight-pro-rata,
// clamped per voter at b₀/2 − 1 (P2 — an idle sybil voting to farm the carrot
// must net strictly negative against its own flag bond), senior-queued
// (2A-T1: policing pay is never scaled, only delayed).
func PullCarrot(cur realm, courtSlug string, claimID uint64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if !cs.crystallized {
		panic("courtv2: the draw has not crystallized")
	}
	if isParticipant(cs, who) {
		panic("courtv2: participants take their own slices, never the carrot")
	}
	if cs.qVoted == nil {
		panic("courtv2: nobody voted on this claim")
	}
	var w, denom int64
	switch {
	case cs.decidedPID != 0:
		v := cs.qVoted.Get("d" + beClaimKey(uint64(cs.decidedPID)) + string(who))
		if v == nil || v.(string) != cs.carrotChoice {
			panic("courtv2: the carrot pays with-verdict voters of the deciding round")
		}
		w = c.coin.PastVotes(who, c.gov.EpochOf(cs.decidedPID))
		denom = cs.carrotDenom
	case cs.conclusiveSeq != 0:
		if !cs.qVoted.Has(beClaimKey(cs.conclusiveSeq) + string(who)) {
			panic("courtv2: the carrot pays the conclusive quality tally's voters")
		}
		w = c.coin.PastVotes(who, cs.qualityEpoch)
		denom = cs.conclusiveTurnout
	default:
		panic("courtv2: no vote resolved this claim; there is no carrot")
	}
	claimedKey := "c" + beClaimKey(cs.conclusiveSeq) + string(who)
	if cs.qVoted.Has(claimedKey) {
		panic("courtv2: carrot already claimed")
	}
	cs.qVoted.Set(claimedKey, true)
	if w <= 0 || denom <= 0 {
		return 0
	}
	touch(c)
	share := mulDiv128(cs.carrotTotal, w, denom)
	b0 := cs.xBarFrozen * flagBondXBps / 10000
	if b0 < flagMinCC {
		b0 = flagMinCC
	}
	if clamp := b0/2 - 1; share > clamp {
		share = clamp // P2: the sybil-margin invariant, per voter
	}
	if share > cs.carrotPool {
		share = cs.carrotPool
	}
	if share <= 0 {
		return 0
	}
	cs.carrotPool -= share
	enqueueSenior(c, who, share, "carrot")
	return share
}

// div128 floors a u128 by a positive int64 divisor into int64.
func div128(hi, lo uint64, den int64) int64 {
	if den <= 0 {
		panic("courtv2: div128 domain")
	}
	if hi >= uint64(den) {
		panic("courtv2: div128 quotient overflow") // unreachable at bounded magnitudes
	}
	q, _ := bits.Div64(hi, lo, uint64(den))
	return int64(q)
}

// ------------------------------------------------------------------ reads --

func Crystallized(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).crystallized
}

// DrawSlices reads the crystallized slice budgets (winners, author, answerer)
// and the carrot pool remaining — the "what is left to pull" legibility line.
func DrawSlices(courtSlug string, claimID uint64) (winners, author, answerer, carrotLeft int64) {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return cs.drawWinners, cs.drawAuthor, cs.drawAnswerer, cs.carrotPool
}

// PullState reports which reward slices `who` has already pulled on a
// crystallized claim — the winning-side accuracy bonus (their position's
// one-shot flag), the author slice, and the answerer slice — so a UI can grey
// out spent pulls. All false before crystallize / for non-participants.
func PullState(courtSlug string, claimID uint64, who address) (winnerPaid, authorPaid, answererPaid bool) {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.provisional >= 0 {
		if v := cs.stakers.Get(posKey(who, int(cs.provisional))); v != nil {
			winnerPaid = v.(*stakePos).bonusPaid
		}
	}
	return winnerPaid, cs.authorPaid && who == cs.author, cs.answererPaid && who == cs.answerer
}
