// Package govern is an analog of OpenZeppelin's ERC20Votes and Governor for
// gno.land: a GRC20-shaped token that remembers who could vote what and when,
// and a governor that decides by reading that history.
//
// An analog, not a port. Where the Solidity design exists because the EVM is
// what it is, this does the thing a Go programmer would call obvious instead.
// docs/DESIGN.md is the design record — what was copied, what was refused, and the
// two routes taken and abandoned. This is the summary.
//
// # What a holder does
//
//	Transfer(to, amount)      move tokens; voting power follows automatically
//	Approve(spender, amount)  let somebody else move some of yours
//	TransferFrom(from, to, amount)
//	Burn(amount)              destroy your own
//	Delegate(to)              hand your say to somebody without handing over the money
//
//	Propose(kind, payload, title) int64
//	                          sixty-four proposals may stand at once, of which
//	                          the last eight are kept for the governor's own
//	                          kinds so a flood of one thing cannot stop the
//	                          holders changing the rules
//	Vote(id, "yes"|"no"|"abstain")
//	VoteWithReason(id, choice, reason)   the same vote, with a note on the record
//	Cancel(id)                the proposer, while it is still open
//	Settle(id)                write down a conclusion the rules already reached;
//	                          for a proposal that wins at its deadline this is
//	                          also what starts the timelock
//	Execute(id)               permissionless: after the vote and the delay, nothing is left to decide
//	ReleaseRoll(id)           permissionless: drop a finished proposal's roll of
//	                          voters and take back the deposit it was holding
//
// One entrypoint is not a holder's:
//
//	Mint(to, amount)          the minter only, until the holders vote it away
//
// And to read it, without a transaction:
//
//	BalanceOf, Allowance, TotalSupply, Minter, GetName/GetSymbol/GetDecimals
//	VotesOf, DelegateOf, PastVotes, PastTotalVotes, Epoch
//	State(id), Describe(id), Tally(id), Timings(id), HasVoted(id, who)
//	VoteOf(id, who)           how one address voted, for a kind paying them out
//	Render(path)
//	Preview(kind, payload)    what a proposal would say, before opening one
//
// And one for realms writing a Kind:
//
//	TextOnly(s)               refuse a payload that could rewrite the page
//
// # What taking part costs, and how to get it back
//
// gno charges a storage deposit for what a transaction writes, paid by the
// CALLER, on the change in encoded size. So these entrypoints are not priced
// alike, and the differences are large enough to plan around:
//
//	Propose                      ~8,800 bytes — most of it the voter roll
//	Vote, first on a proposal      ~510
//	Vote, any later one            ~450
//	Transfer, second in an epoch      0 — genuinely nothing, see the clock below
//
// Bytes rather than ugnot: the price is bytes times a chain parameter, so a
// chain that reprices storage moves every fee and none of these figures.
// Measured on a chain.
//
// Every vote costs the same, which takes doing. The roll of who has voted is a
// tree, a tree buys its first node on its first key, and that node is about
// eleven ordinary votes — so left alone, the first vote on a proposal costs
// eleven times the second, purely for arriving early. Propose plants a sentinel
// in the roll instead, and the proposer pays for the node along with the
// question.
//
// It comes back, in two pieces and to whoever asks for them, since freed
// storage is refunded to whoever frees it: Settle gives back the slot once the
// proposal is decided, and ReleaseRoll gives back the roll once the kind has
// run. That is the practical reason both are permissionless — a proposer who
// wants their deposit back does not have to wait for anybody else to want it.
//
// Nobody has to remember to self-delegate. OpenZeppelin makes it opt-in
// because on the EVM self-by-default would put two SSTOREs on every transfer
// forever; here the checkpoint lives in a record the transfer already writes.
//
// # What it emits
//
// Everything an indexer needs, and nothing it can work out for itself.
//
//	Transfer, Approval, Mint, Burn   the GRC20 names, unchanged
//	DelegateChanged                  delegator, fromDelegate, toDelegate
//	KindOffered                      name, offerer, and all six terms
//	ProposalOpened                   id, kind, proposer, epoch
//	Voted                            id, voter, choice, weight, and a reason
//	                                 when the voter gave one
//	ProposalSettled                  id, state, reason
//
// A mint and a burn each emit TWO events, and the Transfer is the one that
// matters to anybody else. grc20 declares MintEvent and BurnEvent and never
// emits either: its Mint sends a Transfer with an empty `from` and its Burn one
// with an empty `to`, which is the ERC20 convention and how every indexer
// written against the standard reconstructs balances and supply.
//
// Emitting only "Mint" satisfied the claim about names while breaking what the
// names are for — an indexer would have watched this token's supply appear from
// nowhere. "Mint" and "Burn" are still emitted because they say plainly what
// happened, but anything totalling supply should total Transfers and not both.
//
// Two choices worth knowing about. DelegateChanged exists because delegation
// is the only state change here that nothing else reveals — no balance moves,
// so an indexer would see a holder's weight vanish with nothing to explain it.
//
// And there is deliberately no DelegateVotesChanged, which OpenZeppelin emits
// on every power change. Here that would fire on every transfer, mint and burn
// for something a caller can simply ask: VotesOf answers now, PastVotes answers
// for any sealed epoch. Emitting it would be transliteration.
//
// ProposalSettled carries the state rather than there being one event per
// outcome, because the per-outcome shape is what let four of the six go
// unannounced.
//
// KindOffered is the same argument as DelegateChanged. Offer is ungated and
// the registry is never iterated — an ungated registry is unbounded, and
// walking it would put anybody's spam on the page holders read — so before
// this, a published Kind left no trace and could be found only by guessing its
// name. The terms go out with it, because adopting a kind is a decision about
// the code AND about the bar it would pass at.
//
// Adoption gets no event of its own. It happens through a proposal, and a
// proposal is announced when it opens and again when it settles.
//
// # What passes
//
// Three bars, and a proposal has to clear all of them.
//
//	turnout    yes + no + abstain, against QuorumBps of the snapshot supply
//	support    at least one vote in favour — always, whatever the threshold
//	threshold  yes against yes + no, ignoring abstentions
//
// The middle one is not decoration. Abstain counts towards turnout and stays
// out of the threshold, so a proposal where EVERYBODY abstains has an empty
// threshold: yes and no are both zero, and "yes >= threshold of nothing" is
// true of nothing. Without that line such a proposal passed, immediately, with
// nobody in favour.
//
// A decided question closes at once rather than waiting out its clock, in both
// directions: as soon as no remaining vote could take the threshold away, and
// as soon as none could reach it.
//
// # What a proposal is
//
// A kind and a payload, both strings. Not a simplification: MsgCall.Args is
// []string, so an entrypoint taking a struct or an interface silently
// restricts proposing to people who can write and publish Gno.
//
// The consequence is a property OpenZeppelin cannot offer. A kind's Describe
// and its Do consume the identical string, so what a voter reads IS what runs.
// A proposal that carries code can only show a description somebody typed
// beside it, with nothing tying the two together.
//
// What they may contain, since a proposal is refused rather than trimmed:
//
//	title    120 bytes, and no control characters. Prose otherwise — spaces,
//	         any language, markdown inside the line.
//	payload  4096 bytes, and whatever the kind's own Check accepts. Newlines
//	         are allowed here because govern:batch needs them.
//	kind     64 bytes of printable ASCII with no spaces, fixed when offered.
//
// The title rule is about structure rather than taste. A title goes onto the
// front page inside a list item, so a newline in one ends that item and starts
// a row of the proposer's own design — a forged proposal, with a state and a
// link they choose, sitting in the list every holder reads. Markdown within
// the line is left alone: it cannot leave the row it belongs to.
//
// # Who may write on the page
//
// The answer is not uniform, and the pages are what this realm is for.
//
// A kind's Describe is trusted markdown: it gets its own block and may render
// headings and links, because that is how a power explains itself to the people
// granting it. A kind reaches that position by being adopted.
//
// Its PAYLOAD is not. That comes from whoever proposes — any address at all
// when ProposeBps is zero — so a Describe rendering its payload raw hands page
// structure to a stranger. Every built-in avoids this without trying, since
// their payloads are kind names and addresses; a kind taking free text has to
// refuse structure deliberately:
//
//	func (k mykind) Check(payload string) error {
//		if len(payload) > 280 {
//			return errTooLong
//		}
//		return govern.TextOnly(payload)
//	}
//
// The governor cannot apply that itself — govern:batch is defined in terms of
// newlines, and only a kind knows its own grammar. r/cryptocourt/offerer shows the
// call in place.
//
// Two paths carry untrusted text with no kind to vet it, and both are closed: a
// title refuses control characters, and a payload rendered raw because its kind
// was retired is indented line by line into a code block. A kind NAME cannot
// carry structure either — printable ASCII, no spaces.
//
// # What ships adopted
//
// Five kinds are live from the first block — the whole of what can be decided
// before anybody writes any Gno. They must be built in, because adopting a kind
// is itself a kind and there is nothing to bootstrap them with.
//
//	govern:adopt   "mytreasury/spend"
//	               turn an offered kind live. The page shows its terms as well
//	               as its name, since how easily a power can be used is most of
//	               the decision.
//
//	govern:retire  "mytreasury/spend"
//	               withdraw one. Also kills any proposal of that kind already
//	               decided and not yet run, so it is not only about the future.
//
//	govern:rules   "mytreasury/spend quorum=2000 voting=120960"
//	               retune what it takes to pass. Six fields — quorum, threshold,
//	               voting, delay, grace, propose — and the ones left out keep
//	               their value.
//
//	               Zero means three different things across them, which is why
//	               the terms pages spell each out rather than printing it:
//
//	                 delay=0    no timelock
//	                 propose=0  no stake check at all, so any address may
//	                            open one holding nothing
//	                 grace=0    refused: a decided proposal keeps its slot
//	                            until it runs, so one that never expires
//	                            holds it for the life of the realm
//	                 voting=0   refused; a vote needs a period
//
//	govern:minter  "g1..." or "none"
//	               move the power to mint, or give it up permanently.
//
//	govern:batch   "treasury/spend 100\nfee 250"
//	               several adopted kinds as one decision, one per line, up to
//	               sixteen, all or nothing. Members must already be adopted: a
//	               batch decides several things at once and smuggles in nothing.
//
// Their names begin with the reserved prefix and Offer refuses it, so nothing
// published later can render as one of these.
//
// A built-in cannot be RETIRED — retiring govern:adopt would freeze the kind
// set permanently, and govern:rules every term — but it CAN be RETUNED,
// including the bar for adoption itself. So the holders can make granting
// powers harder or easier, and cannot take away their ability to grant them.
//
// All five start on the same bootstrap rules, the bar every early decision has
// to clear:
//
//	quorum     2000 bps, a fifth of the supply must turn out
//	threshold  6600 bps, two thirds of yes+no, not a simple majority
//	voting     120960 blocks, a week
//	delay      34560 blocks, two days
//	grace      241920 blocks, a fortnight
//	propose    0, so the stake check is skipped and ANY address may open one
//	           holding nothing — worth knowing before leaving it there
//
// The turnout bar decides whether a launch works. A fifth of the supply has to
// vote before anything passes, so dispersed holders get a first adoption that
// fails on quorum rather than on disagreement — and govern:rules, which would
// lower it, is subject to it.
//
// # What a realm does
//
// Publishes a Kind and offers it:
//
//	type spend struct{}
//	func (spend) Name() string             { return "mytreasury/spend" }
//	func (spend) Describe(p string) string { return "pay out " + p }
//	func (spend) Check(p string) error     { ... }          // at propose AND before Do
//	func (spend) Do(_ int, rlm realm, p string) error { ... }
//
//	govern.Offer(cross(cur), spend{}, govern.NewRules(
//		2000, // quorum bps
//		6600, // threshold bps
//		120960, 34560, 241920, // voting, delay, grace, in blocks
//		0,    // stake a proposer must hold, in bps
//	))
//
// NewRules rather than a Rules literal: a realm cannot allocate another realm's
// struct, so `govern.Rules{...}` written in YOUR realm is refused by the VM.
//
// r/cryptocourt/offerer is that sketch as a whole file, tested and deployed. Worth
// reading first, because four things it does are not obvious above:
//
//   - its kind carries its NAME as a field, not a constant, so one realm can
//     offer several — and since Offer binds a name to its code forever, a
//     constant name means one offer per chain, ever;
//   - its entrypoint takes that name as a string, because MsgCall carries
//     nothing else, so a Kind assembled behind a Go-only API cannot be offered
//     by a transaction at all;
//   - it tests that Describe is a total function of the payload. The governor
//     cannot check that for you, and reading live state there shows two holders
//     different questions at the same URL;
//   - its Check refuses control characters, because the payload comes from the
//     proposer and Describe renders it where others vote.
//
// Offering grants nothing, and the realm says which half you are missing:
// proposing under a name nobody offered is "no such kind", while one that is
// offered and not adopted says so and names govern:adopt.
//
// The holders adopt it by vote, seeing the name and the terms together.
// Publishing code and letting that code hold this governor's authority are
// different decisions belonging to different people; one registration call
// would fuse them.
//
// A name, once offered, is bound to that code forever. New code takes a new
// name, which the holders adopt knowingly.
//
// # What it will not do
//
//   - A kind's Do never receives this realm's own capability. It gets
//     cur.Sub(kind), a sub-realm with its own pkgpath and address, so a
//     governed realm gates on the power that was granted rather than on the
//     governor as a whole. Passing cur itself would make one adoption vote a
//     grant of govern's identity everywhere govern is trusted.
//   - No arbitrary call. There is no call(address, bytes) in gno and no
//     reflection, so nobody gets one; refusing to simulate it with stored
//     closures is the choice.
//   - No governing an unwilling realm. A realm is governable only if its own
//     source names this one. That is a real loss of reach and a real gain:
//     nothing can be dragged into governance it never contemplated.
//   - Batching is all-or-nothing: a member that fails aborts the whole
//     transaction, so a failed batch leaves its proposal Succeeded and
//     retryable rather than Failed. Nothing happened, including the failure.
//   - A supply ceiling of about 922 million whole tokens at six decimals, which
//     is where the exact-integer tally would start to overflow.
//   - No voting delay. OpenZeppelin has one, and the reason it has one does not
//     apply here: there, the snapshot is taken when voting OPENS, so a gap
//     between proposing and voting is what stops a proposal from being written
//     against a balance somebody has just acquired. Here the snapshot is a
//     SEALED epoch that is already in the past when the proposal is made, so
//     the property that gap buys is an invariant before anybody asks for it.
//     Adding the delay would postpone voting and protect nothing.
//
// # Launching one
//
// The order matters and most of it cannot be undone, so it is written out
// once here rather than assembled from three files.
//
//  1. Publish the packages this realm imports FIRST — p/cryptocourt/checkpoint/v0
//     and p/cryptocourt/grc20votes/v0, in that order. AddPackage
//     compiles on chain, and an import that does not resolve is a deploy that
//     fails — which costs the path, because a realm cannot be redeployed at
//     one.
//
//  2. Publish this realm. Whoever sends that transaction becomes the minter,
//     because init() takes OriginCaller. There is no second chance at that.
//
//     Budget for it: about 68 million gas and 6.6 GNOT of storage deposit,
//     measured on a chain and asserted by a test. AddPackage compiles AND
//     stores the source, so both scale with the file — and three quarters of
//     this file is comments, which is a deliberate trade worth knowing the
//     price of. docs/DESIGN.md has the accounting.
//
//  3. Check Minter(). See below: an empty one means a dead realm.
//
//  4. Mint the supply, all of it, BEFORE anything else. Every later step is
//     easier to reverse than this one, and one of them removes minting for
//     good.
//
//  5. Wait an epoch. Voting weight is read at a SEALED epoch, so nothing can be
//     proposed until the chain passes epochBlocks — 720 blocks, an hour at five
//     seconds. Until then Propose refuses with "too young to vote", which is
//     the realm working rather than a fault.
//
//  6. Offer and adopt any kinds the holders should have. Adoption is a vote
//     under the built-in rules, so the first one runs on the bootstrap
//     timelock: up to a week of voting, then two days of delay.
//
//     Up to. A vote that is already decided closes on the arithmetic rather
//     than on the clock — once no remaining vote could change the answer, it
//     settles then and there. So a launch whose holders agree waits about two
//     days, and one whose holders are split waits up to nine. Both numbers are
//     worth knowing before promising anybody a date.
//
//  7. Deal with the mint, last. Hand it to "none" and the supply is fixed
//     forever.
//
//     Handing it to THIS REALM's own address does not make minting a proposal:
//     there is no built-in kind that mints, and a kind's Do is handed a
//     sub-realm rather than this one, so nothing can present the realm's own
//     address to Mint. The effect is the same as "none" by a longer route.
//
//     "none" is a promise no address can make while it still holds the power to
//     break it, and irreversible in the strongest sense available: there is
//     nobody left to reverse it.
//
// Steps 1, 2, 4 and 7 cannot be taken back. The rest can be repeated.
//
// # After deploying, check Minter()
//
// If it comes back empty the realm is dead and cannot be revived: no minter
// means no supply, no supply means no voting power, and no voting power means
// no proposal can pass — including the one that would appoint a minter. Realms
// cannot be redeployed at their path, so the only remedy is a new path.
//
// MsgAddPackage sets OriginCaller to the creator, so this should not happen on
// a chain. It does happen where there is no deployer at all, which is how it
// was found: a filetest importing this realm gets an empty one.
//
// # The clock, and what a block is worth
//
// Periods are in BLOCKS. Correctness never depends on how long a block takes;
// the wall-clock framing is guidance for choosing a voting period, not a
// promise. Everything here assumes five seconds a block, and two independent
// places in the gno tree agree: testing.SkipHeights advances time by five
// seconds per block, and DefaultConsensusConfig sets TimeoutCommit to 5000
// milliseconds, which is how long a node waits after committing before opening
// the next round.
//
// A floor rather than an exact figure — propose and vote latency ride on top —
// so every hour quoted here is a slight over-estimate of what fits in a day.
// The block counts are exact regardless, which is the half that matters.
//
//
// Block height, quantised into epochs — never block time, which production
// only ever sets to whole seconds, so two blocks under a second apart return
// the same value. Quantising also makes the anti-flash-loan property an
// invariant rather than a discipline: OpenZeppelin tells you to read at
// clock()-1 and trusts you to, whereas a transaction here cannot outlive its
// block, a block cannot outlive its epoch, and PastVotes refuses the epoch it
// is in.
package govern
