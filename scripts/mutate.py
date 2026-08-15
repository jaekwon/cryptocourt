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

Needs a gno toolchain. Paths are the govern realm and the checkpoint package it
imports; edit REALM and DEP for another target.
"""

import json
import os
import re
import shutil
import subprocess
import sys

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


def run_suite(root):
    """Run BOTH suites against the trees as they stand. Returns (passed, output).

    Both, because a mutation in the package can be caught by the package's own
    tests, by the realm that imports it, or by neither — and only the last is a
    finding. Running one suite and calling it the answer would report the realm
    as covering the package it merely depends on, or the reverse.
    """
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

    originals = {}
    for m in muts:
        originals.setdefault(where(m), open(where(m)).read())

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

    print(f"\n{len(survivors)} survived or invalid, of {len(muts)}")
    for s in survivors:
        print(f"  {s}")


if __name__ == "__main__":
    main()
