package govern

import (
	governor "gno.land/p/kourt/governor/v0"
)

// The engine, and the entrypoints that authenticate for it.
//
// Everything about proposals — the kind registry, the tally, the rules, the
// slot sweep, the pages — is p/kourt/governor/v0. What is left here is
// what only a realm can do: hold a `cur realm`, check that it is live, read who
// is calling, and mint the sub-realm token a kind is handed.
//
// Each entrypoint is the same three lines, and that is the point. A reader
// checking whether this realm authenticates every door can do it by looking,
// because there is nothing else in the way.

// Kind and Rules are the engine's, re-exported so a realm publishing a power
// can name them without importing the package twice. Aliases rather than
// wrappers: a wrapper would be a second type that has to be converted at the
// boundary, and the conversion is where a mismatch would hide.
type (
	Kind  = governor.Kind
	Rules = governor.Rules
)

// NewRules and TextOnly are the engine's too. Kept exported here because a
// realm writing a Kind reaches for them and should not have to know that the
// governor moved.
func NewRules(quorumBps, thresholdBps, votingBlocks, delayBlocks, graceBlocks, proposeBps int64) Rules {
	return governor.NewRules(quorumBps, thresholdBps, votingBlocks, delayBlocks, graceBlocks, proposeBps)
}

func TextOnly(s string) error { return governor.TextOnly(s) }

// init registers the powers that are this realm's rather than the engine's.
//
// The mint is the only one. Who may create supply is a policy about a caller,
// so a pure package cannot hold it — see minter.gno — and InstallBuiltin is how
// a realm puts its own power under the reserved prefix that Offer refuses.
func init() {
	engine.InstallBuiltin(minterKind{}, governor.BootstrapRules())
}

// minterNote is this realm's own line on the front page, under the token and
// above the governance.
//
// Who may mint is the realm's fact rather than the engine's — the engine holds
// no minter and could not print one — and it is the strongest promise this
// realm makes, so it cannot be left to inference.
//
// Composed at render time rather than stored. The mint moves by vote, and a
// note written once at init would still name whoever held it then: a cached
// answer to a question whose answer changes is a page that lies.
func minterNote() string {
	if minter == "" {
		// Said loudly rather than omitted. That nobody can mint is not
		// something a reader can conclude from silence.
		return "- **the supply is fixed** — nobody can mint\n"
	}
	return "- minter: " + minter.String() + "\n"
}

// engine is this realm's governor. Unexported and never handed out: whoever
// holds it can adopt a kind without a vote, so publishing it would publish
// governance itself.
var engine = governor.New(ledger, ledger)

// errStaleRealm is what every entrypoint refuses before it reads an identity.
//
// Each derives its caller from cur.Previous(), and a realm value that is not
// the live one designates somebody the caller did not choose. No exploit is
// known — cross() is IsCurrent-strict, and a cross-realm non-crossing call of a
// crossing function is rejected — so this is the house rule and defence in
// depth rather than a live hole. It is one line each, and the alternative is
// arguing about reachability every time the VM changes.
const errStaleRealm = "govern: that realm value is not live; pass your own cur"

// dispatch is how a kind is run, and the only thing here the engine could not
// do for itself.
//
// The kind gets a SUB-REALM, never this realm's own capability. A live cur
// inside a foreign kind's Do has IsCurrent() true and this realm's PkgPath, so
// it is not "the realm as data", it is this realm's authority handed to code
// the holders adopted for one purpose. With it a kind could cross() into any
// realm that trusts this one and be seen as it, issue this realm's tokens, and
// drain its banker.
//
// cur.Sub gives a distinct pkgpath and a distinct address, and the VM refuses
// RealmIssue for a sub-realm outright. The sub-path is the engine's to choose,
// so a kind cannot pick its own identity.
func dispatch(cur realm) governor.Dispatch {
	return func(k Kind, subpath, payload string) error {
		return k.Do(0, cur.Sub(subpath), payload)
	}
}

// ------------------------------------------------------------- entrypoints --

// Offer publishes a kind. It grants nothing: the holders adopt it by vote.
func Offer(cur realm, k Kind, r Rules) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	engine.Offer(cur.Previous().Address(), k, r)
}

// Propose asks a question under an adopted kind.
func Propose(cur realm, kind, payload, title string) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	return engine.Propose(cur.Previous().Address(), kind, payload, title)
}

// Vote casts the caller's weight, as of the proposal's sealed epoch.
func Vote(cur realm, id int64, choice string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	engine.Vote(cur.Previous().Address(), id, choice)
}

// VoteWithReason is the same vote, with a note on the record. The reason rides
// on the event; the realm stores none of it.
func VoteWithReason(cur realm, id int64, choice, reason string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	engine.VoteWithReason(cur.Previous().Address(), id, choice, reason)
}

// Cancel withdraws a proposal. The proposer's, and only while it is open.
func Cancel(cur realm, id int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	engine.Cancel(cur.Previous().Address(), id)
}

// Settle writes down a conclusion the rules already reached, and frees the slot
// if the proposal is finished. Permissionless, and the freed deposit goes to
// whoever calls.
func Settle(cur realm, id int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	engine.Settle(cur.Previous().Address(), id)
}

// Execute runs a decided proposal after its delay. Permissionless: after the
// vote and the timelock there is nothing left to decide.
func Execute(cur realm, id int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	engine.Execute(cur.Previous().Address(), id, dispatch(cur))
}

// ReleaseRoll drops a finished proposal's voter roll and refunds its deposit to
// whoever calls.
func ReleaseRoll(cur realm, id int64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	engine.ReleaseRoll(cur.Previous().Address(), id)
}

// -------------------------------------------------------------- the reads --
//
// No `cur`, because none of these needs a caller. Forwarded rather than
// re-derived, so what a page says and what a query answers cannot drift.

func State(id int64) string       { return engine.State(id) }
func StoredState(id int64) string { return engine.StoredState(id) }
func Describe(id int64) string             { return engine.Describe(id) }
func Preview(kind, payload string) string  { return engine.Preview(kind, payload) }
func Render(path string) string { return engine.Render(path, minterNote()) }
func HasVoted(id int64, who address) bool  { return engine.HasVoted(id, who) }

func Tally(id int64) (yes, no, abstain, total int64) { return engine.Tally(id) }

func Timings(id int64) (opened, closes, ready, expires int64) { return engine.Timings(id) }

func VoteOf(id int64, who address) (choice string, weight int64, ok bool) {
	return engine.VoteOf(id, who)
}

// Sweep reclaims finished proposals' slots. Permissionless, like Settle: it
// decides nothing, and whoever frees the storage is refunded for it.
func Sweep(cur realm) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	engine.Sweep()
}

// KindRules is the terms a kind was adopted on, for anybody deciding whether
// to propose under it. A copy of a struct of numbers, so it hands out nothing
// to write through.
func KindRules(name string) (Rules, bool) { return engine.KindRules(name) }

// engineKind is what a test asks about a kind, in the shape the registry used
// to answer directly. Unexported: a test may know whether a name is adopted
// without this realm publishing its engine to everybody.
func engineKind(name string) (offered, live bool) { return engine.KindStatus(name) }

// timingReady is the height a decided proposal becomes executable, which is
// the third of the four figures Timings reports. Named because a test asking
// for one of them should not have to discard three.
func timingReady(id int64) int64 {
	_, _, ready, _ := Timings(id)
	return ready
}
