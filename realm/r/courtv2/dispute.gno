package courtv2

// The dispute machine's governor seam. V2 adopts V1's machine unchanged
// (PLAN §3.1/§3.6): answer bond → 72h → dispute votes with doubling bonds →
// escrow windows → reopens → 3-round close. This file currently carries only
// the Kind and Rules the governor adoption needs; the machine itself lands
// next (OpenDispute/ResolveDispute/Finalize adapted from the audited V1, with
// the v0.11+ dispositions: forfeitures burn, comp mints senior-queued).

import governor "gno.land/p/cryptocourt/governor/v0"

const disputeKindName = "dispute"

type disputeKind struct{}

func (disputeKind) Name() string { return disputeKindName }
func (disputeKind) Describe(payload string) string {
	return "resolve a disputed claim by a token vote (see the court page for the claim)"
}
func (disputeKind) Check(payload string) error { return nil } // the court validates

// Do is unused: the court resolves by reading the tally, never by
// governor.Execute. It exists only to satisfy the Kind seam.
func (disputeKind) Do(_ int, rlm realm, payload string) error { return nil }

// disputeRules mirror V1: ThresholdBps is the overturn bar; the escrow window,
// not the governor timelock, is the reaction period.
func disputeRules(p Params) governor.Rules {
	return governor.NewRules(5000, p.disputeThresholdBps, p.votingBlocks, 1, p.graceBlocks, 0)
}
