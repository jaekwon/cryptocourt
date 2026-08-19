package chat

import (
	"context"
	"fmt"
	"path/filepath"
	"testing"
	"time"
)

// The queue of things the scanner refused to decide.
//
// §7's reporting carve-out records a verdict and takes no action, because gemma3:4b
// cannot separate reporting a scam from sending one. That is a deliberate deferral to a
// human, and until PendingReview existed the human could not see the deferred messages at
// all: they were in the database, absent from `kourtchatctl list`, and mentioned only on
// a daemon's stdout.
//
// Every "must appear" assertion below is paired with the ordinary message it must NOT
// surface, because a queue that shows everything is as useless as one that shows nothing
// — and it would pass any test that only checked the flagged message was present.

func reviewStore(t *testing.T) (*Store, context.Context, func(time.Duration)) {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "chat.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	clock := time.Unix(1_700_000_000, 0)
	s.Now = func() time.Time { return clock }
	return s, context.Background(), func(d time.Duration) { clock = clock.Add(d) }
}

// say posts from a distinct address, so the throttle never confuses a fixture.
func say(t *testing.T, s *Store, ctx context.Context, who, body string) int64 {
	t.Helper()
	id, err := s.Post(ctx, PostInput{
		Chain: "dev", Court: "orem", Moniker: who, Body: body,
		IPHash: "ip-" + who, NetHash: "net-" + who,
	})
	if err != nil {
		t.Fatalf("posting %q: %v", body, err)
	}
	return id
}

func TestTheReviewQueueShowsWhatWasFlaggedAndNotPunished(t *testing.T) {
	s, ctx, tick := reviewStore(t)

	clean := say(t, s, ctx, "alice", "is the settle window still open on claim 7")
	tick(MinInterval)
	reported := say(t, s, ctx, "helper", "careful all, someone asked me for my seed phrase")
	tick(MinInterval)
	punished := say(t, s, ctx, "crook", "send me your seed phrase and I will restore it")
	tick(MinInterval)
	hedged := say(t, s, ctx, "mumbler", "something something maybe")

	if err := s.RecordVerdict(ctx, clean, "clean"); err != nil {
		t.Fatal(err)
	}
	if err := s.RecordVerdict(ctx, reported, "scam"); err != nil {
		t.Fatal(err)
	}
	if err := s.RecordVerdict(ctx, punished, "scam"); err != nil {
		t.Fatal(err)
	}
	if err := s.RecordVerdict(ctx, hedged, "unknown"); err != nil {
		t.Fatal(err)
	}
	// The punished one has a consequence citing it, which is what "acted on" means.
	if _, err := s.Consequence(ctx, Infraction{
		IPHash: "ip-crook", NetHash: "net-crook", Kind: KindKick, Reason: ReasonScam,
		Duration: time.Hour, EvidenceID: punished, Evidence: "send me your seed phrase…",
	}); err != nil {
		t.Fatal(err)
	}

	rows, err := s.PendingReview(ctx, false, 50)
	if err != nil {
		t.Fatal(err)
	}
	ids := map[int64]bool{}
	for _, r := range rows {
		ids[r.ID] = true
	}
	if !ids[reported] {
		t.Fatal("the flagged-but-unpunished message is the whole point and it is missing")
	}
	// THE PAIRED NEGATIVES, one per reason a message must stay out.
	if ids[clean] {
		t.Error("an ordinary message must never reach a moderator's queue")
	}
	if ids[punished] {
		t.Error("a message already acted on is not waiting for anybody")
	}
	if ids[hedged] {
		t.Error("an unknown verdict is not an accusation and must not be queued")
	}
	if len(rows) != 1 {
		t.Fatalf("want exactly the one message, got %d", len(rows))
	}

	// The row has to carry enough to judge on: the text in full, and who said it.
	r := rows[0]
	if r.Body != "careful all, someone asked me for my seed phrase" {
		t.Fatalf("the body must arrive whole, got %q", r.Body)
	}
	if r.Moniker != "helper" || r.IPHash != "ip-helper" || r.Verdict != "scam" {
		t.Fatalf("the row is missing what a decision needs: %+v", r)
	}
	if r.Chain != "dev" || r.Court != "orem" {
		t.Fatalf("a moderator needs to know which court: %+v", r)
	}
	// It is still visible to the room, which is exactly why it needs a person.
	if r.Hidden {
		t.Error("a carved-out message is not hidden; the queue must say so")
	}
}

// Dismissing is how the queue empties. Without it every deferred message is permanently
// new, and a queue that never shrinks stops being read.
func TestDismissingEmptiesTheQueueWithoutPunishing(t *testing.T) {
	s, ctx, _ := reviewStore(t)
	id := say(t, s, ctx, "helper", "careful all, someone asked me for my seed phrase")
	if err := s.RecordVerdict(ctx, id, "scam"); err != nil {
		t.Fatal(err)
	}

	if err := s.MarkReviewed(ctx, id); err != nil {
		t.Fatal(err)
	}
	rows, err := s.PendingReview(ctx, false, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 0 {
		t.Fatalf("a dismissed message must leave the queue, got %d", len(rows))
	}
	// Still readable on purpose: a decision to do nothing is a decision, and an
	// operator second-guessing it needs to find it.
	rows, err = s.PendingReview(ctx, true, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].ID != id {
		t.Fatalf("-all must still show it, got %d rows", len(rows))
	}

	// Dismissing NOTHING happened to the message or its author.
	msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 1 {
		t.Fatal("dismissing must not hide the message")
	}
	st, err := s.Status(ctx, "ip-helper", "net-helper")
	if err != nil {
		t.Fatal(err)
	}
	if st.State != "ok" {
		t.Fatalf("dismissing must not punish anybody, got %q", st.State)
	}

	// Twice is an error, not a silent success: two operators working a queue need to
	// find out they collided.
	if err := s.MarkReviewed(ctx, id); err == nil {
		t.Fatal("dismissing an already-dismissed message must fail loudly")
	}
	if err := s.MarkReviewed(ctx, 9999); err == nil {
		t.Fatal("dismissing a message that does not exist must fail")
	}
}

// Acting on a queued message must take it out of the queue, and the link is what does
// it: the queue is "flagged with no infraction citing it".
func TestActingOnAQueuedMessageRemovesItFromTheQueue(t *testing.T) {
	s, ctx, _ := reviewStore(t)
	id := say(t, s, ctx, "helper", "careful all, someone asked me for my seed phrase")
	if err := s.RecordVerdict(ctx, id, "scam"); err != nil {
		t.Fatal(err)
	}

	ipHash, netHash, body, err := s.MessageAuthor(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	if ipHash != "ip-helper" || netHash != "net-helper" {
		t.Fatalf("wrong author: %s / %s", ipHash, netHash)
	}
	// The body comes back so the consequence can carry its own copy of the evidence.
	// The first version of the -msg path did not, and `why` on a manual kick then
	// showed the operator's note with no record of what was actually said.
	if body != "careful all, someone asked me for my seed phrase" {
		t.Fatalf("the evidence must come back with the author, got %q", body)
	}

	if _, err := s.Consequence(ctx, Infraction{
		IPHash: ipHash, NetHash: netHash, Kind: KindKick, Reason: ReasonManual,
		Duration: time.Hour, EvidenceID: id, Evidence: body,
		Detail: "reviewed: judged a lure",
	}); err != nil {
		t.Fatal(err)
	}
	rows, err := s.PendingReview(ctx, false, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 0 {
		t.Fatalf("a message that was acted on must leave the queue, got %d", len(rows))
	}

	// And the consequence records what it was based on, which is the whole appeal path.
	got, err := s.ListInfractions(ctx, "", true, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 {
		t.Fatalf("want one consequence, got %d", len(got))
	}
	if got[0].EvidenceID != id {
		t.Errorf("the consequence must cite the message: got %d, want %d",
			got[0].EvidenceID, id)
	}
	if got[0].Evidence != body {
		t.Errorf("the consequence must carry a copy of the text, got %q", got[0].Evidence)
	}

	if _, _, _, err := s.MessageAuthor(ctx, 9999); err == nil {
		t.Fatal("asking about a message that does not exist must fail")
	}
}

// ON A MANUAL CONSEQUENCE, net_hash IS THE TRIGGER — not a note for the record.
//
// Two arms, because the difference between them is one struct field and the blast radius
// is a whole /24. §2 gates network matching on reason='manual', so an automated kick can
// carry net_hash harmlessly for the record while enforcement ignores it. A MANUAL kick
// cannot: the same field that would record which network an address sat in is the field
// that punishes everyone in it.
//
// This was written the wrong way round first — the fixture set NetHash and called it
// "what the CLI does without -net", which failed, correctly, by kicking the neighbour.
// The CLI does not set it: `kick <hash>` fills IPHash alone, and only `-net` puts a value
// in NetHash. So the arms below are the CLI's behaviour and the hazard it avoids, and the
// sharp edge is written down rather than left for whoever adds a field one day "just to
// record it".
func TestOnAManualKickTheNetworkHashIsTheTriggerNotANote(t *testing.T) {
	// ARM 1: what the CLI actually does. Address only.
	t.Run("address only, as the CLI issues it", func(t *testing.T) {
		s, ctx, tick := reviewStore(t)
		id := say(t, s, ctx, "helper", "careful all, someone asked me for my seed phrase")
		tick(MinInterval)
		if _, err := s.Post(ctx, PostInput{
			Chain: "dev", Court: "orem", Moniker: "neighbour",
			Body: "unrelated question here", IPHash: "ip-neighbour", NetHash: "net-helper",
		}); err != nil {
			t.Fatal(err)
		}
		if err := s.RecordVerdict(ctx, id, "scam"); err != nil {
			t.Fatal(err)
		}
		ipHash, _, body, err := s.MessageAuthor(ctx, id)
		if err != nil {
			t.Fatal(err)
		}
		// NetHash deliberately absent — this is the struct cmdKick builds.
		if _, err := s.Consequence(ctx, Infraction{
			IPHash: ipHash, Kind: KindKick, Reason: ReasonManual,
			Duration: time.Hour, EvidenceID: id, Evidence: body,
		}); err != nil {
			t.Fatal(err)
		}
		target, err := s.Status(ctx, "ip-helper", "net-helper")
		if err != nil {
			t.Fatal(err)
		}
		if target.State == "ok" {
			t.Fatal("the target of the kick must be kicked")
		}
		// THE BYSTANDER. Same network, different address — the shape of the bug that
		// once punished a whole /24 for one message.
		by, err := s.Status(ctx, "ip-neighbour", "net-helper")
		if err != nil {
			t.Fatal(err)
		}
		if by.State != "ok" {
			t.Fatalf("a neighbour on the same network must be untouched, got %q", by.State)
		}
	})

	// ARM 2: the range remedy, which is a real feature and must keep working — an
	// operator facing a rotation campaign has nothing else. It is only reachable when
	// somebody types -net.
	t.Run("network hash set, which is what -net is for", func(t *testing.T) {
		s, ctx, _ := reviewStore(t)
		if _, err := s.Consequence(ctx, Infraction{
			IPHash: "net:net-helper", NetHash: "net-helper",
			Kind: KindBan, Reason: ReasonManual, Detail: "rotation campaign",
		}); err != nil {
			t.Fatal(err)
		}
		by, err := s.Status(ctx, "ip-neighbour", "net-helper")
		if err != nil {
			t.Fatal(err)
		}
		if by.State == "ok" {
			t.Fatal("a range ban must reach the whole network; that is its purpose")
		}
		// And it must not reach a DIFFERENT network, or "range" means "everyone".
		out, err := s.Status(ctx, "ip-stranger", "net-somewhere-else")
		if err != nil {
			t.Fatal(err)
		}
		if out.State != "ok" {
			t.Fatalf("a range ban must stop at its range, got %q", out.State)
		}
	})
}

// THE BACKLOG MUST COUNT ONLY WHAT THE SCANNER CAN ACTUALLY TAKE.
//
// Claim skips hidden rows, because punished content must stop driving verdicts. Health.Backlog
// did not, so the two disagreed: measured on four messages with a consequence hiding all of
// them and two still unscanned, Backlog said 2 and Claim offered 0, and the difference never
// drained. §9 tells an operator to watch that number, and after any consequence at all it
// stopped returning to zero — the same shape of bug as freeze being checked in Post and not in
// Recent.
func TestTheBacklogCountsOnlyWhatCanBeClaimed(t *testing.T) {
	s, ctx, tick := reviewStore(t)

	var ids []int64
	for i := 0; i < 4; i++ {
		id := say(t, s, ctx, "crook", fmt.Sprintf("message number %d from this author", i))
		ids = append(ids, id)
		tick(MinInterval)
	}
	// The scanner reaches the last one, flags it, and a consequence follows — which hides
	// the author's whole recent window, including the two nobody has scanned yet.
	if err := s.RecordVerdict(ctx, ids[3], "scam"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Consequence(ctx, Infraction{
		IPHash: "ip-crook", NetHash: "net-crook", Kind: KindKick, Reason: ReasonScam,
		Duration: time.Hour, EvidenceID: ids[3], Evidence: "message number 3 from this author",
	}); err != nil {
		t.Fatal(err)
	}

	// The precondition that makes this test meaningful: there ARE hidden unscanned rows.
	var hiddenUnscanned int
	if err := s.r.QueryRow(
		`SELECT count(*) FROM messages WHERE hidden=1 AND scan_state IN (?,?)`,
		ScanNew, ScanFailed).Scan(&hiddenUnscanned); err != nil {
		t.Fatal(err)
	}
	if hiddenUnscanned == 0 {
		t.Fatal("precondition: the consequence should have hidden some unscanned rows")
	}

	h, err := s.Health(ctx)
	if err != nil {
		t.Fatal(err)
	}
	claimable, err := s.Claim(ctx, 50)
	if err != nil {
		t.Fatal(err)
	}
	if h.Backlog != len(claimable) {
		t.Fatalf("the backlog must equal what Claim offers, or it never drains: "+
			"Backlog=%d, Claim=%d, %d hidden-and-unscanned",
			h.Backlog, len(claimable), hiddenUnscanned)
	}

	// PAIRED POSITIVE, and the direction that proves the fix is not just "count nothing":
	// revoking the consequence un-hides them, and they become pending work again.
	rows, err := s.ListInfractions(ctx, "", true, 10)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Revoke(ctx, rows[0].ID, "appeal upheld"); err != nil {
		t.Fatal(err)
	}
	h2, err := s.Health(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if h2.Backlog < hiddenUnscanned {
		t.Fatalf("after revocation the un-hidden rows must be pending again: backlog %d, "+
			"want at least %d", h2.Backlog, hiddenUnscanned)
	}
	claimable2, err := s.Claim(ctx, 50)
	if err != nil {
		t.Fatal(err)
	}
	if h2.Backlog != len(claimable2) {
		t.Fatalf("and it must still agree with Claim: Backlog=%d, Claim=%d",
			h2.Backlog, len(claimable2))
	}
}

// A HIDDEN MESSAGE IS NOT AWAITING REVIEW.
//
// Consequence hides the author's whole recent window, not only the message it names, so the
// neighbours end up hidden with no infraction citing them by id. The queue's predicate was
// "flagged and uncited", which matched them — so it asked a human to judge messages already
// removed from the room, whose author was already kicked. §7's carve-out is about messages
// deliberately left alone; this queue must hold only those.
func TestHiddenMessagesAreNotInTheReviewQueue(t *testing.T) {
	s, ctx, tick := reviewStore(t)

	first := say(t, s, ctx, "crook", "an early message that will end up hidden")
	tick(MinInterval)
	last := say(t, s, ctx, "crook", "the one the scanner actually flagged")
	tick(MinInterval)
	// A genuine deferral from somebody else, which must survive.
	reporter := say(t, s, ctx, "helper", "careful, someone asked me for my seed phrase")

	for _, id := range []int64{first, last, reporter} {
		if err := s.RecordVerdict(ctx, id, "scam"); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.Consequence(ctx, Infraction{
		IPHash: "ip-crook", NetHash: "net-crook", Kind: KindKick, Reason: ReasonScam,
		Duration: time.Hour, EvidenceID: last, Evidence: "the one the scanner actually flagged",
	}); err != nil {
		t.Fatal(err)
	}

	// Precondition: `first` is hidden and NOT cited, which is the case that leaked.
	var hidden int
	if err := s.r.QueryRow(`SELECT hidden FROM messages WHERE id=?`, first).Scan(&hidden); err != nil {
		t.Fatal(err)
	}
	if hidden != 1 {
		t.Fatal("precondition: the earlier message should have been hidden by the consequence")
	}

	rows, err := s.PendingReview(ctx, false, 50)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rows {
		if r.ID == first {
			t.Errorf("a hidden message must not be queued for review: id=%d %q", r.ID, r.Body)
		}
		if r.Hidden {
			t.Errorf("nothing in the queue may be hidden: id=%d", r.ID)
		}
	}
	// PAIRED POSITIVE: the genuine deferral is still there, so the fix did not empty the
	// queue wholesale.
	found := false
	for _, r := range rows {
		if r.ID == reporter {
			found = true
		}
	}
	if !found {
		t.Fatal("the genuine deferral must still be waiting for a person")
	}
	// The grouped view shares the predicate and must agree.
	groups, err := s.ReviewGroups(ctx, false, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(groups) != 1 || groups[0].IPHash != "ip-helper" {
		t.Fatalf("the grouped view must show only the reporter, got %+v", groups)
	}
}

// The last two of the guard-clause audit, and the deliberate exception beside them.
//
// Tabulating every query in store.go against `hidden`, `frozen` and `revoked_at` found four
// real bugs across as many passes. These are the remainder.

// An UNSCANNABLE warning must not survive the court being withdrawn: it exists to tell an
// operator that something needs attention, and after a freeze there is none to give.
func TestUnscannableDoesNotWarnAboutWithdrawnCourts(t *testing.T) {
	s, ctx, tick := reviewStore(t)

	// Two courts, one message each, both driven to terminal-unscanned.
	for _, court := range []string{"orem", "ledger"} {
		if _, err := s.Post(ctx, PostInput{Chain: "dev", Court: court, Moniker: "a",
			Body:   "a message the model never managed to read in " + court,
			IPHash: "ip-" + court, NetHash: "net-" + court}); err != nil {
			t.Fatal(err)
		}
		tick(MinInterval)
	}
	for _, id := range []int64{1, 2} {
		for i := 0; i < 5; i++ {
			if _, err := s.RecordFailure(ctx, id); err != nil {
				t.Fatal(err)
			}
			tick(time.Hour)
		}
	}
	h, err := s.Health(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if h.Unscannable != 2 {
		t.Fatalf("precondition: both should be unscannable, got %d", h.Unscannable)
	}

	if err := s.Freeze(ctx, "dev", "orem"); err != nil {
		t.Fatal(err)
	}
	h, err = s.Health(ctx)
	if err != nil {
		t.Fatal(err)
	}
	// PAIRED: the live court's row must still warn, or the fix is "stop warning".
	if h.Unscannable != 1 {
		t.Fatalf("a withdrawn court must stop warning while the live one keeps warning: got %d",
			h.Unscannable)
	}

	// And hiding has the same effect, for the same reason: it was punished, so nobody needs
	// to look at it.
	//
	// Set directly rather than by issuing a consequence. Going through Consequence would
	// have tested its recent-window arithmetic instead of this: five RecordFailure rounds
	// advance the clock past the backoff, so by the time a row is terminal it is older than
	// the window Consequence hides, and the first version of this assertion failed for that
	// reason rather than for the one it names.
	if _, err := s.w.ExecContext(ctx, `UPDATE messages SET hidden=1 WHERE id=2`); err != nil {
		t.Fatal(err)
	}
	h, err = s.Health(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if h.Unscannable != 0 {
		t.Errorf("a hidden unscannable row needs no attention either, got %d", h.Unscannable)
	}
}

// A REVERSED consequence must stop truncating the prior-context window.
//
// Escalate already excludes revoked rows, with the reason written beside it: an upheld appeal
// that left somebody one rung higher would be reversible-looking rather than reversible. The
// context window was still being cut off by the reversed consequence — measured at ZERO lines
// of prior context for the next message — and less context is not the safe direction, because
// the window exists so a scam split across innocent lines is visible.
func TestAnUpheldAppealRestoresTheContextWindow(t *testing.T) {
	s, ctx, tick := reviewStore(t)

	for i := 0; i < 3; i++ {
		say(t, s, ctx, "b", fmt.Sprintf("context line number %d", i))
		tick(MinInterval)
	}
	id, err := s.Consequence(ctx, Infraction{IPHash: "ip-b", NetHash: "net-b",
		Kind: KindKick, Reason: ReasonSpam, Duration: time.Minute})
	if err != nil {
		t.Fatal(err)
	}
	tick(2 * time.Minute) // the kick lapses on its own

	// While it stands, the window is deliberately cut at the consequence.
	say(t, s, ctx, "b", "posted while the kick stands")
	pend, err := s.Claim(ctx, 10)
	if err != nil {
		t.Fatal(err)
	}
	standing := -1
	for _, p := range pend {
		if p.Body == "posted while the kick stands" {
			standing = len(p.Prior)
		}
	}
	if standing != 0 {
		t.Fatalf("precondition: a standing consequence should cut the window, got %d lines",
			standing)
	}

	// Now the appeal is upheld.
	if err := s.Revoke(ctx, id, "appeal upheld"); err != nil {
		t.Fatal(err)
	}
	tick(MinInterval)
	say(t, s, ctx, "b", "posted after the appeal was upheld")
	// Reset the claims so the new message is offered.
	if _, err := s.w.ExecContext(ctx,
		`UPDATE messages SET scan_state=?, claimed_at=0`, ScanNew); err != nil {
		t.Fatal(err)
	}
	pend, err = s.Claim(ctx, 20)
	if err != nil {
		t.Fatal(err)
	}
	var prior []string
	for _, p := range pend {
		if p.Body == "posted after the appeal was upheld" {
			prior = p.Prior
		}
	}
	if prior == nil {
		t.Fatal("the new message was not offered to the scanner at all")
	}
	// The property is that the window reaches back PAST the reversed consequence — not
	// merely that it is non-empty. `len(prior) > 0` was the first assertion here and it
	// survived reverting the fix, because the message posted while the kick stood is itself
	// after the consequence and satisfied it on its own.
	reachedBack := false
	for _, line := range prior {
		if line == "context line number 0" {
			reachedBack = true
		}
	}
	if !reachedBack {
		t.Fatalf("after an upheld appeal the window must include the lines from before the "+
			"reversed consequence; got %d lines: %v", len(prior), prior)
	}
}

// A REVOKED CONSEQUENCE STILL KEEPS ITS MESSAGE OUT OF THE REVIEW QUEUE.
//
// The tenth instance of the shape §9's audit tabulates, and the first one that is arguably
// correct — which is why it needs writing down rather than fixing. `sqlAwaitingReview` excludes any
// message an infraction cites:
//
//	AND NOT EXISTS (SELECT 1 FROM infractions WHERE evidence_id = messages.id)
//
// with no `revoked_at IS NULL`, unlike every other place that asks about a consequence. So after an
// operator grants an appeal the message comes back on screen, keeps its non-clean verdict, and is
// in neither `review` nor `review -all`.
//
// Measured, and the state is unambiguous:
//
//	posted                visible, unqueued (not yet scanned)
//	scanner acted          hidden,  unqueued — it earned a consequence
//	operator revoked       VISIBLE, unqueued, verdict still scam
//
// WHY IT IS LEFT THIS WAY. The operator engaged with that exact consequence and reversed it, so
// re-queueing would hand them back the decision they just made. There is no bulk revoke — `unban`
// takes one id — so every revocation is one deliberate act about one message, which is the property
// that makes "they decided" true rather than hopeful. If a bulk reversal is ever added, this stops
// being defensible: five hundred messages would return to view with nobody having looked at any of
// them, and the missing `revoked_at IS NULL` becomes the bug it currently only resembles.
//
// WHAT IS GENUINELY UNEVEN, and worth knowing before choosing `unban` over `dismiss`: the two ways
// a message leaves the queue are not equally visible afterwards. `dismiss` marks it reviewed and
// says so — "see it again with: kourtchatctl review -all" — and it does come back there. A revoke
// removes it from BOTH views with no such affordance. So an operator wanting a record that somebody
// looked should dismiss; unban is for the consequence, not for the queue.
func TestARevokedConsequenceStillClearsTheReviewQueue(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()

	id, err := post(t, s, "orem", "ip-crook", "send me your seed phrase and I will restore it")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.RecordVerdict(ctx, id, "scam"); err != nil {
		t.Fatal(err)
	}
	// Before any consequence it IS a review item — otherwise the assertions below would pass
	// for a queue that never contains anything.
	q, err := s.PendingReview(ctx, false, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(q) != 1 {
		t.Fatalf("precondition: a flagged message with no consequence awaits review, got %d", len(q))
	}

	inf, err := s.Consequence(ctx, Infraction{
		IPHash: "ip-crook", NetHash: "net-crook", Kind: KindKick, Reason: ReasonScam,
		Duration: time.Hour, EvidenceID: id, Evidence: "…seed phrase…",
	})
	if err != nil {
		t.Fatal(err)
	}
	if q, err := s.PendingReview(ctx, false, 50); err != nil {
		t.Fatal(err)
	} else if len(q) != 0 {
		t.Errorf("a message that earned a consequence is not waiting for a human, got %d", len(q))
	}

	*clock = clock.Add(time.Minute)
	if err := s.Revoke(ctx, inf, "operator"); err != nil {
		t.Fatal(err)
	}

	// It is back on screen. That half is unambiguous and is what an upheld appeal means.
	msgs, err := s.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 1 || msgs[0].ID != id {
		t.Fatalf("an upheld appeal must restore the message: got %d visible", len(msgs))
	}

	// And it is in NEITHER queue. Asserted as current behaviour with the reasoning above, so a
	// change here is a decision somebody makes rather than a drift.
	for _, all := range []bool{false, true} {
		q, err := s.PendingReview(ctx, all, 50)
		if err != nil {
			t.Fatal(err)
		}
		if len(q) != 0 {
			t.Errorf("PendingReview(all=%v) returned %d — if a revoked consequence should "+
				"re-queue its message, add `revoked_at IS NULL` to sqlAwaitingReview and "+
				"rewrite this fixture's reasoning with it", all, len(q))
		}
	}

	// THE CONTRAST, measured rather than described: dismiss removes a message from the default
	// queue and keeps it in `review -all`, which is the affordance a revoke does not have.
	id2, err := post(t, s, "orem", "ip-other", "dm me and I will sort out your claim for you")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.RecordVerdict(ctx, id2, "spam"); err != nil {
		t.Fatal(err)
	}
	if err := s.MarkReviewed(ctx, id2); err != nil {
		t.Fatal(err)
	}
	if q, err := s.PendingReview(ctx, false, 50); err != nil {
		t.Fatal(err)
	} else if len(q) != 0 {
		t.Errorf("a dismissed message leaves the default queue, got %d", len(q))
	}
	if q, err := s.PendingReview(ctx, true, 50); err != nil {
		t.Fatal(err)
	} else if len(q) != 1 {
		t.Errorf("but review -all must still show it, got %d — that is the difference between "+
			"dismiss and unban, and the reason to prefer dismiss when the point is the record",
			len(q))
	}
}
