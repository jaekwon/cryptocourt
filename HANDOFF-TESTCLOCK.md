# Handoff: the test clock (realm/r/kourtv2/testclock.gno)

**To the session writing integration tests.** You are already using this — your
`gnoland/testdata/kourtv2_testclock.txtar` (untracked, 14:45) is what found the
bug fixed below, so read the semantics before writing more.

## What it is

A one-shot latch that lets a throwaway chain walk claims through deadlines
measured in days. Published deadlines gate on wall-clock time (clock.gno), so
no test can wait them out, and the txtar harness cannot skew a node's clock.
There is no dev-only build to hide a knob in, so the knob is in the realm and
its safety is structural:

- `init()` records the deployer (MsgAddPackage sets OriginCaller; the same
  moment meta.gno already uses to seat the meta court's admin).
- `EnableTestClock` requires **that address** on a realm that is still PRISTINE:
  no user court, and the meta court seated by init carrying no claims and no
  coin. Court *count* alone was not enough — an audit showed the meta court is a
  fully working court, so a chain with months of activity was still "virgin".
- Creating a court does **not** disarm it any more. That rule was removed the day
  it shipped: it made scenarios impossible (seed a court, then advance), and the
  audit proved the implicit seal REWOUND the clock beneath stamps already
  written, so a permissionless `StartCourt` could reopen an expired window.
- `SealTestClock` is explicit, deployer-only, one-way — and never rewinds: the
  clock keeps a floor at the highest instant it ever showed.
- **Only the deployer may advance.** The first draft checked nothing on
  `AdvanceTestClock`, so arming handed the wheel to anyone.
- Advancing is capped: ten years a step, a hundred years total. Two maximal
  int64 "forward" steps otherwise wrapped the sum negative and walked the clock
  backwards — proven, not theorised.

The deployer check is the load-bearing half: virginity alone loses a race on a
public chain, where an attacker can land a transaction in the block after your
deploy.

## The semantics you must build on: THE CLOCK IS FROZEN, NOT SKEWED

While armed, `now = base + advanced`, where `base` was captured at arming.
**Real time stops passing.** Your boundary assertion is why: a skew added to a
live clock cannot express "one second short", because the seconds the node
spends mining the intervening blocks are added underneath — which is exactly
the failure your txtar hit at line 72 (`CloseDeadClaim` succeeded when you
expected the refusal). Frozen time makes a scenario exactly reproducible:
nothing moves unless you move it.

## API

    EnableTestClock(cur realm)              // deployer, pristine realm, once
    EnableTestClockAt(cur realm, base int64)// same, at a chosen instant, so a
                                            // scenario's dates are reproducible
    AdvanceTestClock(cur realm, secs int64) // forward only; secs > 0
    SealTestClock(cur realm)                // deployer; one-way
    TestClockActive() bool                  // public: is this chain skewed?
    TestClockSkew() int64                   // public: by how much

`TestClockActive` is public on purpose — and now actually READ: `Render()`
prefixes every page with a "test chain — the dates are fabricated" banner while
armed, and `ClaimTimeline` appends a `testclock:<skew>:0` field. An accessor
nobody consults is not a disclosure, which is how the audit put it.

## What it deliberately cannot do

- **Rewind.** `AdvanceTestClock` refuses `secs <= 0`. A backwards clock breaks
  checkpoint's ordering rule and would reopen a deadline a claim already passed.
- **Move heights.** Conviction accrues per block, emission periods are counted
  in blocks, and the coin's voting snapshots are height epochs. Those stay
  honest; only *published deadlines* follow the test clock. If your test needs
  height, it still needs blocks.
- **Allocate on refusal.** `z_testclock_filetest.gno` is budgeted at "wrote
  nothing", so a rejected arming cannot make the realm pay for strangers.

## Gotcha that cost me a test

A zero `answeredAtTime`/`openedAtTime` means "claim predates the stamps" and the
gate silently falls back to its **height** arithmetic (clock.gno keeps that
fallback so pre-upgrade claims keep the deadline they were opened under). If you
hand-build claim state in a unit test, stamp the times too, or you will be
testing the height path while believing you are testing the clock.

## Coverage that already exists — don't duplicate it

- `realm/r/kourtv2/testclock_test.gno` — the guards (stranger refused, used
  realm refused, sealed-is-forever, forward-only, seal disarms) and one
  end-to-end walk of a 72h settle window with no blocks waited.
- `realm/r/kourtv2/z_testclock_filetest.gno` — the virgin-deploy path from
  outside the package, asserting a non-deployer is refused, and budgeted to
  prove a refusal writes nothing.

The in-package suite **cannot** reach the virgin arming path: all its tests
share one realm and an earlier test has always started a court. That is why the
happy path lives in the filetest. If you want more arming-path coverage, add
filetests, not unit tests.
