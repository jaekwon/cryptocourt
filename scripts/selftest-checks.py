#!/usr/bin/env python3
"""Break things on purpose and check that the checkers notice.

A guard reporting success while measuring nothing is indistinguishable, from
the outside, from a guard that works. Every one in scripts/ is capable of it,
in a specific way:

  check-citations exempting a citation that names a file in its own scope —
  the exact class it exists for, exempted by name. Or failing to see a gno-tree
  file NAMED in the prose and never given a row, so a claim is exempt from the
  guard by never having been registered with it.

  check-storage reading the phrase "build errors", which matches the ordinary
  summary line "0 build errors, 1 test errors", so every catch from a filetest
  reads as a mutation that never compiled.

  mutate.py counting a mutation whose anchor matched zero times as a survivor,
  counting a mutant that could not build as a catch, or reporting every
  mutation as caught because the suite was already failing.

  A realm test passing only in company — needing a kind a neighbour registered,
  or asserting a literal epoch that only predates its holder because a
  neighbour moved the clock.

None of those are visible by reading the code. Each is found by breaking
something and noticing the guard stays quiet — and an ad-hoc control is
precisely the step that gets skipped when the guard is already green.

So the controls live here. Each one edits a copy, runs the guard, requires the
expected complaint, and puts the original back.

    python3 scripts/selftest-checks.py

Needs a gno toolchain for the storage arms; skips them without one, and says so
rather than passing quietly.
"""

import glob
import json
import os
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(REPO)

failures = []


# Which guards a control has actually been pointed at this run. Compared
# against scripts/check-*.py at the end, because this file naming its guards
# one by one is the same opt-in coverage that let a citation go unregistered
# and a filetest go unbudgeted: a new guard with no control would sail through
# a green self-test, which is the one outcome a self-test must never produce.
exercised = set()


def control(label, path, find, replace, want, argv=None, stdin=None, cwd=None):
    """Apply an edit, run the guard, and require `want` in its output."""
    for a in (argv or ["python3", "scripts/check-citations.py"]):
        if a.endswith(".py"):
            exercised.add(os.path.basename(a))
    backup = path + ".selftest-backup"
    shutil.copy(path, backup)
    try:
        src = open(path).read()
        n = src.count(find)
        if n != 1:
            print(f"  {label:<44} BROKEN CONTROL (anchor matched {n}x)")
            failures.append(label)
            return
        open(path, "w").write(src.replace(find, replace))
        r = subprocess.run(argv or ["python3", "scripts/check-citations.py"],
                           capture_output=True, text=True, input=stdin, cwd=cwd)
        out = r.stdout + r.stderr
        if want in out:
            print(f"  {label:<44} fires")
        else:
            print(f"  {label:<44} SILENT — the guard did not notice")
            failures.append(label)
    finally:
        shutil.move(backup, path)


def feed(label, mutations, want):
    """Run mutate.py on a mutation spec and require `want` in its verdict."""
    r = subprocess.run(["python3", os.path.join(REPO, "scripts/mutate.py")],
                       capture_output=True, text=True,
                       input=json.dumps(mutations),
                       cwd=os.path.join(REPO, GOVERN))
    out = r.stdout + r.stderr
    if want in out:
        print(f"  {label:<44} fires")
    else:
        print(f"  {label:<44} SILENT — the guard did not notice")
        failures.append(label)


def have_gno():
    try:
        r = subprocess.run(["gno", "env", "GNOROOT"], capture_output=True,
                           text=True, timeout=30)
        return bool(r.stdout.strip())
    except (FileNotFoundError, subprocess.SubprocessError):
        return False


CITE = "scripts/check-citations.py"
STORE = "scripts/check-storage.py"
GOVERN = "realm/r/govern"
VOTES = "realm/p/grc20votes"

print("check-citations")
control("an anchor that no longer matches", CITE,
        'r"LastObjectSize", "LastObjectSize"',
        'r"LastObjectSizeGone", "LastObjectSize"', "MOVED")
control("a file that has been renamed", CITE,
        '("gnovm/pkg/gnolang/store.go",\n     r"LastObjectSize", "LastObjectSize"',
        '("gnovm/pkg/gnolang/store_gone.go",\n     r"LastObjectSize", "LastObjectSize"', "GONE")
control("a manifest row nothing quotes", CITE,
        "CITATIONS = [\n",
        'CITATIONS = [\n    ("gnovm/pkg/gnolang/store.go", r"func ", "NoProseSaysThis", "x"),\n',
        "UNUSED")
control("a gno-tree file nobody cited", f"{GOVERN}/errors.gno",
        "package govern\n",
        "package govern\n\n// see `nobody_cited_this.gno` for the rule\n",
        "UNCITED")
control("a newly written file:line citation", f"{GOVERN}/errors.gno",
        "package govern\n",
        "package govern\n\n// see governor.gno:275\n", "line-number citation")

if not have_gno():
    print("\ncheck-storage: gno not installed - NOT CHECKED")
    failures.append("check-storage arms were not run")
else:
    print("\ncheck-storage")
    control("a budget nobody can meet", STORE,
            '"z_write_filetest.gno": 12_000,',
            '"z_write_filetest.gno": 100,', "OVER",
            argv=["python3", STORE])
    # The read that starts writing is introduced in the LEDGER now, since that
    # is where a balance is looked up. The realm's BalanceOf is a one-line
    # forward, which is the point of the split and also means there is nothing
    # there to break.
    control("a read that starts writing", f"{VOTES}/grc20votes.gno",
            "func (l *Ledger) BalanceOf(owner address) int64 {\n\tif a := l.getAccount(owner); a != nil {",
            "func (l *Ledger) BalanceOf(owner address) int64 {\n\tif a := l.openAccount(owner); a != nil {",
            "WROTE", argv=["python3", STORE])
    # UNKNOWN, not MISSING. MISSING is for a budget whose filetest did not
    # run; this is the other way round — a filetest that ran and nobody had
    # budgeted for. Expecting the wrong word here reports the guard as silent
    # when the guard is right, which is the failure mode a self-test has to be
    # most careful about: crying wolf about your own guards is how they get
    # switched off.
    control("a filetest nobody budgeted for", STORE,
            '"z_use_filetest.gno": None,\n', "", "UNKNOWN",
            argv=["python3", STORE])

    print("\ncheck-docnumbers")
    # The bootstrap table in doc.gno against the values init installs. Broken
    # on the DOC side here; the code side is checked by hand in the commit that
    # added the guard, because mutating governor.gno's init would also fail
    # every other arm of this file and prove nothing about this one.
    control("a bootstrap term the docs disagree with", f"{GOVERN}/doc.gno",
            "//\tgrace      241920 blocks",
            "//\tgrace      241921 blocks", "STALE",
            argv=["python3", "scripts/check-docnumbers.py"])

    print("\ncheck-isolation")
    # One of the two real dependencies: a test asserting messages that need a
    # kind to exist, without registering it. resetLedger does not clear the kind
    # registry, so in company some earlier test always had. --only keeps the
    # control cheap; the full sweep runs the suite once per test.
    #
    # Deliberately NOT the other one — an assertion on a literal epoch 1. Fixing
    # that test added an empty epoch at its start, which makes epoch 1 genuinely
    # empty when it runs first, so putting the literal back no longer recreates
    # the bug. A control has to fail for the reason it names.
    control("a test that passes only in company", f"{GOVERN}/governor_test.gno",
            '\tengine.Adopt(setFee{}, Rules{\n'
            '\t\tQuorumBps: 5000, ThresholdBps: 5000, VotingBlocks: 100, GraceBlocks: 1_000_000,\n'
            '\t})\n',
            "", "ALONE",
            argv=["python3", "scripts/check-isolation.py",
                  "--only", "TestAMalformedRulesPayloadIsRefusedAtTheDoor"])

    # The failure this guard itself suffered, and the reason this file exists.
    # Its package list used to be a hand-kept COPY of the Makefile's, and the two
    # drifted: kourtv2 — the realm under active development — was never checked
    # for its entire life, while the guard kept printing "all N tests across M
    # packages pass alone as well as together". The list is derived from the
    # Makefile now, so drift is impossible; what remains is the derivation itself
    # breaking. It must break LOUDLY, never by quietly reading a shorter list.
    control("a guard that lost its coupling to the Makefile",
            os.path.join(REPO, "Makefile"),
            "for r in govern offerer kourtv1 kourtv2; do",
            "for rlm in govern offerer kourtv1 kourtv2; do",
            "cannot read realm-test's package lists",
            argv=["python3", "scripts/check-isolation.py",
                  "--only", "TestAMalformedRulesPayloadIsRefusedAtTheDoor"])

    # mutate.py takes its work on stdin rather than from a file it owns, so its
    # controls are shaped differently: feed it a mutation and require the right
    # verdict. The first three are the ways it can report a non-result as a
    # result, which is what the docstring names; the fourth is the way a
    # two-tree runner can quietly measure the wrong tree.
    print("\nmutate.py")
    feed("an anchor that matches nothing", [{
        "pkg": "governor", "file": "governor.gno", "label": "x",
        "find": "no such text exists anywhere in this file",
        "replace": "y"}], "BAD ANCHOR")
    feed("a mutant that cannot build", [{
        "pkg": "governor", "file": "governor.gno", "label": "x",
        "find": "\treturn p.yes, p.no, p.abstain, p.total",
        "replace": "\treturn p.yes, p.no, p.abstain, p.thereIsNoSuchField"}], "INVALID")
    # A pkg nobody has is refused rather than defaulted. Silently falling back
    # to the realm would mutate a file the caller did not name and report the
    # verdict as though it had — a mutation runner lying about WHAT it broke,
    # which is worse than lying about whether anything noticed.
    feed("a pkg that does not exist", [{
        "pkg": "checkpont", "file": "checkpoint.gno", "label": "x",
        "find": "x", "replace": "y"}], "no such pkg")
    control("a suite that is already failing", f"{GOVERN}/clock_test.gno",
            "func resumeClock() { advanceBlocks(0) }",
            "func resumeClock() { advanceBlocks(0) }\n\nfunc TestSelfTestDeliberateFailure(t *testing.T) {\n\tt.Error(\"deliberate\")\n}",
            "BASELINE IS RED",
            argv=["python3", os.path.join(REPO, "scripts/mutate.py")],
            stdin='[{"pkg":"governor","file":"governor.gno","label":"x","find":"const maxLive = 64","replace":"const maxLive = 63"}]',
            cwd=os.path.join(REPO, GOVERN))

# Every guard in scripts/ must have been pointed at by at least one control.
print("\ncoverage")
guards = {os.path.basename(p) for p in glob.glob(os.path.join(REPO, "scripts/check-*.py"))}
unguarded = sorted(guards - exercised)
for g in unguarded:
    print(f"  {g:<44} NO CONTROL — nothing here can prove it fires")
    failures.append(f"{g} has no control")
if not unguarded:
    print(f"  all {len(guards)} guards in scripts/ have a control")

if failures:
    print(f"\n{len(failures)} control(s) did not fire. A guard that cannot fail "
          f"is not a guard:")
    for f in failures:
        print(f"  {f}")
    sys.exit(1)
print("\nevery control fires.")
