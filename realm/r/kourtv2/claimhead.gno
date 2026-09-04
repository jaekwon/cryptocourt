// Package-local: the claim page's whole read, in one query.
//
// A SEPARATE FILE BECAUSE OF WHERE IT MAY LOOK. claim.gno moves coin, and this
// realm forbids a money file from reading the comment board — check-nontransferable
// enforces it, and caught this function there: "money WRITES to the standing
// ledger through the four credit hooks and reads nothing back, which is what
// keeps a settlement independent of a claim's comment section". ClaimHead reads
// the board because a claim PAGE shows the board, and it settles nothing. Here
// it can, and the guard stays true of the file that handles the money.
package kourtv2

import (
	"strconv"
	"strings"
)

// ClaimHead answers, in ONE query, every NUMBER, FLAG and ADDRESS a claim page
// needs. Tab-separated, in the fixed order listed below:
//
//	yes  no  convYes  convNo  trailOI  oiMature  trailYes  yesMature
//	answered  disputeOpen  settled  provClose  provisional  closed
//	answer  answerBond  settleAt  answerer  answerRecord
//	round  disputeBondNext  escrowUntil  quorumFloor  voteCloses
//	verdict  route  rewardsOpened  drawW  drawA  drawAns  drawCarrot
//	author  hidden  redacted  purged  seeded  stakeOpenDelay
//	boardSize  boardOpen
//
// WHY IT EXISTS. A qeval costs the same whatever it returns: measured against a
// live node, reading one field takes 270ms, reading eighty-eight across eleven
// claims takes 310ms. The price is the realm being loaded into the VM before the
// question is even read — the same ~20M gas floor a one-field WRITE pays. So a
// claim page asking fifty-three questions paid that toll fifty-three times, and
// no amount of parallelism, HTTP/2 or caching could touch it. This is the fix
// that can: ask once.
//
// EVERY FIELD IS THE EXISTING READER'S OWN ANSWER. This function calls them
// rather than reaching into claimState, so it cannot drift from the reads it
// replaces — the single readers stay, an older overlay keeps working, and
// claimhead_test compares the two field by field. Once the realm is loaded the
// calls are AVL lookups, which is why thirty-eight of them cost what one does.
//
// NO FREE TEXT. Title, body, media, the timeline and the association lists keep
// their own reads: a title may contain a tab, a body contains newlines, and a
// delimited record that can be broken by a caption is worse than a second query.
// Fields that do not apply are still present and zero, so the record always has
// the same number of columns and a reader can index it.
func ClaimHead(courtSlug string, claimID uint64, window int64) string {
	c := mustCourt(courtSlug)
	mustClaim(c, claimID) // refuse a claim this court does not have, as the single reads do

	b := strings.Builder{}
	n := func(v int64) { b.WriteString(strconv.FormatInt(v, 10) + "\t") }
	i := func(v int) { b.WriteString(strconv.Itoa(v) + "\t") }
	f := func(v bool) { b.WriteString(boolDigit(v) + "\t") }
	t := func(v string) { b.WriteString(v + "\t") }

	yes, no := StakePools(courtSlug, claimID)
	cy, cn := PoolConviction(courtSlug, claimID)
	oi, oiM := TrailingOI(courtSlug, claimID, window)
	ty, tyM := TrailingYes(courtSlug, claimID, window)
	n(yes)
	n(no)
	n(cy)
	n(cn)
	n(oi)
	f(oiM)
	n(ty)
	f(tyM)

	answered := HasAnswer(courtSlug, claimID)
	settled := Settled(courtSlug, claimID)
	disputeOpen := DisputeOpen(courtSlug, claimID)
	provClose := ProvClose(courtSlug, claimID)
	f(answered)
	f(disputeOpen)
	f(settled)
	f(provClose)
	i(Provisional(courtSlug, claimID))
	f(ClaimClosed(courtSlug, claimID))

	// The answer block is zero on a claim nobody has answered, rather than absent:
	// a record whose width depends on its content is a record a client has to
	// parse twice.
	if answered {
		who := Answerer(courtSlug, claimID)
		i(AnswerVerdict(courtSlug, claimID))
		n(AnswerBond(courtSlug, claimID))
		n(SettleDeadline(courtSlug, claimID))
		t(who.String())
		i(AnswerRecord(courtSlug, who))
	} else {
		i(-1)
		n(0)
		n(0)
		t("")
		i(0)
	}

	// The dispute block applies while an answer stands unsettled — the same gate
	// the overlay used when it asked for these one at a time.
	if answered && !settled {
		n(FailedRounds(courtSlug, claimID))
		n(DisputeBondNext(courtSlug, claimID))
		n(EscrowUntil(courtSlug, claimID))
		if disputeOpen {
			n(QuorumFloorOf(courtSlug, claimID))
			n(DisputeVoteCloses(courtSlug, claimID))
		} else {
			n(0)
			n(0)
		}
	} else {
		n(0)
		n(0)
		n(0)
		n(0)
		n(0)
	}

	if settled && !provClose {
		i(Verdict(courtSlug, claimID))
		t(VerdictRoute(courtSlug, claimID))
	} else {
		i(-1)
		t("")
	}

	cryst := RewardsOpened(courtSlug, claimID)
	f(cryst)
	if cryst {
		w, au, an, ca := DrawSlices(courtSlug, claimID)
		n(w)
		n(au)
		n(an)
		n(ca)
	} else {
		n(0)
		n(0)
		n(0)
		n(0)
	}

	t(ClaimAuthor(courtSlug, claimID).String())
	f(HiddenFromListing(courtSlug, claimID))
	f(TextRedacted(courtSlug, claimID))
	f(ClaimPurged(courtSlug, claimID))
	f(ClaimSeeded(courtSlug, claimID))
	n(CourtStakeOpenDelay(courtSlug))
	i(BoardSize(courtSlug, claimID))
	f(BoardOpen(courtSlug, claimID))

	return strings.TrimSuffix(b.String(), "\t")
}

// claimHeadFields is how many columns ClaimHead answers with. Stated here so the
// realm's own test and the overlay's parser can both refuse a record of the
// wrong width rather than reading a shifted one.
const claimHeadFields = 39
