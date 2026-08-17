#!/usr/bin/env python3
"""Run every realm test on its own, and require it to pass there too.

A gno test file shares package state with every other test in it. These suites
reset what they know to reset — the trees, the supply, the clock — and two
things were never on that list: the KIND REGISTRY, and where the clock had got
to. So a test could pass only in company:

  A rules test asserting messages that need the kind "fee" to exist, without
  registering it. Some neighbour always has. Run alone it refuses every payload
  with "no kind by that name has been offered" instead — and an assertion on
  the prefix every refusal shares matches that too, so the dependency stays
  invisible until the messages get specific.

  A history test asserting a holder had nothing at epoch 1. True only because
  neighbours pushed the clock well past epoch 1; run first, its own mint lands
  there and the holder has ten.

Both pass in the suite. Neither is testing what it says. That is the failure
mode this guards: not a test that breaks, but one that quietly reports on the
wrong thing.

    python3 scripts/check-isolation.py
    python3 scripts/check-isolation.py --only TestSomething   # one test

The whole sweep runs each suite once per test — 388 of them, about ten minutes
— so it is its own target rather than part of realm-test. --only exists so a control
can prove this guard fires without paying for the sweep.

Everything `make realm-test` compiles, not just the realm most likely to have
the problem. Covering where somebody has already looked is opt-in coverage, and
opt-in coverage is how a citation goes unregistered, a filetest unbudgeted and a
guard uncontrolled. The point of a sweep is the instance nobody predicted.

grc20 and qcards matter more than govern here, on the plain grounds that the
binary ships against grc20 and nothing ships against govern yet. Both were clean
the first time they were swept, which is worth knowing rather than assuming.

Needs a gno toolchain; skips without one unless REQUIRE_GNO is set, and says so
rather than passing quietly.
"""

import contextlib
import os
import re
import shutil
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Everything `make realm-test` compiles, staged the same way it stages them.
# DERIVED from the Makefile, not copied from it. The hand-maintained copy
# drifted and nothing noticed: it swept 151 tests while realm-test compiled 388,
# and every package it skipped was the newer half of the tree (kourtv1, kourtv2,
# p/twap, p/cshares, p/tickbook, p/curve) — i.e. the system under active
# development. A guard that measures less than it claims is worse than no guard,
# because a passing run looks identical either way and the only symptom is a
# count that stops moving. So the coupling is now enforced rather than
# documented.
#
# (Both sessions working this repo found this independently, in the same week,
# and reached the same fix. Treat that as evidence about the failure mode rather
# than about either reader: hand-maintained scope lists fail open, silently.)
#
# Parsing a Makefile is not elegant, but it fails LOUDLY: if either loop stops
# matching, realms() raises and the sweep refuses to run, where the previous
# arrangement just quietly swept less.
def realms():
    mk = open(os.path.join(REPO, "Makefile")).read()
    pkgs = re.search(r"for p in ([\w \t-]+); do", mk)
    rlms = re.search(r"for r in ([\w \t-]+); do", mk)
    if not pkgs or not rlms:
        raise SystemExit(
            "check-isolation: cannot read realm-test's package lists out of the "
            "Makefile. Fix the parse rather than hardcoding a list here — a "
            "hardcoded one is what silently stopped covering kourtv2.")
    out = [(os.path.join(REPO, "realm/p", n), f"examples/gno.land/p/kourt/{n}/v0")
           for n in pkgs.group(1).split()]
    out += [(os.path.join(REPO, "realm/r", n), f"examples/gno.land/r/kourt/{n}")
            for n in rlms.group(1).split()]
    for src, _ in out:
        if not os.path.isdir(src):
            raise SystemExit(f"check-isolation: {src} is in the Makefile but not on disk")
    return out


REALMS = realms()

@contextlib.contextmanager
def stage_lock(root):
    """Serialize the shared staging area.

    Every runner stages into the SAME $GNOROOT/examples/gno.land/{p,r}/kourt
    and rm -rf's it on exit. The location cannot be parameterized: the import paths
    baked into the sources are what make gno resolve siblings there at all. So two
    concurrent runners delete each other's tree mid-run, and the loser reports a
    phantom compile error in code that is fine — which is exactly how a
    "c.mod undefined" failure and an outright `make isolation-test` failure were
    manufactured. mkdir is atomic, so it is the lock.

    THE NAME IS THE CONTRACT. Every runner that stages must use this exact path
    — the Makefile's realm-test, check-storage.py, and the scratchpad staging
    script all take it. Two runners holding two DIFFERENTLY NAMED locks exclude
    nothing while looking fully protected, which is strictly worse than no lock
    at all. (That very thing happened when the rename left this one behind.)
    """
    lock = os.path.join(root, "examples/gno.land/.kourt-stage.lock")
    for _ in range(600):
        try:
            os.mkdir(lock)
            break
        except FileExistsError:
            time.sleep(1)
    else:
        print(f"check-isolation: the stage lock at {lock} has been held for 10 "
              f"minutes; remove it if it is stale", file=sys.stderr)
        raise SystemExit(1)
    try:
        yield
    finally:
        shutil.rmtree(lock, ignore_errors=True)


def stage(root):
    for src, rel in REALMS:
        dst = os.path.join(root, rel)
        shutil.rmtree(dst, ignore_errors=True)
        os.makedirs(dst)
        for f in os.listdir(src):
            if f.endswith(".gno") or f == "gnomod.toml":
                shutil.copy(os.path.join(src, f), dst)


def cleanup(root):
    for _, rel in REALMS:
        shutil.rmtree(os.path.join(root, rel), ignore_errors=True)
    shutil.rmtree(os.path.join(root, "examples/gno.land/p/kourt"), ignore_errors=True)
    shutil.rmtree(os.path.join(root, "examples/gno.land/r/kourt"), ignore_errors=True)


def main():
    try:
        root = subprocess.run(["gno", "env", "GNOROOT"], capture_output=True,
                              text=True, timeout=30).stdout.strip()
    except (FileNotFoundError, subprocess.SubprocessError):
        root = ""
    if not root or not os.path.isdir(root):
        if os.environ.get("REQUIRE_GNO"):
            print("check-isolation: gno not installed", file=sys.stderr)
            return 1
        print("check-isolation: gno not installed - skipping")
        return 0

    only = None
    if "--only" in sys.argv:
        only = sys.argv[sys.argv.index("--only") + 1]

    work = []
    for src, rel in REALMS:
        names = []
        for f in sorted(os.listdir(src)):
            if f.endswith("_test.gno"):
                names += re.findall(r"^func (Test\w+)",
                                    open(os.path.join(src, f)).read(), flags=re.M)
        if only:
            names = [n for n in names if re.search(only, n)]
        if names:
            work.append((rel, names))
    if not work:
        where = f" matching {only}" if only else ""
        print(f"check-isolation: no tests found{where}, which is itself wrong",
              file=sys.stderr)
        return 1

    bad, total = [], 0
    with stage_lock(root):
        stage(root)
        for rel, names in work:
            base = os.path.join(root, rel)
            for t in names:
                total += 1
                r = subprocess.run(["gno", "test", "-run", f"^{t}$", "."], cwd=base,
                                   capture_output=True, text=True)
                if r.returncode != 0:
                    bad.append((rel, t, (r.stdout + r.stderr).strip().split("\n")))
        cleanup(root)

    for rel, t, out in bad:
        print(f"ALONE   {t} ({os.path.basename(rel)}) fails when it is the only "
              f"test that runs")
        for line in out[:4]:
            print(f"        {line}")
    if bad:
        print(f"\n{len(bad)} of {total} tests pass only in company. A test that "
              f"needs its neighbours is reporting on their state, not on the "
              f"thing it names.")
        return 1
    print(f"all {total} tests across {len(work)} packages pass alone as well as "
          f"together.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
