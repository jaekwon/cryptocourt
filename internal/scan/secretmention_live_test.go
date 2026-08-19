package scan

import (
	"context"
	"testing"
	"time"

	"github.com/jaekwon/kourt/internal/chat"
)

// END TO END, WITH THE REAL MODEL: saying the words must not be punished; asking must be.
//
// A bare mention of a seed phrase used to set a deterministic floor of scam — a 24-hour first
// offence with no model in the loop, earned by all eight of the ordinary sentences in
// prefilter_test.go. It is a note now, and the model decides. This is the walk that shows the
// two halves of that trade in one run.
//
// What is ASSERTED is structural: the lure earns a consequence, and each ordinary speaker is a
// BYSTANDER who must still be able to post afterwards. What is LOGGED is the model's judgement,
// following dilution_test.go — a test that fails because a 4B model said clean instead of scam
// about one sentence teaches nothing, and the numbers are what a future reader needs.
func TestLiveSayingTheWordsIsNotAskingForThem(t *testing.T) {
	o := liveClassifier(t)
	ctx := context.Background()
	st, err := chat.Open(t.TempDir() + "/chat.db")
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	clock := time.Unix(1_700_000_000, 0)
	st.Now = func() time.Time { return clock }

	type msg struct {
		who, ip, body string
		lure          bool
	}
	msgs := []msg{
		{"alice", "ip-alice", "never share your seed phrase with anyone, not even a moderator", false},
		{"bob", "ip-bob", "the claim about the private key dispute in court seven is still open", false},
		{"carol", "ip-carol", "a seed phrase is twelve or twenty four words, for anyone wondering", false},
		{"crook", "ip-crook", "send me your seed phrase and i will restore your wallet", true},
	}
	ids := map[string]int64{}
	for _, m := range msgs {
		// Each from its own address, so one consequence cannot silence the next speaker and
		// make a later assertion pass for the wrong reason.
		id, err := st.Post(ctx, chat.PostInput{
			Chain: "dev", Court: "orem", Moniker: m.who, Body: m.body,
			IPHash: m.ip, NetHash: "net-" + m.ip,
		})
		if err != nil {
			t.Fatalf("seeding %s: %v", m.who, err)
		}
		ids[m.who] = id
		clock = clock.Add(chat.MinInterval)
	}

	sc := &Scanner{Store: st, Cls: o, Enforce: true, Batch: 10}
	if _, err := sc.Tick(ctx); err != nil {
		t.Fatal(err)
	}

	rows, err := st.ListInfractions(ctx, "", true, 50)
	if err != nil {
		t.Fatal(err)
	}
	punished := map[int64]bool{}
	for _, r := range rows {
		punished[r.EvidenceID] = true
	}
	for _, m := range msgs {
		id := ids[m.who]
		t.Logf("  %-6s punished=%-5v  %.56q", m.who, punished[id], m.body)
	}

	// THE ASSERTION: the ask is acted on. Measured at scam 0.95-1.00 across every probe, with
	// and without the prefilter's help, so this is a capability rather than a judgement call.
	if !punished[ids["crook"]] {
		t.Errorf("the ask must still earn a consequence with no floor behind it — if this fails, " +
			"demoting the mention to a note gave up more than the measurements said it would")
	}

	// AND THE BYSTANDERS. Logged loudly rather than failed, because the model's opinion of one
	// sentence is not a contract — but if this ever prints, the trade has stopped paying.
	for _, m := range msgs {
		if !m.lure && punished[ids[m.who]] {
			t.Logf("NOTE: %q was punished for SAYING the words. The prefilter no longer floors "+
				"a mention, so this came from the model — re-measure before trusting either "+
				"this file's header or reSecretMention's.", m.body)
		}
	}

	// Whatever the verdicts were, an untouched speaker must still be able to post. This is the
	// rule that caught the /24 collateral bug: the consequence has to land on one address.
	for _, who := range []string{"alice", "bob", "carol"} {
		if punished[ids[who]] {
			continue // already reported above; posting is legitimately blocked
		}
		if _, err := st.Post(ctx, chat.PostInput{
			Chain: "dev", Court: "orem", Moniker: who, Body: "a second, ordinary message",
			IPHash: "ip-" + who, NetHash: "net-ip-" + who,
		}); err != nil {
			t.Errorf("%s was not punished and must still be able to post: %v", who, err)
		}
		clock = clock.Add(chat.MinInterval)
	}
}
