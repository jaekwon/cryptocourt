package kourtv2

// THE ONE VOTE-WEIGHT EXPRESSION IN THIS REALM.
//
//	w = min( PastVotes(who, the question's own frozen epoch), BalanceOf(who) )
//
// The snapshot is the CEILING: you cannot buy in after the question was asked. The
// live balance is the FLOOR: you cannot vote weight you have handed back. Neither
// half works alone — two earlier designs each kept one and failed, one to a rental
// and one to a live numerator against a frozen bar. VOTEFLOOR.md has the history.
//
// WHY IT IS A FUNCTION AND NOT THREE INLINE COPIES. Three lanes charge this weight
// and a reader QUOTES it to the elector, and a quote that can drift from the charge
// is worse than no quote at all — the holder plans against a number the vote will
// not honour. One expression, six call sites — the quality lane, the election lane,
// both readers, the explainer, and the verdict lane through voteCap — and
// check-epoch-coherence arm 4 pins that there is exactly one definition of it.
//
// BalanceOf, never spendable(). Staked coin is still in the holder's balance and
// still votes; spendable() nets the stake out, so using it here would disenfranchise
// every staker in the court — the court-wide disenfranchisement v0.34 deleted, and
// the single most-repeated mistake in this design's history.
//
// COHERENT BY CONSTRUCTION, because a floor can only LOWER a figure that was
// already coherent:
//
//	Σ min(PastVotes(·,E), BalanceOf(·))  ≤  Σ PastVotes(·,E)  =  PastTotal(E)
//
// so every tally stays under the bar it is measured against, provided the bar is
// drawn at the same E. That last identity is the ledger's own and is asserted
// directly by TestPastVotesSumToPastTotal.
//
// Returns BOTH figures because the two zero cases mean different things to a
// holder — "you had nothing when this was asked" and "you no longer hold what you
// had" are different problems with different remedies — and a single return value
// would have collapsed them into one message.
func votingWeight(c *Court, who address, at uint32) (w, snapshot int64) {
	snapshot = c.coin.PastVotes(who, at)
	w = snapshot
	if held := c.coin.BalanceOf(who); held < w {
		w = held
	}
	if w < 0 {
		w = 0
	}
	return w, snapshot
}

// voteCap is the ceiling the DISPUTE lane hands the governor, and it lives here so
// that every live balance read in this realm is in one file.
//
// That lane cannot use votingWeight: the governor owns the verdict tally and
// derives the snapshot itself, so what it must be given is a CEILING it can lower
// to — never a finished weight. An earlier attempt handed it a weight, which is not
// drawn from p.total, so `cast` could exceed it, `rest := p.total - cast` went
// negative, and `no` dropped out of the early-decide test entirely. The two are the
// same number by construction (the governor computes min(PastVotes(who, p.epoch),
// cap) and votingWeight computes min(PastVotes(who, at), BalanceOf(who)) for the
// same epoch), which is what lets ClaimVoteWeightOf quote the verdict lane honestly
// without duplicating the expression — and TestTheQuoteMatchesTheCharge pins it.
func voteCap(c *Court, who address) int64 { return c.coin.BalanceOf(who) }

// ClaimVoteWeightOf quotes what `who` can actually cast on a claim's two open
// questions, right now: the verdict (weighed at the dispute round's own epoch) and
// the quality tally (weighed at the answer's). Zero means either no snapshot or
// nothing still held — VoteWeightWhy says which.
//
// Quoted because a holder refused at the door deserves the number, and because
// "how much am I worth here" is not derivable from a balance: the answer depends on
// an epoch the holder cannot see and on which questions happen to be open.
func ClaimVoteWeightOf(courtSlug string, who address, claimID uint64) (verdict, quality int64) {
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	if cs.disputeOpen {
		verdict, _ = votingWeight(c, who, c.gov.EpochOf(cs.proposalID))
	}
	if qualityQuestionOpen(cs) {
		quality, _ = votingWeight(c, who, cs.qualityEpoch)
	}
	return verdict, quality
}

// ElectionVoteWeightOf quotes what `who` can cast in the open election, and it is
// the frozen figure once they have approved anything: the first approval fixes a
// voter's weight for the whole ballot, so a later quote must report what was
// frozen and not what a fresh derivation would give.
func ElectionVoteWeightOf(courtSlug string, who address) int64 {
	c := mustCourt(courtSlug)
	if c.mod == nil || c.mod.election == nil || c.mod.election.resolved {
		return 0
	}
	e := c.mod.election
	if prior := e.voters.Get(who.String()); prior != nil {
		return prior.(int64)
	}
	w, _ := votingWeight(c, who, e.epoch)
	return w
}

// VoteWeightWhy explains a zero, which is the only part of this a holder cannot work
// out for themselves — ONE ANSWER PER LANE, mirroring ClaimVoteWeightOf.
//
// The first version returned a single string and picked the dispute's epoch whenever
// a dispute was open. That was wrong in a reachable state, and measured: with a
// dispute open BOTH questions are live (VoteQuality accepts votes while
// cs.disputeOpen) at DIFFERENT epochs — the verdict at the proposal's, the quality
// ride at the answer's. A holder who bought after the answer but before the dispute
// opened has a 0 quality snapshot and a positive verdict one, and the single-string
// version told them "weighed at the full snapshot" while VoteQuality was about to
// refuse them outright. Measured at quality 0 against verdict 10 B.
//
// Two lanes, two epochs, two answers. Returning a pair makes that structural instead
// of something a reader has to remember, and it matches the shape of the figures in
// ClaimVoteWeightOf so the two readers cannot drift apart in what they cover.
func VoteWeightWhy(courtSlug string, who address, claimID uint64) (verdict, quality string) {
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	verdict = "no verdict vote is open on this claim"
	if cs.disputeOpen {
		verdict = whyWeighed(c, who, c.gov.EpochOf(cs.proposalID))
	}
	quality = "no quality vote is open on this claim"
	if qualityQuestionOpen(cs) {
		quality = whyWeighed(c, who, cs.qualityEpoch)
	}
	return verdict, quality
}

// whyWeighed is the explanation for ONE epoch. Split out so the two lanes cannot
// share an answer by accident, which is exactly how the first version went wrong.
func whyWeighed(c *Court, who address, at uint32) string {
	w, snapshot := votingWeight(c, who, at)
	switch {
	case snapshot <= 0:
		return "you held no coin at the epoch this question was frozen at, so " +
			"there is nothing to weigh; coin bought since counts in later questions"
	case w <= 0:
		return "you held coin when this question was asked but hold none now, and " +
			"weight is the lesser of the two"
	case w < snapshot:
		return "capped at what you still hold, which is less than you held when " +
			"this question was asked"
	}
	return "weighed at the full snapshot"
}
