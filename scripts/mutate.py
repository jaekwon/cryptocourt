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

Usage — a JSON list of mutations on stdin, each applied and reverted in turn:

    python3 scripts/mutate.py <<'EOF'
    [
     {"file": "governor.gno",
      "label": "anyone may cancel anyone's proposal",
      "find": "\tif cur.Previous().Address() != p.proposer {",
      "replace": "\tif false {"}
    ]
    EOF

A saved batch for the courtv2 money path lives at scripts/mutations-courtv2.json:

    python3 scripts/mutate.py < scripts/mutations-courtv2.json

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

SRC = os.path.dirname(os.path.abspath(__file__))
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
               "examples/gno.land/r/cryptocourt/govern"),
    "checkpoint": (os.path.join(REPO, "realm/p/checkpoint"),
                   "examples/gno.land/p/cryptocourt/checkpoint/v0"),
    "grc20votes": (os.path.join(REPO, "realm/p/grc20votes"),
                   "examples/gno.land/p/cryptocourt/grc20votes/v0"),
    "governor": (os.path.join(REPO, "realm/p/governor"),
                 "examples/gno.land/p/cryptocourt/governor/v0"),
    # Staged but never mutated: the govern realm's offer filetest imports it,
    # so leaving it out makes the baseline red for a staging reason and every
    # mutation reads as caught. That is the same lie as a build failure counted
    # as a catch, told by omission.
    "offerer": (os.path.join(REPO, "realm/r/offerer"),
                "examples/gno.land/r/cryptocourt/offerer"),
    # courtv2 and the packages it needs staged. Added after this harness spent a
    # whole session unusable against the realm that holds almost every guard worth
    # breaking: the money-path work (the slash reserve, the quality ratchet, the
    # carrot withholding) all lives here, and every one of those guards had to be
    # mutated BY HAND because there was no entry for it. That is the same shape as
    # the isolation guard staging 3 p/ + 2 r/ and not courtv2 — a check that
    # measures everything except the thing most worth measuring.
    "courtv2": (os.path.join(REPO, "realm/r/courtv2"),
                "examples/gno.land/r/cryptocourt/courtv2"),
    # The packages courtv2 actually imports. NOT cshares or tickbook: the import graph
    # says only the V1 court realm uses those, and V1 is deliberately absent here, so
    # staging them added two suites to every mutation for nothing. (v0.57 claimed the
    # realm-test set's seven were all needed; that was wrong — courtv2's imports are
    # curve, governor, grc20votes and twap, plus checkpoint transitively.)
    "twap": (os.path.join(REPO, "realm/p/twap"),
             "examples/gno.land/p/cryptocourt/twap/v0"),
    "curve": (os.path.join(REPO, "realm/p/curve"),
              "examples/gno.land/p/cryptocourt/curve/v0"),
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
    "courtv2":    ["courtv2"],
    "govern":     ["govern"],
    "offerer":    ["offerer", "govern"],
    "twap":       ["twap", "courtv2"],
    "curve":      ["curve", "courtv2"],
    "grc20votes": ["grc20votes", "courtv2", "govern"],
    "governor":   ["governor", "courtv2", "govern"],
    "checkpoint": ["checkpoint", "grc20votes", "governor", "govern", "courtv2"],
}


def stage(root):
    """Copy both trees into GNOROOT/examples at the paths they hold on chain."""
    for src, rel in PKGS.values():
        dst = os.path.join(root, rel)
        shutil.rmtree(dst, ignore_errors=True)
        os.makedirs(dst)
        for g in os.listdir(src):
            if g.endswith(".gno") or g == "gnomod.toml":
                shutil.copy(os.path.join(src, g), dst)


def run_suite(root, pkg=None, mut=None):
    """Run the OBSERVER suites for `pkg`; all of them when pkg is None (the baseline).
    Returns (passed, output).

    `mut` is applied to the STAGED COPY after staging and before testing, so the repo's
    own sources are never written to. See the note in this file's header on why that
    matters more than it looks.

    More than the mutated package's own suite, because a mutation there can be caught
    by its own tests, by a realm that imports it, or by neither — and only the last is
    a finding. Running one suite and calling it the answer would report the realm as
    covering the package it merely depends on, or the reverse. But not ALL suites
    either: a courtv2 mutation cannot be caught by twap's tests, and running them
    anyway is what made a full batch time out.
    """
    names = OBSERVERS.get(pkg, list(PKGS)) if pkg else list(PKGS)
    # One complete stage/mutate/test/unstage cycle, in the run's OWN GNOROOT (see
    # scripts/gnoroot.py) — so a long batch no longer holds a shared tree, and a
    # concurrent runner in another worktree cannot delete the mutant mid-test and
    # have it scored INVALID.
    stage(root)
    if mut is not None:
        f = os.path.join(root, PKGS[mut.get("pkg", "govern")][1], mut["file"])
        src = open(f).read()
        open(f, "w").write(src.replace(mut["find"], mut["replace"]))
    out, passed = "", True
    for nm in names:
        rel = PKGS[nm][1]
        r = subprocess.run(["gno", "test", "."], cwd=os.path.join(root, rel),
                           capture_output=True, text=True,
                           env={**os.environ, "GNOROOT": root})
        out += r.stdout + r.stderr
        passed = passed and r.returncode == 0
    for _, rel in PKGS.values():
        shutil.rmtree(os.path.join(root, rel), ignore_errors=True)
    return passed, out


def main():
    muts = json.load(sys.stdin)
    # One shadow GNOROOT for the whole batch, removed at exit. atexit does not run
    # on a kill, same as the backups below — but a leaked root is a directory in
    # the system temp that nothing reads, whereas the shared-tree lock this
    # replaces would block every later run until a human removed it.
    root = gnoroot.build(gnoroot.real_root(), "mutate")
    atexit.register(gnoroot.remove, root)
    # Absolute paths throughout, since a mutation may name a file in either
    # tree and there is no single directory to sit in.
    def where(m):
        pkg = m.get("pkg", "govern")
        if pkg not in PKGS:
            raise SystemExit(f"mutate: no such pkg {pkg!r}; have {sorted(PKGS)}")
        return os.path.join(PKGS[pkg][0], m["file"])

    # Nothing below writes to the repo. Anchors are counted against the sources
    # READ-ONLY and the mutation is applied to the staged copy inside run_suite.

    # The baseline, before anything is mutated.
    #
    # A suite that is already failing reports EVERY mutation as caught, which
    # is the same lie a build failure tells and was told once in this session
    # by a test of mine that was broken rather than by code that was. Nothing
    # below means anything unless this passes.
    if not run_suite(root)[0]:
        print("BASELINE IS RED — the suite fails before any mutation.\n"
              "Every result below would report as caught. Fix the suite first.",
              file=sys.stderr)
        return 2

    survivors = []
    for m in muts:
        label = m["label"]
        n = open(where(m)).read().count(m["find"])
        if n != 1:
            print(f"{label:<46} BAD ANCHOR (matched {n}x)")
            continue

        ok, out = run_suite(root, m.get("pkg", "govern"), mut=m)

        # Filetests are named by FILE, not by a TestXxx function, so a catch
        # from one has no Test name anywhere in the output.
        hits = sorted({w for w in out.split() if w.startswith("Test")})
        hits += re.findall(r"\S+_filetest\.gno", out)

        # "N build errors" — the COUNT, not the phrase. Matching the phrase
        # treats the ordinary summary line "0 build errors, 1 test errors" as a
        # build failure, so every catch without a Test name in it was being
        # reported as INVALID. That is the same lie as counting a build failure
        # as a catch, told the other way round, and it hid four real catches.
        m = re.search(r"(\d+) build errors", out)
        broke = (m and int(m.group(1)) > 0) or "gnoTypeCheckError" in out

        if ok:
            print(f"{label:<46} SURVIVED <<<")
            survivors.append(label)
        elif broke:
            # Nothing was measured: a mutation that cannot build proves exactly
            # as much as one that was never applied.
            print(f"{label:<46} INVALID (did not build) <<<")
            survivors.append(label + " [invalid]")
        else:
            print(f"{label:<46} caught: {hits[0] if hits else 'failed'}")

    print(f"\n{len(survivors)} survived or invalid, of {len(muts)}")
    for s in survivors:
        print(f"  {s}")


if __name__ == "__main__":
    main()
