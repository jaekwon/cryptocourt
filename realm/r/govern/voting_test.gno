package govern

import (
	governor "gno.land/p/kourt/governor/v0"
	"strconv"
	"testing"

	testutils "gno.land/p/nt/testutils/v0"
	uassert "gno.land/p/nt/uassert/v0"
)

var (
	vA = testutils.TestAddress("v-a")
	vB = testutils.TestAddress("v-b")
)

// Voting once means once, and moving the tokens afterwards does not buy
// another go.
//
// This is the oldest attack on token voting: vote, send the balance to a fresh
// address, vote again. It is stopped by the same snapshot that stops a
// borrowed balance, but by a different part of it — the recipient's weight at
// the snapshot was zero because they did not hold the tokens THEN, whatever
// they hold now.
func TestAVoteCannotBePassedAlongWithTheTokens(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = vA
	quiet := testutils.TestAddress("v-quiet")
	testing.SetRealm(testing.NewUserRealm(vA))
	Mint(cross(cur), vA, 100)
	// A large holder who never votes, so vA's vote is never decisive and the
	// proposal stays open. Otherwise it closes on the arithmetic the moment
	// the only holder votes, and the second attempt is refused for being late
	// rather than for being a second attempt.
	Mint(cross(cur), quiet, 900)
	advanceEpochs(1)

	engine.Adopt(setFee{name: "v/kind"}, Rules{
		QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 100000, GraceBlocks: 1_000_000,
	})
	testing.SetRealm(testing.NewUserRealm(vA))
	id := Propose(cross(cur), "v/kind", "1", "vote once")
	Vote(cross(cur), id, "yes")

	yes, _, _, _ := Tally(id)
	if yes != 100 {
		t.Fatalf("first vote counted %d, want 100", yes)
	}

	// The same address cannot vote again, whatever it does in between.
	uassert.AbortsContains(t, cur, "already voted", func() {
		Vote(cross(cur), id, "no")
	})

	// Nor can it hand the ballot on with the balance.
	Transfer(cross(cur), vB, 100)
	testing.SetRealm(testing.NewUserRealm(vB))
	uassert.AbortsContains(t, cur, "no voting power at that epoch", func() {
		Vote(cross(cur), id, "no")
	})

	yes, no, _, _ := Tally(id)
	if yes != 100 || no != 0 {
		t.Fatalf("tally is %d/%d after the tokens moved, want 100/0 — a vote "+
			"already cast is not undone by selling, and the buyer does not "+
			"inherit it", yes, no)
	}
}

// A choice is one of three words.
func TestAVoteMustBeOneOfThreeThings(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = vA
	testing.SetRealm(testing.NewUserRealm(vA))
	Mint(cross(cur), vA, 100)
	advanceEpochs(1)

	engine.Adopt(setFee{name: "v/kind"}, Rules{
		QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: 100000, GraceBlocks: 1_000_000,
	})
	testing.SetRealm(testing.NewUserRealm(vA))
	id := Propose(cross(cur), "v/kind", "2", "choices")

	for _, bad := range []string{"", "YES", "yes ", "maybe", "1"} {
		uassert.AbortsContains(t, cur, "yes, no or abstain", func() {
			Vote(cross(cur), id, bad)
	})
	}
	// And a rejected choice did not consume the ballot.
	Vote(cross(cur), id, "abstain")
	_, _, ab, _ := Tally(id)
	if ab != 100 {
		t.Errorf("abstain counted %d, want 100 — a refused choice must not "+
			"have spent the vote", ab)
	}
}

// Sending tokens to yourself is a no-op, not a way to double your balance or
// your say.
//
// Worth a test because the two sides of a transfer are the same record here,
// so the credit and the debit alias — and an implementation that read the
// balance twice, or credited before debiting, would quietly mint.
func TestSendingToYourselfChangesNothing(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = vA
	testing.SetRealm(testing.NewUserRealm(vA))
	Mint(cross(cur), vA, 500)

	testing.SetRealm(testing.NewUserRealm(vA))
	Transfer(cross(cur), vA, 500) // the whole balance, to itself

	if got := BalanceOf(vA); got != 500 {
		t.Fatalf("balance = %d after sending everything to itself, want 500", got)
	}
	if got := VotesOf(vA); got != 500 {
		t.Fatalf("votes = %d, want 500", got)
	}
	if got := TotalSupply(); got != 500 {
		t.Fatalf("supply = %d, want 500", got)
	}
	// And more than it holds is still refused, even to itself.
	uassert.AbortsContains(t, cur, "insufficient balance", func() {
		Transfer(cross(cur), vA, 501)
	})
}

// The open list must not be exhaustible.
//
// settle runs inside reads as well as writes, and a read does not persist — so
// State() will tell you a proposal is defeated and tell you again tomorrow,
// because the transition it computed went away with the query. Only a
// transaction records it. Without something that does, filling every slot with
// proposals that will lose blocks the governor permanently.
func TestFinishedProposalsGiveTheirSlotsBack(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = vA
	quiet := testutils.TestAddress("s-quiet")
	testing.SetRealm(testing.NewUserRealm(vA))
	Mint(cross(cur), vA, 10)
	Mint(cross(cur), quiet, 990) // so nothing vA does is ever decisive
	advanceEpochs(1)

	engine.Adopt(setFee{name: "s/kind"}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 50, GraceBlocks: 1_000_000,
	})

	testing.SetRealm(testing.NewUserRealm(vA))
	var ids []int64
	for i := 0; i < governor.MaxOpen; i++ {
		ids = append(ids, Propose(cross(cur), "s/kind", strconv.Itoa(i), "filler"))
	}
	if engine.OpenSlots() != governor.MaxOpen {
		t.Fatalf("%d slots taken, want %d", engine.OpenSlots(), governor.MaxOpen)
	}
	uassert.AbortsContains(t, cur, "too many proposals", func() {
		Propose(cross(cur), "s/kind", "9999", "blocked")
	})

	// Every one of them is now past its deadline and unwinnable.
	advanceBlocks(1000)

	// Proposing must work again, and NOTHING may be read first.
	//
	// In a test, settle-inside-a-read does persist — the harness is not a
	// query — so calling State() here frees the slots itself and the sweep is
	// never exercised. A test that reads first passes with the sweep deleted.
	id := Propose(cross(cur), "s/kind", "8888", "unblocked")
	if got := State(id); got != "active" {
		t.Fatalf("the new proposal is %q", got)
	}
	if got := State(ids[0]); got != "defeated" {
		t.Fatalf("the filler reads %q, want defeated", got)
	}

	// Settle does it explicitly too, for anyone who would rather not wait for
	// a proposer to need the room.
	//
	// On one that is still HOLDING a slot. The Propose above swept, and which
	// proposals that reached is the sweep's business — settling one it already
	// freed would assert nothing and fail for the wrong reason.
	var held int64 = -1
	for _, cand := range ids {
		if StoredState(cand) == "active" {
			held = cand
			break
		}
	}
	if held < 0 {
		t.Fatal("the sweep freed every filler, so there is nothing left for " +
			"Settle to free and this proves nothing")
	}
	before := engine.OpenSlots()
	Settle(cross(cur), held)
	if engine.OpenSlots() != before-1 {
		t.Error("a settled proposal is still holding its slot")
	}
}

// Asking a question must not change the answer.
//
// Render walks every proposal, so a settle-on-read there was an unbounded write
// hiding inside something that looks like a query — invisible when it IS a
// query, because the writes are discarded, and a surprise the first time a
// realm calls Render inside a transaction.
func TestReadingDoesNotWrite(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = vA
	quiet := testutils.TestAddress("r-quiet")
	testing.SetRealm(testing.NewUserRealm(vA))
	Mint(cross(cur), vA, 10)
	Mint(cross(cur), quiet, 990)
	advanceEpochs(1)

	engine.Adopt(setFee{name: "r/kind"}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 50, GraceBlocks: 1_000_000,
	})
	testing.SetRealm(testing.NewUserRealm(vA))
	id := Propose(cross(cur), "r/kind", "7", "readable")
	advanceBlocks(1000) // past its deadline, and unwinnable

	// Every read agrees it is finished...
	if got := State(id); got != "defeated" {
		t.Fatalf("State reads %q, want defeated", got)
	}
	Render("")
	Render(strconv.FormatInt(id, 10))

	// ...and none of them wrote that down. The stored state is still what the
	// last transaction left, and the slot is still held.
	if StoredState(id) != "active" {
		t.Errorf("a read changed the stored state to %s", State(id))
	}
	if engine.OpenSlots() == 0 {
		t.Error("a read released the proposal's slot, so reading a page is a " +
			"write and Render is unbounded")
	}

	// Only a transaction records it.
	Settle(cross(cur), id)
	if StoredState(id) != "defeated" {
		t.Errorf("Settle left the stored state at %s", State(id))
	}
	if engine.OpenSlots() != 0 {
		t.Error("a settled proposal still holds its slot")
	}
}

// The sweep must reclaim every slot it looks at, not most of them.
//
// It walks the open index and settles what it finds. Settling releases a slot,
// which removes from that same index — and a bptree must not be modified while
// it is being iterated (bptree tree.gno). Removing the key the cursor stands on
// skips the next one, so a sweep that should reclaim eight reclaims fewer, and
// the shortfall only shows up as slots that never come back.
func TestTheSweepReclaimsEverythingItLooksAt(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = vA
	quiet := testutils.TestAddress("w-quiet")
	testing.SetRealm(testing.NewUserRealm(vA))
	Mint(cross(cur), vA, 10)
	Mint(cross(cur), quiet, 990)
	advanceEpochs(1)

	engine.Adopt(setFee{name: "w/kind"}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 50, GraceBlocks: 1_000_000,
	})
	testing.SetRealm(testing.NewUserRealm(vA))
	for i := 0; i < governor.MaxOpen; i++ {
		Propose(cross(cur), "w/kind", strconv.Itoa(i), "filler")
	}
	advanceBlocks(1000) // all of them past their deadline and unwinnable

	before := engine.OpenSlots()
	engine.Sweep()
	freed := before - engine.OpenSlots()
	// One pass looks at a bounded number and must free all of them: they are
	// every one finished. Fewer means the walk lost its place.
	if freed != 8 {
		t.Fatalf("a sweep over eight finished proposals freed %d — a tree "+
			"rearranged mid-iteration skips entries, and the slots it missed "+
			"never come back", freed)
	}

	// And repeating it keeps working, rather than stalling on whatever the
	// first pass disturbed.
	for engine.OpenSlots() > 0 {
		was := engine.OpenSlots()
		engine.Sweep()
		if engine.OpenSlots() >= was {
			t.Fatalf("a sweep freed nothing with %d still open", was)
		}
	}
}

// The realm must use one block-time assumption, not two.
//
// It used two: an epoch of 1200 blocks described as an hour, which is an hour
// only at three seconds a block, alongside bootstrap periods written as
// seconds/5. Nothing breaks when those disagree — every deadline still works,
// in blocks — but every wall-clock statement the realm makes about itself is
// then wrong for one of them, and the numbers are chosen by reading those
// statements.
func TestTheRealmAssumesOneBlockTime(t *testing.T) {
	// Five seconds is the only cadence anything in the gno tree states:
	// testing.SkipHeights advances time by five seconds per block.
	const secondsPerBlock = 5

	if got := epochBlocks * secondsPerBlock; got != 3600 {
		t.Errorf("an epoch is %d blocks, which is %d seconds at %ds a block — "+
			"the comment calls it an hour", epochBlocks, got, secondsPerBlock)
	}

	// And the built-in periods are the weeks and days they claim to be.
	e, adoptLive := KindRules(governor.Reserved + "adopt")
	if !adoptLive {
		t.Fatal("the adoption kind is missing, so this checks nothing")
	}
	for _, c := range []struct {
		what string
		got  int64
		days int64
	}{
		{"voting", e.VotingBlocks, 7},
		{"delay", e.DelayBlocks, 2},
		{"grace", e.GraceBlocks, 14},
	} {
		if want := c.days * 24 * 60 * 60 / secondsPerBlock; c.got != want {
			t.Errorf("the built-in %s period is %d blocks, want %d — %d days at "+
				"%ds a block", c.what, c.got, want, c.days, secondsPerBlock)
		}
	}
}

// The basis-point scale is one number, used everywhere it matters.
//
// It is load-bearing in three separate places — the tally, the percentages the
// page renders, and the supply ceiling that keeps the tally from overflowing.
// A number that appears in three files eventually disagrees with itself, which
// is not a hypothetical here: the block time did exactly that.
// Tally's fourth number is the snapshot supply, not the supply now.
//
// Three counts without a denominator cannot be checked against anything: every
// bar in this realm is a fraction, quorum of the supply and threshold of what
// was cast. So a reader who wants to verify a state rather than believe it
// needs all four — and the fourth has to be the supply the proposal was
// weighed against, which stopped changing when the question was asked.
//
// Reported live, it drifts away from the quorum the realm is actually applying,
// and every arithmetic check a reader makes against a page comes out wrong
// while every state remains right. A call site that discards the fourth value
// cannot notice, which is why this one exists to read it.
func TestTheTallyReportsTheDenominatorItWasWeighedAgainst(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = vA
	testing.SetRealm(testing.NewUserRealm(vA))
	offerAndAdopt(setFee{}, Rules{
		QuorumBps: 5000, ThresholdBps: 5000, VotingBlocks: 50 * epochBlocks,
	})
	Mint(cross(cur), vA, 1000)
	advanceEpochs(1)

	testing.SetRealm(testing.NewUserRealm(vA))
	id := Propose(cross(cur), "fee", "808", "weighed against a thousand")

	// The supply doubles AFTER the question was asked. The proposal's
	// electorate does not move; it was sealed before this.
	Mint(cross(cur), vA, 1000)
	if got := TotalSupply(); got != 2000 {
		t.Fatalf("the supply is %d, want 2000 — this test needs it to have "+
			"changed since the proposal opened", got)
	}

	yes, no, abstain, total := Tally(id)
	if total != 1000 {
		t.Errorf("Tally reports a denominator of %d, want 1000 — that is the "+
			"supply NOW rather than the supply the proposal is weighed "+
			"against, so every quorum a reader works out from this page "+
			"disagrees with the one the realm applies", total)
	}
	if yes != 0 || no != 0 || abstain != 0 {
		t.Errorf("an unvoted proposal tallies %d/%d/%d, want zeroes", yes, no, abstain)
	}

	// And the arithmetic a reader would do actually works out: half of the
	// snapshot is the quorum, so vA's thousand is exactly enough.
	Vote(cross(cur), id, "yes")
	yes, _, _, total = Tally(id)
	if yes*governor.Bps < total*5000 {
		t.Errorf("%d yes against a denominator of %d does not reach the 50%% "+
			"quorum the rules ask for", yes, total)
	}
	if got := State(id); got != "succeeded" {
		t.Errorf("the realm says %q while the numbers on the page say it "+
			"passed", got)
	}
}

// A vote is weighed at the PROPOSAL's epoch, not at the newest sealed one.
//
// The checkpoint layer has had a test for this since early on, but it tests
// PastVotes directly — it proves the ledger remembers, not that the governor
// asks it the right question. Changing Vote to read voters.Epoch()-1 instead of
// p.epoch left every test in this suite green, because a test that proposes and
// votes without crossing an epoch boundary is asking about the same epoch
// either way, and none of them crossed one.
//
// What that mutation actually restores is the attack the whole design exists to
// stop. Weight would be read as of now rather than as of the question: acquire
// the supply after a proposal opens, wait for the epoch to seal, and vote it.
func TestAVoteIsWeighedAtTheProposalsEpochNotTheNewestOne(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = alice
	testing.SetRealm(testing.NewUserRealm(alice))
	Mint(cross(cur), alice, 1000)
	advanceEpochs(1)

	engine.Adopt(setFee{name: "snap/kind"}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 10 * epochBlocks, GraceBlocks: 1_000_000,
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Propose(cross(cur), "snap/kind", "5", "weighed at the first epoch")
	snapshot := engine.EpochOf(id)

	// Bob is funded only AFTER the question was asked, and then an epoch seals
	// so that his holding is a matter of record at a sealed epoch — just not at
	// the one this proposal is being decided on.
	testing.SetRealm(testing.NewUserRealm(alice))
	Mint(cross(cur), bob, 5000)
	advanceEpochs(1)

	newest := Epoch() - 1
	if newest == snapshot {
		t.Fatalf("the newest sealed epoch is still the proposal's (%d), so the "+
			"two readings coincide and this test cannot tell them apart", newest)
	}
	if got := PastVotes(bob, newest); got != 5000 {
		t.Fatalf("bob holds %d at the newest sealed epoch, want 5000 — without "+
			"that the refusal below is not the one being tested", got)
	}

	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsContains(t, cur, "no voting power at that epoch", func() {
		Vote(cross(cur), id, "yes")
	})
	if yes, _, _, _ := Tally(id); yes != 0 {
		t.Errorf("a balance acquired after the question was asked voted on it: "+
			"yes = %d", yes)
	}
}

// The deadline binds even though nobody has written it down.
//
// A read can work out that a proposal is over but cannot record it, so between
// the deadline and the first transaction that settles, the STORED state still
// says active. Vote settles before it looks, and deleting that one line left
// the suite green: a late vote would be counted, and then the settle at the end
// of Vote would close the proposal on a tally that included it.
func TestAVoteAfterTheDeadlineIsRefusedEvenIfNobodyWroteItDown(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = alice
	testing.SetRealm(testing.NewUserRealm(alice))
	Mint(cross(cur), alice, 1000)
	advanceEpochs(1)

	engine.Adopt(setFee{name: "late/kind"}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 50, GraceBlocks: 1_000_000,
	})
	testing.SetRealm(testing.NewUserRealm(alice))
	id := Propose(cross(cur), "late/kind", "5", "closes soon")
	advanceBlocks(100)

	// The record still says active, which is the state this test needs: the
	// outcome is decided and unrecorded.
	if got := StoredState(id); got != "active" {
		t.Fatalf("the stored state is %q, but this test needs an outcome that "+
			"is true and unwritten", got)
	}

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsContains(t, cur, "that proposal is closed", func() {
		Vote(cross(cur), id, "yes")
	})
	if yes, _, _, _ := Tally(id); yes != 0 {
		t.Errorf("a vote was counted after the deadline: yes = %d", yes)
	}
}

// A voter may say why, and it costs the realm nothing to carry it.
//
// OpenZeppelin has castVote and castVoteWithReason; this is the same pair. A
// governance log recording who voted which way and not why is one people
// reconstruct from a forum afterwards, if at all.
//
// The reason is emitted and never stored, which is the whole reason it can be
// offered at all: a vote is the path this design works hardest to keep cheap,
// and a stored reason would be a new key on every one of them.
func TestAVoteMayCarryAReasonAndStoreNothing(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 600)
	Mint(cross(cur), gBob, 400)
	advanceEpochs(1)
	engine.Adopt(setFee{name: "why/k"}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 100000, GraceBlocks: 1_000_000,
	})

	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "why/k", "5", "explain yourselves")
	VoteWithReason(cross(cur), id, "yes", "the fee is too high")

	// It counts exactly as a plain vote does: the reason is commentary, not
	// weight.
	yes, _, _, _ := Tally(id)
	if yes != 600 {
		t.Errorf("a vote with a reason counted %d, want 600", yes)
	}
	if !p_voted(id, gAlice) {
		t.Error("a vote with a reason was not recorded against its voter")
	}
	// And it is still one vote — the reason does not buy a second.
	testing.SetRealm(testing.NewUserRealm(gAlice))
	uassert.AbortsContains(t, cur, "already voted", func() {
		VoteWithReason(cross(cur), id, "no", "changed my mind")
	})

	// A reason too long to carry is refused rather than clipped, because a
	// voter's words are theirs and half of them is not.
	testing.SetRealm(testing.NewUserRealm(gBob))
	long := ""
	for len(long) <= governor.MaxReason {
		long += "x"
	}
	uassert.AbortsContains(t, cur, "that reason is too long", func() {
		VoteWithReason(cross(cur), id, "no", long)
	})
	// Exactly at the bound is allowed, so it is a bound and not an off-by-one.
	at := ""
	for len(at) < governor.MaxReason {
		at += "y"
	}
	uassert.NotAborts(t, cur, func() {
		VoteWithReason(cross(cur), id, "no", at)
	})
	if _, no, _, _ := Tally(id); no != 400 {
		t.Errorf("bob's vote counted %d, want 400", no)
	}
}

// p_voted reports whether an address is recorded against a proposal.
func p_voted(id int64, who address) bool {
	return HasVoted(id, who)
}

// A voter can ask whether they have voted, and a caller can read the clock.
//
// Both were readable only by doing something. HasVoted was answerable solely by
// sending a vote and being refused — a transaction spent to learn what the
// realm already knew — and the clock was in the rendered page, so anything
// showing a countdown parsed prose written for people.
func TestAProposalAnswersAboutItselfWithoutBeingActedOn(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 600)
	Mint(cross(cur), gBob, 400)
	advanceEpochs(1)
	const window, delay, grace = int64(900), int64(300), int64(1200)
	engine.Adopt(setFee{name: "ask/k"}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000,
		VotingBlocks: window, DelayBlocks: delay, GraceBlocks: grace,
	})

	testing.SetRealm(testing.NewUserRealm(gAlice))
	id := Propose(cross(cur), "ask/k", "5", "ask me anything")

	if HasVoted(id, gAlice) {
		t.Error("alice has voted on a proposal she just opened")
	}
	opened, closes, ready, expires := Timings(id)
	if closes-opened != window {
		t.Errorf("the voting window reads %d blocks, want %d", closes-opened, window)
	}
	// Not recorded yet, so the timelock has not started and nothing expires.
	if ready != 0 || expires != 0 {
		t.Errorf("an unrecorded outcome reports ready=%d expires=%d, want 0 and 0 "+
			"— the delay starts at Settle", ready, expires)
	}

	Vote(cross(cur), id, "yes")
	if !HasVoted(id, gAlice) {
		t.Error("alice voted and the realm says she has not")
	}
	if HasVoted(id, gBob) {
		t.Error("bob has not voted and the realm says he has")
	}

	// Once the outcome is recorded the clock fills in, and the two zeroes stop
	// being zero.
	testing.SetRealm(testing.NewUserRealm(gBob))
	Vote(cross(cur), id, "yes")
	_, _, ready, expires = Timings(id)
	if ready == 0 {
		t.Fatal("a settled proposal still reports no timelock")
	}
	if expires != ready+grace {
		t.Errorf("expiry reads %d, want ready+grace = %d", expires, ready+grace)
	}

	// The roll survives the proposal closing, so a kind that pays the people
	// who voted can still ask. It goes when somebody reclaims the deposit.
	advanceBlocks(window * 2)
	Settle(cross(cur), id)
	if got := State(id); got == "active" {
		t.Fatalf("the proposal is still %q; this needs a settled one", got)
	}
	if !HasVoted(id, gAlice) {
		t.Error("a settled proposal has forgotten who voted, so nothing can pay " +
			"them")
	}
	if choice, weight, ok := VoteOf(id, gAlice); !ok || choice != "yes" || weight != 600 {
		t.Errorf("VoteOf reports %q/%d/%v after settling, want yes/600/true",
			choice, weight, ok)
	}
	// And after the roll is released it answers false rather than panicking.
	ReleaseRoll(cross(cur), id)
	if HasVoted(id, gAlice) {
		t.Error("the roll was released and alice is still on it")
	}
	if _, _, ok := VoteOf(id, gAlice); ok {
		t.Error("VoteOf answers from a released roll")
	}

	// And every settled proposal reports BOTH a ready height and an expiry.
	//
	// This used to check the other case — a grace of zero, meaning never
	// expires — which nothing can produce any more: saneRules refuses zero,
	// because a decided proposal that never expires holds its slot for the life
	// of the realm. The old test reached it only because registering a kind by
	// hand skipped that check, so it was asserting behaviour for a state the
	// realm cannot be in. Now it asserts the state the realm is always in.
	engine.Adopt(setFee{name: "forever/k"}, Rules{
		QuorumBps: 1, ThresholdBps: 5000, VotingBlocks: window,
		GraceBlocks: 1_000_000,
	})
	testing.SetRealm(testing.NewUserRealm(gAlice))
	never := Propose(cross(cur), "forever/k", "6", "a long grace")
	Vote(cross(cur), never, "yes")
	if _, _, r, e := Timings(never); r == 0 || e <= r {
		t.Errorf("a settled proposal reports ready=%d expires=%d, want an "+
			"expiry after the ready height", r, e)
	}
}
