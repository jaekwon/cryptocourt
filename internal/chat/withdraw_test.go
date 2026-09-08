package chat

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// /delete — TAKE BACK THE MESSAGE YOU JUST SENT.
//
// The rule is "the newest VISIBLE row in the room, if it is yours and said
// within WithdrawWindow", and each arm below is one clause of that.
//
// IT USED TO READ THE NEWEST ROW OF ANY KIND, which made a tombstone block the
// message beneath it: after taking back one line you could never take back the
// one before. Reported three times; the third time with the rows in hand.
//
// WHAT THAT OLD READING WAS REALLY PROTECTING IS STILL PROTECTED, by two bounds
// rather than by accident. The newest visible row must be YOURS, so somebody
// else's line ends the run and this can never reach behind another person's
// message to leave their reply answering nothing; and the window means "take
// back what I just said" cannot become "edit the record". The griefing case —
// one message per command, all the way back through a transcript — is
// impossible in both directions.

func withdrawReq(court, ip string) *http.Request {
	return sayReq(court, ip, WithdrawCommand)
}

func sayReq(court, ip, body string) *http.Request {
	r := httptest.NewRequest(http.MethodPost, "/api/chat/dev/"+court,
		strings.NewReader(`{"moniker":"anon","body":`+jsonString(body)+`}`))
	r.Header.Set("Content-Type", "application/json")
	r.RemoteAddr = ip + ":1234"
	return r
}

func jsonString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"', '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case '\n':
			b.WriteString(`\n`)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

func visibleBodies(t *testing.T, s *Store, court string) []string {
	t.Helper()
	ms, err := s.Recent(context.Background(), "dev", court, 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	out := []string{}
	for _, m := range ms {
		out = append(out, m.Body)
	}
	return out
}

func TestDeleteTakesBackYourOwnLastMessage(t *testing.T) {
	srv, s, clock := newServer(t)
	say := func(ip, body string) {
		if rec := do(t, srv, sayReq("orem", ip, body)); rec.Code != http.StatusOK {
			t.Fatalf("post %q: %d %s", body, rec.Code, rec.Body.String())
		}
		*clock = clock.Add(3 * time.Second) // past MinInterval
	}
	say("192.0.2.1", "first from A")
	say("192.0.2.2", "then from B")

	// NOT SOMEBODY ELSE'S. A types /delete while B's message is newest: nothing
	// goes. Everybody in that room is "anon", so ip_hash is the only identity
	// there is — and hiding another person's words is a moderator's business,
	// with an infractions trail and an appeal route behind it.
	rec := do(t, srv, withdrawReq("orem", "192.0.2.1"))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"deleted":0`) {
		t.Fatalf("A should not be able to withdraw B's message: %d %s", rec.Code, rec.Body.String())
	}
	if got := visibleBodies(t, s, "orem"); len(got) != 2 {
		t.Fatalf("nothing should have gone: %v", got)
	}

	// YOUR OWN NEWEST, THOUGH, GOES.
	rec = do(t, srv, withdrawReq("orem", "192.0.2.2"))
	if !strings.Contains(rec.Body.String(), `"deleted":`) ||
		strings.Contains(rec.Body.String(), `"deleted":0`) {
		t.Fatalf("B should be able to withdraw their own: %s", rec.Body.String())
	}
	got := visibleBodies(t, s, "orem")
	if len(got) != 1 || got[0] != "first from A" {
		t.Fatalf("only B's message should have gone: %v", got)
	}

	/* AND IT STOPS AT SOMEBODY ELSE'S WORDS. B's own line is gone, so the newest
	   visible row is now A's — and B's second /delete finds a row that is not
	   theirs and refuses. This assertion is unchanged from when the rule read the
	   newest row of ANY kind, but the reason it holds is different and is the
	   reason that matters: what stops a walk backwards is the other person, not a
	   tombstone. A run of B's OWN trailing messages CAN now be taken back one at
	   a time, which is the next arm. */
	rec = do(t, srv, withdrawReq("orem", "192.0.2.2"))
	if !strings.Contains(rec.Body.String(), `"deleted":0`) {
		t.Fatalf("a second /delete must do nothing: %s", rec.Body.String())
	}
	if got := visibleBodies(t, s, "orem"); len(got) != 1 || got[0] != "first from A" {
		t.Fatalf("the second /delete cascaded: %v", got)
	}
}

/*
A TOMBSTONE MUST NOT BLOCK THE MESSAGE UNDER IT, which is the report this rule

	changed for. Measured on the live site: rows 147 (visible, the author's), 148
	and 149 (the same author's, already withdrawn), and /delete refused because
	149 was newest. The author's own visible last line was undeletable.

	THREE OF YOUR OWN IN A ROW, taken back newest-first, with nobody else in the
	room — the exact shape that was stuck. Each command removes exactly one, and
	the fourth has nothing left to take.
*/
func TestATombstoneDoesNotBlockYourOwnMessageBeneathIt(t *testing.T) {
	srv, s, clock := newServer(t)
	say := func(body string) {
		if rec := do(t, srv, sayReq("orem", "192.0.2.7", body)); rec.Code != http.StatusOK {
			t.Fatalf("post %q: %d %s", body, rec.Code, rec.Body.String())
		}
		*clock = clock.Add(3 * time.Second)
	}
	say("this is a test of the chat bot system.")
	say("please respond.")
	say("this is a test of the chatbot system")

	for i, want := range []int{2, 1, 0} {
		rec := do(t, srv, withdrawReq("orem", "192.0.2.7"))
		if strings.Contains(rec.Body.String(), `"deleted":0`) {
			t.Fatalf("/delete %d of 3 refused: %s", i+1, rec.Body.String())
		}
		if got := visibleBodies(t, s, "orem"); len(got) != want {
			t.Fatalf("after /delete %d, %d visible, want %d: %v", i+1, len(got), want, got)
		}
	}
	if rec := do(t, srv, withdrawReq("orem", "192.0.2.7")); !strings.Contains(rec.Body.String(), `"deleted":0`) {
		t.Errorf("a fourth /delete has nothing to take: %s", rec.Body.String())
	}
}

// AND ONLY WHAT WAS SAID RECENTLY. The window is the other bound: it is what
// keeps this an undo rather than a way to go back through an old thread and
// remove your side of it. Driven with the fake clock, one second either side of
// WithdrawWindow, so the arm is about the boundary and not about a round number.
func TestDeleteWillNotReachPastTheWindow(t *testing.T) {
	srv, s, clock := newServer(t)
	if rec := do(t, srv, sayReq("orem", "192.0.2.8", "said a while ago")); rec.Code != http.StatusOK {
		t.Fatal(rec.Body.String())
	}

	*clock = clock.Add(WithdrawWindow + time.Second)
	if rec := do(t, srv, withdrawReq("orem", "192.0.2.8")); !strings.Contains(rec.Body.String(), `"deleted":0`) {
		t.Errorf("past the window it must refuse: %s", rec.Body.String())
	}
	if got := visibleBodies(t, s, "orem"); len(got) != 1 {
		t.Fatalf("nothing should have gone: %v", got)
	}

	// The control: the same message, the same room, one second INSIDE the window.
	srv2, s2, clock2 := newServer(t)
	if rec := do(t, srv2, sayReq("orem", "192.0.2.8", "said a moment ago")); rec.Code != http.StatusOK {
		t.Fatal(rec.Body.String())
	}
	*clock2 = clock2.Add(WithdrawWindow - time.Second)
	if rec := do(t, srv2, withdrawReq("orem", "192.0.2.8")); strings.Contains(rec.Body.String(), `"deleted":0`) {
		t.Errorf("inside the window it must go: %s", rec.Body.String())
	}
	if got := visibleBodies(t, s2, "orem"); len(got) != 0 {
		t.Fatalf("it should have gone: %v", got)
	}
}

// THE COMMAND IS EXACT, and a sentence about deleting stays a message. Somebody
// who types "/delete this please" has said something, and swallowing it would
// look like the chat had eaten their words.
func TestDeleteIsExactAndASentenceIsStillAMessage(t *testing.T) {
	srv, s, clock := newServer(t)
	for _, body := range []string{
		"/delete this please", "please /delete", "/deleted", "//delete", "delete",
	} {
		if rec := do(t, srv, sayReq("orem", "192.0.2.9", body)); rec.Code != http.StatusOK {
			t.Fatalf("%q should post as an ordinary message: %d", body, rec.Code)
		}
		*clock = clock.Add(3 * time.Second)
	}
	if got := visibleBodies(t, s, "orem"); len(got) != 5 {
		t.Fatalf("all five should be ordinary messages: %v", got)
	}
	// ...and the real command, however it is typed or spaced, is not.
	for _, cmd := range []string{"/delete", "  /delete  ", "/DELETE", "/Delete"} {
		if !isWithdrawCommand(cmd) {
			t.Errorf("%q should be the command", cmd)
		}
	}
	for _, no := range []string{"/delete x", "x /delete", "/deletex", ""} {
		if isWithdrawCommand(no) {
			t.Errorf("%q should NOT be the command", no)
		}
	}
}

// AN EMPTY ROOM, AND A ROOM WHOSE NEWEST MESSAGE A MODERATOR HAS HIDDEN. Neither
// is an error, and neither may be converted into a withdrawal.
func TestDeleteRefusesWhatItCannotTakeBack(t *testing.T) {
	srv, s, clock := newServer(t)
	ctx := context.Background()

	if rec := do(t, srv, withdrawReq("orem", "192.0.2.1")); !strings.Contains(rec.Body.String(), `"deleted":0`) {
		t.Errorf("an empty room withdraws nothing: %s", rec.Body.String())
	}

	if rec := do(t, srv, sayReq("orem", "192.0.2.1", "something a moderator hid")); rec.Code != http.StatusOK {
		t.Fatal(rec.Body.String())
	}
	*clock = clock.Add(3 * time.Second)
	ms, _ := s.Recent(ctx, "dev", "orem", 0, 50)
	if err := s.HideMessage(ctx, ms[len(ms)-1].ID); err != nil {
		t.Fatal(err)
	}
	// The author cannot re-label a moderator's hide as their own withdrawal —
	// which would matter if the two were ever treated differently on appeal.
	if rec := do(t, srv, withdrawReq("orem", "192.0.2.1")); !strings.Contains(rec.Body.String(), `"deleted":0`) {
		t.Errorf("a hidden newest message is not withdrawable: %s", rec.Body.String())
	}
}

/*
AN APPEAL MUST NOT PUT WITHDRAWN WORDS BACK IN THE ROOM.

	Revoke RECOMPUTES hidden from the consequences still standing, and its CASE
	preserved only hidden=2. A withdrawal is hidden=3, so without that value in
	the CASE an unrelated appeal — somebody else's kick being reversed — would
	have republished it. The same class of bug the hidden=2 comment records
	having been measured once already.
*/
func TestAnAppealDoesNotUndoAWithdrawal(t *testing.T) {
	srv, s, clock := newServer(t)
	ctx := context.Background()

	if rec := do(t, srv, sayReq("orem", "192.0.2.1", "words I took back")); rec.Code != http.StatusOK {
		t.Fatal(rec.Body.String())
	}
	*clock = clock.Add(3 * time.Second)
	if rec := do(t, srv, withdrawReq("orem", "192.0.2.1")); strings.Contains(rec.Body.String(), `"deleted":0`) {
		t.Fatalf("the withdrawal did not happen: %s", rec.Body.String())
	}
	if got := visibleBodies(t, s, "orem"); len(got) != 0 {
		t.Fatalf("it should be gone: %v", got)
	}

	// A consequence against that same address, then reversed — the recompute.
	ipHash := srv.Hasher.Hash(mustAddr(t, "192.0.2.1"))
	ref, err := s.Consequence(ctx, Infraction{
		IPHash: ipHash, Kind: KindKick, Reason: ReasonSpam, Duration: time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Revoke(ctx, ref, "operator"); err != nil {
		t.Fatal(err)
	}
	if got := visibleBodies(t, s, "orem"); len(got) != 0 {
		t.Fatalf("an appeal republished a withdrawal: %v", got)
	}
}

/*
AND THE SAME HOLE WAS ALREADY THERE FOR DISCLOSED SECRETS, which is a bug this

	work found rather than caused.
	Consequence hid every message in its window with an unconditional SET
	hidden=1, so it relabelled a secret (2) as an ordinary punishment, and
	Revoke's recompute then set it to 0. MEASURED against the code as it stood
	before this pass: hide a secret, take an unrelated kick against the same
	address, reverse the kick — and the secret was public again. The probe put a
	seed phrase back in the room.
	THE EXISTING TEST COULD NOT SEE IT because it takes the consequence first and
	the secret second; the clobber needs the secret to exist already. Ordering is
	the whole bug, so the ordering is the test.
*/
func TestAConsequenceDoesNotRelabelADisclosedSecret(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()

	id, err := post(t, s, "orem", "ip-a", "my seed phrase is hunter2 obviously")
	if err != nil {
		t.Fatal(err)
	}
	if err := s.HideMessage(ctx, id); err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(time.Second)

	// SECRET FIRST, CONSEQUENCE SECOND. The other way round and the clobber has
	// nothing to clobber.
	ref, err := s.Consequence(ctx, Infraction{IPHash: "ip-a", Kind: KindKick,
		Reason: ReasonSpam, Duration: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Revoke(ctx, ref, "appeal upheld"); err != nil {
		t.Fatal(err)
	}

	if got := visibleBodies(t, s, "orem"); len(got) != 0 {
		t.Errorf("an appeal republished a disclosed secret: %v — a secret was "+
			"never a punishment, so reversing one is not a reason to publish it", got)
	}
}
