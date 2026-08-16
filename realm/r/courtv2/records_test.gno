package courtv2

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
