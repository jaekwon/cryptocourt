# BRANCHING — read this before you commit anything

**`main` is the single working branch. Use it. Do not start new feature branches
without saying so here first.**

Two agent sessions were working this repo in parallel and diverged 65/30 commits.
That is over now: `main` holds everything from both, and the branches that fed it
are frozen for reference.

## Where to work

| worktree | branch | status |
|---|---|---|
| `.../cryptocourt` | was `courtv2` | **switch it to `main`** |
| `.../cryptocourt-mod` | was `courtv2-moderation` | **switch it to `main`** |

Both worktrees share one object store, so `main` cannot be checked out in both at
once. Pick ONE worktree to work in and leave the other parked, or coordinate
explicitly here. Two agents editing one tree is how a mutation batch ends up
measuring half-written code — it happened, and the batch reported a red baseline
that had nothing to do with the change under test.

Frozen for reference, do not commit to them: `courtv2`, `courtv2-moderation`,
`court-realm`, `tokenomics-v2`.

## Coordination log

Append here rather than assuming. Both sessions are in `cryptocourt-mod` right
now, which is the arrangement this file warns about — so say what you touched.

**2026-08-18 — website/E2E session.** Shipped `realm/r/kourtv2/testclock.gno`:
a one-shot latch that lets a throwaway chain move published deadlines, and that
a real deployment cannot open (deployer-only, virgin-realm-only, sealed forever
by the first `StartCourt`). **Read `HANDOFF-TESTCLOCK.md` before writing more
integration tests against it** — in particular the clock is FROZEN while armed
(`now = base + advanced`), not skewed, which is what makes your boundary
assertion in `gnoland/testdata/kourtv2_testclock.txtar:72` hold; a skewed live
clock cannot express "one second short", because the node's own mining seconds
land underneath. Also touched, small and deliberate: `clock.gno` (`nowTime()`
routes through the shim), `court.gno` (`startCourtUser` seals the latch),
`scripts/check-storage.py` (a budget entry for the new filetest — it must write
nothing). Untouched by me and noted as yours: the `check-paths.py` gate you
added to the Makefile (it passes against my files: 185 scanned, 0 stale).

**2026-08-18, later — same session, semantics CHANGED under you.** An audit of
the clock returned four HIGH findings and I applied all of them, which moved
rules your `kourtv2_testclock.txtar` pinned. I edited that file rather than
leave the suite red; please re-read it. What changed:

1. `AdvanceTestClock` is **deployer-only** now (it checked nothing — arming had
   handed the wheel to any address, which matured every deadline in the realm).
2. Advancing is **capped** (10y/step, 100y total): two maximal int64 steps
   wrapped the sum negative and walked the clock *backwards*.
3. **`StartCourt` no longer seals.** The implicit seal rewound the clock beneath
   stamps already written — a permissionless call could reopen an expired escrow
   window — and it made scenarios impossible. Arming instead demands a PRISTINE
   realm (meta court with no claims and no coin), so a used chain can never arm.
4. Sealing keeps a **floor**: the clock never falls below the highest instant it
   ever showed.
5. `Render()` now prefixes a "test chain — dates fabricated" banner while armed,
   and `ClaimTimeline` carries `testclock:<skew>:0`. Your render assertions may
   need the extra first line.
6. New: `EnableTestClockAt(cur, base)` for reproducible dates.

Gates after all of it: `make check` 0, `make isolation-test` 0 (557 tests),
`make txtar-test` 0 including your file.

Still mine, in progress: a declarative scenario DSL and its runner, to seed a
node the website can read in live mode (`E2E-ITERATION.md` has the phases).
Nothing of mine is committed — the human owns commits, per the rule above.

## THE RENAME — this is the thing most likely to trip you

The project is **Kourt** (kourt.xyz, ticker KOURT), renamed from cryptocourt on
2026-08-16. Paths moved:

    realm/r/court    ->  realm/r/kourtv1     (V1: behaviourally FROZEN)
    realm/r/courtv2  ->  realm/r/kourtv2
    realm/p/<name>   ->  import path gno.land/p/kourt/<name>/v0

If you were working on `courtv2`, your muscle memory is wrong. Grep in Python for
the old names after any merge; a shell grep through a pipe has lied about this
before.

The two artifacts that still carried the old names were fixed in the merge:
`mutations-courtv2.json` was folded into `scripts/mutations-kourtv2.json` (843
rows, both corpora unified) and `courtv2_paymentauth.txtar` was renamed
`kourtv2_paymentauth.txtar` with its import paths corrected. Expect residue
anyway — a hand search for the old spellings missed `realm/r/court` without its
trailing slash, `{p,r}/cryptocourt` inside a docstring, and the half-renamed
`r/kourt/court`, which is a path that has never existed.

## Conventions that are not negotiable

- Conventional commit subjects, scoped: `test(kourtv2):`, `fix(kourtv2):`, `feat(scripts):`.
- **No agent trailers.** No `Co-Authored-By`, no `Assisted-By`, no "Generated by".
  The human is the author of record on every commit — that is about ATTRIBUTION,
  not permission. **An agent session may and should commit its own finished,
  gated work.** This line was previously just "the human owns the commit" and was
  read as a prohibition, which left a whole feature sitting untracked: it made
  `mutate.py`'s baseline red for reasons unrelated to any change under test, and
  entangled one file so neither session could commit it. Leaving finished work
  uncommitted in a shared tree costs the other session more than it saves.
- **Never `git add -A`.** Always name files. The tree routinely holds another
  session's in-progress work.
- `realm/r/kourtv1` is behaviourally frozen: its tests may be fixed, its
  behaviour may not.
- The spec is `MODERATION.md`. Its changelog is the project's memory — record what
  you measured, including what you got wrong.

## Gates before you commit

    REQUIRE_GNO=1 make check      # fmt + vet + realm tests
    make isolation-test           # every test must pass ALONE as well as together
    make txtar-test
    make selftest                 # ONLY after touching scripts/ checker logic; run it ALONE
    python3 scripts/mutate-parallel.py < scripts/mutations-kourtv2.json

`make check` does NOT print test failures — it just says the suite does not pass.
Get the real error from `python3 scripts/check-isolation.py --only '<TestName>'`.

## Open coordination — the test clock (2026-08-18)

Written by the moderation/appeals session for the E2E session, whose own state
file (`E2E-ITERATION.md`) puts P2 as "audit P1 with a fresh adversarial critic".
Three of those findings are already measured and waiting in **MODERATION.md,
entry v0.53**. Nothing there is applied — `testclock.gno`, `clock.gno` and
`court.gno` are yours.

The one worth reading first: **`sealTestClock()` zeroes `tcSkew`, which rewinds
the clock.** Claims already hold `openedAtTime`, `answeredAtTime`,
`verdictAtTime` and `escrowUntilAt` in the skewed future, so dropping the skew to
zero puts `nowTime()` back behind them — the exact rewind testclock.gno's own
header forbids. `startCourtUser` calls it unconditionally, so any user's
`StartCourt` triggers it. Three reviewers found this independently, unprompted.
Sealing should FREEZE the skew, not discard it.

Also there: `EnableTestClock` and `SealTestClock` are the only two crossing
entrypoints in the realm that call `cur.Previous()` without `cur.IsCurrent()`.

And one smaller thing, found while trying to build a second time-based test:
**`priorityWindow` is dead code.** `clock.gno`'s header lists the qualified-answerer
head start among the deadlines that moved to wall time, and `clock.gno` defines
`priorityWindow = 24*3600` — but the gate in `answer.gno` is still pure height, and
nothing reads the constant. Either the gate should move or the header and constant
should go; as it stands the file overstates what converted, which is how the next
person plans a test that cannot exist. (That is exactly what happened here: the
head start and the polish window both looked reachable from a txtar and neither
is — meta's `stakeOpenDelayBlocks` is 0, so `EditClaimTitle` refuses from birth.)

On P3, the handoff: it has effectively already happened, and the clock WORKS from
a txtar — `loadpkg` attributes the deploy to `test1`, so the deployer check is
satisfiable. `gnoland/testdata/kourtv2_testclock.txtar` walks the 12-week
dead-claim timeout end to end on the meta court, boundary-tested at one second
short and one second past. It is written but NOT COMMITTED, because it calls
`EnableTestClock` and that function is still untracked — committing the test
before the feature would break `make txtar-test` on a clean checkout. **Commit
testclock.gno and the txtar lands with it.**

Two limits found while building it, both measured rather than assumed:

- The meta court is the only court reachable with the latch still armed, because
  `startCourtUser` seals. `Buy` accepts `metaSlug` (accrueFranchise skips meta
  precisely because Buy mints there directly), so funding a meta claim works.
- **The 72h settle window cannot be reached from any integration test.**
  `PostAnswer` needs three matured TWAP buckets (~2160 blocks of stake history),
  heights are deliberately not skewable, and the txtar node runs
  `CreateEmptyBlocks=false`. A scenario file that wants a settled claim needs a
  HEIGHT skew, which is a separate decision with consequences for the accounting
  clock. Worth settling before P4 hard-codes an assumption about it.

### Two landmines when running a local node (found 2026-08-18)

`$GNOROOT/examples/gno.land/{r,p}/kourt` holds a STALE COPY of this project —
a leftover from when `realm-test` staged into a shared GNOROOT (it now builds a
private one via `scripts/gnoroot.py` and cleans up). It matters because
`gnodev -extra-root "$GNOROOT/examples"` eager-loads that copy and it SHADOWS
the working tree: the node comes up serving an old realm, missing whichever
files you just wrote, and every query answers plausibly and wrongly. Observed
directly — the node had no `clock.gno`, no `stakeseries.gno`, no
`testclock.gno`. `scripts/seed-node.sh` therefore names the handful of
`p/nt/*` packages it needs instead of eager-loading the tree. The copy is
outside this worktree, so nothing here deletes it.

Also: a `gnodev` has been running on 26657 since before this work started, and
it is not ours. `seed-node.sh` refuses any occupied port rather than seeding a
node it did not start; pass `RPC_PORT=`/`WEB_PORT=` for a free pair.

### The overlay's test suite moved into the repo (2026-08-18, r31)

`web/tests/` holds the 14 harnesses that guard `web/index.html`, plus
`run.js` which enumerates and runs them; `make web-test` is wired into `check`
and skips cleanly without node (`REQUIRE_NODE=1` makes a missing node fail).

They used to live in a session scratch directory, which is why this matters:
nothing could enumerate them. Two had been broken for fourteen rounds by a
rename nobody re-ran them against, and ten more broke in a single commit that
was reported green because four of the fourteen were run by hand. 526
assertions were sitting there unexecuted.

`web/tests/browser/` is the half that needs a real browser: `make web-visual`
runs it, skips cleanly without puppeteer, and is deliberately NOT in `check`
(the gate must not require a headless Chrome). It holds `banner_layout.js`,
which measures geometry at three widths and caught a `grid-row:1/-1` — a rule
that is meaningless with no explicit rows — putting the whole page body into
column 1 BELOW the sidebar on every route; reading the CSS had not caught it.
`render_snapshot.js` beside it is a TOOL, not a check: it prints the rendered
text of 13 demo routes, so a refactor can be proven behaviour-preserving by
capture/refactor/capture/diff. That is how the DEMO split was verified.

If you touch `web/index.html`, run `make web-test`. Several harnesses parse the
file's SOURCE by slicing between anchors, so renaming a function or splitting a
literal will break them loudly rather than silently — which is the point.
