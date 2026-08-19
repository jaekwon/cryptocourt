# Making the clock override cover HEIGHT too

## The ruling this changes

The state file recorded, as binding: *"Accounting clocks stay on height and must
not be faked."* Owner reversed it (2026-08-18): the point of a clock override is
that a test chain does not need real blocks, and a override that covers only
wall-clock leaves conviction, emission, voting and quality windows reachable
only by mining — which is what made a mature demo cost twelve days.

## What that costs, stated before the work

1. **The banner becomes a lie unless it changes.** It currently reads "heights
   and balances are real." Once height is overridable that is false, and the
   disclosure must say so.
2. **Derived numbers become asserted, not computed.** Conviction is rate x
   blocks. Advance the height and the chain still *computes* it — but from a
   block count we handed it. The arithmetic stays honest; the input is ours.
   That is the trade the owner accepted.
3. **The real risk is a MISSED call site.** There are 66 direct
   `runtime.ChainHeight()` reads in the realm. If one is missed, a single
   transaction sees two different heights: a claim opened at fake height 20,000
   while the twap ring observes at real height 30. That is corrupt state, not a
   display bug. **A guard script, not care, is what makes this safe.**

## The height reads, surveyed

| where | count | notes |
|---|---|---|
| `r/kourtv2/*.gno` | 66 | across 16 files; moderation (16) and quality (15) dominate |
| `p/governor` | 8 | PURE package — cannot import the realm |
| `p/grc20votes` | 1 | `Epoch()` = height/epochBlocks + 1 — gates vote snapshots |

Two helpers already exist and disagree: `clock.gno:heightNow()` and
`stake.gno:runtimeHeight()`. One survives.

## Phases

**A. One shim, one name.** Extend the existing test-clock latch with a height
skew carrying the same guards the time skew already has: deployer-only,
forward-only, per-step and total caps against int64 wrap, one-way seal, and a
floor so a sealed chain never reports a height below one it already showed.
`heightNow()` becomes the single reader; `runtimeHeight()` is deleted.

**B. Convert all 66 realm sites** to `heightNow()`. Mechanical, but see (3).

**C. Guard it.** `scripts/check-height-shim.py`: no `runtime.ChainHeight()`
anywhere in `r/kourtv2` except inside the shim itself. Wired into `check`, with
a negative control proving it fails when a raw read is reintroduced. This is the
deliverable that makes "thorough" checkable instead of hopeful.

**D. The pure packages.** `p/governor` and `p/grc20votes` cannot import a realm.
The realm is their only caller, so height gets PASSED IN rather than read —
`wouldBe(p, now)` already works this way. Anything else that reads height
internally grows a parameter the realm fills from its shim. No settable global
in a pure package: that would be a capability anyone could take.

**E. Tell the truth.** `TestClockFabricated()` covers height; the banner stops
claiming heights are real; `ClaimTimeline`'s test-clock marker carries the height
skew beside the time skew.

**F. Prove it.** Unit tests for the latch (stranger refused, backwards refused,
wrap refused, seal one-way, floor kept), a scenario that reaches crystallize,
emission and a resolved dispute WITHOUT MINING A SINGLE BLOCK — which is the
whole point — plus a fresh adversarial audit, since the first version of this
latch came back with four HIGH findings.

## Acceptance — MET (2026-08-18)

`scenarios/crystal.py` needed ~17,280 mined blocks and about two hours. It now
runs against a real node in **6.7 seconds with zero blocks mined**, and it is in
the ordinary suite rather than excluded from it.

| what | before | after |
|---|---|---|
| crystallize (`scn_crystal`) | ~17,280 blocks, ~2h | 0 blocks, 6.7s |
| resolve a dispute (`scn_dispute`) | 138,240 blocks, ~15h | 0 blocks, 8.4s |
| emission accrues | 120,960+ blocks | 0 blocks, unit-proven |

Gates at close: `REQUIRE_GNO=1 REQUIRE_NODE=1 make check` exit 0,
`make txtar-test` exit 0, `make web-test` 14/14,
`make isolation-test` — 573 tests across 11 packages pass alone as well as
together (559 before this work).

### What the audit cost, and what it was worth

A fresh adversarial critic returned 2 HIGH, 4 MEDIUM and 3 LOW. All applied
except LOW-3, declined as documented dead code. The two HIGHs were both mine and
both structural:

* **HIGH-1** — I made the height a LIVE skew directly beneath this file's own
  "FROZEN, NOT SKEWED" paragraph explaining why time could not be. On sealing,
  the realm reported a height BELOW ones already written into claims; `p/twap`
  and `p/checkpoint` correctly refuse a backwards clock, so every Stake and
  every Transfer in that court aborted **for ever**. My regression test missed
  it by exactly one block.
* **HIGH-2** — I sized the caps against int64 rather than against the realm.
  `touch()` walks emission periods one at a time, so one legal advance at the
  old cap cost 713,771,568 gas: past the transaction ceiling, the touch reverts,
  and every entrypoint that touches first is dead in that court for ever.

Neither was reachable by any test I would have written. Both were found by an
adversary executing the code rather than reading it.
