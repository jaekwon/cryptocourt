package archive

import (
	"context"
	"testing"
)

// TestPendingIsWhatAwaitsAPersonRatherThanWhatWasEverFlagged.
//
// Stats.Pending is what archive health reports, and an operator reads it to
// answer one question: does anything need me. It counted every uncleared,
// non-clean review row — including the ones written BY an operator, since
// BlockByOperator records its own decision and deliberately leaves it uncleared.
//
// That is right for the LISTING. PendingReview is the only inventory of what is
// blocked, and the unblock verb takes a hash somebody has to be able to read, so
// an operator's own blocks must stay visible there or they become unreachable.
// It was wrong for the COUNT: once an operator had ever acted, the number could
// never return to zero, so the state that means "nothing to do" was unreachable
// for the rest of the deployment's life.
//
// Both directions are asserted, because a count that reached zero by ignoring
// the model's blocks would be a far worse bug than the one being fixed.
func TestPendingIsWhatAwaitsAPersonRatherThanWhatWasEverFlagged(t *testing.T) {
	ctx := context.Background()

	byPerson := namedStore(t, t.Name()+"/person")
	sum, err := byPerson.Put(ctx, "image/png", pngWith("op-blocked"), "c")
	if err != nil {
		t.Fatal(err)
	}
	if err := byPerson.Promote(ctx, sum); err != nil {
		t.Fatal(err)
	}
	if err := byPerson.BlockByOperator(ctx, sum, "reported"); err != nil {
		t.Fatal(err)
	}
	st, err := byPerson.Stats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st.Pending != 0 {
		t.Fatalf("pending is %d after the only decision was made by a person", st.Pending)
	}
	if st.Blocked != 1 {
		t.Fatalf("the block itself did not survive: blocked=%d", st.Blocked)
	}
	// And it is still findable, which is the reason it stays uncleared.
	rows, err := byPerson.PendingReview(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].SHA256 != sum || !rows[0].Blocked {
		t.Fatalf("an operator's own block left the only listing of it: %+v", rows)
	}

	byModel := namedStore(t, t.Name()+"/model")
	sum2, err := byModel.Put(ctx, "image/png", pngWith("auto-blocked"), "c")
	if err != nil {
		t.Fatal(err)
	}
	if err := byModel.Promote(ctx, sum2); err != nil {
		t.Fatal(err)
	}
	did, err := byModel.Review(ctx, sum2, ImageVerdict{
		Label: AutoBlockLabel, Confidence: AutoBlockConfidence, Why: "x"})
	if err != nil {
		t.Fatal(err)
	}
	if !did {
		t.Fatal("the model's verdict did not block at the stated threshold")
	}
	st2, err := byModel.Stats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st2.Pending != 1 {
		t.Fatalf("a machine's block must still await a person: pending=%d", st2.Pending)
	}
	// A person clearing it is what ends it, and that unblocks as well.
	if err := byModel.Clear(ctx, sum2); err != nil {
		t.Fatal(err)
	}
	st3, err := byModel.Stats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if st3.Pending != 0 || st3.Blocked != 0 {
		t.Fatalf("clearing left pending=%d blocked=%d", st3.Pending, st3.Blocked)
	}
}
