// CRYSTALLIZE (PLAN §10.2 Q6-Q8): the one moment a claim's emission becomes
// concrete. Everything before it is principal (never gated) or reservation;
// everything after is pull-claims. The draw is WALK-FREE: the denominators are
// the side-level pool integrals (exact by construction — advancePools), so no
// step here iterates stakers, and every individual payment applies P10's
// scale-then-cap at ITS OWN pull. Cap-cut and rounding dust stays reserved
// and unminted — economically a burn, always on the conservative side of the
// 20% ceiling.
package kourtv2

import (
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
		panic("kourtv2: already crystallized")
	}
	if cs.verdictAt == 0 {
		panic("kourtv2: no final verdict yet")
	}
	// S3: provClose now DRAWS. Only a dead claim has no draw — it has no answer, no
	// provisional and therefore no winning side to pay.
	if cs.closed {
		panic("kourtv2: dead claims have no draw")
	}
	if cs.flagOpen || cs.counterOpen || cs.pendingSlash > 0 {
		panic("kourtv2: a quality question is still open")
	}
	now := heightNow()
	if now < cs.lastFlagEventAt+priorityWindowBlocks {
		panic("kourtv2: the 24h quiet window after the last flag event has not passed")
	}
	if now < cs.verdictAt+finalizeGraceBlocks && !isParticipant(cs, who) {
		panic("kourtv2: Crystallize is participant-only for its first week")
	}
	touch(c)
	advancePools(c, cs) // settle the denominators to the freeze pin, exactly

	cs.tierFinal = true // whatever stands now (default mid if never voted) is it
	cs.crystallized = true
	stripExit(c, cs)              // no longer policeable (§5.3 membership exit)
	releaseMetaLatchIfMeta(c, cs) // an appeal's review slot is freed at its end
	// The F9 time-averaged-stake cap divides by the claim's stakeable life. The
	// polish window is dead time (staking is closed), so counting it would
	// over-tighten every cap by (delay/life) — re-anchored (MODERATION.md §9).
	// Default delay 0 → identical to before.
	cs.openBlocks = cs.frozenAt - (cs.openedAt + c.params.stakeOpenDelayBlocks)
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
	// DRAW CAP: the claim may not mint more than the answer bond collateralized.
	//
	// WHY. A sniper stakes dust on one side, declares it, and lets 72h of silence
	// settle: the opposing pool's whole draw is annihilated while the bond returns
	// whole. What that costs the attacker is bounded by the bond; what it destroys
	// is bounded by tier × midGross. So the ratio destroyed/posted — the only
	// well-defined leverage here, since on every realized path either destruction
	// or forfeiture is zero — is (tier + carrot)/(slashDrawBps/1e4). That is
	// 1.07/1.6 = 0.669 at MID but 2.07/1.6 = 1.294 at HIGH, i.e. sniping an
	// exceptional claim PAYS. Measured 1.2937 end to end.
	//
	// The alternative was to freeze the tier the floor was sized against. It is
	// strictly dominated: because answerBond0 >= 1.6·mg always, capd >= 1.53·mg,
	// so the cap never pays less than 1.53×mg where the freeze always pays 1×mg —
	// the freeze is this cap evaluated at the extremal and then applied
	// everywhere, abolishing the HIGH premium (0% kept) where the cap keeps 53%.
	// A stored frozen-tier field would also be dead state: slashSizeAt has no tier
	// factor, so the value is tierMidX on every claim.
	//
	// STANDING ANSWERS ONLY, and this gate is load-bearing rather than tidy. The
	// leverage above compares what a snipe destroys against what the sniper
	// FORFEITS, and on an overturn the bond has already burned in full
	// (dispute.gno, A19) — the collateral premise is satisfied by the forfeiture,
	// so there is nothing left for a cap to bound. Capping there would instead cut
	// the vindicated majority's draw to pay for an attack that already failed, and
	// it is the one path where the floor carries no information about the winning
	// pool: the floor keys on the ANSWERED side, which on an overturn is the losing
	// side. Measured on a dust-answered overturn, the floor delivered 40% of the
	// 1.6·mg_win it is casually assumed to give.
	//
	// INERT ON THE PUBLISHED RATE. Two regimes, and BOTH are needed — an earlier
	// version of this comment gave only the first and was therefore wrong about the
	// shipped tree:
	//
	//   floor binds (mg_max >= answerBondBps/slashDrawBps·X̄):
	//     capd >= (1.60 - 0.07)·mg_win = 1.53·mg_win > want. Carries no X̄, no age,
	//     no rate, no bond level — this is the post-re-keying guarantee.
	//   base arm binds (mg_max below that):
	//     capd >= answerBondBps·X̄ - 0.07·mg_max, and mg_max is small by assumption,
	//     so the slack is answerBondBps·X̄ minus a fraction of something smaller.
	//     At 600 bps: 573 bps·X̄ against a want under 375 bps·X̄.
	//
	// On the CURRENT tree it is the second regime that carries it — the 5000 bps
	// base arm against maxMidGrossBps, measured at 2.42× margin. That is a
	// calibration, not a proof — exactly what court.gno's own "CALIBRATION, NOT A
	// SAFETY PROOF" note says of the neighbouring draw-arm check. **So the bond constant must not drop to 600 before
	// the floor is re-keyed to max over both sides. The two deploy
	// interlocks ("answer bond below the undisputed-extraction bound" and "the draw
	// arm exceeds the base bond") force that change to be deliberate, but they do
	// not force the two halves into one commit, and this cap is a third reason they
	// must be.**
	//
	// Do NOT lower crystallize.gno's AnswererBonus cap or capBonus to match:
	// lowering this arm alone can only make those LESS binding, and lowering them
	// independently strands coin.
	if int(cs.provisional) == int(cs.answer) {
		if capd := cs.answerBond0 - mulDiv128(midGross, splitCarrot, 100); want > capd {
			want = capd
			if want < 0 {
				want = 0
			}
		}
	}
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
	// I5 (MODERATION.md §8): a moderator-SEEDED claim never pays an author
	// slice. Seeding waives the CC deposit/fee to bootstrap a young court, and
	// the author slice staying unminted is what proves seeding is uncompensated
	// work — the securities-relevant fact, and it keeps the waiver un-farmable.
	// The points stay unminted (conservative, under the ceiling).
	if cs.seeded {
		cs.drawAuthor = 0
	}

	// The carrot: 7 points of the MID-weight gross, tier-invariant (paid even
	// at low — F2), senior-lane, per-voter clamped at pull (P2). 128-bit: midGross
	// is conviction (stake×time), not supply-bounded, so a bare ×7 could wrap and
	// then panic PullCarrot at extreme scale (math-audit NOTE-2).
	cs.carrotTotal = mulDiv128(midGross, splitCarrot, 100)
	// TIER-invariant, but not TURNOUT-invariant (v0.55). A conclusive tally BELOW the
	// supply-floored fullBar can only be a LOW — mid and high both gate on the bar —
	// and there ResolveFlag returns the flag bond WHOLE. So the pot minted ~1.35%·X̄
	// against 1.1 CC of burn, on never-escrowed weight that voting does not consume and
	// that services every claim with X̄ <= 4W in parallel: v0.25's A21 faucet at 0.675×
	// the bounty flow that closed it, same reachable bar, arriving through the carrot —
	// the one leg the per-event burn invariant never reached. It also made the whole
	// band [demotionBar, fullBar) pay EVERY ballot only if low wins, since mid and high
	// cannot go conclusive there and an inconclusive tally sets no conclusiveSeq: a
	// structural demotion cartel for the entire electorate, which is F2/A11's forbidden
	// tier-contingency arriving through the turnout door.
	//
	// P2's clamp does not bound this: it is per-VOTER against a shared pot, so two
	// addresses each take carrotTotal/2, stay under b0/2-1, and collect the whole
	// 7%·midGross. Withholding the pot is the only lever that survives — excluding the
	// flagger's own address is defeated by one extra wallet (OpenFlag and VoteQuality
	// take separate callers), and half-burning the sub-bar bond leaves a bloc at
	// +0.175·b0 while pricing a CORRECT dust flag at 2%·X̄, which is v0.29/T1's
	// cheap-when-right property and the F3 asymmetry the v0.54 ratchet leans on.
	//
	// F2 survives because this keys on TURNOUT, not tier: above the bar a conclusive
	// low still draws the full tier-invariant 7%·midGross, and below it a voter's only
	// alternative is an inconclusive tally, which v0.25 already pays nothing. Withheld,
	// never redirected — strictly ceiling-safer.
	if cs.decidedPID == 0 && cs.conclusiveSeq != 0 {
		if _, fullBar := qualityBars(c, cs); cs.conclusiveTurnout < fullBar {
			cs.carrotTotal = 0
		}
	}
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
		panic("kourtv2: the draw has not crystallized")
	}
	if side != int(cs.provisional) {
		panic("kourtv2: only the winning side draws (principal came back either way)")
	}
	v := cs.stakers.Get(posKey(who, side))
	if v == nil {
		panic("kourtv2: no position on that side")
	}
	p := v.(*stakePos)
	if p.bonusPaid {
		panic("kourtv2: this position's bonus was already drawn")
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
		panic("kourtv2: the draw has not crystallized")
	}
	if who != cs.author {
		panic("kourtv2: only the author draws this slice")
	}
	if cs.authorPaid {
		panic("kourtv2: the author slice was already drawn")
	}
	touch(c)
	cs.authorPaid = true
	var pay int64
	// I5, second gate: a seeded claim pays its author nothing here either. The
	// draw is already zeroed at crystallize, so this is belt-and-braces — but
	// the invariant is asserted at the payout site because that is where a
	// future change would most plausibly break it.
	if cs.seeded {
		mintEmission(c, who, 0)
		return 0
	}
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
		panic("kourtv2: the draw has not crystallized")
	}
	if who != cs.answerer {
		panic("kourtv2: only the answerer draws this slice")
	}
	if cs.answererPaid {
		panic("kourtv2: the answerer slice was already drawn")
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
		panic("kourtv2: the draw has not crystallized")
	}
	if isParticipant(cs, who) {
		panic("kourtv2: participants take their own slices, never the carrot")
	}
	if cs.qVoted == nil {
		panic("kourtv2: nobody voted on this claim")
	}
	// THE CARROT PAYS THE WEIGHT THAT WAS TALLIED, read back from THIS REALM's own
	// record of the vote — never re-derived, and never from the governor.
	//
	// Two reasons, and the second is a bug this file briefly had. Re-deriving from
	// PastVotes is exactly equal only while the tally is a bare snapshot read; the
	// moment it weighs anything else — RENTEDWEIGHT.md's open decision is about
	// exactly that — the numerator diverges from the voter's own contribution to
	// `denom` and the carrot over-pays. And reading it from the governor is worse
	// than either: ReleaseRoll is permissionless and sets p.voted = nil, so
	// gov.VoteOf stops answering once anyone reclaims the roll, and a claimant who
	// had not pulled yet would be refused a carrot they had earned. dispute.gno
	// has said so since the choice record was added; an earlier version of this
	// block ignored it and called VoteOf directly.
	var w, denom int64
	switch {
	case cs.decidedPID != 0:
		v := cs.qVoted.Get("d" + beClaimKey(uint64(cs.decidedPID)) + string(who))
		if v == nil || v.(string) != cs.carrotChoice {
			panic("kourtv2: the carrot pays with-verdict voters of the deciding round")
		}
		vw := cs.qVoted.Get("dw" + beClaimKey(uint64(cs.decidedPID)) + string(who))
		if vw == nil {
			panic("kourtv2: no recorded weight for that voter on the deciding round")
		}
		w = vw.(int64)
		denom = cs.carrotDenom
	case cs.conclusiveSeq != 0:
		v := cs.qVoted.Get(beClaimKey(cs.conclusiveSeq) + string(who))
		if v == nil {
			panic("kourtv2: the carrot pays the conclusive quality tally's voters")
		}
		w = v.(int64)
		denom = cs.conclusiveTurnout
	default:
		panic("kourtv2: no vote resolved this claim; there is no carrot")
	}
	claimedKey := "c" + beClaimKey(cs.conclusiveSeq) + string(who)
	if cs.qVoted.Has(claimedKey) {
		panic("kourtv2: carrot already claimed")
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
		panic("kourtv2: div128 domain")
	}
	if hi >= uint64(den) {
		panic("kourtv2: div128 quotient overflow") // unreachable at bounded magnitudes
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
