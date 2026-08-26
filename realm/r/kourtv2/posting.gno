// Posting: what a level is, what it costs to reach, and how fast it lets you
// write (docs/CLAIM_BOARDS.md §3 and §4). standing.gno owns the RECORD; this file
// owns what the record buys.
//
// TWO DOORS, AND NO FREE TIER. You post at a level, and you reach one of two
// ways: earn standing, or burn CC once for an entry pass. Zero standing and no
// pass is zero posts — not a small allowance, zero. Any free per-address
// allowance is a free sybil flood, which is the whole reason the door is priced
// at all.
//
// THE THRESHOLDS ARE FRACTIONS OF SUPPLY, never absolute standing. Standing is
// denominated in CC and a mature court's acts pay on the order of a hundred times
// a young court's for the same work, so a fixed number is unreachable on one and
// trivial on the other. Every other bar in this realm is already a fraction of
// supply for the same reason — quorumSupplyBps, electionFloor, supplyFloor — and
// this one reads the same sealed epoch they do, because live supply is griefable
// in the same block.
package kourtv2

import (
	"chain"
	"strconv"
	"strings"

	sanitize "gno.land/p/nt/markdown/sanitize/v0"
)

// The ladder, in bps of supply, and the rate each rung buys.
//
// The TOP-TO-ENTRY RATIO IS A REALM CONSTANT and the rungs are not: the ratio is
// what bounds both a splitter's gain and what farming standing is worth in
// throughput, so a court that raised it would move a bound that protects readers
// of its own board and everyone reasoning about the lane. The thresholds only
// shape how fast people climb inside one court.
const (
	ladderT1BpsInit = int64(5)   // 0.05% of supply — about one undisputed win
	ladderT2BpsInit = int64(25)  // 0.25% — five wins, or one caught bad claim
	ladderT3BpsInit = int64(100) // 1% — twenty wins, or three caught bad claims

	postsEntryInit = int64(3)  // level 1: the pass, or t1 standing
	postsT2Init    = int64(10) // level 2
	postsT3Init    = int64(30) // level 3 — ten times entry, the frozen ratio

	// ladderTopRatio is that ratio, checked at deploy. Frozen: see above.
	ladderTopRatio = int64(10)

	// passPriceMinCC floors the entry burn so a young court is never free, and
	// passPriceBps scales it so it does not decay to nothing as a court grows.
	// The EFFECTIVE price is additionally lidded — see passPriceFor, where the
	// lid is the §16 relation rather than a number.
	passPriceMinCC = int64(100_000) // 0.1 CC
	passPriceBps   = int64(1)       // 0.01% of supply

	// passPriceOfT3 is that relation: a unit of standing must be worth little
	// enough that the flag lane's burn still dominates it (A19) and staking does
	// not pay on carry alone. Both reduce to V <= 0.10, and substituting the
	// substitutability bound V <= ratio x passPrice / t3 gives t3 >= 100 x
	// passPrice. docs/CLAIM_BOARDS.md §16 carries the derivation.
	passPriceOfT3 = int64(100)
)

// mustPostingInvariants is the deploy gate on the frozen half.
//
// ITS PANICS ARE IN NO MUTATION BATCH, deliberately, and for the reason
// mustElectionInvariants records about its own: every comparison here is between
// package CONSTANTS, and init() runs on every package load including every test
// load, so the relationships are enforced on every run by the guard itself.
// Violate one and the package does not load; delete a panic and nothing can
// observe the difference, because the constants satisfy it.
func mustPostingInvariants() {
	if postsT3Init != postsEntryInit*ladderTopRatio {
		panic("kourtv2: the top rung must be exactly ladderTopRatio x entry — the ratio is the bound, not a suggestion")
	}
	if !(0 < ladderT1BpsInit && ladderT1BpsInit < ladderT2BpsInit && ladderT2BpsInit < ladderT3BpsInit) {
		panic("kourtv2: the ladder must be strictly increasing")
	}
	if !(0 < postsEntryInit && postsEntryInit < postsT2Init && postsT2Init < postsT3Init) {
		panic("kourtv2: the rates must be strictly increasing")
	}
	// The §16 relation, on the DEFAULTS. passPriceFor clamps it at runtime for
	// every court and every supply; this catches a default that could never
	// satisfy it.
	if ladderT3BpsInit < passPriceOfT3*passPriceBps {
		panic("kourtv2: t3 must be at least 100x the pass price, or a unit of standing is worth more than the flag lane's burn can cover")
	}
}

func init() { mustPostingInvariants() }

// ---- the ladder: a realm default a court may override ---------------------

// ladder is the five settable numbers. A TUPLE, as creditRates is, because the
// bound on t3 is a RELATION to the pass price and the bound on the rungs is that
// they increase — neither is a range on one number, and independent setters would
// leave a window between two calls where the relation is violated.
type ladder struct {
	t1Bps, t2Bps, t3Bps int64
	postsEntry, postsT2 int64
}

var ladderDefault = ladder{
	t1Bps: ladderT1BpsInit, t2Bps: ladderT2BpsInit, t3Bps: ladderT3BpsInit,
	postsEntry: postsEntryInit, postsT2: postsT2Init,
}

// postsT3 is derived, never stored: the ratio is frozen, so the top rung is not
// a settable number and cannot drift from the constant that bounds it.
func (l ladder) postsT3() int64 { return l.postsEntry * ladderTopRatio }

func ladderFor(c *Court) ladder {
	if c.ladder != nil {
		return *c.ladder
	}
	return ladderDefault
}

// mustLadder refuses a set that breaks the ordering or the §16 relation.
//
// t1 AND t2 CARRY NO CROSS-PARAMETER CONDITION, and t3 does. Getting t1 or t2
// wrong only changes how fast people climb inside one court, which is
// self-punishing — a slow board or a loose one, harming nobody who did not
// choose it. Getting t3 wrong changes what a unit of standing is WORTH, which is
// the bound the whole earning table rests on. Hence one extra clause on one
// number, and it is a relation rather than a range.
func mustLadder(l ladder) {
	if !(0 < l.t1Bps && l.t1Bps < l.t2Bps && l.t2Bps < l.t3Bps && l.t3Bps <= 10_000) {
		panic("kourtv2: the ladder must be strictly increasing within 0..10000 bps")
	}
	if !(0 < l.postsEntry && l.postsEntry < l.postsT2 && l.postsT2 < l.postsT3()) {
		panic("kourtv2: the posting rates must be strictly increasing")
	}
	if l.t3Bps < passPriceOfT3*passPriceBps {
		panic("kourtv2: t3 must stay at least 100x the pass price — lowering it alone would make a unit of standing worth more than the flag lane's burn can cover")
	}
}

// SetLadderDefault sets the realm-wide ladder every court inherits.
func SetLadderDefault(cur realm, t1Bps, t2Bps, t3Bps, postsEntry, postsT2 int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin sets the default ladder")
	}
	l := ladder{t1Bps, t2Bps, t3Bps, postsEntry, postsT2}
	mustLadder(l)
	ladderDefault = l
	// EMITTED, because this is the widest act in the lane: it moves the
	// default for EVERY court at once. The per-court setters log and emit;
	// these two changed the floor under all of them in silence. There is no
	// single court to log against, so the event is the whole record.
	chain.Emit(globalActEvent,
		"court", "*",
		"claim", "0",
		"act", "set-ladder-default:"+ladderKey(l),
		"by", cur.Previous().Address().String(),
		"height", eventHeight(),
	)
}

// SetCourtLadder overrides the ladder for one court.
//
// speechM-of-n, LOGGED, AND REVERSIBLE BY THE GLOBAL DAO — because this is the
// most powerful speech verb in the realm, not the least.
//
// It shipped as `requireActiveMod` alone: membership, not suspended, and nothing
// else. So any single member of any set could call
// SetCourtLadder(slug, 9998, 9999, 10000, 1, 2) — which mustLadder accepts, being
// strictly increasing and within its bounds — and every address below 99.98% of
// supply drops to level 0. That is a permanent, court-wide, unlogged speech
// throttle with no recovery path, sitting twenty lines from FreezeBoard, which
// silences ONE address for twelve hours and was given m-of-n, a ceiling, a gap, a
// log row, an event and an O(1) backstop. The blast radius ran the wrong way
// round the authority.
//
// The per-court override itself stays: it is an owner ruling (§15) that these are
// global defaults a court may override. What was missing was the authority, not
// the lever.
func SetCourtLadder(cur realm, courtSlug string, t1Bps, t2Bps, t3Bps, postsEntry, postsT2 int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireActiveMod(cm, who)
	l := ladder{t1Bps, t2Bps, t3Bps, postsEntry, postsT2}
	mustLadder(l)
	// THE VALUES ARE IN THE ACTION KEY. Without them two moderators proposing
	// DIFFERENT ladders would each count toward one threshold, and the set would
	// install whichever one happened to arrive last — an m-of-n that never agreed
	// on anything.
	if fire, _ := approveAction(cm.pending, "setladder:"+ladderKey(l), who, "",
		speechM(cm)); !fire {
		return
	}
	c.ladder = &l
	cm.appendCourtLog(who, "setladder:"+ladderKey(l), "")
	emitModAct(c.id, 0, "setladder", who)
}

// ladderKey is the tuple as one string, for the action key and the log row. One
// definition so the thing voted on and the thing recorded cannot differ.
func ladderKey(l ladder) string {
	return strconv.FormatInt(l.t1Bps, 10) + ":" + strconv.FormatInt(l.t2Bps, 10) +
		":" + strconv.FormatInt(l.t3Bps, 10) + ":" +
		strconv.FormatInt(l.postsEntry, 10) + ":" + strconv.FormatInt(l.postsT2, 10)
}

// ClearCourtLadder returns a court to the realm default.
//
// requireMod, not requireActiveMod: returning to the realm default is
// de-escalation, and a suspended set must be able to undo its own throttle — the
// same rule the six sanction undos follow, and the reason a suspended set could
// not previously clear the very override that got it suspended.
func ClearCourtLadder(cur realm, courtSlug string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireMod(cm, who)
	if c.ladder == nil {
		panic("kourtv2: this court has no ladder override")
	}
	if fire, _ := approveAction(cm.pending, "clearladder:"+c.id, who, "",
		speechM(cm)); !fire {
		return
	}
	c.ladder = nil
	cm.appendCourtLog(who, "clearladder", "")
	emitModAct(c.id, 0, "clearladder", who)
}

// ---- the price of the entry pass ------------------------------------------

// passPriceFor is the CC an address burns once to hold the entry level.
//
// THE LID IS THE §16 RELATION, EXPRESSED AS A CLAMP RATHER THAN A CHECK, and
// that is what makes the relation hold at every supply instead of only where a
// setter looked. The floor exists so a young court is never free; on a court
// small enough for the floor to bind it can exceed t3/100, and a check would
// then have to refuse a configuration nobody chose. Clamping keeps the door
// priced AND the bound intact, and the two never fight.
//
// Reads the last SEALED epoch, never live supply: supplyFloor's own note says
// why — a live figure is griefable inside the same block.
// boardSupply is the sealed supply every board threshold is quoted against, and
// whether there IS one yet.
//
// grc20votes' mustBeSealed panics on `at == 0 || at >= Epoch()`, so
// PastTotal(Epoch()-1) panics for any court whose coin has not reached epoch 2 —
// which is every brand-new court. The realm already lives with that on the
// dispute and election paths (quorumFloor and electionBond read the same
// expression), but those are unreachable until a claim has been answered and
// disputed, by which time epochs have rolled. The board is reachable in the
// first block, so it hit the condition head-on: `PostComment` aborted with
// "grc20votes: that epoch has not been sealed yet", and `PassPrice`, `PostLevel`
// and the whole `/me` page — all READS — panicked outright.
//
// Found by z_read_filetest on the first run after the board reads were added to
// it, which is exactly the defect class that file exists for: every unit test
// skips two epochs in its fixture (see postingFixture's own note), so the suite
// could not see it.
func boardSupply(c *Court) (int64, bool) {
	if c.coin.Epoch() < 2 {
		return 0, false
	}
	return c.coin.PastTotal(c.coin.Epoch() - 1), true
}

func passPriceFor(c *Court) int64 {
	sup, sealed := boardSupply(c)
	if !sealed {
		return 0
	}
	p := sup * passPriceBps / 10_000
	if p < passPriceMinCC {
		p = passPriceMinCC
	}
	if lid := sup * ladderFor(c).t3Bps / 10_000 / passPriceOfT3; p > lid {
		p = lid
	}
	if p < 0 {
		p = 0
	}
	return p
}

// PassPrice is what an entry pass costs in this court right now.
func PassPrice(courtSlug string) int64 { return passPriceFor(mustCourt(courtSlug)) }

// Ladder is what this court currently runs, packed:
//
//	t1:<bps>;t2:<bps>;t3:<bps>;entry:<n>;l2:<n>;l3:<n>;inherited:<0|1>
func Ladder(courtSlug string) string {
	c := mustCourt(courtSlug)
	l := ladderFor(c)
	inherited := "1"
	if c.ladder != nil {
		inherited = "0"
	}
	return "t1:" + strconv.FormatInt(l.t1Bps, 10) +
		";t2:" + strconv.FormatInt(l.t2Bps, 10) +
		";t3:" + strconv.FormatInt(l.t3Bps, 10) +
		";entry:" + strconv.FormatInt(l.postsEntry, 10) +
		";l2:" + strconv.FormatInt(l.postsT2, 10) +
		";l3:" + strconv.FormatInt(l.postsT3(), 10) +
		";inherited:" + inherited
}

// ---- the level ------------------------------------------------------------

// postLevel is what an address may do, 0..3.
//
// The pass floors at 1 and standing may lift above it, so the two doors compose
// rather than compete: buying in does not cap what earning can reach, and
// earning does not refund a pass.
func postLevel(c *Court, who address) int64 {
	l := ladderFor(c)
	sup, sealed := boardSupply(c)
	if !sealed {
		// NOT "level 0 because you have no standing" — the court has no sealed
		// history to quote a threshold against yet. Nobody posts, pass or no
		// pass: a pass cannot be bought either (BuyCommentPass refuses), so
		// honouring one here would be honouring something unobtainable.
		return 0
	}
	var s int64
	if r := lookupStanding(c, who); r != nil {
		s = r.score
	}
	switch {
	case s >= sup*l.t3Bps/10_000:
		return 3
	case s >= sup*l.t2Bps/10_000:
		return 2
	case s >= sup*l.t1Bps/10_000:
		return 1
	}
	if r := lookupStanding(c, who); r != nil && r.passHeld {
		return 1
	}
	return 0
}

// postsPerDayAt is the rate a level buys.
func postsPerDayAt(l ladder, level int64) int64 {
	switch level {
	case 3:
		return l.postsT3()
	case 2:
		return l.postsT2
	case 1:
		return l.postsEntry
	}
	return 0
}

// PostLevel and PostsPerDay are the two figures a client needs to say what an
// address may do, and why.
func PostLevel(courtSlug string, who address) int64 {
	return postLevel(mustCourt(courtSlug), who)
}

func PostsPerDay(courtSlug string, who address) int64 {
	c := mustCourt(courtSlug)
	return postsPerDayAt(ladderFor(c), postLevel(c, who))
}

// ---- the entry pass: the one coin movement in this lane -------------------

// BuyCommentPass burns the caller's own CC once and floors their posting level
// at the entry rung.
//
// THE ONLY COIN MOVEMENT IN THE WHOLE LANE, and it is the poster's own coin, by
// their own act, destroyed. Nothing is escrowed, so no moderator ever holds it
// and no refund path exists to be judged; nothing is transferred, so no
// moderator can be paid for finding spam. That is what keeps
// moderation.gno's claim — a fully captured moderator is harmless to funds —
// true of this lane too.
//
// mustSpendable AND THEN Burn ON THE ADJACENT LINE, deliberately: ARM 7 of
// check-epoch-coherence.py requires a spend guard within three lines above any
// non-escrow-sourced coin movement, and every prose reason belongs above the
// guard rather than between it and the burn.
//
// It is the FIRST path in this realm to burn from a user's balance rather than
// from the escrow. lock.gno's spendable() carries a comment saying nothing does;
// that comment is corrected in the same change, because a stale claim about a
// defence is worse than none.
func BuyCommentPass(cur realm, courtSlug string) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	touch(c)
	if r := lookupStanding(c, who); r != nil && r.passHeld {
		panic("kourtv2: this address already holds a pass in this court")
	}
	price := passPriceFor(c)
	if price <= 0 {
		// Two ways to get here and the message must not pick the wrong one: a
		// court with no sealed epoch cannot quote a price at all, and a court
		// with zero sealed supply has nothing to take a fraction of.
		if _, sealed := boardSupply(c); !sealed {
			panic("kourtv2: this court has not completed a sealed epoch yet; its board is not open")
		}
		panic("kourtv2: this court cannot price a pass yet — it has no supply")
	}
	mustSpendable(c, who, price)
	c.coin.Burn(who, price)
	getStanding(c, who).passHeld = true
	return price
}

// HoldsPass reports whether an address has bought in.
func HoldsPass(courtSlug string, who address) bool {
	r := lookupStanding(mustCourt(courtSlug), who)
	return r != nil && r.passHeld
}

// ---- the throttle ---------------------------------------------------------

// secsPerDay is the refill window. WALL-CLOCK, never height: clock.gno's rule is
// that a deadline a user plans around gates on block time, because a height only
// means a date if the chain's pace never changes — and "eight posts a day" is
// exactly something a user plans around.
const secsPerDay = int64(86_400)

// bucketAt is the WHOLE of the refill arithmetic, and it is one function because
// the alternative was two.
//
// The write path (refill) and the read path (PostsAvailable) need the same
// answer, and the first version of this file computed it twice — once in each.
// Measured: three separate mutations of the write-path copy survived the suite,
// because every assertion read the OTHER copy. That is the defect stakeIdxMine's
// note names in one line — "two copies of that check is how the second one comes
// to disagree with the first" — arrived at from the other direction, where the
// copies agree and the tests are what stop meaning anything.
//
// Pure: no reads, no writes, no clock. Returns what is available now and the
// stamp that goes with it.
//
// THE REMAINDER IS KEPT. The stamp advances by what the granted posts actually
// cost, not to `now`, so a poster who checks every minute is not rounded down to
// nothing forever. Advancing to now would make the effective rate a function of
// how often anyone looked at the page.
//
// The bucket caps at ONE DAY of posts, so being away a week banks a day.
func bucketAt(tokens, lastRefill, rate, now int64) (avail, stamp int64) {
	if rate <= 0 {
		return 0, lastRefill
	}
	if lastRefill == 0 { // first ever post: start full, not empty
		return rate, now
	}
	stamp = lastRefill
	if gain := (now - lastRefill) * rate / secsPerDay; gain > 0 {
		tokens = satAdd(tokens, gain)
		stamp += gain * secsPerDay / rate
	}
	if tokens > rate {
		tokens = rate
	}
	if tokens < 0 {
		tokens = 0
	}
	return tokens, stamp
}

// refill brings a stored bucket up to date. The ONLY writer.
//
// It persists across everything — buying a pass, a slash, a freeze — and a
// purchase never tops it up: the pass buys a rate, and granting a full bucket
// with it would make buy-post-withdraw a way to spend one allowance twice.
func refill(c *Court, who address, r *standingRow) int64 {
	rate := postsPerDayAt(ladderFor(c), postLevel(c, who))
	r.tokens, r.lastRefill = bucketAt(r.tokens, r.lastRefill, rate, nowTime())
	return r.tokens
}

// mustSpendPost takes one post from the bucket or refuses.
//
// The refusal names the LEVEL, because "slow down" is not actionable and "you
// are at level 1, which allows 3 a day" tells a poster both what they have and
// what earning more would buy.
func mustSpendPost(c *Court, who address) {
	lvl := postLevel(c, who)
	if lvl == 0 {
		// The unsealed case is NOT "earn standing or buy a pass": neither is
		// available, and telling someone to buy something they cannot buy is the
		// same defect the frozen standing page had.
		if _, sealed := boardSupply(c); !sealed {
			panic("kourtv2: this court has not completed a sealed epoch yet; its board is not open")
		}
		panic("kourtv2: you cannot post in this court yet — earn standing, or buy an entry pass")
	}
	r := getStanding(c, who)
	if refill(c, who, r) < 1 {
		panic("kourtv2: your posting allowance for now is spent — level " +
			strconv.FormatInt(lvl, 10) + " allows " +
			strconv.FormatInt(postsPerDayAt(ladderFor(c), lvl), 10) + " a day")
	}
	r.tokens--
}

// PostsAvailable is what an address may write right now. A READ, so it must not
// move the bucket — it takes bucketAt's answer and discards the stamp rather
// than reimplementing the arithmetic, which is how the two used to drift.
func PostsAvailable(courtSlug string, who address) int64 {
	c := mustCourt(courtSlug)
	r := lookupStanding(c, who)
	if r == nil {
		return 0
	}
	avail, _ := bucketAt(r.tokens, r.lastRefill, postsPerDayAt(ladderFor(c), postLevel(c, who)), nowTime())
	return avail
}

// ------------------------------------------------------------------ render --

// renderStanding is one address's page: what it has earned, what that buys, and
// what a moderator has taken.
//
// CAPABILITY FACTS, and deliberately not a punishment dossier. MODERATION.md §2
// declined to build an on-chain per-address index of a person's activity, and §6
// forbids moderator copy that makes assertions of fact about a person. So this
// page answers "what may I do, and why" — standing, level, rate, high-water mark
// — and leaves the audit trail of individual acts to the moderation log, which is
// addressed by row id and reachable by purge. A page headed with someone's
// address listing what they were punished for is a claim about the person, in the
// realm's own voice, with no §230 shield.
//
// The only user text here is an address, which still goes through the gate: a
// bare string type carries no length invariant and IsValid() is not an escaping.
func renderStanding(slug, addrArg string) string {
	c := mustCourt(slug)
	who := address(addrArg)
	if !who.IsValid() {
		return "## Not found\nThat is not a valid address."
	}
	l := ladderFor(c)
	sup, sealed := boardSupply(c)
	lvl := postLevel(c, who)

	var b strings.Builder
	b.WriteString("# Standing in " + courtNameFor(c) + "\n\n")
	b.WriteString("`" + sanitize.InlineText(who.String()) + "`\n\n")
	if !sealed {
		// The page renders rather than panicking, and says the true thing: this
		// court has no sealed epoch yet, so there is no threshold to be above or
		// below. It used to abort here with a grc20votes-internal message.
		b.WriteString("This court is too new to have a board. Its thresholds are quoted\n" +
			"against a sealed epoch and it has not completed one yet; comments open\n" +
			"as soon as it has.\n")
		return b.String()
	}

	var score, hw int64
	if r := lookupStanding(c, who); r != nil {
		score, hw = r.score, r.highWater
	}
	// WHAT IS BLOCKING YOU, BEFORE WHAT YOU MAY DO. A frozen address used to
	// read this page as "you cannot comment here YET — buy an entry pass", which
	// invited a purchase that would not work, never mentioned the freeze, and
	// never said the pass they already held had been forfeited by the slash. The
	// freeze reads existed with no caller at all.
	frozenUntil := boardFrozenAt(c, who)
	if frozenUntil != 0 {
		b.WriteString("> **This court's moderators have frozen you out of its boards**\n" +
			"> until block " + strconv.FormatInt(frozenUntil, 10) + ".\n>\n" +
			"> It reaches comments and upvotes and nothing else: you may still stake,\n" +
			"> vote, answer, dispute, flag, open claims, withdraw, draw emission, and\n" +
			"> take every election action. An entry pass will not lift it, and buying\n" +
			"> one now would burn coin for nothing.\n>\n" +
			"> The court's [moderation log](/r/kourt/kourtv2:" + slug +
			"/mod) records who acted and why.\n\n")
	}

	b.WriteString("## What you may do\n\n")
	b.WriteString("- level: **" + strconv.FormatInt(lvl, 10) + "** of 3\n")
	b.WriteString("- comments: **" + strconv.FormatInt(postsPerDayAt(l, lvl), 10) +
		" a day**, " + strconv.FormatInt(PostsAvailable(slug, who), 10) + " available now\n")
	b.WriteString("- per claim: at most " + strconv.Itoa(maxBoardRowsPerAuthor) + " comments\n")
	// TWO DIFFERENT FACTS WITH TWO DIFFERENT REMEDIES, and both are reported.
	// A freeze lifts on its own; a slash does not. Suppressing the slash line
	// while a freeze is live — which an earlier version did — means a thawed user
	// discovers their standing is gone and their pass with it, with nothing on
	// any page having said so.
	if lvl == 0 {
		if hw > score {
			b.WriteString("\nA moderator slash took your standing to zero, and with it the\n" +
				"entry pass if you held one — the burn is not refunded. A successor\n" +
				"set, or the platform, can restore up to the high-water mark below.\n")
		}
		// The INVITATION is what a freeze suppresses: a pass floors the level at
		// 1 and would otherwise work, so offering it to a frozen address invites
		// a purchase that cannot help until the freeze lifts.
		if frozenUntil == 0 {
			if hw > score {
				b.WriteString("You can also earn back from zero, or buy a new pass for " +
					strconv.FormatInt(passPriceFor(c), 10) + ".\n")
			} else {
				b.WriteString("\nYou cannot comment here yet. Earn standing below, or buy an entry\n" +
					"pass for " + strconv.FormatInt(passPriceFor(c), 10) + " (burned, one-off).\n")
			}
		}
	}

	b.WriteString("\n## Standing\n\n")
	b.WriteString("- earned: **" + strconv.FormatInt(score, 10) + "**\n")
	b.WriteString("- high-water mark: " + strconv.FormatInt(hw, 10) +
		" — what a moderator slash can be restored toward\n")
	b.WriteString("- entry pass: " + yesNo(HoldsPass(slug, who)) + "\n")
	// WHERE IT CAME FROM, IN WORDS, AND ONLY WHAT IS THERE. This line used to
	// print StandingBreakdown verbatim — a semicolon-separated WIRE format, on a
	// human page, listing four categories most of which are zero for most
	// addresses. StandingBreakdown stays exactly as it is: it is the qeval read
	// it was written to be, and a client parsing it is the reason it exists.
	writeStandingFrom(&b, c, who)

	b.WriteString("\n## The rungs, in this court\n\n")
	for _, k := range []struct {
		name string
		bps  int64
		rate int64
	}{{"1", l.t1Bps, l.postsEntry}, {"2", l.t2Bps, l.postsT2}, {"3", l.t3Bps, l.postsT3()}} {
		b.WriteString("- level " + k.name + ": " + strconv.FormatInt(sup*k.bps/10_000, 10) +
			" standing (" + strconv.FormatInt(k.bps, 10) + " bps of supply) → " +
			strconv.FormatInt(k.rate, 10) + " a day\n")
	}

	// THE CONSEQUENCE OF A BPS BAR, said once. The rungs above are a share of a
	// sealed supply that only grows, so a score that never moves still crosses
	// back down a rung on its own. §2.3's "standing never decays" is true of the
	// NUMBER and says nothing about the rung, which is what actually gates
	// posting — and a reader who lost a rung with no notice has no other way to
	// learn why.
	b.WriteString("\nEach rung is a **share of this court's supply**, not a fixed " +
		"number, so the bar rises as the court grows. Standing itself is never " +
		"taken except by a logged moderator slash — but a score that does not " +
		"move can still fall below a rung it used to clear.\n")

	b.WriteString("\n## How standing is earned\n\n")
	b.WriteString("Only where the court adjudicated something, and always in proportion\n" +
		"to your own capital that the act committed or destroyed:\n\n")
	b.WriteString("- a quality flag whose slash **settled** — the full bar, two thirds low\n")
	b.WriteString("- **prevailing in a dispute** — an uphold against real opposition, or an overturn\n")
	b.WriteString("- authoring a claim the court rated **HIGH** — seeded claims earn nothing\n")
	b.WriteString("- **winning conviction** on a resolved claim; half where nobody disputed it\n\n")
	b.WriteString("Never earned: commenting, being upvoted, buying CC, or buying the pass.\n")
	b.WriteString("Standing does not decay. A moderator may slash it for abuse; the\n")
	b.WriteString("high-water mark above is what a successor set can restore.\n")

	b.WriteString("\n## The answer record\n\n")
	b.WriteString("- contested-and-upheld answers: **" +
		strconv.FormatInt(int64(AnswerRecord(slug, who)), 10) + "**\n")
	b.WriteString("\n_Adjudicated — moderators cannot change this._\n")
	return b.String()
}

// renderStandingIndex is /<slug>/me with no address: the rules, and nothing
// about anybody.
func renderStandingIndex(slug string) string {
	c := mustCourt(slug)
	l := ladderFor(c)
	var b strings.Builder
	b.WriteString("# Standing in " + courtNameFor(c) + "\n\n")
	b.WriteString("Append an address to see its standing: `" + sanitize.InlineText(slug) +
		"/me/<address>`\n\n")
	b.WriteString("An entry pass costs " + strconv.FormatInt(passPriceFor(c), 10) +
		", burned, once. Standing is earned and cannot be bought.\n\n")
	b.WriteString("- level 1 at " + strconv.FormatInt(l.t1Bps, 10) + " bps of supply → " +
		strconv.FormatInt(l.postsEntry, 10) + " comments a day\n")
	b.WriteString("- level 2 at " + strconv.FormatInt(l.t2Bps, 10) + " bps → " +
		strconv.FormatInt(l.postsT2, 10) + " a day\n")
	b.WriteString("- level 3 at " + strconv.FormatInt(l.t3Bps, 10) + " bps → " +
		strconv.FormatInt(l.postsT3(), 10) + " a day\n")
	return b.String()
}

// writeStandingFrom names the categories an address actually earned in, and says
// nothing at all when there are none — "flag: 0, dispute: 0, author: 0,
// conviction: 0" tells a new participant four things that are not true of them.
func writeStandingFrom(b *strings.Builder, c *Court, who address) {
	r := lookupStanding(c, who)
	if r == nil {
		return
	}
	labels := [standingCatN]string{
		"quality flags whose slash settled",
		"disputes you prevailed in",
		"claims of yours the court rated HIGH",
		"conviction on resolved claims",
	}
	listed := false
	for i := 0; i < standingCatN; i++ {
		if r.from[i] == 0 {
			continue
		}
		if !listed {
			b.WriteString("- from: ")
			listed = true
		} else {
			b.WriteString("; ")
		}
		b.WriteString(strconv.FormatInt(r.from[i], 10) + " from " + labels[i])
	}
	if listed {
		b.WriteString("\n")
	}
}

func yesNo(b bool) string {
	if b {
		return "held"
	}
	return "none"
}
