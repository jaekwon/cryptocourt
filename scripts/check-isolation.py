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

The whole sweep runs each suite once per test — every Test function in every
staged package, presently a few hundred of them and a quarter of an hour — so it
is its own target rather than part of realm-test. --only exists so a control can
prove this guard fires without paying for the sweep.

That cost is stated as a range on purpose. It read "143 of them, a few minutes"
for as long as the realm lists were a hand-copy, and stayed at 143 through the
fix that added kourtv2 and quadrupled the real number. A figure nobody can
recompute from the tree is a figure that will be wrong again.

Everything `make realm-test` compiles, not just the realm most likely to have
the problem. Covering where somebody has already looked is opt-in coverage, and
opt-in coverage is how a citation goes unregistered, a filetest unbudgeted and a
guard uncontrolled. The point of a sweep is the instance nobody predicted.

Needs a gno toolchain; skips without one unless REQUIRE_GNO is set, and says so
rather than passing quietly.
"""

import os
import re
import subprocess
import sys

import gnoroot
import repolock

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

def main():
    # The last guard to take the lock, and the one that needed it most: this is
    # the heaviest reader in the repo — it stages every realm and runs the suite
    # once per test — so the window in which a selftest could rewrite a source
    # underneath it is minutes wide rather than seconds. A test broken on purpose
    # by another gate would be reported here as an isolation failure, which is a
    # false finding in a guard whose whole output is a list of suspect tests.
    repolock.refuse_if_held("check-isolation")
    if not gnoroot.real_root():
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
    red = set()   # (pkg, test) pairs that fail WITH their package too
    rered = []    # packages whose suite is red as a whole
    never = []    # (pkg, test) whose -run filter selected nothing at all
    with gnoroot.shadow("check-isolation") as root:
        gnoroot.stage(root, REALMS)
        # The together-run comes FIRST, and unconditionally. It used to run only
        # for packages that had already produced a per-test failure, which meant
        # the success line — "pass alone as well as together" — asserted a thing
        # the guard had never once checked when everything passed alone. A slug
        # collision between two tests is invisible test-by-test and fails the
        # suite instantly; that is exactly what slipped through. One run per
        # package, against N runs per package for the sweep itself: free.
        for rel, names in work:
            r = subprocess.run(["gno", "test", "."], cwd=os.path.join(root, rel),
                               capture_output=True, text=True,
                               env={**os.environ, "GNOROOT": root})
            if r.returncode != 0:
                out = r.stdout + r.stderr
                rered.append((rel, out.strip().split("\n")))
                for t in names:
                    if f'failed: "{t}"' in out or f"--- FAIL: {t}" in out:
                        red.add((rel, t))
        for rel, names in work:
            base = os.path.join(root, rel)
            for t in names:
                total += 1
                # `-v` IS LOAD-BEARING, not noise. `gno test -run` exits 0 when the
                # filter matches NOTHING, and without -v the output is identical to
                # a pass — filetests run regardless, so a name that selects no test
                # still prints its GAS lines and then `ok`. This loop reads only the
                # return code, so such a test would be counted in `total` and
                # asserted to "pass alone" having never run: the same non-result-as-
                # result this file was already bitten by once (see the together-run
                # comment above). `=== RUN` is the only discriminator, and -v is what
                # prints it.
                r = subprocess.run(["gno", "test", "-run", f"^{t}$", "-v", "."],
                                   cwd=base, capture_output=True, text=True,
                                   env={**os.environ, "GNOROOT": root})
                out = r.stdout + r.stderr
                if r.returncode != 0:
                    bad.append((rel, t, out.strip().split("\n")))
                elif not re.search(r"^=== RUN\s+%s\b" % re.escape(t), out, re.M):
                    never.append((rel, t))

    alone = [(rel, t, out) for rel, t, out in bad if (rel, t) not in red]
    broken = [(rel, t, out) for rel, t, out in bad if (rel, t) in red]
    # THE EXCERPT DROPS GAS LINES, and until it did this printed nothing useful.
    # `gno test -v` emits one "--- GAS:" line per crossing call, and they come
    # FIRST — measured on a single-test run of this realm, the first four lines of
    # output were four gas numbers and nothing else. So a flat four-line slice, on
    # the tool BRANCHING.md sends people to for "the real error", showed four
    # integers and hid the uassert message three lines below them. The same defect
    # bit twice in one programme: a scratch runner kept a last-4000-characters
    # window that these very lines flooded.
    def excerpt(out, n=8):
        keep = [l for l in out if not l.lstrip().startswith("--- GAS:")]
        return (keep or out)[:n]

    for rel, t, out in broken:
        print(f"BROKEN  {t} ({os.path.basename(rel)}) fails alone AND with its "
              f"package — an ordinary failure, not an isolation problem")
        for line in excerpt(out):
            print(f"        {line}")
    for rel, t, out in alone:
        print(f"ALONE   {t} ({os.path.basename(rel)}) fails when it is the only "
              f"test that runs, but passes with its package")
        for line in excerpt(out):
            print(f"        {line}")
    unattributed = [(rel, out) for rel, out in rered
                    if not any(rl == rel for rl, _ in red)]
    for rel, out in unattributed:
        print(f"SUITE   {os.path.basename(rel)} fails as a whole with no single "
              f"test to blame — the package dies before any test's own marker "
              f"prints. A slug collision or a package-level panic looks like this.")
        for line in excerpt(out):
            print(f"        {line}")
    for rel, t in never:
        print(f"NEVER   {t} ({os.path.basename(rel)}) was selected by no test — "
              f"`gno test -run ^{t}$` ran zero tests and exited 0, so this test "
              f"would have been counted as passing alone without running. The name "
              f"is harvested from the source, so either it is not a test the runner "
              f"recognises or -run's matching has changed.")
    if bad or unattributed or never:
        if never:
            print(f"\n{len(never)} of {total} tests never ran at all. That is worse "
                  f"than a failure: the summary line below counts them as passing.")
        if alone:
            print(f"\n{len(alone)} of {total} tests pass only in company. A test "
                  f"that needs its neighbours is reporting on their state, not on "
                  f"the thing it names.")
        if broken:
            print(f"{len(broken)} of {total} tests fail either way. Fix those "
                  f"first: a red suite tells you nothing about isolation.")
        if unattributed:
            print(f"{len(unattributed)} package suite(s) are red as a whole. Fix "
                  f"those first: a red suite tells you nothing about isolation.")
        return 1
    print(f"all {total} tests across {len(work)} packages pass alone as well as "
          f"together.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
