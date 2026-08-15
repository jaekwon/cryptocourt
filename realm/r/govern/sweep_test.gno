package govern

import (
	governor "gno.land/p/cryptocourt/governor/v0"
	"strings"
	"strconv"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

// sweep has to make progress no matter which slots are the finished ones.
//
// It scans a bounded window of the open index, and the index is keyed by
// engine.Digest(kind, payload) — which the PROPOSER chooses, because they choose the
// payload. Scanning always from the low end therefore lets somebody decide
// what the sweeper looks at: park a few long-running proposals on the lowest
// keys and the window never sees past them, so the reclaim frees nothing while
// the rest of the list is finished business waiting to be written down.
//
// The result is a governor that refuses every new proposal with "too many
// proposals are already open" while most of those proposals are over. Settle
// is permissionless, so the slots can still be freed by hand, one call each,
// by somebody who knows to do it — but the automatic path that exists so
// nobody has to know that is exactly the path being defeated.
//
// No hash grinding is needed to show it, which is rather the point: digest is
// right here in the package, so this test SORTS where an attacker would
// search. Searching to beat fifty-six random keys is a few hundred hashes on a
// laptop, which is not a cost.
func TestSweepReclaimsSlotsItDoesNotScanFirst(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 1_000_000)
	advanceEpochs(1)

	// Two kinds that differ only in how long their vote runs.
	const fast, slow = "fast/k", "slow/k"
	engine.Adopt(setFee{name: fast}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 50, GraceBlocks: 1_000_000,
	})
	engine.Adopt(setFee{name: slow}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 1_000_000, GraceBlocks: 1_000_000,
	})

	// The business that will be over: fifty-six of them, and the lowest key
	// among them is the bar the parked ones have to get under.
	const filler = governor.MaxOpen - 8
	low := ""
	var fillerPayloads []string
	for i := 0; i < filler; i++ {
		p := strconv.Itoa(i)
		fillerPayloads = append(fillerPayloads, p)
		if d := engine.Digest(fast, p); low == "" || d < low {
			low = d
		}
	}

	// Eight payloads whose keys sort below every one of those. The search stays
	// inside setFee's range because the kind only accepts a payload it can read
	// as basis points, which is a limit on this fixture and not on an attacker.
	var parked []string
	for i := 0; len(parked) < 8 && i <= 10000; i++ {
		p := strconv.Itoa(i)
		if engine.Digest(slow, p) < low {
			parked = append(parked, p)
		}
	}
	if len(parked) < 8 {
		t.Fatalf("only found %d payloads sorting below the filler; without "+
			"eight the list is not blocked and the rest proves nothing", len(parked))
	}

	for _, p := range parked {
		Propose(cross(cur), slow, p, "parked on a low key")
	}
	var fillerIDs []int64
	for _, p := range fillerPayloads {
		fillerIDs = append(fillerIDs, Propose(cross(cur), fast, p, "ordinary business"))
	}
	if engine.OpenSlots() != governor.MaxOpen {
		t.Fatalf("%d slots taken, want the list full at %d", engine.OpenSlots(), governor.MaxOpen)
	}

	// Past the fast kind's deadline and nowhere near the slow one's. Fifty-six
	// proposals are now decided and unrecorded; eight are genuinely still open.
	advanceBlocks(100)
	for _, id := range fillerIDs {
		if got := State(id); got != "defeated" {
			t.Fatalf("filler #%d reads %q, want defeated — the fixture is wrong "+
				"and the rest of this test would prove nothing", id, got)
		}
	}

	before := engine.OpenSlots()
	engine.Sweep()
	if engine.OpenSlots() == before {
		t.Errorf("sweep freed nothing from a list of %d where %d proposals are "+
			"over: it scans the low keys, and a proposer picks their key by "+
			"picking their payload", before, filler)
	}

	// And the whole point of freeing a slot: somebody can ask a new question.
	uassert.NotAborts(t, cur, func() {
		Propose(cross(cur), fast, "77", "after the sweep")
	})
}

// A flood of one kind cannot shut the governor out of its own realm.
//
// governor.MaxLive is one number for the whole realm, so without a reservation the
// sixty-four slots are a commons and any kind may hold all of them. Sixty-four
// proposals of some cheap kind with a long voting window, and nothing else can
// be asked until that window runs out — including the govern:rules vote that
// would shorten the window. The realm stays up and stops being governable.
//
// Priced, because "possible" and "worth doing" are different: the bootstrap
// terms set ProposeBps to zero, so any holder at all may propose, and a
// proposal is ~8,800 bytes of deposit. Sixty-four of them is about 56 GNOT,
// refundable, held for one bootstrap voting window of a week.
//
// What the lane does NOT do is stop the flood, and it is not meant to: the
// board really does fill, ordinary business really is refused, and the holders
// have to vote their way out. It guarantees only that they can.
func TestAFloodOfOneKindCannotShutTheGovernorOut(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 1_000_000)
	advanceEpochs(1)

	// A kind whose vote runs long enough that no slot comes back on its own,
	// so the sweep on the way in finds nothing to reclaim and every refusal
	// below is a refusal rather than a delay.
	const flood = "flood/k"
	engine.Adopt(setFee{name: flood}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 1_000_000,
		GraceBlocks: 1_000_000,
	})

	for i := 0; i < governor.MaxOpen; i++ {
		Propose(cross(cur), flood, strconv.Itoa(i), "flooding")
	}
	if engine.OpenSlots() != governor.MaxOpen {
		t.Fatalf("%d slots taken, want %d — the flood did not fill the board "+
			"and the rest of this proves nothing", engine.OpenSlots(), governor.MaxOpen)
	}

	// Ordinary business is shut out, and told why rather than left to guess.
	uassert.AbortsContains(t, cur, "kept for the governor's own kinds", func() {
		Propose(cross(cur), flood, "9999", "one more")
	})

	// And the PAGE says so too, which is the half a refusal cannot cover. A
	// holder reading "56 of 64 slots in use" sees eight free and is refused
	// anyway; the page has to name the lane or it contradicts the realm.
	page := Render("")
	if !strings.Contains(page, "kept for the governor's own kinds") {
		t.Errorf("the front page shows free slots and does not say they are "+
			"governor.Reserved, so being refused reads as a fault:\n%s", page)
	}

	// And the realm can still be governed. This is the whole of it.
	uassert.NotAborts(t, cur, func() {
		Propose(cross(cur), governor.Reserved+"rules", flood+" quorum=100", "retune it")
	})

	// The lane is finite too, so the governor.Reserved kinds run out at governor.MaxLive and not
	// before — otherwise "governor.Reserved" would mean "unbounded" and the front page's
	// worst case, which is what governor.MaxLive is for, would be a guess.
	for i := 1; i < governor.GovLanes; i++ {
		Propose(cross(cur), governor.Reserved+"rules", flood+" quorum="+strconv.Itoa(100+i),
			"retune it again")
	}
	if engine.OpenSlots() != governor.MaxLive {
		t.Fatalf("%d slots taken with the lane full, want %d", engine.OpenSlots(), governor.MaxLive)
	}
	uassert.AbortsContains(t, cur, "too many proposals are already open", func() {
		Propose(cross(cur), governor.Reserved+"rules", flood+" quorum=200", "and again")
	})

	// And with room to spare the page stays quiet, because there the count is
	// the whole story and the clause would be noise on every ordinary page.
	// Nine of them, because one is not enough to get back under the line.
	// Cancelling is the proposer's, and alice opened all of these.
	for i := int64(1); i <= int64(governor.MaxLive-governor.MaxOpen)+1; i++ {
		Cancel(cross(cur), i)
	}
	if got := engine.OpenSlots(); got >= governor.MaxOpen {
		t.Fatalf("%d slots still taken, so this measures the full case again", got)
	}
	if page := Render(""); strings.Contains(page, "kept for the governor's own kinds") {
		t.Errorf("the page names the lane when there is room to spare:\n%s", page)
	}
}

// The lane is wide enough for every question the governor can ask at once.
//
// A reservation of one would satisfy the test above and be nearly useless: the
// governor has five kinds of its own and they are not alternatives — retuning
// one kind, adopting another and retiring a third can all be live at the same
// time, and with a lane of one the first of them blocks the rest for a whole
// voting window. The board being flooded is exactly when the holders need
// several answers at once.
//
// So this fills the board and then opens one proposal of every governor.Reserved kind,
// which is what governor.GovLanes is sized for. A lane narrower than the number of
// built-in kinds fails here and nowhere else: the test above is satisfied by a
// reservation of one.
func TestTheGovernorsLaneFitsEveryQuestionItCanAsk(cur realm, t *testing.T) {
	resumeClock()
	resetLedger()
	minter = gAlice
	testing.SetRealm(testing.NewUserRealm(gAlice))
	Mint(cross(cur), gAlice, 1_000_000)
	advanceEpochs(1)

	const flood = "flood/k"
	engine.Adopt(setFee{name: flood}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 1_000_000,
		GraceBlocks: 1_000_000,
	})
	// Offered and not adopted, so govern:adopt has something to ask about.
	// Adopting an adopted kind is refused, which would read here as a lane
	// that does not fit.
	const waiting = "waiting/k"
	namedAs = waiting
	engine.Offer(alice, named{}, Rules{
		QuorumBps: 9000, ThresholdBps: 5000, VotingBlocks: 100,
		GraceBlocks: 1000,
	})
	for i := 0; i < governor.MaxOpen; i++ {
		Propose(cross(cur), flood, strconv.Itoa(i), "flooding")
	}

	// One of each, on a board with nothing but the lane left. Payloads chosen
	// so each is a question the kind will actually accept — a refusal for the
	// wrong reason would read as a lane that fits.
	each := []struct{ kind, payload string }{
		{governor.Reserved + "rules", flood + " quorum=100"},
		{governor.Reserved + "adopt", waiting},
		{governor.Reserved + "retire", flood},
		{governor.Reserved + "minter", gBob.String()},
		{governor.Reserved + "batch", flood + " 250\n" + governor.Reserved + "minter " + gCarl.String()},
	}
	for _, q := range each {
		kind, payload := q.kind, q.payload
		uassert.NotAborts(t, cur, func() {
			Propose(cross(cur), kind, payload, "governing a flooded realm")
	})
	}

	// And the count is the check on the fixture: five governor.Reserved proposals stood,
	// so the loop above measured five lanes rather than five refusals nobody
	// looked at.
	if got := engine.OpenSlots() - governor.MaxOpen; got != len(each) {
		t.Fatalf("%d governor.Reserved proposals stand of %d opened", got, len(each))
	}
}

// And the cursor has to come back around.
//
// Rotating the window solves being held at the low end, and introduces the
// opposite failure: once the cursor walks off the end of the index it stays
// there, and every later sweep looks at nothing at all. That is worse than the
// bug it replaced — the first one needed somebody to grind keys, this one would
// happen on its own, to everybody, the first time the list drained.
// A window must not hand the next one a key it has already looked at.
//
// Also asserted on the cursor, and for the same reason: at a scan of eight,
// re-examining one key wastes a slot and still makes progress through the other
// seven, so nothing observable changes. It would matter at a smaller scan, and
// "correct only because the window is wide enough" is not a property worth
// resting on when the alternative is one character.