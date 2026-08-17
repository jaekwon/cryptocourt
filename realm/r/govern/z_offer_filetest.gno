// PKGPATH: gno.land/r/kourt/offerer
package offerer

// Can a DIFFERENT realm publish a Kind and offer it?
//
// The whole design rests on yes. A realm registers what may be done, the
// holders adopt it, and an account proposes instances of it — but nothing had
// ever implemented the interface from outside package govern, so the extension
// point was a claim rather than a fact.
//
// It is not an idle worry. Kind.Do takes a realm as a parameter, and gno's own
// security notes warn against realm-typed interface methods; the VM permits
// what r/gov/dao already does, but permitted and usable from another package
// are different questions. This file asks the second one.

import (
	"gno.land/r/kourt/govern"
)

// mine is a Kind declared entirely outside govern.
type mine struct{}

func (mine) Name() string { return "offerer/greet" }

func (mine) Describe(payload string) string { return "say hello to " + payload }

func (mine) Check(payload string) error {
	if payload == "" {
		return errEmpty
	}
	return nil
}

// Do takes the realm as data, not as a crossing parameter — the shape a /p/
// package could use unchanged, and the shape commondao's ExecFunc uses.
func (mine) Do(_ int, rlm realm, payload string) error {
	println("greeted:", payload)
	return nil
}

type strErr struct{ s string }

func (e *strErr) Error() string { return e.s }

var errEmpty = &strErr{"nothing to greet"}

func main(cur realm) {
	// A foreign realm offers its own kind. Ungated, because an offered kind
	// can do nothing until the holders adopt it.
	// govern.Rules{...} here is refused by the VM — a realm cannot allocate
	// another realm's struct — so the terms are built by a constructor inside
	// govern, from numbers.
	govern.Offer(cross(cur), mine{}, govern.NewRules(2000, 6600, 100, 0, 1000, 0))
	println("a foreign realm offered its own kind: true")

	// And govern can call INTO it. This is the half that offering does not
	// prove: the Describe and Check that run here are this realm's code,
	// reached across a realm boundary from a value govern merely holds.
	println(govern.Preview("offerer/greet", "world"))
	println("---")
	// Including the refusal, which is the offering realm's own Check talking.
	println(govern.Preview("offerer/greet", ""))
	println("---")
	println(govern.Preview("nothing/here", "x"))

	// What it CANNOT do next is said here only in words. The refusal to
	// propose an unadopted kind is a panic inside a crossing call, which
	// aborts rather than being recoverable, so a filetest can only demonstrate
	// it by failing. TestAKindCannotBeProposedUntilItIsAdopted asserts it in
	// package govern, where an abort can be caught.
}

// Output:
// a foreign realm offered its own kind: true
// say hello to world
//
// _This kind has not been adopted, so it cannot be proposed yet._
// ---
// say hello to
//
// _This would be refused: nothing to greet_
//
// _This kind has not been adopted, so it cannot be proposed yet._
// ---
// no kind by that name has been offered
