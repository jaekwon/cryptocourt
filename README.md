# cryptocourt

A governor and a checkpointed voting token for gno.land.

The court system this is named for is not here yet. What is here is the layer
it needs: many independent courts, each with its own coin and its own treasury,
resolving contested claims by a vote weighted at an epoch sealed before the
fight started. The governance half of that is what this repository is.

The governance layer is an analog of OpenZeppelin's `Governor` + `ERC20Votes`
rather than a transliteration of it. Where the EVM's shape exists only because
the EVM is what it is — proposals as untyped calldata, opt-in delegation, a
storage model that charges for every extra word forever — gno gets to do the
obvious thing instead. `docs/DESIGN.md` is the record of which of those choices
were inherited, which were refused, and what was measured to decide.

## What is here

    realm/p/checkpoint/     gno.land/p/cryptocourt/checkpoint/v0
    realm/p/grc20votes/     gno.land/p/cryptocourt/grc20votes/v0
    realm/p/governor/       gno.land/p/cryptocourt/governor/v0
    realm/r/govern/         gno.land/r/cryptocourt/govern
    realm/r/offerer/        gno.land/r/cryptocourt/offerer

The `/p/` packages are the reusable half: any realm can import them and get a
checkpointed voting token and a governor over it without forking anything. The
`/r/` realms are one worked consumer.

`r/govern` is 432 lines of non-test code: fourteen entrypoints, the deployer
captured at init, who may mint, and a one-line dispatcher. Everything else it
used to hold is `p/governor` now, which any other realm can import.

**checkpoint** remembers what a number used to be, as of an epoch. Two points
inline plus a paged archive, so an account whose balance has not moved since it
was created answers without touching the archive at all. No crossing functions
and no realm state, which is what makes it the half that can be a `/p/` package.

**grc20votes** is the ledger: balances, allowances, one-hop delegation with self
as the default, and a checkpoint of voting power on every change. A `*Ledger` is
a value the consuming realm allocates, so one realm can run several — a court
per coin — and each names its own token.

It takes an acting address rather than reading one. A `/p/` package cannot
declare a crossing function and so has no caller to authenticate; the realm
above holds the `cur realm`, checks `IsCurrent()`, and passes the address in.
That is the split, and it is the reason the ledger needs no capability of its
own.

**governor** is the engine: the kind registry, every proposal, the tally
arithmetic, the rules, the slot sweep and the pages. A `*Governor` the consuming
realm allocates, over any `Electorate` and `Token` — a ledger, or a council with
one address and one vote.

It cannot run a kind by itself. Handing a kind its sub-realm token needs a live
`cur`, which a pure package has none of, so the realm supplies a one-line
`Dispatch`. What that dispatcher receives is a kind, a subpath and a payload,
and no pointer into governor or ledger state.

**govern** is one realm consuming these. It owns what only a realm can: the
entrypoints, the deployer captured at init, the minter policy, and the governor
that decides by reading the ledger's history at an epoch sealed when the
question was asked — which is what stops voting weight being bought once a
fight is visible.

A proposal is a kind name and a string. Kinds are registered by realms and
adopted by vote, so an ordinary account can propose without being able to write
Gno — which matters, because `MsgCall.Args` is `[]string` and any entrypoint
taking a struct has silently restricted proposing to people who can deploy code.

**offerer** is a worked example: a realm that is not `govern` publishing a power
for the holders to adopt. It exists as a realm rather than a test because
`Offer` takes an interface and a transaction cannot carry one.

## Running the tests

    make check            fmt, vet, and the realm suites (needs the gno toolchain)
    make chain-test       the parts that need a running gnodev
    make isolation-test   every realm test run as the only test that runs
    make selftest         break each guard on purpose, check it notices

`make check` skips the gno half cleanly if the toolchain is absent; set
`REQUIRE_GNO=1` to make that a failure instead. `make chain-test` needs gnodev
on 127.0.0.1:26657 with chain id `dev`.

Both need a gno checkout. `go.mod` carries a `replace` pointing at a local one,
which you will have to repoint; the realms target the crossing API that gnodev
serves, and the published copy the module cache would fetch still predates it.

`docs/VERIFYING.md` is the practice the suite is written against — mutation
testing over coverage, and the specific ways a test here can be green and mean
nothing.
