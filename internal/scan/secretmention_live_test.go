package scan

import (
	"context"
	"strings"
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

// THE SAME WALK FOR PLATFORM NAMES: naming one is not pulling anybody to it.
//
// reOffWord matched "telegram" or "whatsapp" anywhere and set a floor of spam — an hour of
// silence, deterministic. Its own comment said "not a finding on its own — plenty of people
// mention Telegram" and then floored it anyway. Seven ordinary sentences out of seven earned it,
// including "the evidence includes a whatsapp screenshot submitted by the claimant": describing
// the evidence in a dispute about a messenger conversation, which is this application's job.
//
// Unlike the secret-phrase case this cost nothing to fix. The model acts on every word-only pull
// at 0.85-0.86, including the skeleton evasion, and comes back clean on every ordinary mention.
// The LINK forms keep their deterministic floor, so `t.me/` is unaffected either way.
func TestLiveNamingAPlatformIsNotPullingToIt(t *testing.T) {
	o := liveClassifier(t)
	ctx := context.Background()
	st, err := chat.Open(t.TempDir() + "/chat.db")
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	clock := time.Unix(1_700_000_000, 0)
	st.Now = func() time.Time { return clock }

	speakers := []struct {
		who, body string
		pull      bool
	}{
		{"dana", "the evidence includes a whatsapp screenshot submitted by the claimant", false},
		{"eli", "their telegram group has the same claim number listed", false},
		{"fern", "i do not use whatsapp, is there another way to reach the answerer", false},
		{"gus", "dm me on telegram @kourthelp", true},
	}
	ids := map[string]int64{}
	for _, s := range speakers {
		// One address each: a consequence must not be able to silence the next speaker and make
		// a later assertion pass for the wrong reason.
		id, err := st.Post(ctx, chat.PostInput{
			Chain: "dev", Court: "orem", Moniker: s.who, Body: s.body,
			IPHash: "ip-" + s.who, NetHash: "net-" + s.who,
		})
		if err != nil {
			t.Fatalf("seeding %s: %v", s.who, err)
		}
		ids[s.who] = id
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
	for _, s := range speakers {
		t.Logf("  %-5s punished=%-5v  %.58q", s.who, punished[ids[s.who]], s.body)
	}

	// ASSERTED: the pull is acted on with no floor behind it. Measured at spam 0.85-0.86 across
	// every word-only form, so a capability rather than a judgement call.
	if !punished[ids["gus"]] {
		t.Errorf("a word-only off-platform pull must still earn a consequence — if this fails, " +
			"demoting reOffWord gave up more than the measurements said")
	}
	// LOGGED, not failed: the model's read of one sentence is not a contract.
	for _, s := range speakers {
		if !s.pull && punished[ids[s.who]] {
			t.Logf("NOTE: %q was punished for NAMING a platform. The prefilter no longer floors "+
				"a bare word, so this came from the model — re-measure before trusting "+
				"reOffWord's header.", s.body)
		}
	}
	// And an untouched speaker must still be able to post.
	for _, s := range speakers {
		if s.pull || punished[ids[s.who]] {
			continue
		}
		if _, err := st.Post(ctx, chat.PostInput{
			Chain: "dev", Court: "orem", Moniker: s.who, Body: "a second, ordinary message",
			IPHash: "ip-" + s.who, NetHash: "net-" + s.who,
		}); err != nil {
			t.Errorf("%s was not punished and must still be able to post: %v", s.who, err)
		}
		clock = clock.Add(chat.MinInterval)
	}
}

// AND THE COURT'S OWN CORE FLOW: submitting evidence about a scam must not be punished.
//
// §7 says quoting a scam link "is not the harm", and that was not implemented — the alarm shapes
// covered "heads up" and "beware" but nothing a person writes when filing evidence. Measured, the
// model acts on every way of quoting a link (scam 0.95, spam 0.86, scam 0.86), so this could not
// be fixed by demoting the link floor; only the carve-out reaches it.
//
// The lure is in the same run on purpose. The carve-out suppresses ALL consequences, so widening
// it is only safe if a lure without those phrases still earns one.
func TestLiveSubmittingEvidenceIsNotPunished(t *testing.T) {
	o := liveClassifier(t)
	ctx := context.Background()
	st, err := chat.Open(t.TempDir() + "/chat.db")
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	clock := time.Unix(1_700_000_000, 0)
	st.Now = func() time.Time { return clock }

	speakers := []struct {
		who, body string
		lure      bool
	}{
		{"hana", "the scam link was t.me/fakegnot, for the record", false},
		{"ivan", "the evidence is a message linking to t.me/fakegnot", false},
		{"jo", "the evidence shows they asked for a recovery phrase", false},
		{"kai", "dm me on t.me/kourtsupport", true},
	}
	ids := map[string]int64{}
	for _, s := range speakers {
		id, err := st.Post(ctx, chat.PostInput{
			Chain: "dev", Court: "orem", Moniker: s.who, Body: s.body,
			IPHash: "ip-" + s.who, NetHash: "net-" + s.who,
		})
		if err != nil {
			t.Fatalf("seeding %s: %v", s.who, err)
		}
		ids[s.who] = id
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
	for _, s := range speakers {
		t.Logf("  %-5s punished=%-5v  %.56q", s.who, punished[ids[s.who]], s.body)
	}

	// Both directions are asserted here rather than logged, because neither depends on the
	// model's judgement: the carve-out suppresses regardless of the verdict, and the lure has no
	// carve-out phrase to hide behind.
	for _, s := range speakers {
		if !s.lure && punished[ids[s.who]] {
			t.Errorf("filing evidence must not earn a consequence: %q", s.body)
		}
	}
	if !punished[ids["kai"]] {
		t.Errorf("a lure with no reporting phrase must still earn one, or widening the " +
			"carve-out has cost more than the phrases it added")
	}
}

// AND THE DISCLOSURE BRANCH AGAINST THE REAL MODEL, which will call a pasted recovery phrase a
// scam. The unit arms use a fake clean verdict to isolate the deterministic layer; this confirms
// the branch still wins when gemma3:4b asks for a consequence.
//
// §7 said a disclosed secret "goes out of sight whoever posted it, and nobody is punished for it".
// The hide used to sit inside the reporting branch, so an unframed disclosure — including
// "help, is this phrase still valid: <phrase>" — earned a 24-hour timeout instead.
func TestLiveADisclosedPhraseIsNotPunishedEvenWhenTheModelSaysScam(t *testing.T) {
	o := liveClassifier(t)
	ctx := context.Background()
	st, err := chat.Open(t.TempDir() + "/chat.db")
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	clock := time.Unix(1_700_000_000, 0)
	st.Now = func() time.Time { return clock }

	phrase := validPhrases["zero12"]
	speakers := []struct {
		who, body string
		lure      bool
	}{
		{"lena", "help, is this phrase still valid: " + phrase, false},
		{"milo", phrase, false},
		{"nadia", "send me your seed phrase and i will restore your wallet", true},
	}
	ids := map[string]int64{}
	for _, s := range speakers {
		id, err := st.Post(ctx, chat.PostInput{
			Chain: "dev", Court: "orem", Moniker: s.who, Body: s.body,
			IPHash: "ip-" + s.who, NetHash: "net-" + s.who,
		})
		if err != nil {
			t.Fatalf("seeding %s: %v", s.who, err)
		}
		ids[s.who] = id
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
	for _, s := range speakers {
		t.Logf("  %-6s punished=%-5v  %.50q", s.who, punished[ids[s.who]], s.body)
	}

	// Both directions asserted: neither depends on the verdict. The disclosure branch suppresses
	// whatever the model said, and the lure has no phrase to shelter behind.
	for _, s := range speakers {
		if !s.lure && punished[ids[s.who]] {
			t.Errorf("a disclosure must not be punished even when the model calls it scam: %q",
				s.body)
		}
	}
	if !punished[ids["nadia"]] {
		t.Error("a lure carrying no phrase must still earn a consequence")
	}
	// The phrases must be gone from the room, which is what makes not punishing safe.
	msgs, err := st.Recent(ctx, "dev", "orem", 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range msgs {
		if strings.Contains(m.Body, "abandon") {
			t.Errorf("a disclosed phrase is still readable in the room: %q", m.Body)
		}
	}
	// And the disclosers, not being punished, must still be able to post.
	for _, who := range []string{"lena", "milo"} {
		if _, err := st.Post(ctx, chat.PostInput{
			Chain: "dev", Court: "orem", Moniker: who, Body: "a second, ordinary message",
			IPHash: "ip-" + who, NetHash: "net-" + who,
		}); err != nil {
			t.Errorf("%s was not punished and must still be able to post: %v", who, err)
		}
		clock = clock.Add(chat.MinInterval)
	}
}
