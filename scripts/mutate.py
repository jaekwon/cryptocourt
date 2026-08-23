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
    if mut is not None:
        f = os.path.join(root, PKGS[mut.get("pkg", "govern")][1], mut["file"])
        src = open(f).read()
        open(f, "w").write(src.replace(mut["find"], mut["replace"]))
    out, passed, hung = "", True, []
    for nm in names:
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
    return passed, out, hung


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
    base_ok, _, base_hung = run_suite(root)
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

        ok, out, hung = run_suite(root, m.get("pkg", "govern"), mut=m)

        # Filetests are named by FILE, not by a TestXxx function, so a catch
        # from one has no Test name anywhere in the output.
        hits = sorted({w for w in out.split() if w.startswith("Test")})
        hits += re.findall(r"\S+_filetest\.gno", out)

        # "N build errors" — the COUNT, not the phrase. Matching the phrase
        # treats the ordinary summary line "0 build errors, 1 test errors" as a
        # build failure, so every catch without a Test name in it was being
        # reported as INVALID. That is the same lie as counting a build failure
        # as a catch, told the other way round, and it hid four real catches.
        bm = re.search(r"(\d+) build errors", out)
        broke = (bm and int(bm.group(1)) > 0) or "gnoTypeCheckError" in out

        if hung:
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
