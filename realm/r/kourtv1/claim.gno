package kourtv1

import (
	tickbook "gno.land/p/kourt/tickbook/v0"
	twap "gno.land/p/kourt/twap/v0"
	bptree "gno.land/p/nt/bptree/v0"
)

const (
	maxTitle     = 200
	maxBodyChunk = 4000
)

// claimState is a court's record for one claim: its identity and append-only body
// (claim.gno), its market (market.gno), and — as those files land — its answer and
// dispute state. One struct so a claim is one keyed record; the underlying YES/NO
// shares live in the court's shared cshares ledger under the same id.
type claimState struct {
	id        uint64
	title     string
	parent    uint64 // 0 = top-level; a folder-claim's children point at it
	isFolder  bool
	depositor address // who paid the deposit — repaid to THEM, never a sweeper
	deposit   int64

	// body is append-only and chunked: each append is a new object, so it never
	// rewrites what came before (COURTS_STRUCTURE — an immutable title, a growing
	// body).
	body    *bptree.BPTree // be8(seq) -> string
	bodySeq uint64

	// market (market.gno wires these; claim.gno just allocates them)
	book  *tickbook.Book
	price twap.Ring // last-trade price, 0..100, hourly, one week
	oi    twap.Ring // open interest X, for the trailing-average quorum/answerability

	// answer (answer.gno) + dispute (dispute.gno)
	answered       bool
	answer         int8    // posted verdict: outcomeYES or outcomeNO
	answerer       address // who posted it and put up the answer bond
	answerBond     int64   // CC escrowed by the answerer
	answerHeight   int64   // height the answer was posted (undisputed settlement clock)
	preAnswerPrice int64   // grid price (0..100) snapshotted ONCE at the first answer
	preAnswerSet   bool
	failedRounds   int // failed-quorum dispute rounds: bond doubling, 3rd → CloseAt

	// dispute machine (dispute.gno)
	round       int64   // dispute round counter — the unique-payload nonce
	proposalID  int64   // current dispute proposal (0 = none open)
	disputeOpen bool    // an active dispute vote is running
	disputeBond int64   // CC escrowed for the current dispute
	disputer    address // who opened the current dispute
	provisional int8    // provisional verdict after Resolve: outcomeYES/outcomeNO, or -1
	provClose   bool    // provisional is a fractional close (3 failed rounds), not a resolve
	escrowUntil int64   // height the escrow window ends; Finalize is gated on it
	finalized   bool    // the irreversible cshares settlement has run

	// fee accounting (fees.gno). feeKind is set ONCE at the resolution step, with
	// feePool (the CC skimmed from the winning collateral) and winShares (the payout
	// denominator, the winning-share supply frozen there). A claim pays one fee or none.
	feeKind       uint8 // feeNone / feeAdj (disputed→decided) / feeSettle (undisputed)
	feePool       int64 // CC earmarked in escrow for the fee's claimants
	winShares     int64 // winning-share supply S at resolution — RedeemWinning's denominator
	feeProposalID int64 // the DECIDED round whose voters split the adjudication fee (a reopen moves proposalID)
	settleFeePaid bool  // the answerer has pulled the settlement fee
}

// OpenClaim opens a claim in a court. The opener pays the court's never-zero CC
// deposit into escrow (recorded against them for later repayment) and must hold
// the CC to do so — which is the point: a claim costs something to make. Returns
// the new claim id.
func OpenClaim(cur realm, courtSlug, title string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	mustTitle(title)

	// The deposit: CC from the opener into the court's escrow. Transfer panics if
	// the opener lacks the balance, so holding CC (bought on the curve) is required.
	c.coin.Transfer(who, c.escrow, c.params.minClaimDepositCC)

	cid := c.shares.OpenClaim()
	cs := &claimState{
		id:          cid,
		title:       title,
		depositor:   who,
		deposit:     c.params.minClaimDepositCC,
		body:        bptree.NewBPTree32(),
		book:        tickbook.NewBook(),
		price:       twap.New(epochBlocks, twapBuckets, 1),
		oi:          twap.New(epochBlocks, twapBuckets, 8),
		provisional: -1, // no verdict yet
	}
	c.claims.Set(be8(cid), cs)
	return cid
}

// twapBuckets is a week of hourly buckets — the window the tokenomics measured the
// trailing average and flash-resistance at.
const twapBuckets = 168

// AppendBody adds a chunk to a claim's body. Only the opener may append (the body
// is their evidence to build); the title never changes. Each chunk is its own
// object, so an append never rewrites the earlier body.
func AppendBody(cur realm, courtSlug string, claimID uint64, chunk string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if who != cs.depositor {
		panic("court: only the claim's author may append to its body")
	}
	if len(chunk) == 0 || len(chunk) > maxBodyChunk {
		panic("court: a body chunk is 1..4000 bytes")
	}
	cs.bodySeq++
	cs.body.Set(be8(cs.bodySeq), chunk)
}

// ------------------------------------------------------------------ reads --

// ClaimCount is how many claims a court has opened. ClaimTitle and ClaimDepositor
// are per-claim facts. ClaimBody concatenates the append-only chunks in order.
func ClaimCount(courtSlug string) uint64 { return mustCourt(courtSlug).shares.Count() }

func ClaimTitle(courtSlug string, claimID uint64) string {
	return mustClaim(mustCourt(courtSlug), claimID).title
}

func ClaimDepositor(courtSlug string, claimID uint64) address {
	return mustClaim(mustCourt(courtSlug), claimID).depositor
}

func ClaimBody(courtSlug string, claimID uint64) string {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	out := ""
	cs.body.Iterate("", "", func(_ string, v any) bool {
		out += v.(string)
		return false
	})
	return out
}

// ClaimSupply is the claim's open interest X — outstanding YES/NO sets, the number
// the quorum floor and answerability key off.
func ClaimSupply(courtSlug string, claimID uint64) int64 {
	return mustCourt(courtSlug).shares.Supply(claimID)
}

// ----------------------------------------------------------------- innards --

func mustClaim(c *Court, id uint64) *claimState {
	v := c.claims.Get(be8(id))
	if v == nil {
		panic("court: no such claim")
	}
	return v.(*claimState)
}

func mustTitle(title string) {
	if len(title) == 0 || len(title) > maxTitle {
		panic("court: a title is 1..200 bytes")
	}
}

// be8 is a big-endian, fixed-width, order-preserving key for a claim id.
func be8(u uint64) string {
	var b [8]byte
	for i := 7; i >= 0; i-- {
		b[i] = byte(u & 0xff)
		u >>= 8
	}
	return string(b[:])
}
