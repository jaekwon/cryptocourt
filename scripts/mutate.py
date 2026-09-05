#!/usr/bin/env python3
"""Change the realm on purpose and see whether the tests object.

A test suite that passes tells you nothing on its own — it passes against
correct code and against code whose guard you deleted. This breaks the code in
a specific, named way and reports which mutations no test noticed. Those are
either a missing test or a claim the code does not actually make, and both are
worth knowing.

The second kind is the common one, and the shape is always the same: a rule the
source states in a comment and nothing checks. Who may call Cancel. Whether a
proposer may withdraw a proposal that has already succeeded. Whether
PastTotalVotes refuses an unsealed epoch the way PastVotes does. Whether
NewRules puts each number where it belongs.

Two ways this can lie to you:

  A mutation whose anchor matches zero times never applied, and a suite that
  passes without it looks exactly like a mutation that survived. Anchors must
  match EXACTLY once or the row is reported as BAD ANCHOR.

  A mutant that fails to BUILD is not a test objecting. That happens when a
  mutation removes the last use of an import, and it happened for a whole batch
  when the realm gained a dependency this script did not stage. Reported as
  INVALID rather than counted as a catch.

  And a suite that is already red reports every mutation as caught. The
  baseline runs first; if it fails, nothing else runs.

  A mutant that HANGS is none of the above, and it is the one that had no bound
  at all. Flip a comparison in a merge loop and the loop stops advancing rather
  than producing a wrong answer, so the suite never finishes to object — one such
  row spun for 56 minutes and would have spun for ever, indistinguishable from a
  slow machine. Every suite is bounded by SUITE_TIMEOUT now and a row that
  reaches it is TIMED OUT: counted with the non-results, never as a catch.

Usage — a JSON list of mutations on stdin, each applied and reverted in turn:

    python3 scripts/mutate.py <<'EOF'
    [
     {"file": "governor.gno",
      "label": "anyone may cancel anyone's proposal",
      "find": "\tif cur.Previous().Address() != p.proposer {",
      "replace": "\tif false {"}
    ]
    EOF

A saved batch for the kourtv2 money path lives at scripts/mutations-kourtv2.json:

Everything in that batch is CAUGHT, and it is meant to stay that way: a batch with
a standing survivor is a batch whose output people learn to skim. Guards that are
known to be unpinned live in scripts/mutations-kourtv2-KNOWN-GAPS.json instead —
every entry there survives, deliberately, and the file shrinks as tests are
written. Run it the same way; a CAUGHT result means one can move to the main batch.


    python3 scripts/mutate.py < scripts/mutations-kourtv2.json

Needs a gno toolchain. PKGS below lists every tree this can stage or mutate.

THE REPO'S SOURCES ARE NEVER WRITTEN TO. A mutation is applied to the STAGED COPY,
inside this run's own GNOROOT, between staging and testing.

It did not always work that way, and the reasons it changed are worth keeping. When
mutations went into the repo, a run that was KILLED left one there — invisible in an
untracked tree, where `git status` reports only that the directory is new. That cost
an hour once, to a mutant that recursed forever and made every later run "hang" for
no visible reason, and it needed a whole apparatus to paper over: backup files
written beside the sources, recovered on the next run, plus a standing rule to check
`git diff` before trusting any green suite.

Worse, it made two runs in ONE worktree corrupt each other silently. The second run
would find the first's backups, "recover" them — reverting a mutation that was at
that moment under test — and the row would report SURVIVED because nothing had been
broken. That is the harness's own failure mode, a non-result reported as a result,
which this file's header warns about in three other forms. Mutating the staged copy
removes the whole class: no backups, no recovery, no rule to remember, and any number
of runs in parallel.
"""

import atexit
import json
import os
import re
import shutil
import subprocess
import sys

import gnoroot

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Both trees, because the realm imports the package and either can be the thing
# worth breaking. The package has to be staged whatever is being mutated:
# without it every mutant fails to BUILD, which is not a test objecting — and a
# build failure counted as a catch is the same lie as an anchor that never
# matched, told the other way round.
#
# A mutation names its tree with "pkg", defaulting to the realm. The package was
# unreachable from here for a long time, which meant the half of the design that
# is meant to be REUSED — and so is the half whose tests have to stand on their
# own — was the half nothing broke on purpose.
PKGS = {
    "govern": (os.path.join(REPO, "realm/r/govern"),
               "examples/gno.land/r/kourt/govern"),
    "checkpoint": (os.path.join(REPO, "realm/p/checkpoint"),
                   "examples/gno.land/p/kourt/checkpoint/v0"),
    "grc20votes": (os.path.join(REPO, "realm/p/grc20votes"),
                   "examples/gno.land/p/kourt/grc20votes/v0"),
    "governor": (os.path.join(REPO, "realm/p/governor"),
                 "examples/gno.land/p/kourt/governor/v0"),
    # Staged because the govern realm's offer filetest imports it, so leaving it
    # out makes the baseline red for a staging reason and every mutation reads as
    # caught. That is the same lie as a build failure counted as a catch, told by
    # omission.
    #
    # It said "staged but never mutated" for as long as that was true, and the
    # zero read as deliberate rather than as a hole — a package present in this
    # map with no row in the corpus is exactly as unmeasured as one that is
    # missing, and this comment explained only the staging. It now carries 8
    # rows, measured 8/8 caught, which is what says its five tests have teeth.
    "offerer": (os.path.join(REPO, "realm/r/offerer"),
                "examples/gno.land/r/kourt/offerer"),
    # kourtv2 and the packages it needs staged. Added after this harness spent a
    # whole session unusable against the realm that holds almost every guard worth
    # breaking: the money-path work (the slash reserve, the quality ratchet, the
    # carrot withholding) all lives here, and every one of those guards had to be
    # mutated BY HAND because there was no entry for it. That is the same shape as
    # the isolation guard staging 3 p/ + 2 r/ and not kourtv2 — a check that
    # measures everything except the thing most worth measuring.
    "kourtv2": (os.path.join(REPO, "realm/r/kourtv2"),
                "examples/gno.land/r/kourt/kourtv2"),
    # The packages kourtv2 actually imports. NOT cshares or tickbook: the import graph
    # says only the V1 court realm uses those, and V1 is deliberately absent here, so
    # staging them added two suites to every mutation for nothing. (v0.57 claimed the
    # realm-test set's seven were all needed; that was wrong — kourtv2's imports are
    # curve, governor, grc20votes and twap, plus checkpoint transitively.)
    #
    # THE EXCLUSION IS A COST DECISION, NOT A VERDICT ON THOSE SUITES, and the
    # difference matters: a package outside this map is unmeasured, and unmeasured
    # reads the same as untested to anyone who looks. So cshares was measured once by
    # hand rather than left to the assumption.
    #
    # SIXTEEN MUTATIONS ACROSS ITS CONSERVATION CORE — MintSet, RedeemSet, Resolve,
    # RedeemWinning, CloseAt, RedeemClosed and TransferFrom — every one KILLED by
    # cshares' own suite. They were not added to the corpus, because adding them
    # would contradict the paragraph above for a package nothing deployed imports;
    # they are recorded here so the exclusion is informed rather than assumed.
    #
    # The mutations were the ones that would matter if they lived: minting without
    # locking collateral, redeeming a set without burning the shares, an overdraw off
    # by one, a close price above par, the NO side paid the YES price, a paid position
    # left standing to be paid again, and an unapproved spender moving another
    # account's shares.
    #
    # tickbook, the other package in that sentence, got the same treatment: SIX
    # mutations over Place, Take and Price — a tick off the grid resting, a bid
    # resting at or above the best ask so the book crosses, a zero quantity
    # resting, a taker crossing past its own limit, a bad side coerced instead of
    # refused, and an off-grid tick priced. Every one KILLED.
    #
    # Twenty-two mutations across the two, no survivors. That is a statement about
    # two suites and NOT about the packages being sound: these are the mutations a
    # reader thought to write, and the corpus exists precisely because that is a
    # weaker guarantee than a corpus run. If either package is ever imported by
    # something deployed, it belongs in this map with rows of its own, and the
    # measurement above is where to start rather than where to stop.
    "twap": (os.path.join(REPO, "realm/p/twap"),
             "examples/gno.land/p/kourt/twap/v0"),
    "curve": (os.path.join(REPO, "realm/p/curve"),
              "examples/gno.land/p/kourt/curve/v0"),
    # ccwrap, added when it stopped being a pure adapter. It now carries a LIVENESS
    # bound — the wrap cap that keeps a court's own electorate able to clear the
    # bars quoted as a share of votable — and a guard with no mutation coverage is
    # the shape the kourtv2 note above is about. It imports kourtv2, which is
    # already staged.
    "ccwrap": (os.path.join(REPO, "realm/r/ccwrap"),
               "examples/gno.land/r/kourt/ccwrap"),
}

# Which suites can plausibly OBJECT to a mutation in a given tree: that tree's own
# tests, plus every staged tree that imports it, directly or transitively. This keeps
# the principle in run_suite's docstring exactly — a mutation caught by neither the
# package's own tests nor its importers is the finding — while cutting the common case
# from nine suites to one. Running all of them per mutation is what made the 56-row
# batch exceed a ten-minute budget and get killed mid-mutation, leaving a disabled
# guard in the source. Staging is unchanged: every tree is still staged, because the
# imports must resolve whatever is being mutated.
OBSERVERS = {
    "kourtv2":    ["kourtv2"],
    # ccwrap only: nothing imports it, so no other suite can observe its
    # mutations. Listing more would let an unrelated failure read as a catch.
    "ccwrap":     ["ccwrap"],
    "govern":     ["govern"],
    "offerer":    ["offerer", "govern"],
    "twap":       ["twap", "kourtv2"],
    "curve":      ["curve", "kourtv2"],
    "grc20votes": ["grc20votes", "kourtv2", "govern"],
    "governor":   ["governor", "kourtv2", "govern"],
    "checkpoint": ["checkpoint", "grc20votes", "governor", "govern", "kourtv2"],
}


# A MUTANT CAN HANG INSTEAD OF FAILING, and until this bound one did — for 56
# minutes at 110% of a core, with no way to tell it from a slow suite.
#
# The row was `ys[i].e == e` -> `!=` in ClaimSeries' merge loop. That loop sets
# `e` to the min of the two heads, so unmutated at least one side matches `e` and
# an index always advances; the flip makes the matching side the one that does
# NOT advance, so neither index moves, `e` never changes, and it appends rows for
# ever. A mutation like that cannot be caught, because catching needs the suite
# to finish and say so.
#
# Ten minutes per suite, because the whole batch used to fit in that budget — so
# a suite alone reaching it is not slow, it is stuck. Overridable for a loaded
# machine, where every suite is genuinely slower.
SUITE_TIMEOUT = int(os.environ.get("MUTATE_SUITE_TIMEOUT", "600"))


# GNO'S ERROR CODES, split by what they mean for a mutation run.
#
# COMPILE means the mutant never ran, so the row measured nothing and is INVALID.
# Both of these arrive with "0 build errors" in the summary line, which is why the
# count alone is not enough: gno reports a type error and a parse error as TEST
# errors. gnoParserError was found by planting an unbalanced paren, and until it was
# named here an unparseable mutant scored as a CATCH.
#
# RUNTIME means the mutant ran and something objected — which is a CATCH, and must
# not be mistaken for a build failure. gnoUnknownError is how a realm panic at init
# surfaces, deploy invariants included: the first attempt at this fix matched every
# gno*Error and threw away a genuine catch where kourtv2's own flood invariant had
# fired. Measured, on the P-CONST grc20votes Bps row.
# Read from gno's own enumeration — gnovm/cmd/gno/common.go, the gnoCode consts —
# rather than from whichever ones happened to turn up here. The first version of this
# named two, both met by accident: gnoTypeCheckError via an unused import, and
# gnoParserError by planting an unbalanced paren. Naming a set from encounters means
# the next code that appears is silently mistaken for something.
#
# SPLIT BY WHETHER THE CODE IS AMBIGUOUS, which is the only split that matters here.
# gnoImportError is the SAME types.Error case as gnoTypeCheckError, reclassified when
# the message names an unknown import path, so it is exactly as unambiguous. The rest
# all mean the package never got far enough to run.
COMPILE_CODES = frozenset({
    "gnoTypeCheckError", "gnoParserError", "gnoPreprocessError", "gnoImportError",
    "gnoReadError", "gnoGnoModError", "gnoPackageNameMismatchError",
})
# AMBIGUOUS, and the reason mutant_builds() exists. gnoUnknownError is both "the
# mutant could never run" (a planted goroutine: "goroutines are not permitted") and
# "it ran and a realm panic objected" (a deploy invariant firing, which is a CATCH).
# Listing it here says only "do not treat this as a build failure on the strength of
# the code"; `gno lint` is what actually decides it.
RUNTIME_CODES = frozenset({"gnoUnknownError"})
# gnoLintError is deliberately in NEITHER set: `gno test` should not emit it, and if
# it ever does, the unclassified path below is the honest answer rather than a guess.

def mutant_builds(root, pkg):
    """Ask the TOOLCHAIN whether the mutant compiles, instead of inferring it.

    THE ERROR CODE IS NOT A DISCRIMINATOR, and that is measured rather than
    assumed. A mutation that plants a goroutine — a mutant that cannot run at all,
    since gno excludes them — reports:

        0 build errors, 1 test errors
        governor.gno:1532:2: goroutines are not permitted (code=gnoUnknownError)

    and a mutation whose only failure is a REALM PANIC AT INIT, which is a genuine
    catch, reports gnoUnknownError too. The same code for "never ran" and for "ran
    and something objected", so no amount of naming codes can separate them. That
    is what this function is for.

    `gno lint` answers it directly, and both sides were checked before this was
    trusted: clean code exits 0 with no output; the goroutine mutant exits 1; and
    the Bps mutation whose kourtv2 init invariant panics — a real catch — LINTS
    CLEAN and only fails under `gno test`. So lint means "it built", nothing more.

    Costs about 3.3s on kourtv2 against 12.9s for its suite, and it is only asked
    when a catch is about to be scored, which is the one verdict that would be
    wrong if the mutant never built.
    """
    rel = PKGS[pkg][1]
    try:
        r = subprocess.run(["gno", "lint", "."],
                           cwd=os.path.join(root, rel),
                           capture_output=True, text=True,
                           timeout=SUITE_TIMEOUT,
                           env={**os.environ, "GNOROOT": root})
    except subprocess.TimeoutExpired:
        # A lint that will not finish is not evidence of building.
        return False, "gno lint timed out"
    return r.returncode == 0, (r.stdout + r.stderr).strip()


def run_suite(root, pkg=None, mut=None):
    """Run the OBSERVER suites for `pkg`; all of them when pkg is None (the baseline).
    Returns (passed, output, hung) — `hung` names the suites that ran out of time.

    `mut` is applied to the STAGED COPY after staging and before testing, so the repo's
    own sources are never written to. See the note in this file's header on why that
    matters more than it looks.

    More than the mutated package's own suite, because a mutation there can be caught
    by its own tests, by a realm that imports it, or by neither — and only the last is
    a finding. Running one suite and calling it the answer would report the realm as
    covering the package it merely depends on, or the reverse. But not ALL suites
    either: a kourtv2 mutation cannot be caught by twap's tests, and running them
    anyway is what made a full batch time out.
    """
    names = OBSERVERS.get(pkg, list(PKGS)) if pkg else list(PKGS)
    # One complete stage/mutate/test/unstage cycle, in the run's OWN GNOROOT (see
    # scripts/gnoroot.py) — so a long batch no longer holds a shared tree, and a
    # concurrent runner in another worktree cannot delete the mutant mid-test and
    # have it scored INVALID.
    gnoroot.stage(root, PKGS.values())
    out, passed, hung, built = "", True, [], True
    if mut is not None:
        f = os.path.join(root, PKGS[mut.get("pkg", "govern")][1], mut["file"])
        src = open(f).read()
        open(f, "w").write(src.replace(mut["find"], mut["replace"]))
        # ASKED HERE, BEFORE THE SUITES, and the placement earns its keep twice.
        # A mutant that cannot compile makes every suite fail, so settling it now
        # skips N suite runs that would prove nothing — and the staged tree only
        # exists INSIDE this function, which is what the first attempt at this got
        # wrong: it linted after the unstage and died on a missing directory.
        built, lint_out = mutant_builds(root, mut.get("pkg", "govern"))
        if not built:
            out += lint_out
            passed = False
    for nm in names if built else []:
        rel = PKGS[nm][1]
        try:
            r = subprocess.run(["gno", "test", "."], cwd=os.path.join(root, rel),
                               capture_output=True, text=True,
                               timeout=SUITE_TIMEOUT,
                               env={**os.environ, "GNOROOT": root})
        except subprocess.TimeoutExpired as e:
            # Whatever it managed to say before it was killed. TimeoutExpired
            # carries bytes on some versions even under text=True, so decode
            # defensively rather than crash the batch on the one row that hung.
            for chunk in (e.stdout, e.stderr):
                if chunk:
                    out += chunk if isinstance(chunk, str) else chunk.decode("utf-8", "replace")
            hung.append(nm)
            passed = False
            continue
        out += r.stdout + r.stderr
        passed = passed and r.returncode == 0
    for _, rel in PKGS.values():
        shutil.rmtree(os.path.join(root, rel), ignore_errors=True)
    return passed, out, hung, built


# Absolute paths throughout, since a mutation may name a file in either tree and
# there is no single directory to sit in.
#
# Module level, not nested in main(), so scripts/check-mutation-anchors.py can
# import these two instead of restating them. It re-implemented both and the
# copies were free to drift — the same argument this file makes for PKGS being
# defined once.
def where(m):
    pkg = m.get("pkg", "govern")
    if pkg not in PKGS:
        raise SystemExit(f"mutate: no such pkg {pkg!r}; have {sorted(PKGS)}")
    return os.path.join(PKGS[pkg][0], m["file"])


def anchor_count(m):
    """How many times a row's anchor occurs in its target. Exactly 1 or the row
    measured nothing: 0 means nothing was mutated, >1 means an ambiguous edit."""
    return open(where(m)).read().count(m["find"])


def main():
    muts = json.load(sys.stdin)
    if not muts:
        # AN EMPTY BATCH IS NOT A RUN. One line here, against a full baseline
        # across every staged package for nothing without it — and "0 not caught,
        # of 0" at exit 0 would be a clean bill of health for having measured
        # nothing, which is this file's oldest complaint about itself.
        # mutate-parallel already refuses one; this is the same rule at the layer
        # below, where the vacuity audit and any other caller invoking this script
        # with no batch ends up.
        print("mutate: no mutations on stdin — nothing to measure.", file=sys.stderr)
        return 1
    # One shadow GNOROOT for the whole batch, removed at exit. atexit does not run
    # on a kill, same as the backups below — but a leaked root is a directory in
    # the system temp that nothing reads, whereas the shared-tree lock this
    # replaces would block every later run until a human removed it.
    root = gnoroot.build(gnoroot.real_root(), "mutate")
    atexit.register(gnoroot.remove, root)

    # Nothing below writes to the repo. Anchors are counted against the sources
    # READ-ONLY and the mutation is applied to the staged copy inside run_suite.

    # The baseline, before anything is mutated.
    #
    # A suite that is already failing reports EVERY mutation as caught, which
    # is the same lie a build failure tells and was told once in this session
    # by a test of mine that was broken rather than by code that was. Nothing
    # below means anything unless this passes.
    base_ok, _, base_hung, _ = run_suite(root)
    if base_hung:
        # Distinguished from red, because the fix is different: a red baseline is
        # a broken test, a hung one is a suite that never answered — including the
        # case where somebody has a break armed in the working tree right now.
        print("BASELINE DID NOT FINISH — %s ran past %ds before any mutation.\n"
              "Nothing below would mean anything. Check for an armed break in the "
              "working tree, or raise MUTATE_SUITE_TIMEOUT if the machine is loaded."
              % (", ".join(base_hung), SUITE_TIMEOUT), file=sys.stderr)
        return 2
    if not base_ok:
        print("BASELINE IS RED — the suite fails before any mutation.\n"
              "Every result below would report as caught. Fix the suite first.",
              file=sys.stderr)
        return 2

    survivors, elsewhere = [], []
    for m in muts:
        label = m["label"]
        # Captured HERE because the loop used to rebind `m` to a regex match halfway
        # down; anything read after that line was reading the wrong object. The match
        # is `bm` now, but the capture stays: it is the row's own data and belongs at
        # the top.
        covered = m.get("elsewhere", "")
        n = anchor_count(m)
        if n != 1:
            # Counted, not just printed. A row whose anchor never matched was never
            # tested, and the summary used to exclude it — so "0 survived or invalid,
            # of 177" read as "all 177 were exercised" while one had silently not
            # run for several batches. That is this file's own failure mode, a
            # non-result reported as a result, committed by its own summary line.
            print(f"{label:<46} BAD ANCHOR (matched {n}x)")
            survivors.append(label + " [bad anchor]")
            continue

        ok, out, hung, built = run_suite(root, m.get("pkg", "govern"), mut=m)

        # Filetests are named by FILE, not by a TestXxx function, so a catch
        # from one has no Test name anywhere in the output.
        hits = sorted({w for w in out.split() if w.startswith("Test")})
        hits += re.findall(r"\S+_filetest\.gno", out)

        # "N build errors" — the COUNT, not the phrase. Matching the phrase
        # treats the ordinary summary line "0 build errors, 1 test errors" as a
        # build failure, so every catch without a Test name in it was being
        # reported as INVALID. That is the same lie as counting a build failure
        # as a catch, told the other way round, and it hid four real catches.
        # AND THE ERROR CODE, ANY of them, not just the type-check one. Measured on
        # a staged copy: an unbalanced paren in lock.gno reports
        #
        #     0 build errors, 1 test errors        code=gnoParserError
        #
        # so a mutant that does not PARSE looked exactly like a catch — the very lie
        # the paragraph above exists to prevent, arriving through the door that was
        # left open when only gnoTypeCheckError was named. Latent rather than live
        # when found: all 1,240 corpus mutants were confirmed to parse (gofmt -e on
        # each), and check-mutant-collisions now refuses any row that stops doing so.
        #
        # The pattern is deliberately a CATCH-ALL over gno's error codes rather than
        # the two known spellings, because a third code would reopen the hole in
        # silence. It biases toward scoring a real catch as INVALID, and that is the
        # safe direction: this harness must under-claim coverage, never over-claim.
        bm = re.search(r"(\d+) build errors", out)
        codes = set(re.findall(r"code=(gno\w*Error)", out))
        broke = (bm and int(bm.group(1)) > 0) or bool(codes & COMPILE_CODES)
        # A code that is neither a known compile failure nor a known runtime one is
        # SAID OUT LOUD rather than assumed either way. Assuming it means "compiled
        # fine" is how the parser door stayed open; assuming it means "did not build"
        # is how a real catch gets thrown away, which is what a catch-all over every
        # gno*Error did the moment it met gnoUnknownError.
        unknown = sorted(codes - COMPILE_CODES - RUNTIME_CODES)
        for c in unknown:
            print(f"mutate: UNCLASSIFIED gno error code {c} — this row is counted "
                  f"with the non-results, not as a catch. Decide what {c} means and "
                  f"add it to COMPILE_CODES or RUNTIME_CODES; common.go's own list "
                  f"ends with 'TODO: add new gno codes here', so this will happen "
                  f"again.", file=sys.stderr)

        if unknown:
            # BEFORE the catch verdicts, for the same reason the timeout branch is:
            # an unclassified code means nobody knows whether the mutant ran, and
            # this file's oldest rule is that a non-result must not report as a
            # result. Warning and scoring a catch anyway — which is what the first
            # version of this did — is the over-claim, and the safe reading of "we
            # do not know" is not coverage.
            print(f"{label:<46} UNCLASSIFIED ({', '.join(unknown)}) <<<")
            survivors.append(label + " [unclassified]")
        elif hung:
            # FIRST, and that ordering is the whole point. A timeout leaves `ok`
            # false, so without this branch the chain below would fall through to
            # the final `else` and print "caught: failed" — reporting a mutation
            # nothing ever judged as one the suite objected to. That is the same
            # lie this file already refuses twice: a build failure counted as a
            # catch, and an anchor that matched nothing counted as exercised.
            # Nothing was measured, so it goes with the other non-results.
            print(f"{label:<46} TIMED OUT after {SUITE_TIMEOUT}s "
                  f"({', '.join(hung)}) <<<")
            survivors.append(label + " [timed out]")
        elif ok and covered:
            # A guard whose coverage lives in a suite this harness does not run —
            # today only the txtar tests, which need a real node. Such a row survives
            # for ever here, so omitting it was the alternative, and omission is
            # worse: it leaves no trace that the guard was ever considered. Recorded,
            # never counted as a finding, and ALWAYS printed in the summary below, so
            # this cannot become a way to silence a real survivor.
            print(f"{label:<46} covered elsewhere: {covered}")
            elsewhere.append(f"{label} — {covered}")
        elif ok:
            print(f"{label:<46} SURVIVED <<<")
            survivors.append(label)
        elif broke:
            # Nothing was measured: a mutation that cannot build proves exactly
            # as much as one that was never applied.
            print(f"{label:<46} INVALID (did not build) <<<")
            survivors.append(label + " [invalid]")
        elif not built:
            # THE LAST DOOR, and the only one the output text cannot close. `broke`
            # above reads gno's error codes, and gnoUnknownError means both "this
            # mutant could never run" and "it ran and a realm panic objected" — the
            # second being a catch. Asked of the toolchain instead: the suite failed,
            # so this is about to be called a catch, and a catch is the one verdict
            # that is wrong if nothing ever compiled.
            print(f"{label:<46} INVALID (did not build) <<<")
            survivors.append(label + " [invalid]")
        elif covered:
            # It is caught HERE after all, so the annotation is stale — the row does
            # not need it, and leaving it would hide a future regression behind an
            # excuse that no longer applies.
            print(f"{label:<46} caught: {hits[0] if hits else 'failed'} "
                  f"— drop its `elsewhere`, it is covered here")
        else:
            print(f"{label:<46} caught: {hits[0] if hits else 'failed'}")

    print(f"\n{len(survivors)} not caught (survived, invalid, or never applied), "
          f"of {len(muts)}")
    for s in survivors:
        print(f"  {s}")
    if elsewhere:
        print(f"\n{len(elsewhere)} row(s) survive here BY DESIGN, covered by a suite "
              f"this harness does not run:")
        for s in elsewhere:
            print(f"  {s}")


if __name__ == "__main__":
    # sys.exit(main()), NOT main(). main() has returned 2 for a red baseline since
    # it was written and the value went straight in the bin, so the process exited
    # 0 — and mutate-parallel.py, which checks `code == 2` for exactly this, has
    # been carrying a dead condition and leaning on a string match beside it.
    sys.exit(main())
