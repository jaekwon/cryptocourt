// Package offerer is a worked example of extending the governor, and the
// fixture that proves the extension point works from a real realm on a chain.
//
// The governor's whole shape rests on one claim: a realm that is not govern can
// publish a power, the holders can adopt it by vote, and a proposal can then run
// it. Everything on the govern side is tested from inside package govern, where
// a test can write to the registry directly — which proves the machinery and
// not the claim.
//
// This is the other side. It implements govern.Kind entirely out here, calls
// govern.Offer, and does so through an entrypoint a TRANSACTION can reach: the
// name is a string parameter, because MsgCall carries nothing else and a fixture
// that can only be driven from Go would not be testing the path anybody uses.
//
// It also shows the constraint that shapes every Kind: Describe must be a total
// function of the payload alone. Read live state in it and two holders looking
// at the same proposal at different heights are voting on different questions.
package offerer

import (
	"chain"
	"strconv"

	"gno.land/r/cryptocourt/govern"
)

// greeting is a Kind whose name is chosen when it is offered.
//
// A name per instance rather than a constant, so the same realm can offer
// several — and so a test can offer a fresh one on a chain that already holds
// the last run's. Offer binds a name to its code permanently and refuses to
// rewrite one, which is the rule that makes an adoption vote mean something.
type greeting struct {
	name string
}

func (g greeting) Name() string { return g.name }

// Describe renders the payload and nothing else. No live state, no clock.
func (g greeting) Describe(payload string) string {
	return "greet the holders with: " + payload
}

// Check is asked twice — when the proposal opens, and again immediately before
// Do — so it must answer about the world as it is each time.
func (g greeting) Check(payload string) error {
	if payload == "" {
		return errEmpty
	}
	if len(payload) > 280 {
		return errTooLong
	}
	// One line of text, and this is the part worth copying.
	//
	// A payload is supplied by whoever PROPOSES, not by the realm that wrote
	// the kind — and the governor lets any address propose when ProposeBps is
	// zero, which is what this kind asks for above. Describe then renders it
	// onto a page other holders read and vote from.
	//
	// So the kind is trusted with markdown and its payload is not. A newline
	// here ends whatever line Describe put it on and starts one of the
	// proposer's own: a heading, a list, a row that reads like a proposal.
	//
	// Every built-in kind is safe from this without doing anything, because
	// their payloads are names and addresses and cannot hold a newline. Which
	// is exactly why it is easy to miss — it first bites a kind that takes free
	// text, and that is the first kind anybody writes.
	return govern.TextOnly(payload)
}

// Do performs it. Non-crossing, taking the realm as data, which is the shape a
// Kind must have: crossing functions are illegal outside a realm and this
// interface has to be implementable from a p/ package too.
func (g greeting) Do(_ int, rlm realm, payload string) error {
	greeted++
	last = payload
	chain.Emit("Greeted", "text", payload, "count", strconv.Itoa(greeted))
	return nil
}

var (
	greeted int
	last     string
)

// Greeted is how many times a greeting has run, and the most recent one.
//
// Exported so a test on a chain can see that Do actually ran and its effect
// stuck, which is the half of execution that a transaction receipt cannot show.
func Greeted() (int, string) { return greeted, last }

// OfferNamed publishes a greeting kind under the given name.
//
// Ungated, exactly as govern.Offer is: publishing code grants nothing, and it
// is the holders' adoption vote that decides whether it may ever run. The terms
// below are what they would be adopting it on.
func OfferNamed(cur realm, name string) {
	govern.Offer(cross(cur), greeting{name: name}, govern.NewRules(
		2000, // a fifth of the supply must turn out
		5100, // a bare majority of what is cast; this only says hello
		100,  // a short vote, because nothing here is dangerous
		0,    // no timelock, for the same reason
		5000, // but a real expiry: a grace of zero is refused, because a
		//       decided proposal holds its slot until it runs
		0, // anybody may propose one
	))
}

var (
	errEmpty   = govErr("a greeting needs something to say")
	errTooLong = govErr("that greeting is too long to put on a page")
)

type govErr string

func (e govErr) Error() string { return string(e) }
