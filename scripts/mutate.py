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
"""

import contextlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

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
    # Staged, not mutated: courtv2 imports twap directly and the realm-test set
    # stages all seven, so leaving any out makes the baseline red for a staging
    # reason and every mutation then reads as caught — the lie this file's header
    # warns about, told by omission.
    "twap": (os.path.join(REPO, "realm/p/twap"),
             "examples/gno.land/p/cryptocourt/twap/v0"),
    "cshares": (os.path.join(REPO, "realm/p/cshares"),
                "examples/gno.land/p/cryptocourt/cshares/v0"),
    "tickbook": (os.path.join(REPO, "realm/p/tickbook"),
                 "examples/gno.land/p/cryptocourt/tickbook/v0"),
    "curve": (os.path.join(REPO, "realm/p/curve"),
              "examples/gno.land/p/cryptocourt/curve/v0"),
}


@contextlib.contextmanager
def stage_lock(root):
    """Serialize the shared staging area, as realm-test and check-isolation do.

    Every runner stages into the SAME $GNOROOT/examples/gno.land/{p,r}/cryptocourt
    and removes it afterwards; the import paths fix that location, so it cannot be
    parameterized. Two concurrent runners delete each other's tree mid-run and the
    loser reports a phantom build failure — which this harness would count as
    INVALID, i.e. as a mutation it could not judge. mkdir is atomic, so it is the
    lock.
    """
    lock = os.path.join(root, "examples/gno.land/.cryptocourt-stage.lock")
    for _ in range(600):
        try:
            os.mkdir(lock)
            break
        except FileExistsError:
            time.sleep(1)
    else:
        print(f"mutate: the stage lock at {lock} has been held for 10 minutes; "
              f"remove it if it is stale", file=sys.stderr)
        raise SystemExit(1)
    try:
        yield
    finally:
        shutil.rmtree(lock, ignore_errors=True)


def stage(root):
    """Copy both trees into GNOROOT/examples at the paths they hold on chain."""
    for src, rel in PKGS.values():
        dst = os.path.join(root, rel)
        shutil.rmtree(dst, ignore_errors=True)
        os.makedirs(dst)
        for g in os.listdir(src):
            if g.endswith(".gno") or g == "gnomod.toml":
                shutil.copy(os.path.join(src, g), dst)


def run_suite(root):
    """Run BOTH suites against the trees as they stand. Returns (passed, output).

    Both, because a mutation in the package can be caught by the package's own
    tests, by the realm that imports it, or by neither — and only the last is a
    finding. Running one suite and calling it the answer would report the realm
    as covering the package it merely depends on, or the reverse.
    """
    # Under the lock: one complete stage/test/unstage cycle. Taking it here rather
    # than around the whole run keeps a long batch from holding the shared tree for
    # its entire duration, and every cycle is self-contained.
    with stage_lock(root):
        stage(root)
        out, passed = "", True
        for _, rel in PKGS.values():
            r = subprocess.run(["gno", "test", "."], cwd=os.path.join(root, rel),
                               capture_output=True, text=True)
            out += r.stdout + r.stderr
            passed = passed and r.returncode == 0
        for _, rel in PKGS.values():
            shutil.rmtree(os.path.join(root, rel), ignore_errors=True)
    return passed, out


BAK = ".mutate-backup"


def recover_backups():
    """Put back anything a killed run left mutated."""
    for src, _ in PKGS.values():
        for f in os.listdir(src):
            if not f.endswith(BAK):
                continue
            bak = os.path.join(src, f)
            orig = bak[: -len(BAK)]
            if not os.path.exists(orig):
                # The original is gone, so this backup is from a tree that no
                # longer exists — a file deleted deliberately since the run
                # that left it. Restoring would RESURRECT it, which is worse
                # than the mutation this was meant to undo: it happened, and
                # the resurrected file broke a build for an hour.
                os.remove(bak)
                print(f"mutate: discarded a stale backup for {orig}, which no "
                      f"longer exists", file=sys.stderr)
                continue
            shutil.move(bak, orig)
            print(f"mutate: recovered {orig} from a run that did not finish",
                  file=sys.stderr)


def main():
    muts = json.load(sys.stdin)
    root = subprocess.run(["gno", "env", "GNOROOT"], capture_output=True,
                          text=True).stdout.strip()
    # Absolute paths throughout, since a mutation may name a file in either
    # tree and there is no single directory to sit in.
    def where(m):
        pkg = m.get("pkg", "govern")
        if pkg not in PKGS:
            raise SystemExit(f"mutate: no such pkg {pkg!r}; have {sorted(PKGS)}")
        return os.path.join(PKGS[pkg][0], m["file"])

    # Backups on DISK, not just in memory.
    #
    # The restore is in a finally, and a finally does not run when the process
    # is killed — a mutation that hangs the suite gets the whole run timed out,
    # and the source is left broken. That is bad enough in a tracked tree and
    # invisible in an untracked one, where `git status` says only that the
    # directory is new. It cost an hour once: a mutant that recursed forever
    # was still in the source, and every later run "hung" for no visible reason.
    #
    # So the originals are written beside the files, recovered on the next run,
    # and removed on a clean exit.
    recover_backups()
    originals = {}
    for m in muts:
        f = where(m)
        if f not in originals:
            originals[f] = open(f).read()
            open(f + BAK, "w").write(originals[f])

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
        f, label = where(m), m["label"]
        src = originals[f]
        n = src.count(m["find"])
        if n != 1:
            print(f"{label:<46} BAD ANCHOR (matched {n}x)")
            continue
        open(f, "w").write(src.replace(m["find"], m["replace"]))

        ok, out = run_suite(root)
        open(f, "w").write(src)

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

    for f in originals:
        if os.path.exists(f + BAK):
            os.remove(f + BAK)

    print(f"\n{len(survivors)} survived or invalid, of {len(muts)}")
    for s in survivors:
        print(f"  {s}")


if __name__ == "__main__":
    main()
