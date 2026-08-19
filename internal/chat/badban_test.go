package chat

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"
)

// A BAD BAN, FROM THE OPERATOR'S SIDE.
//
// Every other fixture here asks whether the guilty are caught. This one asks what happens to
// somebody who did nothing, because that is the failure with a person on the other end of it: a
// wrongly banned user cannot post to appeal, and the operator has to work out what was done, what
// it took down, and how to give it back — from the CLI, after the fact, with only an ip_hash.
//
// The walk is deliberately end-to-end rather than per-method. Each step below is a surface the
// operator actually reads (`status`, `list`, `why`, `unban`) and the bug this class of fixture
// exists to catch lives BETWEEN them: a reversal that clears the status but leaves the messages
// hidden, or restores the messages but leaves the address unable to speak, passes every
// single-method test and is still a person locked out.
func TestTheOperatorsViewOfABadBan(t *testing.T) {
	s, clock := newStore(t)
	ctx := context.Background()

	say := func(ip, body string) (int64, error) {
		return s.Post(ctx, PostInput{Chain: "dev", Court: "orem", Moniker: ip,
			Body: body, IPHash: "ip-" + ip, NetHash: "net-" + strings.Split(ip, "/")[0]})
	}

	// An ordinary room. `victim` and `roommate` share a network — a household, an office, a
	// university — which is the case a manual ban is aimed at and the case it over-reaches in.
	var victimMsgs []int64
	for i := 0; i < 3; i++ {
		for _, who := range []string{"shared/victim", "shared/roommate", "elsewhere/bystander"} {
			id, err := say(who, fmt.Sprintf("%s, message %d about the docket ordering", who, i))
			if err != nil {
				t.Fatalf("the room must be ordinary before anything goes wrong: %v", err)
			}
			if who == "shared/victim" {
				victimMsgs = append(victimMsgs, id)
			}
		}
		*clock = clock.Add(MinInterval + time.Second)
	}

	// The operator bans the wrong person. Manual, so it may be a ban at all, and manual is also
	// what makes it match the whole network.
	banID, err := s.Consequence(ctx, Infraction{
		IPHash: "ip-shared/victim", NetHash: "net-shared",
		Kind: KindBan, Reason: ReasonManual,
		EvidenceID: victimMsgs[len(victimMsgs)-1],
		Evidence:   "shared/victim, message 2 about the docket ordering",
		Detail:     "misread as a lure",
	})
	if err != nil {
		t.Fatal(err)
	}

	// ── WHAT THE OPERATOR SEES ──────────────────────────────────────────────────────────────
	for _, who := range []string{"shared/victim", "shared/roommate", "elsewhere/bystander"} {
		st, err := s.Status(ctx, "ip-"+who, "net-"+strings.Split(who, "/")[0])
		if err != nil {
			t.Fatal(err)
		}
		t.Logf("status %-20s %s", who, st.State)
	}
	msgs, err := s.Recent(ctx, "dev", "orem", 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	byWho := map[string]int{}
	for _, m := range msgs {
		byWho[m.Moniker]++
	}
	t.Logf("visible after the ban: victim %d/3, roommate %d/3, bystander %d/3",
		byWho["shared/victim"], byWho["shared/roommate"], byWho["elsewhere/bystander"])

	// THE COLLATERAL, asserted because it is the operator's actual problem and it is easy to
	// miss: a manual consequence matches net_hash, so the roommate cannot speak either.
	if _, err := say("shared/roommate", "wait, why can I not post"); err == nil {
		t.Error("a manual ban matches the network, so the roommate must be blocked too — " +
			"if this stopped being true, §2's net_hash rule changed")
	}
	// But hiding keys on ip_hash ALONE, so the roommate's messages are still on screen. The
	// asymmetry is deliberate — they wrote nothing wrong — and it is what the operator sees:
	// a silenced person whose words are all still there.
	if byWho["shared/roommate"] != 3 {
		t.Errorf("the roommate wrote nothing bad, so their messages stay visible: %d of 3",
			byWho["shared/roommate"])
	}
	if byWho["elsewhere/bystander"] != 3 {
		t.Errorf("an unrelated address must be untouched in both respects: %d of 3",
			byWho["elsewhere/bystander"])
	}
	if _, err := say("elsewhere/bystander", "carrying on as before"); err != nil {
		t.Errorf("and must still be able to post: %v", err)
	}

	// `why` must give the operator enough to undo it: the evidence copy, and who it hit.
	rows, err := s.ListInfractions(ctx, "", true, 50)
	if err != nil {
		t.Fatal(err)
	}
	var row InfractionRow
	for _, r := range rows {
		if r.ID == banID {
			row = r
		}
	}
	if row.ID == 0 {
		t.Fatal("the ban must be findable by id or `why` cannot answer")
	}
	if row.Evidence == "" || row.Detail == "" {
		t.Errorf("`why` must show what it was based on: evidence %q, finding %q",
			row.Evidence, row.Detail)
	}
	if row.ExpiresAt != 0 {
		t.Errorf("a ban does not expire, so nothing frees this person but the operator: %d",
			row.ExpiresAt)
	}
	if row.RevokedAt != 0 {
		t.Error("it is in force")
	}

	// ── THE REVERSAL, AND WHETHER IT ACTUALLY GIVES ANYTHING BACK ────────────────────────────
	if err := s.Revoke(ctx, banID, "operator"); err != nil {
		t.Fatal(err)
	}

	// Both people can speak. This is the assertion that a status-only reversal passes and a
	// real one has to earn.
	for _, who := range []string{"shared/victim", "shared/roommate"} {
		st, err := s.Status(ctx, "ip-"+who, "net-shared")
		if err != nil {
			t.Fatal(err)
		}
		if st.State != "ok" {
			t.Errorf("%s must be clear after the reversal, got %q", who, st.State)
		}
		if _, err := say(who, fmt.Sprintf("%s, back and posting again", who)); err != nil {
			t.Errorf("%s must be able to POST, not merely read as ok: %v", who, err)
		}
	}
	// And their words are back on screen.
	msgs, err = s.Recent(ctx, "dev", "orem", 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	byWho = map[string]int{}
	for _, m := range msgs {
		byWho[m.Moniker]++
	}
	if byWho["shared/victim"] != 4 {
		t.Errorf("the reversal must un-hide what the ban hid: victim has %d of 4 visible",
			byWho["shared/victim"])
	}

	// The RECORD stays, reversed rather than erased — an operator who deletes their mistakes
	// leaves the next operator unable to see that anything happened.
	rows, err = s.ListInfractions(ctx, "", true, 50)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, r := range rows {
		if r.ID == banID {
			found = true
			if r.RevokedAt == 0 || r.RevokedBy != "operator" {
				t.Errorf("the reversal must be on the record: revoked_at %d by %q",
					r.RevokedAt, r.RevokedBy)
			}
			if r.Evidence == "" {
				t.Error("and the evidence must survive it, or the appeal cannot be reviewed")
			}
		}
	}
	if !found {
		t.Error("the row must be kept, not deleted")
	}

	// FINALLY: the wrongly banned person is not one rung up the ladder. A reversal that leaves
	// them pre-escalated is reversible-looking rather than reversible — and a manual
	// consequence never counted toward the ladder in the first place, so this holds twice.
	next, err := s.Escalate(ctx, "ip-shared/victim")
	if err != nil {
		t.Fatal(err)
	}
	if next != Ladder[0] {
		t.Errorf("a cleared person starts at the bottom of the ladder: got %s, want %s",
			next, Ladder[0])
	}
}
