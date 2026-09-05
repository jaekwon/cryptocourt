// Claims: an immutable statement of fact, a refundable deposit, a conditionally
// refundable fee, and two stake pools. No shares exist — see stake.gno.

package kourtv2

import (
	"chain"
	"strconv"
	"strings"

	checkpoint "gno.land/p/kourt/checkpoint/v0"
	twap "gno.land/p/kourt/twap/v0"
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
// A body is optional and bounded. 2,000 characters is a couple of paragraphs —
// enough to say what would settle the question and what it is not asking, and
// short of the essay that would make every claim page a wall.
const maxClaimBodyLen = 2000

// runeLen counts CHARACTERS, which is what every limit in this realm is stated
// in and what a person can count.
//
// len() counts UTF-8 BYTES, and every one of these caps used it. The two agree
// only for ASCII, so a 200-character Russian claim title — about 370 bytes — was
// refused with "a title is at most 200 characters", about a title that was 200.
// The surfaces that collect this text count characters too: an <input> maxLength
// is UTF-16 code units, so the composer accepted what the chain then rejected.
// Every non-Latin script hit the wall at roughly half the stated limit, and
// nobody writing in English could see it.
//
// Counting runes is strictly more permissive, so no claim that was valid becomes
// invalid. The cost is that text can occupy up to four times the bytes, which
// the author already pays for through the storage deposit.
func runeLen(s string) int {
	n := 0
	for range s {
		n++
	}
	return n
}

type claimState struct {
	id     uint64
	title  string
	// The claim's own statement of what it means: what would settle it, what
	// evidence is in view, what it is NOT asking. COURTS_STRUCTURE.md §4 gives
	// the rule and the reason — "the body is append-only, fixed at creation" —
	// and the reason is the attack it prevents: if the body could be revised, an
	// author could take a position, watch the market, and rewrite the framing
	// until their side is the true one. So there is no editor for it, not even
	// inside the polish window where the TITLE can still be corrected. A claim
	// filed with a bad body is a claim to close and re-file.
	body   string
	// Evidence the claim carries: a sha256 the author committed to and the
	// places the bytes may be found. media.gno holds the shape and the reasons;
	// docs/CLAIM_MEDIA.md holds the design. Fixed at creation like the body, and
	// for the body's reason — an author who could re-point an image could reframe
	// the claim after watching the market. A moderator can tombstone a slot.
	media  []mediaItem
	author address

	deposit  int64 // refundable anti-spam deposit (escrowed)
	fee      int64 // 10% of deposit: burned on dead/conclusive-low, else refunded
	seeded   bool  // moderator-seeded (deposit/fee waived; author draw = 0, I5)
	// noAccuracy: this claim pays no ACCURACY slice — drawWinners is zeroed and
	// the points stay unminted, exactly as `seeded` does for the author slice.
	// Set at open for a `mod:newfolder` appeal, whose question ("should this
	// court have a folder called X") is a proposal rather than a matter of fact:
	// paying stakers by conviction for agreeing with a proposal is a vote bought
	// with the reward pool, and this product's rule is stakes, never ballots. The
	// AUTHOR slice is untouched on purpose — proposing a folder the court adopts
	// is work worth paying for, and that lane already exists.
	noAccuracy bool
	openedAt int64
	// Wall-clock stamps for the published deadlines (clock.gno). Heights above
	// and below stay as reference; these decide. Zero on pre-upgrade claims,
	// which keep their original height gates.
	openedAtTime   int64
	answeredAtTime int64
	verdictAtTime  int64
	escrowUntilAt  int64 // absolute: the reopen window's close, in unix seconds
	closed         bool  // dead-claim close (unanswered past the timeout)
	// dustBurns IS DEAD STATE. It recorded what deposit+fee actually burned at a
	// conclusive low, so settleSlash could size a bounty top-up against real
	// burns rather than params — a seeded claim burns nothing, and the params
	// base would have under-paid the flagger. settleSlash and the conclusive-low
	// path both went with the quality lane, and this field now has exactly one
	// non-comment line in the realm: the declaration below. Removing it changes
	// claimState's stored shape, so it is filed with flagger and flagVoteEnd
	// rather than dropped here.
	dustBurns int64
	// The board (board.gno). Four indexes, nil until the first comment: every
	// read tests for nil rather than calling ensure*, because a query carries no
	// storage deposit and a lazily-initialising read is unpaid state growth.
	board      *bptree.BPTree // be(rowID)            -> *boardRow
	boardTop   *bptree.BPTree // be(rowID)            -> true (top-level only)
	boardKids  *bptree.BPTree // be(parent)|be(rowID) -> true
	boardWrote *bptree.BPTree // string(addr)         -> int64
	boardScore *bptree.BPTree // beInv(score)|beInv(rowID) -> rowID (visible top-level only)
	boardVoted *bptree.BPTree // be(rowID)|string(addr)    -> true (one vote per address)
	boardNextID uint64

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
	// Drawable stake history (stakeseries.gno): the two pools as checkpoint
	// series, hourly (trimmed past a week) and daily (kept). VALUE fields on
	// this record deliberately — a pointer would be a second object. The twap
	// rings above are NOT replaced: they are bounded windows feeding X̄; these
	// are the archive a chart reads.
	yesH, noH     checkpoint.Series // hourly grain, epoch = height/720 + 1
	yesD, noD     checkpoint.Series // daily grain, epoch = height/17280 + 1
	histTrimmedTo uint32            // newest hourly epoch a trim rode on (throttle)

	// Answer-freeze markers (answer.gno sets them; stake/unstake refuse after).
	// rateAccAtFreeze pins the era integral at the freeze height so frozen
	// conviction can never be repriced by later d_eff moves (audit H1).
	frozenAt        int64 // 0 = live
	rateAccAtFreeze int64
	xBarFrozen      int64 // P6: the trailing-X̄ snapshot at the answer
	// THE RECORD, per side, as it stood when the claim was answered.
	//
	// These exist because nothing else preserves it. The conviction integrals are
	// add-only and survive forever, but yesStake/noStake are DECREMENTED on every
	// withdrawal, so once the participants take their principal home a settled
	// claim reads YES 0 / NO 0 — and the docket was rendering that live figure. The
	// whitepaper's introduction promises "every claim, every stake, every verdict,
	// every dissent" stays; the weight did stay, the amounts did not.
	//
	// xBarFrozen cannot substitute: it is the time-averaged TOTAL, so "how much was
	// on YES when it was answered" was recoverable from nowhere. Written once,
	// beside frozenAt, never touched again.
	yesStakeAtFreeze, noStakeAtFreeze int64
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
	// tierRef is the court's typical claim size AS OF THIS CLAIM'S ANSWER — the
	// size that would have earned exactly 1x here (tier.gno). Frozen beside
	// xBarFrozen and for the same reason: the multiplier is the ratio of the
	// two, and a live denominator would let whoever calls the permissionless
	// OpenRewards choose it. Zero on any claim frozen before this shipped, which
	// tierBpsFor reads as par.
	tierRef int64

	// Quality (quality.gno finalizes; mid is the undisputed default).
	// The dispute machine (dispute.gno). provisional is the standing verdict
	// between a decided round and Finalize (-1 = none); escrowUntil is the
	// reopen window's end, set once at the first resolution.
	disputeOpen   bool
	// disputeOpenedTime is when the CURRENT round opened, in wall seconds.
	// The height is already on chain — the governor records it and Timings
	// returns it — but the height alone cannot be dated: the test clock moves
	// heights and seconds by independent skews, so deriving one from the other
	// puts the marker months from the events beside it. Overwritten by each
	// round, like proposalID, because a chart marks the round that is running.
	disputeOpenedTime int64
	round         int64
	failedRounds  int64
	decidedRounds int64
	// disputer is the CURRENT round's disputer and is overwritten by every
	// OpenDispute. Read it only for this round's bond dispositions — never to
	// attribute an earlier round's outcome. See overturnBy.
	disputer      address
	disputeBond   int64
	// overturnBy is who won the overturn, recorded AT the round that won it
	// rather than read back from `disputer` afterwards — the same discipline
	// slashFlagger uses, and for the same reason.
	//
	// THE BUG THIS FIELD EXISTS TO PREVENT, because it was live and measured: a
	// failed reopen does NOT reset `provisional` (only the first resolution
	// does), so after an overturn a stranger could open a second round, let it
	// fail quorum for half a bond, and become `cs.disputer` — collecting the
	// standing credit for an overturn they did not win and denying it to the
	// address that did. Attribution has to be stamped when the thing happens.
	overturnBy address
	// overturnBond is that winner's OWN posted bond, captured at the same
	// instant. The dispute credit scales each party on their own risk, and the
	// disputer's is min(20%·X̄, 40%·answerBond0) — the answer arm always binds,
	// so scaling them on answerBond0 instead paid them 2.5x what they staked.
	// cs.disputeBond cannot be read back later; it is zeroed on disposal.
	overturnBond int64
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
	flagger     address
	flagVoteEnd int64
	// slotConsumed IS GONE, and so is every reader that made it interesting. The
	// field is not declared in this struct any more; what stood here was a
	// twenty-two-line enumeration of SEVEN behavioural readers, written because
	// three reviewers costing a change to it had each under-counted them, and
	// warning that the cheapest-looking fix to any one silently broke the others.
	//
	// All seven went with the quality lane. Three were quality.gno itself
	// (OpenFlag, reaskQualityTally, resolveQualityRide); two were
	// SettleUndisputed's tier-clobber guard and slash-reserve retention, and two
	// the same pair in Finalize — and stripped of comments neither of those
	// functions now contains any tier or slot code at all (see 76b2941, daee87b).
	// The two display readers, FlagState and render.gno's, went with them.
	//
	// It also carried PLAN §13 v0.56's open owner decision — that jobs (1), (5)
	// and (7) keyed slash-eligibility to a tally possibly decided at the
	// supply-floorLESS demotionBar, so a sub-bar low disarmed the full-bar slash.
	// That decision is moot: there is no latch to split and no slash to disarm.
	// Recorded rather than dropped, because "we decided nothing and the question
	// went away with the code" is a different fact from "we forgot".
	//
	// The two fields BELOW are a different matter: flagger and flagVoteEnd are
	// still declared and have zero non-comment readers anywhere in the realm.
	// Dead persisted state, not a dead comment — removing them changes the stored
	// shape and wants a reseed, so it is filed rather than done here.
	voted          *bptree.BPTree // seq|addr -> true (one vote per tally)
	// THE SLASH ESCROW (Q5) IS GONE, with the quality lane. What stood here was
	// twenty-five lines on slashLevied, slashFlagger and qualityReasked -- three
	// one-way exactly-once latches bounding, respectively, slash ORIGINATION, the
	// bounty beneficiary, and the dispute ride's tally wipe. None of the three is
	// declared any more, and slashSizeFor, settleSlash and CounterFlag, which the
	// text reasoned through, have no non-comment line left in this realm either.
	// Its closing worry -- that without the ride latch a sock could re-roll the
	// slash and then the tier ~3x inside a 3-week escrow, at the price of a dispute
	// bond each time -- describes an attack on machinery that no longer exists.
	//
	// ONE INVARIANT IN IT IS STILL LIVE AND IS KEPT. The old text explained why
	// settleSlash must never fall back to cs.flagger: on a ride path that is either
	// the zero address, so grc20votes.Mint's mustBeValid PANICS and the entitlement
	// is unpayable forever, or a stale flagger from an earlier cycle. The part that
	// outlives the slash path is the CONSEQUENCE -- reservedTail is monotone and
	// never decremented (court.gno declares it; emission.gno advances it with
	// mustAdd), so enqueueing a senior entitlement that can never be paid does not
	// merely fail, it permanently shrinks the reservoir for every later junior
	// draw. That hazard belongs to enqueueSenior and reservedTail, which are both
	// live, and it is written here rather than deleted with the dead latches.
	// OpenRewards marker (Q6-Q8): after it, quality is immutable.
	rewardsOpened bool
	// Carrot pull-claim anchors (set at the conclusive tally)
	// The draw (openrewards.gno): D's slices, denominators, one-shot flags.
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
	// The deciding round's spam tally, frozen beside decidedPID and for exactly
	// its reason: cs.proposalID is OVERWRITTEN by every later round, so by
	// OpenRewards it may name a round that did not decide anything. The
	// governor's counters do survive a ReleaseRoll — Tally reads yes/no/abstain,
	// not the roll — so this is not about the figures disappearing; it is about
	// reading the WRONG round's figures.
	//
	// BOTH numbers, not the ratio: a discount whose denominator is gone cannot
	// be checked against anything, and a reader given only "0.8x" cannot tell a
	// 1-of-5 round from a 20-of-100 one.
	//
	// Zero on any claim decided before this shipped, which the draw reads as
	// "no discount" rather than as "discount to nothing".
	spamW      int64
	spamTotalW int64
	// spamClosed marks a claim the electorate DISCARDED — more than half the
	// weight cast called it spam. It is a reason, not a mechanism: the claim
	// also carries provClose, so every withdrawal path that already means
	// "everyone takes their principal back" works unchanged. What this field
	// buys is that a page, and a later reader, can tell "three rounds failed to
	// reach quorum" from "the court looked and said this was junk" — two very
	// different things that would otherwise be one flag.
	spamClosed bool
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
		panic("kourtv2: this court is purged; no new claims may be opened")
	}
	return openClaim(c, cur.Previous().Address(), title, "", false)
}

// OpenClaimP posts a claim WITH A BODY. Additive rather than a third parameter on
// OpenClaim: that one is called by every committed filetest, txtar and scenario in
// the tree, and widening it would break all of them for a field the caller may
// legitimately not want. The `P` suffix follows StartCourtP — same entrypoint,
// one more thing said about it.
//
// There is deliberately no OpenClaimSeededP. A seeded claim is a moderator
// bootstrapping a young court's docket with somebody else's question; writing a
// body on another author's behalf is a different act from filing one, and it
// should not be a quiet parameter on an existing waiver path.
func OpenClaimP(cur realm, courtSlug, title, body string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	if courtIsPurged(c) {
		panic("kourtv2: this court is purged; no new claims may be opened")
	}
	return openClaim(c, cur.Previous().Address(), title, body, false)
}

// OpenClaimSeeded posts a claim with the CC deposit and fee WAIVED, for a
// moderator bootstrapping a young court (MODERATION.md §8). Mod-only; a
// suspended set is refused. The GNOT storage deposit is still the mod's to pay,
// and the author emission slice never mints on a seeded claim (I5, open the rewards)
// so the waiver cannot be farmed. Refused on a purged court.
func OpenClaimSeeded(cur realm, courtSlug, title string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	if courtIsPurged(c) {
		panic("kourtv2: this court is purged; no new claims may be opened")
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
		panic("kourtv2: a meta-installed moderator set may not seed claims; seed after a local election")
	}
	return openClaim(c, who, title, "", true)
}

// openClaim is the shared creation core. A seeded claim waives deposit+fee.
// OpenClaimPM posts a claim with a body AND media. Additive for OpenClaimP's
// reason, restated because it keeps being the right one: OpenClaim is called by
// every committed filetest, txtar and scenario in the tree, and widening a
// signature breaks all of them for a field most callers will not want.
//
// There is deliberately no OpenClaimSeededPM, following the same rule that
// refused OpenClaimSeededP. Attaching evidence on another author's behalf is a
// different act from filing it, and it should not ride in as a quiet parameter
// on an existing waiver path.
//
// The media argument's format is documented on parseMediaArg. A fault in it
// panics rather than dropping the item, because a claim is filed once and cannot
// be amended: silently discarding evidence would be discovered by the author
// only after they had paid the deposit for a claim they can no longer fix.
func OpenClaimPM(cur realm, courtSlug, title, body, media string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	if courtIsPurged(c) {
		panic("kourtv2: this court is purged; no new claims may be opened")
	}
	// Parsed BEFORE the claim is opened, so a malformed media argument is
	// refused before the deposit moves. A panic would revert either way; doing
	// the cheap check first means the escrow transfer is never work thrown away.
	items := parseMediaArg(media)
	id := openClaim(c, cur.Previous().Address(), title, body, false)
	if len(items) > 0 {
		mustClaim(c, id).media = items
	}
	return id
}

func openClaim(c *Court, who address, title, body string, seeded bool) uint64 {
	if runeLen(title) == 0 || runeLen(title) > 200 {
		panic("kourtv2: a claim title is 1..200 characters")
	}
	// Optional: a claim is a title first and the body earns its bytes. The cap is
	// not arbitrary — every byte is storage the author pays a deposit on, and a
	// court of record wants the question stated, not an essay attached to it.
	if runeLen(body) > maxClaimBodyLen {
		panic("kourtv2: a claim body is at most " + strconv.Itoa(maxClaimBodyLen) + " characters")
	}
	var dep, fee int64
	if !seeded {
		dep = effMinDeposit(c)
		fee = dep * depositFeeBps / 10000
		mustSpendable(c, who, dep+fee)
		c.coin.Transfer(who, c.escrow, dep+fee)
		c.deposit += dep + fee
	}
	c.nextID++
	id := c.nextID
	cs := &claimState{
		id:           id,
		title:        title,
		body:         body,
		author:       who,
		deposit:      dep,
		fee:          fee,
		seeded:       seeded,
		openedAt:     heightNow(),
		openedAtTime: nowTime(),
		stakers:      bptree.NewBPTree32(),
		oi:           twap.New(epochBlocks, twapBuckets, 8),
		yes:          twap.New(epochBlocks, twapBuckets, 8),
		provisional:  -1, // int8 zero is sideYES — the sentinel must be explicit
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
	// address→claims index exists; MODERATION.md §2/I3).
	//
	// NO USER TEXT AT ALL, and the title is excluded DELIBERATELY rather than
	// forgotten. Four fields go out — court, claim, author, seeded — and every
	// one is an identifier or a flag. A client that wants the title reads it
	// from state, where purge can still reach it.
	//
	// This comment used to say "no user text beyond the title, which is the
	// claim's whole public content", which described an emit that has never
	// existed and read as prior sanction for adding one. Events are unpurgeable
	// history, so an editor who added the title on the strength of that
	// sentence would put user text somewhere purge cannot retract — defeating
	// the thing purge is for. moderation.gno states the rule as I6: events
	// carry act metadata and a category/act code only, NEVER
	// reason/annotation/title text. This lane is not an exception to it.
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
		panic("kourtv2: only the author may edit the title")
	}
	if len(newTitle) == 0 || len(newTitle) > 200 {
		panic("kourtv2: a claim title is 1..200 characters")
	}
	if cs.closed || cs.frozenAt != 0 {
		panic("kourtv2: the claim is no longer editable")
	}
	if passed, known := pastDeadline(cs.openedAtTime, blocksToSecs(c.params.stakeOpenDelayBlocks)); (known && passed) ||
		(!known && heightNow() >= cs.openedAt+c.params.stakeOpenDelayBlocks) {
		panic("kourtv2: the polish window has closed; the title is frozen")
	}
	if cs.yesStake != 0 || cs.noStake != 0 {
		panic("kourtv2: staking has begun; the title is frozen")
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
		panic("kourtv2: already closed")
	}
	if cs.frozenAt != 0 {
		panic("kourtv2: this claim has an answer; it settles, it does not die")
	}
	if passed, known := pastDeadline(cs.openedAtTime, deadClaimSecs); (known && !passed) ||
		(!known && heightNow() < cs.openedAt+deadClaimTimeout) {
		panic("kourtv2: the dead-claim timeout has not passed")
	}
	cs.closed = true
	// Terminal: nothing on a dead claim is policeable any more (§5.3 exits).
	pendingExit(c, cs)
	stripExit(c, cs)
	releaseMetaLatchIfMeta(c, cs)
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

// ClaimTitle goes through the SAME text gate as render: a purged claim returns
// its tombstone and a globally-redacted one returns nothing. A raw accessor here
// would defeat purge — the legal-compliance power — with a single qeval.
func ClaimTitle(courtSlug string, claimID uint64) string {
	c := mustCourt(courtSlug)
	return claimTitleFor(c, mustClaim(c, claimID))
}
// ClaimBody goes through the same moderation gate as the title. A purged or
// globally-redacted claim must not answer with the text the purge exists to
// remove — and the body is the bigger surface of the two, so a read that
// returned cs.body directly would make the whole moderation layer decorative.
func ClaimBody(courtSlug string, claimID uint64) string {
	c := mustCourt(courtSlug)
	return claimBodyFor(c, mustClaim(c, claimID))
}
// ClaimMedia answers with the claim's evidence as one line of JSON, through the
// same moderation gate the title and the body go through — for the reason stated
// on ClaimBody, which applies here with more force: media is the likeliest thing
// a purge is FOR, so a read that returned cs.media directly would defeat the
// legal-compliance power with a single qeval.
//
// One line, because the overlay's qeval parser splits raw output on newlines
// before it matches a typed value. See encodeMedia.
func ClaimMedia(courtSlug string, claimID uint64) string {
	c := mustCourt(courtSlug)
	return encodeMedia(claimMediaVisible(c, mustClaim(c, claimID)))
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
	return cs.oi.Average(heightNow(), window)
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
	return cs.yes.Average(heightNow(), window)
}

// DocketSeries answers, in ONE query, the four reads a docket row needs for each
// of many claims:
//
//	"<id>:<yesStake>:<noStake>:<convYes>:<convNo>:<trailOI>:<oiMature>:<trailYes>:<yesMature>;…"
//
// mature flags are "1" or "0". ids is a comma-separated list, in any order; the
// reply keeps that order and SKIPS an id this court does not have, so a caller
// matches on the id field rather than on position. At most seriesPageMax ids are
// answered and the rest are dropped — read the length of what came back.
//
// WHY IT EXISTS. The overlay drew a docket of fourteen rows by asking
// StakePools, PoolConviction, TrailingOI and TrailingYes per row: 56 queries,
// each one reloading this realm at ~60-90ms, which is most of the four seconds a
// court page spent reading the chain. Every one of those numbers is already in
// the claimState this function walks once. Batching at the RPC does not help —
// gno executes a JSON-RPC array serially — so the batching has to happen HERE,
// where the realm is loaded once for the whole page.
//
// The four single-claim readers stay: a claim page wants one row, and an older
// overlay is still entitled to ask the old way.
func DocketSeries(courtSlug string, ids string, window int64) string {
	c := mustCourt(courtSlug)
	now := heightNow()
	out := strings.Builder{}
	sent := 0
	for _, part := range strings.Split(ids, ",") {
		if sent >= seriesPageMax {
			break
		}
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		id, err := strconv.ParseUint(part, 10, 64)
		if err != nil {
			continue
		}
		v := c.claims.Get(beClaimKey(id))
		if v == nil {
			continue // a claim this court does not have is skipped, never guessed
		}
		cs := v.(*claimState)
		oi, oiMature := cs.oi.Average(now, window)
		yes, yesMature := cs.yes.Average(now, window)
		if sent > 0 {
			out.WriteString(";")
		}
		out.WriteString(strconv.FormatUint(id, 10))
		out.WriteString(":" + strconv.FormatInt(cs.yesStake, 10))
		out.WriteString(":" + strconv.FormatInt(cs.noStake, 10))
		out.WriteString(":" + strconv.FormatInt(convToCC(cs.yesConvHi, cs.yesConvLo), 10))
		out.WriteString(":" + strconv.FormatInt(convToCC(cs.noConvHi, cs.noConvLo), 10))
		out.WriteString(":" + strconv.FormatInt(oi, 10))
		out.WriteString(":" + boolDigit(oiMature))
		out.WriteString(":" + strconv.FormatInt(yes, 10))
		out.WriteString(":" + boolDigit(yesMature))
		sent++
	}
	return out.String()
}

// seriesPageMax caps one DocketSeries reply. The overlay pages the docket at 50;
// this leaves room for that plus the strips above it without a second query.
const seriesPageMax = 60

func boolDigit(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

func mustClaim(c *Court, id uint64) *claimState {
	v := c.claims.Get(beClaimKey(id))
	if v == nil {
		panic("kourtv2: no such claim")
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
