package kourtv2

import (
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
)

func TestRecordsCreditResetAndGate(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rec-alice")
	bob := testutils.TestAddress("rec-bob")
	dan := testutils.TestAddress("rec-dan")
	eve := testutils.TestAddress("rec-eve")
	c := testCourt(cur, "rec1", alice, 1_000_000_000)

	if PriorityGateActive("rec1") {
		t.Fatal("the cold-start guard keeps the gate off in a fresh court")
	}
	// Contested wins accumulate; the gate arms only at N qualified addresses.
	for i := 0; i < priorityNetRecord; i++ {
		creditUpheld(c, alice)
		creditUpheld(c, bob)
	}
	if AnswerRecord("rec1", alice) != priorityNetRecord || c.qualifiedCount != 2 {
		t.Fatalf("two qualified: score=%d count=%d", AnswerRecord("rec1", alice), c.qualifiedCount)
	}
	if PriorityGateActive("rec1") {
		t.Fatal("two qualified is below the cold-start N of three")
	}
	for i := 0; i < priorityNetRecord; i++ {
		creditUpheld(c, dan)
	}
	if !PriorityGateActive("rec1") {
		t.Fatal("three qualified arms the gate")
	}

	// An overturn burns the WHOLE credential and de-qualifies.
	creditUpheld(c, alice) // score 4
	resetOverturned(c, alice)
	if AnswerRecord("rec1", alice) != 0 || c.qualifiedCount != 2 {
		t.Fatalf("overturn must reset to zero and de-qualify: score=%d count=%d",
			AnswerRecord("rec1", alice), c.qualifiedCount)
	}
	if PriorityGateActive("rec1") {
		t.Fatal("the gate disarms when qualified addresses drop below N")
	}
	// Undisputed stands earn nothing by construction: no credit path exists
	// except creditUpheld — asserted by the API surface (eve never credited).
	if AnswerRecord("rec1", eve) != 0 {
		t.Fatal("no free credentials")
	}
}

func TestOneActivePriorityClaim(cur realm, t *testing.T) {
	alice := testutils.TestAddress("rec2-alice")
	c := testCourt(cur, "rec2", alice, 1_000_000_000)
	for i := 0; i < priorityNetRecord; i++ {
		creditUpheld(c, alice)
	}
	if !mayAnswerInPriority(c, alice) {
		t.Fatal("a qualified, unengaged answerer may use the window")
	}
	holdPriority(c, alice, 7)
	if mayAnswerInPriority(c, alice) {
		t.Fatal("one active priority claim at a time")
	}
	releasePriority(c, alice, 3) // wrong claim: no-op
	if mayAnswerInPriority(c, alice) {
		t.Fatal("releasing a different claim must not free the slot")
	}
	releasePriority(c, alice, 7)
	if !mayAnswerInPriority(c, alice) {
		t.Fatal("finalizing the held claim frees the slot")
	}
}

// resetOverturned's qualification check, found SURVIVING by the mutation harness:
// decrementing qualifiedCount UNCONDITIONALLY failed no test. The count exists only to
// drive priorityGateActive's cold-start guard (R5e: the 24h window binds only once the
// court has real qualified answerers), and it is an int with no floor — so overturning
// answerers who never qualified drives it NEGATIVE and the gate then stays off no
// matter how many genuine credentials the court later earns.
//
// Exercised directly on the record helpers, since driving three contested-and-upheld
// rounds plus an overturn through the dispute machine for each address would test the
// dispute machine rather than this accounting.
func TestOverturnOnlyDecrementsAQualifiedRecord(cur realm, t *testing.T) {
	alice := testutils.TestAddress("recq-alice")
	unqual := testutils.TestAddress("recq-unqual")
	c := testCourt(cur, "recq", alice, 1_000_000_000)

	// An address that never reached the threshold: overturning it must not decrement.
	creditUpheld(c, unqual) // score 1, still under priorityNetRecord (3)
	if c.qualifiedCount != 0 {
		t.Fatalf("setup: one win must not qualify: %d", c.qualifiedCount)
	}
	resetOverturned(c, unqual)
	if c.qualifiedCount != 0 {
		t.Fatalf("overturning an UNQUALIFIED record must not decrement the count "+
			"(it has no floor, so this goes negative and disables the gate): %d",
			c.qualifiedCount)
	}

	// A qualified address: the count rises once at the threshold, not per win, and
	// falls once on overturn.
	for i := 0; i < priorityNetRecord; i++ {
		creditUpheld(c, alice)
	}
	if c.qualifiedCount != 1 {
		t.Fatalf("reaching the threshold qualifies exactly once: %d", c.qualifiedCount)
	}
	creditUpheld(c, alice) // a further win must not double-count
	if c.qualifiedCount != 1 {
		t.Fatalf("a win beyond the threshold must not re-qualify: %d", c.qualifiedCount)
	}
	resetOverturned(c, alice)
	if c.qualifiedCount != 0 {
		t.Fatalf("overturning a qualified record decrements once: %d", c.qualifiedCount)
	}
	// And the credential burns entirely rather than decaying.
	if r := getRecord(c, alice); r.score != 0 {
		t.Fatalf("an overturn burns the whole career score: %d", r.score)
	}
}
