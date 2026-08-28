// Answer records: the non-transferable, difficulty-weighted credential (PLAN
// §3.8, pin P13). Only a CONTESTED-AND-UPHELD answer earns a point — an
// undisputed stand earns nothing (raw counting would reward cherry-picking
// trivially-true claims, the mill's habitat — A18); an overturn RESETS the
// record to zero (lying spends the whole credential). A record of
// priorityNetRecord+ earns the 24h priority window on the answer slot, gated
// off court-wide until priorityColdStartN addresses qualify (no launch-wide
// latency tax), and limited to ONE active priority claim per address at a time
// (no flywheel blanketing).

package kourtv2

// answerRecord is one address's standing in one court.
type answerRecord struct {
	score          int    // contested-and-upheld count; reset to 0 on overturn
	activePriority uint64 // claim currently held via the priority window (0 = none)
}

// creditUpheld is called by the dispute machine when a contested answer is
// UPHELD by a decided vote (never on undisputed settles — P13).
func creditUpheld(c *Court, who address) {
	r := getRecord(c, who)
	wasQualified := r.score >= priorityNetRecord
	r.score++
	if !wasQualified && r.score >= priorityNetRecord {
		c.qualifiedCount++
	}
}

// resetOverturned is called when an answer is overturned: the credential burns
// entirely — the record prices a CAREER of honesty, the bond priced the lie.
func resetOverturned(c *Court, who address) {
	r := getRecord(c, who)
	if r.score >= priorityNetRecord {
		c.qualifiedCount--
	}
	r.score = 0
}

// priorityGateActive: the 24h window binds only once the court has real
// qualified answerers (cold-start guard, R5e).
func priorityGateActive(c *Court) bool { return c.qualifiedCount >= priorityColdStartN }

// mayAnswerInPriority: qualified, and not already holding a priority claim.
func mayAnswerInPriority(c *Court, who address) bool {
	r := getRecord(c, who)
	return r.score >= priorityNetRecord && r.activePriority == 0
}

// holdPriority / releasePriority bracket the one-active rule (P13): held from
// the priority answer until that claim finalizes.
func holdPriority(c *Court, who address, claimID uint64) {
	getRecord(c, who).activePriority = claimID
}

func releasePriority(c *Court, who address, claimID uint64) {
	r := getRecord(c, who)
	if r.activePriority == claimID {
		r.activePriority = 0
	}
}

func getRecord(c *Court, who address) *answerRecord {
	if v := c.records.Get(string(who)); v != nil {
		return v.(*answerRecord)
	}
	r := &answerRecord{}
	c.records.Set(string(who), r)
	return r
}

// ------------------------------------------------------------------ reads --

// AnswerRecord is an address's difficulty-weighted score in a court.
func AnswerRecord(courtSlug string, who address) int {
	c := mustCourt(courtSlug)
	if v := c.records.Get(string(who)); v != nil {
		return v.(*answerRecord).score
	}
	return 0
}

// PriorityGateActive reports whether the 24h priority window currently binds.
func PriorityGateActive(courtSlug string) bool {
	return priorityGateActive(mustCourt(courtSlug))
}
