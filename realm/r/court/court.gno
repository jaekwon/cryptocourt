// Package court is cryptocourt: a directory of prediction-market "courts", each
// its own coin, governor, bonding curve, and set of claims. It is the one worked
// consumer of the audited /p/ primitives (grc20votes, governor, curve, cshares,
// tickbook, twap); every court-specific rule — the one-way curve, bonds, the
// dispute/escrow/reopen machine, fees, the directory — lives here.
//
// This file is the backbone: the Court and Params types, the directory, and the
// crossing entrypoint that creates a court. The mechanics are in sibling files
// (buy, claim, market, answer, dispute, session, directory, render).
//
// See docs/COURT_REALM_PLAN.md for the converged design and docs/AUDIT.md for the
// obligations this realm must honor (twap freshness, tickbook minimum order,
// ThresholdBps>5000, no returned /p/ interior pointers). The escrow-dust sweep is a
// deferred tidiness nicety, not a safety must — floored dust only ever accrues in the
// over-funded escrow (deflationary, never insolvent).
package court

import (
	cshares "gno.land/p/cryptocourt/cshares/v0"
	curve "gno.land/p/cryptocourt/curve/v0"
	governor "gno.land/p/cryptocourt/governor/v0"
	grc20votes "gno.land/p/cryptocourt/grc20votes/v0"
	bptree "gno.land/p/nt/bptree/v0"
)

const errStaleRealm = "court: stale realm; call through a crossing function"

// coinDecimals and epochBlocks fix every court's coin shape. Six decimals matches
// the audited MaxSupply ceiling; 720 blocks is an hour at gno's five-second cadence
// (the figure twap and the tokenomics were measured at).
const (
	coinDecimals = 6
	epochBlocks  = int64(720)
	// curveCap is the position ceiling; the curve keeps cap² inside 128 bits and it
	// stays under grc20votes' own MaxSupply so a tally can never overflow.
	curveCap = int64(9223372036854775807) / grc20votes.Bps
)

// Court is one court instance. Every field is unexported and no method returns a
// /p/ pointer (borrow rule #2): a *Ledger/*Governor/*Book handed out would run a
// mutator under this realm's authority. Reads return values.
type Court struct {
	id    string
	name  string
	tier  uint8
	// admin is the court's creator, recorded at StartCourt but currently unused: there is
	// deliberately NO param-retune entrypoint, and that immutability is what keeps the
	// overflow bounds sound (Params are frozen at mustSane-clamped defaults).
	admin address

	coin   *grc20votes.Ledger // the court coin (CC); the curve is its only mint
	gov    *governor.Governor // the supreme-court arbiter; electorate = coin
	crv    curve.Curve        // the one-way bonding curve (GNOT -> CC)
	shares *cshares.Ledger    // conditional shares, one binary claim per court claim

	// escrow is where escrowed collateral CC sits; it never votes, so the quorum
	// floor nets it out (votable = PastTotal − PastVotes(escrow)). Per court, but
	// each court's own coin ledger already isolates the balance.
	escrow address

	minted   int64 // MONOTONIC curve position; burns/redeems never lower it
	treasury int64 // GNOT taken in by the curve (bookkeeping; unspendable in V1)
	oi       int64 // court-wide open interest in CC (Σ sets × priceScale); ≤ 20% of supply

	claims    *bptree.BPTree // be8(claimID) -> *claimState (claim.gno)
	feeClaims *bptree.BPTree // be8(claimID)+voter -> true: the adjudication-fee double-claim guard
	params    Params
}

// Params are the governance-set knobs, each clamped to a hard bound the realm
// enforces so a captured governance can bend but not break the court (§9a). All
// basis points are of grc20votes.Bps (10000).
type Params struct {
	disputeThresholdBps int64 // overturn threshold; hard floor 5001 (a tie must fail)
	votingBlocks        int64 // dispute vote length
	graceBlocks         int64 // modest, so a won proposal's slot frees via Sweep
	floorSupplyBps      int64 // the 5%-of-supply quorum floor term
	oiCeilingBps        int64 // court-wide open-interest ceiling (2000 = 20%)

	minAnswerX       int64 // min trailing open interest X̄ (CC) before a claim is answerable
	answerBondCapCC  int64 // cap on min(50%X, cap)
	disputeBondMinCC int64 // floor on max(gov-min, 20%X)
	adjFeeBps        int64 // adjudication fee, of X (300 = 3%)
	adjFeeCapGNOT    int64 // and its GNOT cap (200 GNOT)
	settleFeeBps     int64 // settlement fee, undisputed path only (100 = 1%)

	minClaimDepositCC int64 // NEVER zero
	minOrderShares    int64 // tickbook minimum order, so ≤1-share dust is negligible

	escrowMinBlocks int64 // 1 week
	escrowMaxBlocks int64 // 3 weeks
}

// defaultParams are the V4 tokenomics figures; StartCourt clamps them and any
// later retune to the hard bounds below.
func defaultParams() Params {
	return Params{
		disputeThresholdBps: 5001,
		votingBlocks:        120960, // 7 days
		graceBlocks:         17280,  // 1 day
		floorSupplyBps:      500,    // 5%
		oiCeilingBps:        2000,   // 20%
		minAnswerX:          10_000, // 100 sets' worth of CC (100 * priceScale)
		answerBondCapCC:     0,      // 0 = no extra cap beyond 50%X (governance may raise)
		disputeBondMinCC:    1_000_000,
		adjFeeBps:           300,
		adjFeeCapGNOT:       200_000_000, // 200 GNOT at 6 decimals
		settleFeeBps:        100,
		minClaimDepositCC:   1_000_000,
		minOrderShares:      1_000,
		escrowMinBlocks:     120960, // 1 week
		escrowMaxBlocks:     362880, // 3 weeks
	}
}

// mustSane clamps a Params to the realm's hard bounds and panics on a value no
// bound can rescue (a zero min deposit, a sub-5001 overturn threshold) — the two
// the tokenomics is most emphatic about.
func (p Params) mustSane() Params {
	if p.disputeThresholdBps < 5001 || p.disputeThresholdBps > grc20votes.Bps {
		panic("court: overturn threshold must be in [5001, 10000]")
	}
	if p.minClaimDepositCC < 1 {
		panic("court: the claim deposit must never be zero")
	}
	if p.minOrderShares < 1 {
		panic("court: the minimum order must be positive")
	}
	if p.oiCeilingBps < 1 || p.oiCeilingBps > grc20votes.Bps {
		panic("court: the OI ceiling must be a fraction of supply")
	}
	if p.floorSupplyBps < 0 || p.floorSupplyBps > grc20votes.Bps {
		panic("court: the supply floor must be in [0, 10000]")
	}
	if p.escrowMinBlocks < 1 || p.escrowMaxBlocks < p.escrowMinBlocks {
		panic("court: the escrow window is malformed")
	}
	if p.votingBlocks < 1 || p.graceBlocks < 1 {
		panic("court: voting and grace must be positive")
	}
	// Fees skim from winners; bound them so a captured governance can bend but not
	// break the court — at most a tenth of a resolved claim, never a standing skim.
	if p.adjFeeBps < 0 || p.adjFeeBps > 1000 {
		panic("court: adjFeeBps out of [0, 1000]")
	}
	if p.settleFeeBps < 0 || p.settleFeeBps > 1000 {
		panic("court: settleFeeBps out of [0, 1000]")
	}
	if p.adjFeeCapGNOT < 0 {
		panic("court: adjFeeCapGNOT must be non-negative")
	}
	return p
}

// -------------------------------------------------------------- directory --

// courts is the realm's directory: every court, keyed by its slug. A package var
// because a realm is stateful; unexported because the *Court it holds carries the
// realm's authority and must never leave.
var courts = bptree.NewBPTree32()

// StartCourt creates a court with its own coin, governor, curve, and share ledger,
// and returns its id (the slug). The creator becomes its admin. Anyone may open a
// court; the directory's tiers (directory.gno) are what surface the good ones.
//
// The GNOT creation deposit and its IsUserCall/OriginSend guard live in the buy/
// directory path; this constructor is the pure wiring.
func StartCourt(cur realm, slug, name string) string {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	mustSlug(slug)
	if courts.Has(slug) {
		panic("court: that slug is taken")
	}
	admin := cur.Previous().Address()

	coin := grc20votes.NewLedger(name, "COURT", coinDecimals, epochBlocks)
	c := &Court{
		id:        slug,
		name:      name,
		tier:      tierListed, // a new court is listed; the directory admin may promote or hide it
		admin:     admin,
		coin:      coin,
		gov:       governor.New(coin, coin),
		crv:       curve.New(curveDenom, curveCap),
		shares:    cshares.NewLedger(name, 2),
		escrow:    cur.Address(), // the realm's own address; each coin ledger isolates it
		claims:    bptree.NewBPTree32(),
		feeClaims: bptree.NewBPTree32(),
		params:    defaultParams().mustSane(),
	}
	// Adopt the dispute kind into this court's own governor (dispute.gno).
	c.gov.Adopt(disputeKind{}, disputeRules(c.params))
	courts.Set(slug, c)
	// The first court's creator becomes the directory curator (directory.gno).
	if directoryAdmin == "" {
		directoryAdmin = admin
	}
	return slug
}

// curveDenom is the reciprocal slope shared by every court's curve: a gentle rise
// that prices the marginal coin near a whole GNOT once a court holds ~a million
// coins. A per-court denom is a later refinement.
const curveDenom = int64(1_000_000_000)

// ------------------------------------------------------------------ reads --

// CourtCount is how many courts have been started.
func CourtCount() int { return courts.Size() }

// Exists reports whether a slug names a court.
func Exists(slug string) bool { return courts.Has(slug) }

// mustCourt fetches a court or panics — the internal accessor every entrypoint
// funnels through. Never exported: the *Court must not leave the realm.
func mustCourt(slug string) *Court {
	v := courts.Get(slug)
	if v == nil {
		panic("court: no such court")
	}
	return v.(*Court)
}

// CourtName, CoinSupply, Treasury, OpenInterest, and Backing are value reads a
// page or a client needs. Backing is treasury per circulating coin, which a burn
// correctly raises.
func CourtName(slug string) string   { return mustCourt(slug).name }
func CoinSupply(slug string) int64   { return mustCourt(slug).coin.TotalSupply() }
func Treasury(slug string) int64     { return mustCourt(slug).treasury }
func OpenInterest(slug string) int64 { return mustCourt(slug).oi }

// CourtEscrow is the address that holds a court's escrow — collateral, bonds, and
// fees in CC, and the treasury in GNOT. It is the realm's own address (every court
// shares it; each court's coin ledger isolates its balances). A client uses it to
// audit the on-chain coin invariant against the bank balances.
func CourtEscrow(slug string) address { return mustCourt(slug).escrow }

// mustSlug refuses a slug that is empty, too long (a key bound), or contains a
// character a path or a render could not carry safely. The charset is URL- and
// markdown-safe by construction — lowercase letters, digits, and hyphen — so a slug
// never needs escaping when it reaches a path segment or a rendered link.
func mustSlug(slug string) {
	if len(slug) == 0 || len(slug) > 64 {
		panic("court: a slug is 1..64 characters")
	}
	for i := 0; i < len(slug); i++ {
		ch := slug[i]
		ok := (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-'
		if !ok {
			panic("court: a slug is lowercase letters, digits, and hyphens only")
		}
	}
}
