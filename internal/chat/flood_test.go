package chat

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// Can one address bury the person the carve-out depends on?
//
// §7 defers reporting-shaped messages to a human because gemma3:4b cannot tell reporting
// a scam from sending one. That deferral is the design's answer to its own weakest point,
// and it has a cost nobody had measured: the queue is a shared, finite resource called
// somebody's attention, and filling it is cheaper than evading the classifier.
//
// The attack needs no evasion at all. Reporting-shaped text is what gets carved out, so
// the attacker writes exactly that, varies a number so the skeleton dedup does not fire,
// and stays inside the throttle. Measured against the flat queue: 70 accepted, the single
// genuine report at position 71 of 71, and all twenty of the first rows an operator reads
// belonging to the attacker.
//
// What follows pins the flat queue's weakness AND the grouped view that answers it, in one
// fixture, because the second is only meaningful beside the first.

// flood posts n reporting-shaped messages from one address, respecting the throttle.
//
// Returns what actually landed rather than what was attempted, and the LAST body that
// landed — which is not the (accepted-1)th attempt, because the throttle's refusals are
// scattered through the loop. Assuming otherwise cost one wrong assertion: 70 of 200 got
// through and the final accepted message was attempt 183, not attempt 69.
func flood(t *testing.T, s *Store, ctx context.Context, tick func(time.Duration),
	ip, moniker string, n int) (accepted int, lastBody string) {
	t.Helper()
	for i := 0; i < n; i++ {
		tick(MinInterval + 100*time.Millisecond)
		body := fmt.Sprintf("beware everyone, someone asked me for my seed phrase, incident %d", i)
		id, err := s.Post(ctx, PostInput{
			Chain: "dev", Court: "orem", Moniker: moniker,
			Body: body, IPHash: ip, NetHash: "net-" + ip,
		})
		if err != nil {
			continue // the throttle refusing is fine; this measures what gets through
		}
		accepted++
		lastBody = body
		if err := s.RecordVerdict(ctx, id, "scam"); err != nil {
			t.Fatal(err)
		}
	}
	return accepted, lastBody
}

func TestOneAddressCannotBuryTheReviewQueue(t *testing.T) {
	s, ctx, tick := reviewStore(t)

	// A genuine report, first, so burying it is the attacker's job rather than an
	// accident of ordering.
	good, err := s.Post(ctx, PostInput{
		Chain: "dev", Court: "orem", Moniker: "goodcitizen",
		Body:   "careful, someone asked me for my seed phrase in DMs",
		IPHash: "ip-good", NetHash: "net-good",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.RecordVerdict(ctx, good, "scam"); err != nil {
		t.Fatal(err)
	}

	accepted, lastSaid := flood(t, s, ctx, tick, "ip-flood", "flooder", 200)
	if accepted < 20 {
		t.Fatalf("the fixture needs a real flood to be worth anything, only %d got through", accepted)
	}
	t.Logf("the throttle let %d of 200 through", accepted)

	// THE WEAKNESS, pinned so nobody restores the flat list as the default. This asserts
	// the attack WORKS against the flat view — it is the reason the grouped one exists.
	flat, err := s.PendingReview(ctx, false, 500)
	if err != nil {
		t.Fatal(err)
	}
	pos := -1
	for i, r := range flat {
		if r.ID == good {
			pos = i
			break
		}
	}
	if pos < 20 {
		t.Fatalf("the flat queue was expected to bury the report; it is at %d, so this "+
			"fixture no longer measures what it claims", pos)
	}
	t.Logf("flat queue: %d rows, the genuine report at position %d", len(flat), pos+1)

	// THE FIX. Two authors, so the report is one of two rows however long the flood is.
	groups, err := s.ReviewGroups(ctx, false, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(groups) != 2 {
		t.Fatalf("want one row per author, got %d", len(groups))
	}
	var floodG, goodG *ReviewGroup
	for i := range groups {
		switch groups[i].IPHash {
		case "ip-flood":
			floodG = &groups[i]
		case "ip-good":
			goodG = &groups[i]
		}
	}
	if floodG == nil || goodG == nil {
		t.Fatalf("both authors must appear: %+v", groups)
	}
	if goodG.Count != 1 {
		t.Errorf("the genuine reporter filed once, got %d", goodG.Count)
	}
	if floodG.Count != accepted {
		t.Errorf("the flood must be counted in full: got %d, want %d", floodG.Count, accepted)
	}
	// The count IS the signal — nobody files this many in twenty minutes — and it is why
	// no new automatic punishment was added for the pattern.
	if floodG.Count < 20 {
		t.Errorf("the flood row must say how big it is, got %d", floodG.Count)
	}
	// The row has to be judgeable on its own, and the message shown must be the MOST
	// RECENT one. Asserting merely that some message is shown does not discriminate —
	// swapping MAX(id) for MIN(id) passed that, and would have shown an operator the
	// flood's first message while it was still arriving.
	if floodG.Latest == "" || floodG.LatestID == 0 {
		t.Fatal("a grouped row still has to show a message an operator can read")
	}
	if floodG.Latest != lastSaid {
		t.Errorf("the row must show the latest message, not the earliest:\n got %q\nwant %q",
			floodG.Latest, lastSaid)
	}
	if floodG.LatestID <= flat[len(flat)-1].ID {
		t.Error("the latest id must be the newest of the group, not the oldest")
	}
	if floodG.LastAt <= floodG.FirstAt {
		t.Error("a flood's span is what makes it legible as a flood")
	}

	// Both directions on the same assertion: the genuine report is READABLE, not merely
	// present. A grouped view that showed only the loudest author would pass a count
	// check and still lose the report.
	if goodG.Latest != "careful, someone asked me for my seed phrase in DMs" {
		t.Errorf("the genuine report must be readable in its own row, got %q", goodG.Latest)
	}
	if goodG.Moniker != "goodcitizen" {
		t.Errorf("and attributed, got %q", goodG.Moniker)
	}
}

// Clearing the flood must be one command, or the flood wins at the dismissal step
// instead of the reading step — and it must not clear anybody else.
func TestClearingOneAuthorLeavesTheOthersAlone(t *testing.T) {
	s, ctx, tick := reviewStore(t)

	good, err := s.Post(ctx, PostInput{
		Chain: "dev", Court: "orem", Moniker: "goodcitizen",
		Body:   "careful, someone asked me for my seed phrase in DMs",
		IPHash: "ip-good", NetHash: "net-good",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.RecordVerdict(ctx, good, "scam"); err != nil {
		t.Fatal(err)
	}
	accepted, _ := flood(t, s, ctx, tick, "ip-flood", "flooder", 60)

	n, err := s.MarkReviewedFrom(ctx, "ip-flood")
	if err != nil {
		t.Fatal(err)
	}
	if int(n) != accepted {
		t.Fatalf("one command must clear the whole flood: cleared %d of %d", n, accepted)
	}

	// THE BYSTANDER, in queue form: the genuine report is still waiting.
	groups, err := s.ReviewGroups(ctx, false, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(groups) != 1 || groups[0].IPHash != "ip-good" {
		t.Fatalf("clearing one author must leave the other queued, got %+v", groups)
	}
	if groups[0].Count != 1 {
		t.Fatalf("the surviving report must be intact, got %d", groups[0].Count)
	}

	// And it punished nobody, which is the whole difference between dismissing and acting.
	for _, ip := range []string{"ip-flood", "ip-good"} {
		st, err := s.Status(ctx, ip, "net-"+ip)
		if err != nil {
			t.Fatal(err)
		}
		if st.State != "ok" {
			t.Errorf("%s must not be punished by a dismissal, got %q", ip, st.State)
		}
	}
	// The flood is still visible in the court, too: dismissing is not hiding.
	msgs, err := s.Recent(ctx, "dev", "orem", 0, 200)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != accepted+1 {
		t.Errorf("dismissing must not hide anything: %d visible, want %d", len(msgs), accepted+1)
	}

	// A second run has nothing to do and says so rather than reporting a silent success.
	if _, err := s.MarkReviewedFrom(ctx, "ip-flood"); err == nil {
		t.Error("clearing an already-clear author must fail loudly")
	}
	if _, err := s.MarkReviewedFrom(ctx, ""); err == nil {
		t.Error("clearing with no author must fail rather than clear everything")
	}
	if _, err := s.MarkReviewedFrom(ctx, "ip-nobody"); err == nil {
		t.Error("clearing an unknown author must fail")
	}
}

// One address wearing several names, and one spread across courts, are the two patterns a
// grouped row has to make legible — otherwise grouping by address hides the very thing
// that shows a flood is coordinated rather than diligent.
func TestAGroupedRowShowsNamesAndCourts(t *testing.T) {
	s, ctx, tick := reviewStore(t)
	for i, name := range []string{"alice", "bob", "carol"} {
		court := "orem"
		if i == 2 {
			court = "ledger"
		}
		tick(MinInterval + 100*time.Millisecond)
		id, err := s.Post(ctx, PostInput{
			Chain: "dev", Court: court, Moniker: name,
			Body:   fmt.Sprintf("someone asked me for my seed phrase, report %d", i),
			IPHash: "ip-one", NetHash: "net-one",
		})
		if err != nil {
			t.Fatal(err)
		}
		if err := s.RecordVerdict(ctx, id, "scam"); err != nil {
			t.Fatal(err)
		}
	}
	groups, err := s.ReviewGroups(ctx, false, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(groups) != 1 {
		t.Fatalf("one address is one row, got %d", len(groups))
	}
	g := groups[0]
	if g.Count != 3 {
		t.Errorf("want 3 messages, got %d", g.Count)
	}
	if g.Monikers != 3 {
		t.Errorf("three names from one address is the signal; got %d", g.Monikers)
	}
	if g.Courts != 2 {
		t.Errorf("two courts is the other signal; got %d", g.Courts)
	}
	// The single-author, single-name case must NOT claim a pattern — the paired negative,
	// because a row that always says "3 names" is as useless as one that never does.
	s2, ctx2, _ := reviewStore(t)
	id, err := s2.Post(ctx2, PostInput{Chain: "dev", Court: "orem", Moniker: "solo",
		Body: "someone asked me for my seed phrase", IPHash: "ip-solo", NetHash: "net-solo"})
	if err != nil {
		t.Fatal(err)
	}
	if err := s2.RecordVerdict(ctx2, id, "scam"); err != nil {
		t.Fatal(err)
	}
	gs, err := s2.ReviewGroups(ctx2, false, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(gs) != 1 || gs[0].Monikers != 1 || gs[0].Courts != 1 || gs[0].Count != 1 {
		t.Fatalf("one report from one name must read as exactly that: %+v", gs)
	}
}
