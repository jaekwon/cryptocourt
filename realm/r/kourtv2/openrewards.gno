// OPEN THE REWARDS (PLAN §10.2 Q6-Q8): the one moment a claim's emission becomes
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

// OpenRewards computes a settled claim's draw D and opens the pull-claims.
// Gates (Q6): verdict final; every quality question closed and 24h quiet
// (flags pause THIS, never principal); participant-only for the first week
// of the verdict (A13 — a stranger must not pick the reservoir moment).
func OpenRewards(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.rewardsOpened {
		panic("kourtv2: already rewardsOpened")
	}
	if cs.verdictAt == 0 {
		panic("kourtv2: no final verdict yet")
	}
	// S3: provClose now DRAWS. Only a dead claim has no draw — it has no answer, no
	// provisional and therefore no winning side to pay.
	if cs.closed {
		panic("kourtv2: dead claims have no draw")
	}
	// THE 24h QUIET WINDOW STOOD HERE and went with the quality lane. It held the
	// draw for a day after the last FLAG event so a resolved flag could not be
	// rewardsOpened out from under a replacement flag. lastFlagEventAt was written
	// only by the flag lane, so with the lane gone nothing stamps it, the field is
	// zero on every claim, and the guard would compare against block 0 — a check
	// that can only fire in the first day of a chain's life. Deleted rather than
	// left reading a field nobody writes.
	now := heightNow()
	/* THE WEEK IS A WEEK, NOT 120,960 BLOCKS. Counted in blocks this gate held
	   long past its own week whenever the chain ran slower than 5s — measured on
	   kourt-1, a claim settled in April 2022 was still inside its grace in
	   December 2026, because 1,713 days had passed but only 53,280 blocks.
	   Seconds first, blocks only for a claim whose verdict predates the stamp,
	   so a record keeps the deadline it was decided under. */
	if passed, known := pastDeadline(cs.verdictAtTime, finalizeGraceSecs); ((known && !passed) ||
		(!known && now < cs.verdictAt+finalizeGraceBlocks)) && !isParticipant(cs, who) {
		panic("kourtv2: OpenRewards is participant-only for its first week")
	}
	touch(c)
	advancePools(c, cs) // settle the denominators to the freeze pin, exactly

	cs.rewardsOpened = true
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
	// THE MULTIPLIER IS THE CLAIM'S OWN SIZE now, not a voted band (tier.gno).
	// It was `mustMul(cs.tier, midGross)` with tier in {0,1,2}; it is a
	// continuous bps multiplier over the same range, read from xBarFrozen.
	//
	// mulDiv128, not mustMul: midGross is CONVICTION — stake × time, not
	// supply-bounded — and the same warning the carrot's ×7 carries applies to a
	// ×2 here at extreme scale.
	// TWO MULTIPLIERS, COMPOSED. Size says what the claim was worth by the money
	// that showed up; spam says what the voters made of it, on the one round that
	// decided. Composed rather than either-or, so a dispute can only ever lower a
	// claim — see spamNetBps for why replacing would let a small self-staked claim
	// buy a promotion with a dispute bond.
	//
	// Floored twice, once per step, which is conservative in the only direction
	// that matters: the draw is never rounded up.
	want := drawWant(c, cs, midGross)
	d := reserveJunior(c, want)
	cs.drawWinners, cs.drawAuthor, cs.drawAnswerer = drawSplit(cs, d)
	// THE AUTHOR'S STANDING CREDIT IS GONE, and it is worth saying why rather
	// than leaving a hole. It paid only at tier HIGH — "a default MID is what an
	// unlooked-at claim gets, and crediting that is the author-mill's habitat"
	// (PLAN §3.4 F1) — so with no tier there is no non-mill population left to
	// pay it to. Crediting every author instead would be the mill faucet the
	// gate existed to close, so the row is dropped rather than widened.
	//
	// The MONEY lane is untouched: AuthorBonus was never tier-gated, and an
	// author still draws cs.drawAuthor. What is gone is the standing ROW; the
	// standingCatAuthor slot stays in the persisted enum (append-only wire) and
	// simply stops receiving.

	// The carrot: 7 points of the MID-weight gross, senior-lane, per-voter clamped
	// at pull (P2). 128-bit: midGross is conviction (stake×time), not
	// supply-bounded, so a bare ×7 could wrap and then panic PullCarrot at extreme
	// scale (math-audit NOTE-2).
	//
	// NO LONGER WITHHELD ON TURNOUT. A conclusive quality tally below the
	// supply-floored fullBar used to zero this pot, because such a tally could only
	// be a LOW, ResolveFlag returned the flag bond WHOLE there, and the result was a
	// mint against ~1.1 CC of burn on never-escrowed weight — v0.25's A21 faucet
	// arriving through the carrot. Both halves of that vector are gone: there is no
	// quality tally to go conclusive below a bar, and no flag bond to return whole.
	// The carrot now pays only the deciding DISPUTE round's with-verdict voters, who
	// reached it by someone posting a dispute bond.
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
		settleAnswerBond(c, cs)
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
	if !cs.rewardsOpened {
		panic("kourtv2: the draw has not rewardsOpened")
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
	// SETTLE TO THE FREEZE PIN, and it is load-bearing twice over: the draw below
	// reads p.convHi/convLo, and creditWinConviction reads p.rawHi/rawLo. Neither
	// accrues for itself. advancePools settles the SIDE integrals only, so
	// without this line both read a figure stale as of this position's last stake
	// event — measured at ~7.9x understatement when that was last found.
	accrue(c, cs, p, side)
	p.bonusPaid = true

	convCC := convToCC(p.convHi, p.convLo)
	// Standing for winning conviction (standing.gno): linear and uncapped, taken
	// from the SAME convCC the draw is computed from so the two can never
	// disagree about what was held.
	//
	// BEFORE THE CAP is the placement that matters: capBonus is concave, and a
	// concave credit pays a split position more than a whole one — the lesson
	// the carrot's own P2 per-voter clamp note records a few lines above.
	//
	// Before the early return below is NOT load-bearing, and an earlier version
	// of this comment implied it was. That return fires only when convCC <= 0 or
	// the winning pool is empty, the second cannot happen while the first does
	// not (the pool integral contains this position's), and a zero credit is
	// refused downstream anyway — so either side of it behaves identically. It
	// reads better here; it defends nothing here.
	creditWinConviction(c, cs, who, p)
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
	if !cs.rewardsOpened {
		panic("kourtv2: the draw has not rewardsOpened")
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
	// draw is already zeroed at open the rewards, so this is belt-and-braces — but
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
	if !cs.rewardsOpened {
		panic("kourtv2: the draw has not rewardsOpened")
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
	// tier/2 × the bond, as it always was — now a bps multiplier. Both operands
	// are plain int64 here (a bond, not an integral), but mulDiv128 keeps the
	// rounding identical to the old `mustMul(...) / 2`: multiply first, halve
	// once, floor once.
	if bound := mulDiv128(cs.answerBond0, tierBpsFor(cs), 2*tierParBps); pay > bound {
		pay = bound
	}
	mintEmission(c, who, pay)
	return pay
}

// capBonus applies the F9 cap: (tier/2) × time-averaged stake, where the
// average is the raw ∫stake·dt over the claim's open life. Floors.
// timeAvgStake is a position's raw integral divided by the claim's open blocks —
// the F9/Q7 cap base, and now also the base the author and conviction STANDING
// rows are scaled on (standing.gno §2.2).
//
// EXTRACTED RATHER THAN COPIED, because the second caller arrived and the divide
// was folded inside capBonus together with the (tier/2) multiply. Two spellings
// of one quantity is how the two come to disagree.
//
// AND IT CLAMPS WHERE div128 PANICS. div128 aborts on `hi >= den`, which is fine
// where it has always run — inside the pull functions, where a panic strands one
// address. The standing credits run inside OpenRewards, where the same panic
// would strand the whole claim's draw: the exact blast-radius widening satAdd
// and scaleBps exist to prevent on these paths. Unreachable at real magnitudes;
// clamped anyway, because "unreachable" is what every one of those guards was
// also told about itself.
func timeAvgStake(cs *claimState, rawHi, rawLo uint64) int64 {
	if cs.openBlocks <= 0 || rawHi >= uint64(cs.openBlocks) {
		return 0
	}
	return div128(rawHi, rawLo, cs.openBlocks)
}

func capBonus(cs *claimState, gross int64, rawHi, rawLo uint64) int64 {
	rawAvg := timeAvgStake(cs, rawHi, rawLo)
	// Was `mustMul(cs.tier, rawAvg) / 2` — the F9/Q7 cap, in bps now.
	bound := mulDiv128(rawAvg, tierBpsFor(cs), 2*tierParBps)
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
	if !cs.rewardsOpened {
		panic("kourtv2: the draw has not rewardsOpened")
	}
	if isParticipant(cs, who) {
		panic("kourtv2: participants take their own slices, never the carrot")
	}
	if cs.voted == nil {
		panic("kourtv2: nobody voted on this claim")
	}
	// THE CARROT PAYS THE WEIGHT THAT WAS TALLIED, read back from THIS REALM's own
	// record of the vote — never re-derived, and never from the governor.
	//
	// Two reasons, and the second is a bug this file briefly had. Re-deriving from
	// PastVotes is exactly equal only while the tally is a bare snapshot read, and
	// IT NO LONGER IS: every lane now caps at the voter's live balance, so a
	// re-derived numerator would exceed that voter's own contribution to `denom`
	// and the carrot would over-pay everyone who was capped. What was a precaution
	// when written is load-bearing now (VOTEFLOOR.md). And reading it from the governor is worse
	// than either: ReleaseRoll is permissionless and sets p.voted = nil, so
	// gov.VoteOf stops answering once anyone reclaims the roll, and a claimant who
	// had not pulled yet would be refused a carrot they had earned. dispute.gno
	// has said so since the choice record was added; an earlier version of this
	// block ignored it and called VoteOf directly.
	if cs.decidedPID == 0 {
		panic("kourtv2: no vote resolved this claim; there is no carrot")
	}
	v := cs.voted.Get("d" + beClaimKey(uint64(cs.decidedPID)) + string(who))
	if v == nil || v.(string) != cs.carrotChoice {
		panic("kourtv2: the carrot pays with-verdict voters of the deciding round")
	}
	vw := cs.voted.Get("dw" + beClaimKey(uint64(cs.decidedPID)) + string(who))
	if vw == nil {
		panic("kourtv2: no recorded weight for that voter on the deciding round")
	}
	w, denom := vw.(int64), cs.carrotDenom
	// KEYED ON THE DECIDING ROUND, and this line is the one to get right: it is
	// the only thing standing between a voter and pulling the carrot twice.
	//
	// It used to key on cs.conclusiveSeq, which was the QUALITY tally's sequence
	// number. On a dispute-decided claim that field was 0, so the key was "c" +
	// eight zero bytes + the address — a correct per-address latch by accident of
	// the constant rather than by design. conclusiveSeq is gone with the quality
	// lane, so the latch is re-keyed deliberately onto the round that actually
	// paid, which is the same round the weight above was read from.
	claimedKey := "c" + beClaimKey(uint64(cs.decidedPID)) + string(who)
	if cs.voted.Has(claimedKey) {
		panic("kourtv2: carrot already claimed")
	}
	cs.voted.Set(claimedKey, true)
	if w <= 0 || denom <= 0 {
		return 0
	}
	touch(c)
	share := mulDiv128(cs.carrotTotal, w, denom)
	b0 := cs.xBarFrozen * carrotClampXBps / 10000
	if b0 < carrotClampMinCC {
		b0 = carrotClampMinCC
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

func RewardsOpened(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).rewardsOpened
}

// drawWant is the draw a claim ASKS for, before the reservoir is consulted.
//
// A FUNCTION SO THE QUOTE AND THE PAYMENT CANNOT DISAGREE. DrawQuote below shows
// a reader what pressing "Open the rewards" will pay, and a page deriving that
// figure independently is the same defect as a page deriving a deadline
// independently — which this realm has had three times. One computation, two
// callers, and the cap's reasoning moved here with it, unchanged.
func drawEntitlement(c *Court, cs *claimState, midGross int64) int64 {
	tierBps := tierBpsFor(cs)
	want := mulDiv128(midGross, tierBps, tierParBps)
	want = mulDiv128(want, spamNetBps(cs), tierParBps)
	// DRAW CAP: the claim may not mint more than the answer bond collateralized.
	//
	// WHY. A sniper stakes dust on one side, declares it, and lets 72h of silence
	// settle: the opposing pool's whole draw is annihilated while the bond returns
	// whole. What that costs the attacker is bounded by the bond; what it destroys
	// is bounded by tier × midGross. So the ratio destroyed/posted — the only
	// well-defined leverage here, since on every realized path either destruction
	// or forfeiture is zero — is (tier + carrot)/(bondFloorConvBps/1e4). That is
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
	//   floor binds (mg_max >= answerBondBps/bondFloorConvBps·X̄):
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
	// Do NOT lower openrewards.gno's AnswererBonus cap or capBonus to match:
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
	return want
}

// drawWant is drawEntitlement clamped by what this period may still mint. The
// clamp lives HERE and not in the entitlement because it is a property of the
// court's emission schedule at the moment of payment, not of what the claim
// earned — and DrawQuote must not pretend to know the first.
func drawWant(c *Court, cs *claimState, midGross int64) int64 {
	want := drawEntitlement(c, cs, midGross)
	if want > c.curPeriodBudget {
		want = c.curPeriodBudget
	}
	return want
}

// drawSplit cuts a granted draw into its three slices. Shared with DrawQuote for
// the same reason as drawWant: the figure a reader is shown and the figure they
// are paid have to come from one place. The two exclusions and their reasoning
// travel with it.
func drawSplit(cs *claimState, d int64) (winners, author, answerer int64) {
	winners = d * splitWinners / (splitWinners + splitAuthor + splitAnswerer)
	author = d * splitAuthor / (splitWinners + splitAuthor + splitAnswerer)
	answerer = d * splitAnswerer / (splitWinners + splitAuthor + splitAnswerer)
	// An OVERTURNED answer never stood — the answerer was adjudicated wrong
	// (bond burned in full, record reset). They draw NO answerer slice, mirroring
	// the author slice's winning-side gate and PLAN Appendix B's overturn example
	// (audit-final MED). The unclaimed points stay unminted — conservative, under
	// the ceiling. The undisputed and upheld paths set provisional == answer, so
	// a standing answer is paid as before.
	if int(cs.provisional) != int(cs.answer) {
		answerer = 0
	}
	// I5 (MODERATION.md §8): a moderator-SEEDED claim never pays an author
	// slice. Seeding waives the CC deposit/fee to bootstrap a young court, and
	// the author slice staying unminted is what proves seeding is uncompensated
	// work — the securities-relevant fact, and it keeps the waiver un-farmable.
	// The points stay unminted (conservative, under the ceiling).
	if cs.seeded {
		author = 0
	}
	// A PROPOSAL PAYS ITS AUTHOR AND NOBODY ELSE. See claimState.noAccuracy: the
	// accuracy slice pays stakers by conviction for backing the right side of a
	// question of FACT, and a `mod:newset` appeal is not one. The author slice
	// stays, because writing a proposal the court adopts is the work being
	// rewarded. Unclaimed points stay unminted, like every other zeroed slice
	// here — conservative, under the ceiling.
	if cs.noAccuracy {
		winners = 0
	}
	return winners, author, answerer
}

// DrawQuote is what OpenRewards would pay if it ran now: the three slices, in CC.
//
// (0,0,0) on a claim with no final verdict or one already rewardsOpened — in the
// second case DrawSlices holds the real figures, and answering here too would
// only invite a reader to compare two answers to one question.
//
// WHAT THE CLAIM EARNED, and the payment can only be this or less. The two
// clamps left off are the court's, not the claim's: the period budget and the
// junior reservoir are both advanced by touch(), which reserveJunior calls and a
// READ MAY NOT (check-read-purity — a read that mutated would let the first
// caller change what the second sees). Quoting them untouched reports 0 on a
// court nobody has poked this period, which is worse than not quoting them: a
// page would tell a reader their reward is nothing when it is not.
//
// So this answers "what has this claim earned", and the reservoir figure the
// court page already shows answers "what can be paid out right now". Two honest
// numbers beat one dishonest one, and the tier/spam/bond chain that decides the
// first is shared with the payment path so it cannot drift.
func DrawQuote(courtSlug string, claimID uint64) (winners, author, answerer int64) {
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.verdictAt == 0 || cs.rewardsOpened || cs.provisional < 0 {
		return 0, 0, 0
	}
	var midGross int64
	if cs.provisional == sideYES {
		midGross = convToCC(cs.yesConvHi, cs.yesConvLo)
	} else {
		midGross = convToCC(cs.noConvHi, cs.noConvLo)
	}
	return drawSplit(cs, drawEntitlement(c, cs, midGross))
}

// DrawSlices reads the rewardsOpened slice budgets (winners, author, answerer)
// and the carrot pool remaining — the "what is left to pull" legibility line.
func DrawSlices(courtSlug string, claimID uint64) (winners, author, answerer, carrotLeft int64) {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return cs.drawWinners, cs.drawAuthor, cs.drawAnswerer, cs.carrotPool
}

// PullState reports which reward slices `who` has already pulled on a
// rewardsOpened claim — the winning-side accuracy bonus (their position's
// one-shot flag), the author slice, and the answerer slice — so a UI can grey
// out spent pulls. All false before open the rewards / for non-participants.
func PullState(courtSlug string, claimID uint64, who address) (winnerPaid, authorPaid, answererPaid bool) {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.provisional >= 0 {
		if v := cs.stakers.Get(posKey(who, int(cs.provisional))); v != nil {
			winnerPaid = v.(*stakePos).bonusPaid
		}
	}
	return winnerPaid, cs.authorPaid && who == cs.author, cs.answererPaid && who == cs.answerer
}
