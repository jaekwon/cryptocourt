# Governor + GRC20Votes, for gno

An analog of OpenZeppelin's `Governor` + `ERC20Votes`, not a transliteration.
Where the EVM's shape exists only because the EVM is what it is, gno gets to do
the obvious thing instead.

This file is the design record: what the shape is, what was measured to get
there, and which alternatives were weighed and refused. Every claim about the
gno tree in it is a quotation checked by `scripts/check-citations.py`, so a
statement here that stops being true of gno fails the build rather than
misleading a reader.

## Ground truth

Everything here was read out of the gno tree at `$(gno env GNOROOT)`, not
recalled.

**A proposal can carry a function.** `p/nt/commondao/v0/proposal.gno`
declares `Executor() ExecFunc` on a proposal definition, and `commondao.gno`'s
`Execute` runs it after the vote. So a stored, persisted func value is not a
trick — it is how gno's own DAO already works. This is the single fact that
decides the design, because it is the thing the EVM cannot do: there, a proposal
is `(targets[], values[], calldatas[])`, untyped bytes assembled off-chain and
dispatched by address. Here it is code.

**Proposals reach that code through a registry, not a closure literal.**
`ProposalKind` (`proposal.gno`) is `Name() string` plus
`New(dao ReadonlyCommonDAO, args any) (ProposalDefinition, error)`. This is the
part that took a moment to see the point of: an external account sending a
transaction cannot construct a closure — only code can. So the kind registry is
what lets an ordinary caller propose at all. It is the analog of a function
selector, with the ABI replaced by a typed factory that can refuse.

**Execution is remove-before-run, with a re-entrancy latch**
(`commondao.gno`, `func (dao *CommonDAO) Execute`). Worth copying outright rather than rediscovering.

**Block height is available and testable.** `testing.SkipHeights(int64)` at
`gnovm/tests/stdlibs/testing/context_testing.gno` (`SkipHeights`), used by the commondao
filetests to jump a voting deadline. A height-based clock is therefore
verifiable in tests, which a wall-clock one would not be.

**A block is about five seconds.** Two independent sources say so:
`SkipHeights` advances time by `count*5`, and `DefaultConsensusConfig` sets `TimeoutCommit` to 5000 milliseconds with
`SkipTimeoutCommit` false, so a node waits five seconds after committing before
opening the next round, and `CreateEmptyBlocks` is true with a zero interval, so
it keeps making blocks with no traffic and the cadence does not track load.

A floor rather than an exact figure — propose and vote latency ride on top — so
every wall-clock number in this realm slightly over-estimates what fits in a
day. The block counts are exact either way, which is the half correctness rests
on.

**The toolchain lies when it is stale.** `gno test` reporting that a
`chain/banker` native function "does not have a body" means the `gno` binary
predates the checkout. `go install ./gnovm/cmd/gno` first. Nothing in a realm
explains that error.

## Why the token keeps its own ledger

The obvious move is to wrap `p/demo/tokens/grc20` and checkpoint around it. It
does not work, and the reason is not cost.

The floor query certainly is not the problem. `ReverseIterate(start, end, cb)` walks
`[start, end]` **descending with end inclusive** (`tree.gno`, "ReverseIterate calls cb"), so taking the
first callback answers *greatest key ≤ T* in one descent and stops. Checkpoints
on a bptree are perfectly viable, and for a while that looked like the answer.

What kills checkpoint-on-transfer is not cost, it is `CallerTeller`.

`(*Token).CallerTeller()` (`p/demo/tokens/grc20/tellers.gno`) hands
any holder a teller that moves **their own** balance, acting as the caller. That
is correct for a token and fatal for a wrapper: if the realm ever exposes its
`*Token` — which is exactly what makes a token discoverable, registrable in
grc20reg, and usable by a wallet — then balances can move without the wrapper
seeing it, and checkpointed voting power silently stops matching who holds what.
The only way to hook every balance change through the stock package is to never
hand out the Token, which throws away the reason to use the stock package.

So the choice is not "OZ versus Maker on gas". It is:

- reimplement the ledger to get transfer hooks, and lose the standard package; or
- leave the token vanilla and standard, and checkpoint an **escrow** instead.

Escrow is the tempting answer to the second, and it rests on a step that does
not hold. The claim is that a new key costs far more than an update, so escrow —
which writes one only when somebody joins or leaves — must beat taxing every
transfer. True about keys, and it does not follow, because checkpointing does
not have to add a key per transfer.

**Storage deposit is charged per OBJECT, on the DELTA of its encoded size**
(`gnovm/pkg/gnolang/store.go`, `LastObjectSize`, at 100ugnot/byte). Adding checkpoint fields
to an account record that a transfer was going to write anyway costs those
bytes ONCE, at account creation, and nothing on every write after. The EVM
charges an SSTORE for every extra word touched, forever — which is the entire
reason `ERC20Votes` is shaped the way it is, and the reason that shape does not
have to be inherited here.

So escrow buys nothing on storage. What is left of its case is composability,
and there is a better answer to that.

## Checkpoint on transfer, with this package's own ledger

`CallerTeller` rules out WRAPPING `p/demo/tokens/grc20`, and the problem runs
deeper than the teller: `grc20reg.Register` takes the concrete `*Token`, so the
act of making a token discoverable is the act of publishing a transfer path that
never enters this realm.

The move is to conform on the WIRE rather than on the type: our own ledger,
emitting the same events and offering the same read names, so an indexer cannot
tell the difference.

The read half checks out exactly, and was checked rather than assumed: all six
reads on grc20's `Teller` — `GetName`, `GetSymbol`, `GetDecimals`,
`TotalSupply`, `BalanceOf`, `Allowance` — exist here with the same names and
the same signatures. The write half deliberately does not match, which is the
subject of the paragraph above.

Matching the NAMES is not matching the wire, and the difference is easy to
miss. grc20 declares `MintEvent` and `BurnEvent` and emits neither, sending a
`Transfer` with an empty counterparty instead, because that is the ERC20
convention and what indexers sum to reconstruct balances. Emitting "Mint" and no
Transfer would leave a standard indexer watching the supply appear from nowhere
and every derived balance come out short — while every name in the log matched
the standard exactly. Both go out.

Deliberately not implementing `grc20.Teller`, either. The SECURITY note on
`types.gno`'s `Teller` tells every consumer to reject anything that fails
`IsCanonicalTeller`, so satisfying that interface is worthless to a careful
caller and misleading to a careless one.

The clock is an epoch counter over block height, not height itself and not
time:

- Block time is unusable. `execctx` carries `TimestampNano` but production
  never sets it — every path in `keeper.go` writes seconds only — so two blocks
  under a second apart return the same `time.Now()`. `runtime.ChainHeight()` is
  the only quantity a realm can read that strictly increases per block.
- Quantising coalesces every change within an epoch into one update of an
  object already being written, and bounds archive growth by wall-clock
  activity rather than by block production.
- And it makes the anti-flash-loan property an invariant rather than a
  discipline. OZ says read at `clock()-1` and trusts you; here a transaction
  cannot outlive its block, a block cannot outlive its epoch, and `PastVotes`
  refuses the current epoch outright.

History is two points inline plus a paged archive. An account whose balance has
not moved since it was created answers from the inline slots and never touches
the archive, which is the overwhelming majority of queries; one new key buys
32 checkpoints rather than one.

## Constraints the VM imposes on the governor

Found by reading the VM, and each one would have cost a day to discover from a
failure:

- **A persisted closure must not capture `cur`.** Realm values are frame-bound
  and the save walk refuses them (`uverse.go`, `errPersistRealm`, filetest
  `zrealm_cur_persist_closure.gno`). This is why gno's own `Executor.Execute`
  takes `cur realm` as a PARAMETER and calls `e.callback(cross(cur))` rather
  than closing over it.
- **A `/p/` package cannot declare a crossing function** (`preprocess.go`, the `crossing function literal ... in non-realm package` panic),
  which settles the package-or-realm fork: an `Executor` whose method takes
  `cur realm` must live in a realm. That is why gno's own lives in `r/gov/dao`.
- **Persisted closures do work**, and the evidence is production rather than a
  test: `r/demo/defi/atomicswap` stores `sendFn func(cur realm, to address)` as
  a struct field and invokes it in a LATER transaction, with balance assertions
  proving the captured coins moved.
- **`testing.SkipHeights` resets the caller context** — OriginCaller,
  CurrentRealm, ChainID and OriginSend all go to zero. Use `testing.SetHeight`
  when a test needs to keep who it was.

## A proposal is a name and a string

The fact that decides it: **`MsgCall.Args` is `[]string`**
(`gno.land/pkg/sdk/vm/msgs.go`), and `convertArgToGno`
(`convert.go`, `convertArgToGno`) accepts only bool, string, the int/uint/float families
and byte slices — a struct, an interface, a pointer or a func panics with
"unexpected type in contract arg". So **any proposal entrypoint whose signature
contains a struct or an interface has silently restricted proposing to people
who can write and publish Gno.** That is not a small ergonomic tax; it is a
different system.

It also finishes the closure question. A realm can persist one — proven in
production, not in a test — but an account can never AUTHOR one: `MsgRun`
forces the ephemeral package private, so the save walk refuses it
(`realm.go`, "cannot persist function or method from the private realm"), and an ephemeral package may only declare `main` as a
crossing function anyway. Closures are a realm's tool, never a proposer's.

So a proposal is `(kind string, payload string)`:

- **A realm registers what may be done. An account chooses which of those to
  do, and with what data.** The governor never executes code it was handed at
  propose time.
- `Describe(payload)` and `Do(payload)` consume the same string, so what voters
  read IS what runs. A stored closure cannot have that property: its `String()`
  is prose typed by the proposer, with nothing tying it to the code.
- Whether a kind may ever run at all becomes its own vote, separate from
  whether to run it this time. The closure model fuses those two into one
  decision made on a description.

Per-kind rules rather than one global quorum, which is why every OZ DAO's bar
is either too low for its money or too high for its chores. Thresholds in basis
points as int64, never float64 — a governance threshold decided by binary
floating point is a rounding argument waiting to happen.

The electorate is snapshotted at propose. Recomputing it live means passing a
fast membership change moves the denominator under every proposal already open,
lowering a bar that voters already cleared.

And the governor must hold no assets, for a reason with no EVM analog: a
handler can mint a realm banker and RETAIN it, since authorisation happens at
construction and the banker keeps no realm reference. One hostile adopted kind,
run once, is a permanent unrevocable spending capability over the governor's
address. If the address holds nothing, the capability is worth nothing.

## Alternatives weighed and refused

- **Reusing `p/nt/commondao`.** commondao is a Council — `a set of addresses
  with equal voting power` — whose proposals snapshot that council at creation
  and are decided by the constitution's own arithmetic: a supermajority of
  `3*yes >= 2*D` passes and `2*no > D` dismisses, over `D = |electorate| -
  abstains`. It is good, and none of the three differences below is about
  quality.

  Its electorate is a cardinality and ours is a checkpointed balance. Epochs,
  PastVotes, a snapshotted denominator, the whole anti-flash-loan property —
  all of it exists because weight moves and can be borrowed. A council has no
  such problem and correctly does not solve it.

  Its rules are the constitution's; ours are six terms per kind, tunable by
  vote. Taking commondao's means giving up `govern:rules`, which is a large
  part of what the holders here actually control.

  And it ships no governance meta-kinds on purpose — `managing a DAO's kind set
  through governance is the consuming realm's job`. Adopt, retire, rules,
  minter and batch are most of this governor's own logic, so borrowing would
  supply the easy part and leave the hard part exactly where it was.

  The decisive one is a VM constraint rather than a preference. Its entrypoint
  is `Propose(creator address, kind string, args any)`, and its kinds are built
  by `New(dao ReadonlyCommonDAO, args any)`. `MsgCall.Args` is `[]string`, so
  an `args any` cannot come off a transaction at all: a consuming realm has to
  write a typed entrypoint per kind and do the string conversion itself. That
  is precisely what "a proposal is a name and a string" was chosen to avoid,
  and it is why a kind's Describe and its Do here consume the identical string.

  The seam that would make reuse real is the ELECTORATE, and it already exists.
  A test drives this whole governor on a council — one address, one vote — by
  swapping the one line that names the electorate. Which is to say the
  composition this bullet kept asking about has been available the entire time,
  in the direction that costs a line rather than a dependency.

- **Moving the governor ENGINE into a `p/` package.** A `p/` package holds no
  state, so the engine would become a
  struct the realm allocates and threads through every call — and it cannot
  declare crossing functions, so the realm would still write every entrypoint
  as a wrapper. The result is the same surface an auditor reads, with a layer
  of indirection under it, for a reuse nobody has asked for.

  What reuse actually needs is the ELECTORATE, and that seam is one line:
  `var voters electorate = tokenVotes{}`. A test drives the whole governor on a
  council — one address, one vote, no balances, no checkpoints, no delegation —
  and quorum, threshold, the early decision and the deadline all behave. Forking
  the realm and swapping that line is cheaper than a package, for everybody.

  The checkpoint store is a different case: pure data structure, no crossing
  functions, no realm state. The engine has none of those properties.

- **The checkpoint STORE, which IS a `p/` package**: `p/cryptocourt/checkpoint/v0`.
  That half needs no crossing functions at all, which is what makes it the half
  that can move. It is the honest gno reading of ERC20Votes-as-a-reusable-extension: in
  Solidity the extension is inherited and brings the token with it, here the
  reusable part can only ever be the storage machinery, and the realm still
  writes its own Transfer and Delegate.
Two things that could only be settled on a chain, and were. Execution after the
full two-day timelock works — 34,560 blocks, an hour of sending, kept behind
`SLOW_EXECUTE`; the checkpoint layer's own curve is behind `SLOW_ARCHIVE`, six
sealed epochs, for the same reason. And a realm that is not `govern` can publish
a power: `r/cryptocourt/offerer` does, on a chain. `Offer` takes a Kind
INTERFACE and `MsgCall` cannot carry one, so that needed a realm to exist rather
than a test. See "Proven on a chain" below.

## The premise, measured

Every choice in the checkpoint store rests on one claim: a new key costs far
more than an update. It is read off `store.go`, and measured on a live chain by
`TestIntegrationGovernTokenOnChain` — two
mints that differ only in whether the recipient already had a record, with the
flat gas fee subtracted so what remains is the storage deposit:

| operation | bytes | storage deposit |
| --- | --- | --- |
| first mint to an address (creates the record) | 1,781 | 178,100 ugnot |
| second mint to the same address (updates it) | 24 | 2,400 ugnot |

Seventy-four times. Read off the `StorageDepositEvent` every transaction
carries, rather than by differencing account balances — differencing works but
has to subtract a gas fee written down in another file, so the measurement
depends on that file not changing.

The byte column is the durable one. The fee is bytes times a chain parameter —
literally a parameter, `storage_price` in `params.go`, whose default is the
100ugnot used above — so a chain that reprices storage moves every ugnot figure
here and none of the byte figures. The test asserts the ratio in both. The test asserts ten, which is far below what it measures
and far above what a design built on the opposite assumption would produce, so
it catches a regression without breaking the day the chain reprices bytes.

### What a checkpoint costs, epoch by epoch

Measured the same way, transferring repeatedly and sealing an epoch between
rounds:

| transfer | bytes |
| --- | --- |
| second and later inside one epoch | **0** (24 while a balance is still growing a digit) |
| first in a new epoch, before the archive is touched | 0 |
| first in a new epoch, creating the archive's first page | **8,467** |
| first in a new epoch, appending to that page | 212, then 158 |

Three things fall out of this that the design assumed and had not checked.

Coalescing inside an epoch is not cheap, it is FREE — the transaction carries
no deposit event at all, because the record was rewritten at the same encoded
size and there is no delta to charge for. That is the whole argument for
quantising the clock, and it holds exactly.

With one honest qualification, found when this was asserted rather than
measured. Free means no CHECKPOINT is written; it does not mean the record
cannot change size. In an account's first epoch the balance is still small and
growing a digit at a time, and the deposit is charged on the delta of the
ENCODED size — so a second transfer there costs about 24 bytes, which is the
same figure a second mint to an existing address costs and for the same reason.
From the second epoch on, once the numbers have settled into their encoding,
the delta really is nothing. The design claim is intact; the table said 0 where
it meant "0, once the encoding stops moving".

The expensive unit is not a "key" in the abstract, it is a bptree NODE. Eight
and a half thousand bytes is the archive tree's first node, not one page — it
is nearly five times a whole new account record, and it is paid once and then
not again until the node splits. Later pages land in the node already bought.

And the first roll out of the inline slots is free, because the second slot was
still empty so nothing was archived. The two-slot design earns its keep in the
plainest possible way here: an account's first move into a new epoch costs
nothing at all.

### What governing costs

| operation | bytes |
| --- | --- |
| the FIRST proposal on a realm | 17,788 |
| every proposal after that | ~8,786 |
| the first vote on a proposal | 508 |
| every vote after that | 454 |

The first proposal is not what proposing costs — it is what starting costs. It
buys the first node of the proposals tree AND of the open index, and nothing
pays for those again until they split. Measuring one proposal and reporting it
as the price would have been wrong by more than three times when this was first
measured, and by about double now.

Both proposal figures grew by about 4,900 when the voter roll started being
bought at Propose rather than by the first voter — see "Charging the proposer
for the voter set" below, which was written when it went the other way and now
records both the argument and the reversal.

Every vote costs the same, and it took two changes to get there. The roll's
first node moved to the proposer, which is the whole of the gap between 508 and
4,955. And the value stored per voter is a packed int64 rather than a struct,
which is the whole of the gap between 454 and 846: the tree hands out each
value as its own object for lazy loading, and a struct there is a SECOND object
per vote. 405 bytes of object header, on every vote, for two fields that fit in
one word with four orders of magnitude to spare.

A later vote cannot be free, and measuring one at zero means measuring the
wrong thing: a vote that DECIDES the proposal settles it, the refund for the
freed node cancels the cost of the entry almost exactly, and what gets reported
as a cost is the sum of a real cost and an unrelated refund. The test carrying
these figures keeps the proposal active across both measurements for that
reason, and says so where it does it.

It asserts the ratios rather than the counts, because the counts move a few
bytes whenever a string in the realm changes, and a test that fails on that gets
deleted rather than read.

### The voter set stays at fanout 32, measured

A narrower tree looked like free money: the first voter pays for the first NODE,
and a 32-wide node is mostly empty on a proposal three people vote on. bptree
takes any fanout down to 4, so this was cheap to try. Nine voters, one
proposal, measured at both:

| voters | fanout 8 | fanout 32 |
| --- | --- | --- |
| 1 | 2,717 | 4,973 |
| 2–8 | ~420 each | ~420 each |
| 8 (cumulative) | 5,690 | 7,946 |
| 9 (cumulative) | 11,166 | 8,369 |

Fanout 8 is cheaper by a flat ~2,256 bytes for the first eight voters and then
the ninth splits the tree — a new leaf AND a new root — and pays 5,476, which is
thirteen times what the eighth paid and more than the original node cost.

Kept at 32 for the reason that cliff is: it lands on whoever happens to vote
ninth, and nine is an ordinary turnout. A governance realm that charges a
person thirteen times the going rate for arriving in the wrong order is
punishing participation, and doing it invisibly. Fanout 32 has the same cliff
at the thirty-third voter, which is rarer and no better shaped, but 2,256 bytes
is a poor price for moving it eight times closer.

It is also a float rather than a cost: the node comes back when the proposal
settles. The saving would never have been permanent, and the penalty would.

Written down because the reasoning does not survive in the code — `NewBPTree32()`
looks like a default nobody thought about, and anybody noticing that the first
vote costs eleven times the second will have exactly this idea.

### Who pays for the voter roll, and for its first node

Two separable questions, and the expensive one is the second.

The roll is allocated when a proposal OPENS, so the proposer pays for a
structure that exists to serve voters. Allocating it on first use instead is
near enough zero-sum — measured both ways, 752 bytes off one and 740 onto the
other:

| | proposer | first voter |
| --- | --- | --- |
| allocated at Propose | 3,790 | 4,973 |
| allocated on first vote | 3,034 | 5,713 |

Neither choice moves the expensive part. A bptree allocates nothing until its
first key, and its leaf carries fanout-sized backing arrays, so the roll's first
NODE — about 4,500 bytes — is bought on the first Set either way. Voting first
costs eleven times voting second.

The proposer pre-buys it, by writing a sentinel key at Propose that no address
can collide with:

| | propose | first vote | later vote |
| --- | --- | --- | --- |
| first voter buys the node | 3,829 | 4,955 | 441 |
| proposer pre-buys it | 8,786 | 508 | 454 |

Two real costs, worth stating rather than glossing. The sentinel is about 440
bytes nothing will ever read, so the total goes UP: propose plus first vote is
9,294 against 8,784. And the penalty it removes was already recoverable by the
person paying it, since `ReleaseRoll` is permissionless and refunds whoever
calls it — fronting a cost you can reclaim is a different thing from bearing
one.

What outweighs them is whether the proposer and the first voter are the same
person. On a token where most holders never vote — which is what a court is,
and what `EngagedTotal` exists to measure — they are usually not, and the first
voter is the participant a proposal most needs. Eleven times the going rate,
refundable only by taking a second action later, is a real deterrent placed at
the exact moment participation is scarcest.

The argument on the other side is genuine: deferring the cost makes an
unanswered proposal cheaper, which is the direction `maxLive` and `ProposeBps`
both push. It is worth less than participation at the margin, and reasonable
people would weigh the two differently.

### The unit of cost is a node, not a key

Predicted from the archive measurement above and then checked, by minting to
forty successive new holders and pricing each:

| holder | bytes |
| --- | --- |
| 1 | 6,300 — the tree's first node |
| 2 – 32 | 1,737 – 1,781 |
| **33** | **11,430** — the node fills and splits |
| 34 – 40 | 1,737 – 1,781 |

Re-measured since, forty holders in one run: every row above holds to the byte
except the first, which had been recorded as "~11,000" and is 6,300. A first
node and a SPLIT are not the same event — a split allocates a new leaf and a
new root, which is why the thirty-third holder pays nearly twice what the first
did. Two different costs had been collapsed into one number.

Asserted now rather than measured by hand, in `internal/chain`. The SHAPE, not
the bytes: that the middle of the curve is flat, that the thirty-third holder
costs several times a steady one, that the thirty-fourth comes back down, and
that the first node is dearer than a holder and cheaper than a split. Narrowing
the tree's fanout to six fails it in two places with the right complaints,
which is how the assertions were checked.

So a bptree32 node holds thirty-two entries and costs about eleven thousand
bytes, and the honest cost of a new holder is not 1,757 bytes but

    1,757 + 11,430/32  ≈  2,114 bytes amortised.

This is the correction to the vocabulary the rest of this document uses. "A new
key costs far more than an update" is true — 1,757 against 24 — but the cost
does not arrive per key. It arrives in lumps — eleven thousand bytes every
thirty-second key HERE — and a design that adds a key per something is buying a
thirty-second of a node each time.

The size of the lump is not a constant. It is this tree's, holding these
values; the voter set's node is about 4,500 at the same fanout because its
values are integers rather than account records. Measure the tree you are
about to add a key to.

### Why the voter set is per-proposal and not one shared tree

Because a shared tree looks cheaper and is not, once cleanup is counted.

A tree per proposal costs a whole node the first time anybody votes — around
4,500 bytes for a set that may hold one voter. Not the eleven thousand a node
costs above: a node holds its values, and a voter set's are int64s where the
account tree's are records, so the same fanout is less than half the price. The
lump is a property of bptree AND of what goes in it, which is easy to lose once
the number has been written down once. One shared tree keyed
by (proposal, voter) would spread thirty-two votes across a node however they
fall, so a proposal with one voter would cost one entry rather than a node.

What settles it is what happens afterwards. Dropping a per-proposal tree is one
assignment, and the deposit comes back to whoever wrote the outcome down — that
is the incentive that makes permissionless settling work at all. Clearing a
range out of a shared tree is a removal per voter, unbounded in the number of
voters, and bptree forbids removing during iteration, so it is collect-then-act
over a list with no ceiling.

Bounded worst case with O(1) reclamation beats a lower average with an
unbounded sweep. maxLive caps the concurrent trees at sixty-four, of which
`govLanes` keeps eight for the governor's own kinds — see the flood below.

Freed storage is refunded, to whoever sent the transaction that freed it
(`keeper.go`, `refundStorageDeposit`, with `receiver := caller`). Measured the
same way, cancelling a proposal that had one vote recorded against cancelling
one that had none:

| operation | net cost to the caller |
| --- | --- |
| cancel a proposal with a vote recorded | **−62,500 ugnot** (the caller gained) |
| cancel a proposal with no votes | 433,000 ugnot |

Both refund; the one carrying a voter set refunds about 495,500 ugnot more, and
enough to more than cover the flat million of gas. Some small part of that gap
is the payload being longer in one case, but nothing near the size of it — a
`bptree32` node is sized for its slots rather than its contents, so a set with
one voter in it costs about what a full one does.

**Measured when a terminal state dropped the roll, which it no longer does.**
The roll now survives until `ReleaseRoll`, so the gap between those two rows
has moved rather than closed: cancelling either kind of proposal frees the slot
and nothing else, and the 495,500 turns up at whoever calls `ReleaseRoll`
afterwards. Left as measured rather than re-run, because what the two rows were
measuring — that a voter set is worth far more than the gas to free it — is
what has to stay true, and it does.

Which is the incentive that makes permissionless cleanup work, now in two
pieces rather than one. Settle and ReleaseRoll both decide nothing and anyone
may call either; before, settling cost gas and returned nothing, so nobody
would. Now writing down a finished proposal hands the writer the slot, and
reclaiming its roll hands the reclaimer the rest — separately, because a kind
that pays the people who voted has to read the roll after the proposal is
over, so the two refunds cannot both be taken at the same moment.

That ratio is the whole argument for epochs over blocks, for two inline slots
before the archive, for paging, and for keeping a record alive at a zero
balance. None of those are worth anything if the ratio is near one.

### What a launch costs

The one figure a deployer has to fund before anything else works, measured by
`TestIntegrationGovernDeploys` rather than remembered:

| | |
| --- | --- |
| gas to publish the realm | about 173 million |
| storage deposit | 108,393 bytes — 10,839,300 ugnot at the default price |

Both fell when the ledger moved to `/p/`: a realm's deploy pays for its own
source, and roughly a tenth of it is now published once as a package that other
realms share rather than every time somebody forks this one. The dependency
deploys are separate transactions with their own deposits, so this is a
reapportioning rather than a saving — the difference is who pays, and how often.

Rounded on purpose. The gas moves whenever a comment does — two runs a few
edits apart measured 187,858,573 and 187,900,714 before the split — so an exact figure written
here is stale by the next commit, which is how the hand-measured tables this
document used to carry went wrong. The test logs the current cost on every run
and names it in the failure when the ceiling fires.

`AddPackage` compiles AND stores the source, so both scale with the file,
comments included. Three quarters of the govern realm is comments; that is a
deliberate trade, and this is its price. It is also why the design records live
in `docs/` — `ReadMemPackage` takes the whole directory, so a plan file beside
the code is published with it.

The test holds the gas to a ceiling of 400,000,000 rather than to the figure,
because the figure moves whenever a comment does and a test that fails on prose
gets deleted rather than read. What the ceiling catches is a doubling, and it
names the current cost when it fires so the next person has the number. It
fails outright if no deposit event arrives at all, since a launch budget that
is not being measured is a launch budget that has quietly stopped being true.

## Proven on a chain

The parts that can only be true of a chain, checked on one:

| | |
| --- | --- |
| the package deploys, then the realm against it | order matters and cannot be undone |
| init() captures the deployer as minter | no unit test can — a harness has no deployer |
| propose, vote, settle | weight read from the checkpoint store through the package |
| the timelock refuses early execution | a delay that failed open looks exactly like one that works |
| **execute, after the full two-day delay** | 34,560 blocks, about an hour of sending |
| a foreign realm offers a Kind | the extension point, from a realm rather than a filetest |
| every documented event, emitted | gno's test stdlib cannot read events at all |
| storage arrives in lumps, not per key | the premise every other figure is reasoned from |
| **the two inline slots earn their keep** | six sealed epochs; the free roll is invisible elsewhere |

The execution run is the expensive one, and the only one that reaches the
timelock. The built-in kinds hold a decision for two days and gnodev makes a
block only when there is a transaction, so getting there means sending 34,560 of
them: about an hour, and between 3,700 and 4,500 seconds depending on the
machine. It ends with the mint given up — State is `executed`, `Minter()` is
empty, and minting refuses with "the supply is fixed".

Worth re-running rather than trusting after a change to the tally, because the
whole point of this row is that the delay is the part no unit test can reach.

## What the tests hold

A hundred and forty-three tests across three gno packages, three filetests, and
ten integration tests against a live chain:

| | |
| --- | --- |
| `r/cryptocourt/govern` | 123 tests, 3 filetests |
| `p/cryptocourt/checkpoint/v0` | 15 tests |
| `r/cryptocourt/offerer` | 5 tests — the worked example, and the fixture that proves the extension point |
| `internal/chain` | 10 `TestIntegrationGovern*`, needing a node (two behind flags) |

The token checkpoints voting power on every balance change; the governor votes
that history; the checkpoint store is a package either of them could be swapped
out from under.

The suite is written against mutation testing rather than against coverage:
`scripts/mutate.py` changes the source on purpose and reports which change no
test objected to. What that reliably finds is assertions that cannot fail — a
test that asks a zero-valued series and so never reaches the archive it is
about, a deadline test that reads the deadline off the proposal it is
measuring, a paging test parameterised by the page size it is checking, a
refusal test that asserts only the prefix every refusal shares.

`make isolation-test` covers the other way a test lies: a gno test file shares
package state and these suites do not rewind the clock, so a test can pass
because of the test that ran before it — needing a kind a neighbour registered,
or asserting a holder was empty at an epoch that only predates them because
something else moved the clock. Each test is run as the only test that runs.

The properties worth naming, because each one is a test rather than an
intention:

- A balance acquired after a proposal opens cannot vote on it. Refused at the
  door, not merely outweighed.
- A decided proposal closes on the arithmetic rather than waiting out its
  timer — computable only because the denominator was snapshotted. In BOTH
  directions: as soon as no remaining vote could take the threshold away, and
  as soon as none could reach it. Only the first is obvious, and without the
  second a decided yes closes at once while a decided no sits out its deadline
  holding a slot.
- Nothing passes without somebody voting for it, whatever the threshold is set
  to. Abstain counts towards turnout and stays out of the threshold — which
  means the threshold's denominator, yes+no, is empty on a proposal everybody
  abstained on. Compared naively that is 0 against 0, and it passes with nobody
  in favour: every number on the page correct, the state succeeded, and no
  arithmetic a reader checks disagreeing with it.
- Reading never writes, and what a read works out is not what the realm has
  recorded. State and Render compute an outcome; only a transaction stores one.
  Every check that acts on a proposal settles it first, and the page says when
  a decision is true but unrecorded — because the alternative is a governor
  whose reads quietly cost storage.
- Retiring a kind kills the proposals of that kind already decided and not yet
  run, and says so on the page where somebody votes to retire it.
- Offering a kind grants nothing. Publishing code and letting that code hold
  the governor's authority are different decisions and take different actors.
- A rules change cannot move the bar under a vote already being cast, because
  each proposal keeps a copy of the rules it opened under.
- A voter may say why, and the realm carries none of it. VoteWithReason emits
  the reason on the Voted event and stores nothing — measured at 454 bytes with
  a reason and 454 without, against a plain vote in the same position.
- The governor's own kinds cannot be impersonated or retired. They CAN be
  retuned, including the bar for adoption itself — holders who cannot move
  their own bar are stuck with whatever the deployer guessed on day one.
- The slot reclaim cannot be held shut by the people filling the slots. It
  scans a window of the open index, the index is keyed by a digest of the
  payload, and a proposer chooses their payload — so the window rotates rather
  than always starting at the low end.

One VM behaviour worth having checked rather than assumed: mutating a `*page`
fetched from the tree, without calling Set, really is tracked. Every field write
goes through `m.Realm.DidUpdate` in `op_assign.go`, which marks the base object
dirty (`realm.go`, `MarkDirty`) — so the archive persists and the cheap append
is safe. Had it been otherwise, archived checkpoints would have vanished between
blocks and only an old query would have noticed.

## Five ways this could go wrong, and what stops each

Each is a live capability rather than a hypothetical, and each is closed by a
specific line rather than by care.

**A kind holding the governor's realm capability.** If `Execute` passes its live
`cur` into `Kind.Do`, then inside a foreign kind's `Do` `IsCurrent()` is true and
`PkgPath()` is `gno.land/r/cryptocourt/govern`. That is not "the realm as data",
it is govern's authority: the kind can `cross()` into any realm that trusts
govern and be seen as govern, issue this realm's tokens, and call `Mint` as the
realm itself. One adoption vote, cast to grant one power, hands over the
governor's identity everywhere it is trusted. `Do` gets `cur.Sub(kind)` instead:
distinct pkgpath, distinct address, `RealmIssue` refused by the VM.

This is also why the mint must not be handed to the realm's own address. "The
only way to mint becomes a proposal" holds only if something can present that
address, and after the Sub nothing can — there is no built-in kind that mints.
Ending the mint outright is the real answer.

**A grace period of zero.** A Succeeded proposal keeps its place in the open
index until it runs. With no grace period nothing ends one — Cancel refuses a
decided proposal, Settle and sweep find nothing to change — so the slot is held
for the life of the realm. Sixty-four like that and nobody can open a proposal
again. No hostile handler is needed: any grace-zero proposal nobody executes
does it. `saneRules` refuses zero, which makes "every proposal eventually gives
its slot back" true by construction.

**One kind taking every slot.** Sixty-four slots as a single pool means a kind
adopted for one purpose can hold all of them: sixty-four proposals of something
cheap with a long voting window, and nothing else can be asked until the window
runs out — including the `govern:rules` vote that would shorten it. Nothing
breaks and nothing is stolen; the realm stops being governable, which is worse,
because every other kind of congestion is something the holders can vote their
way out of. The bootstrap terms make it cheap: `ProposeBps` is zero, so any
holder may propose, and sixty-four proposals is about 56 GNOT of refundable
deposit held for a bootstrap voting window of a week.

`govLanes` keeps eight of the sixty-four for the governor's own kinds, using the
`isReserved` predicate two other callers already need. Eight rather than one
because the governor has five kinds and they are not alternatives — a lane that
fits only one question means the first blocks the rest at exactly the moment
several answers are needed. It does not stop the flood: the board fills,
ordinary business is refused, and the holders vote their way out. The guarantee
is only that they can.

A per-kind cap is the other candidate. It needs a counter per kind that
`release` has to maintain exactly, and it does not on its own guarantee a lane —
many kinds under their own caps still fill a shared board.

**The slot reclaim held shut from outside.** `sweep` scans a bounded window of
the open index. Starting that window at the lowest key is fatal, because the
index is keyed by `digest(kind, payload)` and a proposer picks the payload, so a
proposer picks their key: park eight long-running proposals on the lowest keys
and the window never sees past them. The reclaim frees nothing while the other
fifty-six slots hold finished business, and the governor refuses every new
proposal with "too many proposals are already open" when most of those proposals
are over. Getting under the lowest of fifty-six random keys is a few hundred
hashes offline. The cursor rotates instead.

What makes this easy to miss is a plausible-sounding comment: that Cancel and
the passage of time both free a slot. Cancel does; time does not — a read can
work out that a proposal is over but cannot write it down. While that reads as
true, `sweep` looks like a convenience and what it scans first looks like it
does not matter. It is the mechanism, and what it scans first is a security
property.

**Swapping the code under an adoption vote.** Refusing to replace a kind only
once it is ADOPTED leaves the window between offering and adopting open: publish
harmless code, wait for the adoption vote, re-offer hostile code under the same
name while holders are voting, and the vote cast on the first description adopts
the second implementation. gno's own daokit has the same shape and records it as
a TODO. A name is bound to its code permanently; new code takes a new name,
which the holders then have to adopt knowingly.

And the unilateral power that has no exploit because it needs none: an unbounded
minter. New supply is new voting power, so a minter who can mint without limit
can out-vote every holder at will and no proposal can stop them — the vote would
be decided by tokens minted to defeat it. It moves by vote, and can be ended
outright: a fixed supply is a promise that cannot be made any other way, because
there is nobody left to break it.

## Batching, and the question it forces

`govern:batch` runs several adopted kinds as one decision. Partial failure is
settled by there being no partial: a member that errors panics, which aborts the
transaction and unwinds everything the earlier members did, because there is no
rollback in gno short of ending the transaction.

The visible consequence is that a failed batch leaves its proposal Succeeded
rather than Failed — the transaction wrote nothing at all, including the failure
— so it can be run again and will keep failing until the world changes or the
grace period ends it. That is the honest reading: it did not happen.
Single-member kinds keep the other behaviour, since there is nothing to be
atomic with respect to.

## The electorate seam

The engine reads an `electorate` interface — past votes, past total, engaged
total, current epoch — rather than calling the token directly, so everything
about proposals is independent of what supplies the weight.

It pays for itself in the tests. Quorum and threshold at their exact boundaries
are the arithmetic most worth testing and the hardest to reach by minting:
reaching exactly 30.00% of a real supply means solving for it, and a test that
does arithmetic to check arithmetic proves nothing. Against a stated electorate
the boundary is just stated. All three mutations of the comparisons fail it — a
`>` where a `>=` belongs, on either bar, and counting abstentions inside the
threshold they are meant to stay out of.

It is also the seam that makes reuse real without a package. A test drives this
whole governor on a council — one address, one vote, no balances, no
checkpoints, no delegation — by swapping the one line that names the electorate.

## Shape

    realm/p/checkpoint/     gno.land/p/cryptocourt/checkpoint/v0
    realm/p/grc20votes/     gno.land/p/cryptocourt/grc20votes/v0
    realm/p/governor/       gno.land/p/cryptocourt/governor/v0
    realm/r/govern/         gno.land/r/cryptocourt/govern
    realm/r/offerer/        gno.land/r/cryptocourt/offerer
    internal/chain/         the tests that need a running node
    scripts/                the guards, and the mutation runner
    docs/                   this file, and VERIFYING.md

### Where the line between /p/ and /r/ falls, and why

Three facts from the interrealm spec decide it, and none of them is a
preference.

A `/p/` package **cannot declare a crossing function** (§11.1). So every
entrypoint — everything with a `cur realm` — is `/r/`, always. What a library
can offer is the bookkeeping behind one.

A `/p/` package's own state is **frozen after init** (§3.3): `Realm.DidUpdate`
panics on a write to a real `/p/`-stamped object outside init. So a library
holds no package state — and neither do its TESTS, which are part of the same
package. No shared fixture, no high-water clock, no "who is acting now": a
package-level `var` that a test assigns to panics with "package is immutable
post-init". Everything that changes during a test is a local. The rule the code
is built to is one the tests cannot cheat around either, which is a good sign
about the rule. Anything durable is a value the consuming realm
allocates, which is why `NewLedger` returns a `*Ledger` rather than the package
being the ledger. The trees inside carry the consumer's storage stamp, the
storage-realm borrow (§4.2) hands the consumer's authority back for each method
call, and the deposit is billed to them.

And `/p/`-declared types **can be named by other `/p/` packages**, which is the
one that shapes the API rather than the layout. A stranger can declare a method
over a type this package exports, and the storage-realm borrow would run it
under the CONSUMING realm's authority. The defence is the encapsulation pattern
`p/demo/tokens/grc20` sets out (`gno-security-guide.md` §4): every field
unexported, no exported method handing back an interior pointer, and no method
taking a callback.

### What stays in the realm, and the one that is not obvious

The entrypoints, the deployer captured at init, and the minter policy are all
`/r/` because they need a caller. The one worth stating is `Kind.Do`.

A kind is code somebody else wrote, adopted by vote and then invoked by the
governor. That is `gno-security-guide.md` §3(C) exactly: a victim dispatching a
caller-supplied interface value while holding its own authority. A `/p/`-declared
kind on a primitive-underlying type anchors no borrow, so its body would run
with the dispatching realm's authority.

What makes it safe is not where the dispatch lives — moving it to `/r/` changes
nothing, since the realm holds its own authority there too — but that **`Do`
receives no pointer into anything**. Its parameters are an int, a realm token
and a string. There is nothing to write through, which is §3(A) arrived at from
the other side: the callback cannot name a type it could damage.

So the rule for anything added here later: a kind may be handed scalars and a
sub-realm token, and never a pointer to governor or ledger state.

## Shape, in one line each

    checkpoint   what a number used to be, as of an epoch
    grc20votes   balances, delegation, and a checkpoint of voting power
    governor     kinds, proposals, the tally, the rules, the pages
    r/govern     entrypoints, init, the minter policy, and a Dispatch
    r/offerer    a realm publishing a power for the holders to adopt

The realm is 432 lines of non-test code. It was about 2,600 before the engine
moved, and what is left is the part that needs a caller: fourteen entrypoints
that check `cur.IsCurrent()`, read who is acting and hand an address down; the
deployer captured at init; who may mint; and the one-line dispatcher that mints
`cur.Sub(subpath)` for a kind.
