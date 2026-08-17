// Claims: an immutable statement of fact, a refundable deposit, a conditionally
// refundable fee, and two stake pools. No shares exist — see stake.gno.
package courtv2

import (
	"chain"
	"chain/runtime"
	"strconv"

	twap "gno.land/p/cryptocourt/twap/v0"
	bptree "gno.land/p/nt/bptree/v0"
)

// Sides of a claim. A side is an int in the API for gnokey ergonomics.
const (
	sideYES = 0
	sideNO  = 1
)

const twapBuckets = 168 // a week of hourly buckets, as V1

// claimState is one claim. Fields group by lifecycle; answer/dispute/quality
// fields are added by their modules as they land (fresh code, no live state).
type claimState struct {
	id     uint64
	title  string
	author address

	deposit  int64 // refundable anti-spam deposit (escrowed)
	fee      int64 // 10% of deposit: burned on dead/conclusive-low, else refunded
	seeded   bool  // moderator-seeded (deposit/fee waived; author draw = 0, I5)
	openedAt int64
	closed   bool // dead-claim close (unanswered past the timeout)
	// dustBurns is what the deposit+fee ACTUALLY burned at a conclusive low —
	// recorded because settleSlash must size its bounty top-up against real
	// burns, not against params (a seeded claim burns nothing, and the params
	// base would silently under-pay the flagger). See strips.gno / quality.gno.
	dustBurns int64
	// Policing-surface membership (strips.gno, MODERATION.md §5.3). Render-layer
	// only: no money path reads them; they make index entry/exit idempotent.
	inStrip   bool
	inPending bool

	// The two stake pools and their staker records (stake.gno).
	yesStake, noStake int64
	stakers           *bptree.BPTree // addr|side -> *stakePos
	// Per-side lifetime conviction (rate-weighted, u128) — the reward
	// denominators and the manipulation-resistant lifetime ratio (§3.9) —
	// and the raw ∫stake·dt pools (the Q7 cap bases), both freeze-capped.
	yesConvHi, yesConvLo uint64
	noConvHi, noConvLo   uint64
	yesRawHi, yesRawLo   uint64
	noRawHi, noRawLo     uint64
	// The side integrals' last-advance markers (advancePools).
	yesLastAcc, noLastAcc     int64
	yesLastRawAt, noLastRawAt int64

	// The trailing rings (§3.9): total staked (answerability X̄) and the YES
	// pool (the ratio series). Observed on every stake/unstake.
	oi  twap.Ring // total stake, hourly, one week
	yes twap.Ring // YES pool, hourly, one week

	// Answer-freeze markers (answer.gno sets them; stake/unstake refuse after).
	// rateAccAtFreeze pins the era integral at the freeze height so frozen
	// conviction can never be repriced by later d_eff moves (audit H1).
	frozenAt        int64 // 0 = live
	rateAccAtFreeze int64
	xBarFrozen      int64 // P6: the trailing-X̄ snapshot at the answer
	// Q1: the quality electorate's epoch — the last SEALED epoch at the
	// answer, set before any flag can exist; every quality vote reads it.
	qualityEpoch uint32

	// The answer (answer.gno). answerBond is the LIVE escrowed remainder
	// (zeroed as disposed, exactly once); answerBond0 is the posted magnitude —
	// the anchor the dispute-bond and comp formulas read across rounds.
	answer       int8 // sideYES/sideNO once frozenAt != 0
	answerer     address
	answerBond   int64
	answerBond0  int64
	answerHeight int64

	// VERDICT_FINAL (P4): set by SettleUndisputed, Finalize, or provClose.
	verdictAt int64  // 0 = no verdict yet
	route     string // "undisputed" | "vote" | "closed"
	// Quality (quality.gno finalizes; mid is the undisputed default).
	tier      int64
	tierFinal bool
	// The dispute machine (dispute.gno). provisional is the standing verdict
	// between a decided round and Finalize (-1 = none); escrowUntil is the
	// reopen window's end, set once at the first resolution.
	disputeOpen   bool
	round         int64
	failedRounds  int64
	decidedRounds int64
	disputer      address
	disputeBond   int64
	proposalID    int64
	provisional   int8
	escrowUntil   int64
	provClose     bool
	// credEligible: some UPHELD round's overturn side carried >= 1/4 of the
	// quorum floor — the record credits only for genuinely contested wins
	// (audit M2-1: a weightless self-contest must not mint the credential).
	credEligible bool

	// The quality lane (quality.gno, §10.2 Q2-Q5). One flag slot per claim;
	// a court-local sealed 3-bucket tally rides flags AND dispute rounds.
	flagOpen        bool
	flagger         address
	flagBond        int64
	flagVoteEnd     int64
	flagCycles      int64 // inconclusive reopens; bond frozen at 4xb0 after 3
	slotConsumed    bool
	lastFlagEventAt int64 // restamped at vote close/reopen/void — the 24h rule
	lastFlagAt      int64 // cooldown anchor once the bond is frozen
	qVoteSeq        uint64
	qLowW           int64 // the SEALED tally: no read ever exposes these live
	qMidW           int64
	qHighW          int64
	qVoted          *bptree.BPTree // seq|addr -> true (one vote per tally)
	// The slash escrow (Q5): reserved from the answer bond at a slash-low,
	// disposed exactly once at the counter-flag window's close.
	pendingSlash      int64
	pendingSlashUntil int64
	counterUsed       bool
	counterOpen       bool
	counterVoteEnd    int64
	// Crystallize marker (Q6-Q8): after it, quality is immutable.
	crystallized bool
	// Carrot pull-claim anchors (set at the conclusive tally)
	conclusiveSeq     uint64
	conclusiveTurnout int64
	// The draw (crystallize.gno): D's slices, denominators, one-shot flags.
	drawWinners   int64
	drawAuthor    int64
	drawAnswerer  int64
	winPoolConvCC int64
	openBlocks    int64
	carrotTotal   int64
	carrotPool    int64 // remaining
	carrotChoice  string
	carrotDenom   int64
	decidedPID    int64
	authorPaid    bool
	answererPaid  bool
}

// OpenClaim posts a claim. The opener escrows deposit + fee; the fee's
// disposition is decided at resolution (refund unless dead or conclusive low).
// Refused on a whole-court-purged court (§3.2 carve-out #2).
func OpenClaim(cur realm, courtSlug, title string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	if courtIsPurged(c) {
		panic("courtv2: this court is purged; no new claims may be opened")
	}
	return openClaim(c, cur.Previous().Address(), title, false)
}

// OpenClaimSeeded posts a claim with the CC deposit and fee WAIVED, for a
// moderator bootstrapping a young court (MODERATION.md §8). Mod-only; a
// suspended set is refused. The GNOT storage deposit is still the mod's to pay,
// and the author emission slice never mints on a seeded claim (I5, crystallize)
// so the waiver cannot be farmed. Refused on a purged court.
func OpenClaimSeeded(cur realm, courtSlug, title string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	if courtIsPurged(c) {
		panic("courtv2: this court is purged; no new claims may be opened")
	}
	cm := ensureMod(c)
	requireActiveMod(cm, who) // mod-only; suspension refuses (a read gate, no money)
	// A META-INSTALLED set may not seed (setmods vet, 2/3): the waiver skips the
	// CC deposit AND fee while the winner/answerer emission slices still mint,
	// so seeding is an economic privilege, not a render-layer act. A captured
	// meta court seating puppets must not thereby hand them a free claim
	// faucet. Creator-appointed and election-installed sets seed normally —
	// bootstrapping a young court is the whole point of the verb.
	if cm.installedByMeta {
		panic("courtv2: a meta-installed moderator set may not seed claims; seed after a local election")
	}
	return openClaim(c, who, title, true)
}

// openClaim is the shared creation core. A seeded claim waives deposit+fee.
func openClaim(c *Court, who address, title string, seeded bool) uint64 {
	if len(title) == 0 || len(title) > 200 {
		panic("courtv2: a claim title is 1..200 characters")
	}
	var dep, fee int64
	if !seeded {
		dep = c.params.minClaimDepositCC
		fee = dep * depositFeeBps / 10000
		c.coin.Transfer(who, c.escrow, dep+fee)
		c.deposit += dep + fee
	}
	c.nextID++
	id := c.nextID
	cs := &claimState{
		id:          id,
		title:       title,
		author:      who,
		deposit:     dep,
		fee:         fee,
		seeded:      seeded,
		openedAt:    runtime.ChainHeight(),
		stakers:     bptree.NewBPTree32(),
		oi:          twap.New(epochBlocks, twapBuckets, 8),
		yes:         twap.New(epochBlocks, twapBuckets, 8),
		provisional: -1, // int8 zero is sideYES — the sentinel must be explicit
	}
	c.claims.Set(beClaimKey(id), cs)
	// A seeded claim is force-visible on the pending list from birth: the set
	// that seeds content must not also be able to embargo it (§5.3, M-A18).
	if seeded {
		pendingEnter(c, cs)
	}
	// On the meta court, store the parsed `mod:` instruction (meta.gno).
	onClaimOpened(c, cs)
	// Claim-lane event: clients enumerate claims off events (no on-chain
	// address→claims index exists; MODERATION.md §2/I3). No user text beyond the
	// title, which is the claim's whole public content.
	chain.Emit("ClaimOpened",
		"court", c.id,
		"claim", strconv.FormatUint(id, 10),
		"author", who.String(),
		"seeded", strconv.FormatBool(seeded),
	)
	return id
}

// EditClaimTitle lets the author fix wording during the polish window, before
// any stake (MODERATION.md §6). The first stake or the window's close freezes
// the title forever. (With a 0 window the title is frozen from birth.) On the
// meta court this re-runs the mod: parser — wired in the meta module.
func EditClaimTitle(cur realm, courtSlug string, claimID uint64, newTitle string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if who != cs.author {
		panic("courtv2: only the author may edit the title")
	}
	if len(newTitle) == 0 || len(newTitle) > 200 {
		panic("courtv2: a claim title is 1..200 characters")
	}
	if cs.closed || cs.frozenAt != 0 {
		panic("courtv2: the claim is no longer editable")
	}
	if runtime.ChainHeight() >= cs.openedAt+c.params.stakeOpenDelayBlocks {
		panic("courtv2: the polish window has closed; the title is frozen")
	}
	if cs.yesStake != 0 || cs.noStake != 0 {
		panic("courtv2: staking has begun; the title is frozen")
	}
	cs.title = newTitle
	onTitleEdited(c, cs) // meta-parser re-run hook (no-op until the meta module)
	chain.Emit("ClaimTitleEdited", "court", c.id, "claim", strconv.FormatUint(claimID, 10))
}

// CloseDeadClaim closes a claim that never got an answer within the timeout:
// the deposit refunds to the author, the fee burns (the dead-claim spam price),
// and new stakes are refused. Existing stakes were never locked (no freeze
// happened) and remain withdrawable through Unstake. Permissionless.
func CloseDeadClaim(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.closed {
		panic("courtv2: already closed")
	}
	if cs.frozenAt != 0 {
		panic("courtv2: this claim has an answer; it settles, it does not die")
	}
	if runtime.ChainHeight() < cs.openedAt+deadClaimTimeout {
		panic("courtv2: the dead-claim timeout has not passed")
	}
	cs.closed = true
	// Terminal: nothing on a dead claim is policeable any more (§5.3 exits).
	pendingExit(c, cs)
	stripExit(c, cs)
	// Exactly-once dispositions: refund the deposit, burn the fee.
	if cs.deposit > 0 {
		c.coin.Transfer(c.escrow, cs.author, cs.deposit)
		c.deposit -= cs.deposit
		cs.deposit = 0
	}
	if cs.fee > 0 {
		c.coin.Burn(c.escrow, cs.fee)
		c.deposit -= cs.fee
		cs.fee = 0
	}
}

// ------------------------------------------------------------------ reads --

func ClaimCount(courtSlug string) uint64 { return mustCourt(courtSlug).nextID }
func ClaimTitle(courtSlug string, claimID uint64) string {
	return mustClaim(mustCourt(courtSlug), claimID).title
}
func ClaimAuthor(courtSlug string, claimID uint64) address {
	return mustClaim(mustCourt(courtSlug), claimID).author
}
func ClaimClosed(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).closed
}
func ClaimSeeded(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).seeded
}

// StakePools returns the two live pool totals — the instantaneous ratio's
// numerator and denominator.
func StakePools(courtSlug string, claimID uint64) (yes, no int64) {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return cs.yesStake, cs.noStake
}

// TrailingOI is the flash-resistant trailing average of total stake (X̄).
func TrailingOI(courtSlug string, claimID uint64, window int64) (avg int64, mature bool) {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return cs.oi.Average(runtime.ChainHeight(), window)
}

// PoolConviction is each side's lifetime rate-weighted conviction in CC units —
// the numerator/denominator of the manipulation-resistant lifetime ratio (§3.9).
// Exposed so a client can render that ratio series (render shows it, but a
// structured UI needs it via qeval).
func PoolConviction(courtSlug string, claimID uint64) (yes, no int64) {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return convToCC(cs.yesConvHi, cs.yesConvLo), convToCC(cs.noConvHi, cs.noConvLo)
}

// TrailingYes is the flash-resistant trailing average of the YES pool — the
// numerator of the trailing-week ratio (TrailingOI is its denominator).
func TrailingYes(courtSlug string, claimID uint64, window int64) (avg int64, mature bool) {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	return cs.yes.Average(runtime.ChainHeight(), window)
}

func mustClaim(c *Court, id uint64) *claimState {
	v := c.claims.Get(beClaimKey(id))
	if v == nil {
		panic("courtv2: no such claim")
	}
	return v.(*claimState)
}

// beClaimKey is big-endian so claim ids iterate in order.
func beClaimKey(id uint64) string {
	b := [8]byte{
		byte(id >> 56), byte(id >> 48), byte(id >> 40), byte(id >> 32),
		byte(id >> 24), byte(id >> 16), byte(id >> 8), byte(id),
	}
	return string(b[:])
}
