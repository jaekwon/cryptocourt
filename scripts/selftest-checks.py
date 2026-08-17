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
NONTRANS = "scripts/check-nontransferable.py"
MEMCLEAR = "scripts/check-membership-clears.py"
GOVERN = "realm/r/govern"
KOURTV2 = "realm/r/kourtv2"
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

print("\ncheck-nontransferable")
# The guard is a tripwire on an ABSENCE — no exported entrypoint moves a court
# coin between two user addresses — and an absence check is the easiest kind to
# write so that it can never fire. Both arms exist because both failure modes
# are live: the thing it watches for actually appearing, and the guard losing
# sight of the tree it is supposed to be watching.
control("a coin that became transferable", "realm/r/kourtv2/buy.gno",
        "func BurnSink() address",
        "func Transfer(cur realm, slug string, to address, amount int64) {}\n\n"
        "func BurnSink() address",
        "appears to have become transferable",
        argv=["python3", NONTRANS])
# Fail CLOSED, not open. This is the shape that let check-isolation sweep 39% of
# the suite while reporting success: a scope list that no longer resolves must be
# an error, never an empty scan reported as a clean one.
control("a guard that lost the tree it watches", NONTRANS,
        'REALMS = ["kourtv1", "kourtv2"]',
        'REALMS = ["kourtv9_moved"]',
        "measuring nothing",
        argv=["python3", NONTRANS])

print("\ncheck-membership-clears")
# The guard exists because ResetModSet's clear cannot be pinned by any TEST — it
# empties the set, so nothing can act until AppointMods or installModSet
# re-installs one, and both clear on the way in. Its effect is always superseded,
# so a mutation deleting it survives every possible test and always will. What can
# still go wrong is a FOURTH install path that forgets to clear, which is
# structural, so it gets a script instead of a test.
control("a membership write that forgets to clear", f"{KOURTV2}/moderation.gno",
        "func ResetModSet(cur realm, courtSlug string) {",
        "func SelfTestSneakyInstall(c *Court, cm *courtMod) {\n\tcm.n = 1\n}\n\n"
        "func ResetModSet(cur realm, courtSlug string) {",
        "changes without discarding its pending approvals",
        argv=["python3", MEMCLEAR])
# Fail CLOSED: a write pattern that stops matching the code must be an error, not
# an empty scan reported as a clean one.
control("a membership pattern that drifted off the code", MEMCLEAR,
        r'r"^\s*cm\.(members\s*=|n\s*=|n\+\+|n--)"',
        r'r"^\s*cmNOPE\.(members)"',
        "cannot be right",
        argv=["python3", MEMCLEAR])

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
    # Appended AFTER an existing function, not after the package clause: a
    # declaration inserted above the import block is a PARSE error, and a package
    # that will not parse never runs a test, so the control would be measuring the
    # parser rather than the classification. (It did, briefly.)
    control("an ordinary failure misreported as isolation",
            f"{GOVERN}/clock_test.gno",
            "func resumeClock() { advanceBlocks(0) }",
            "func resumeClock() { advanceBlocks(0) }\n\n"
            "func TestSelfTestBrokenEitherWay(t *testing.T) {\n"
            "\tt.Error(\"deliberate\")\n}",
            "fail either way",
            argv=["python3", "scripts/check-isolation.py",
                  "--only", "TestSelfTestBrokenEitherWay"])

    # The genuine article: a test that reads a court a NEIGHBOUR created. kourtv2's
    # package-global `courts` tree is never reset between tests, so alone this
    # panics with "no such court" and in company it passes — which is exactly the
    # dependency this guard exists to surface, and the label that must not be
    # confused with the one above.
    #
    # This used to be done in govern, by deleting the kind registration from
    # TestAMalformedRulesPayloadIsRefusedAtTheDoor. That control is retired
    # because its premise is dead, not because it was noisy: resetLedger now
    # builds a WHOLE NEW governor (`engine = governor.New(...)`), so the kind
    # registry no longer survives a reset and the leak it reproduced cannot
    # happen. Verified by running it — the test fails alone AND with its package
    # now, so the old control was pointing the new classifier at the wrong label.
    # The third label, and the one that exposed the guard's own false success. Two
    # tests claiming the same court slug kills the package the instant both run,
    # and it is INVISIBLE test-by-test: each passes alone. The guard used to run
    # the suite together only for packages that had already failed alone, so with
    # everything green it printed "pass alone as well as together" having never
    # checked the second half. The together-run is unconditional now, and this is
    # what proves it.
    control("a suite that dies with no test to blame", f"{KOURTV2}/stake_test.gno",
            'c := testCourt(cur, "rlk1", alice, 500_000_000_000)',
            'c := testCourt(cur, "st1", alice, 500_000_000_000)',
            "fails as a whole",
            argv=["python3", "scripts/check-isolation.py",
                  "--only", "TestReleasingMoreThanIsLockedIsRefused"])

    control("a test that passes only in company", f"{KOURTV2}/stake_test.gno",
            "// THE invariant the lock has to buy back.",
            "func TestSelfTestNeedsANeighboursCourt(cur realm, t *testing.T) {\n"
            "\tif StakePools(\"st1\", 1); false {\n"
            "\t\tt.Fatal(\"unreachable\")\n\t}\n}\n\n"
            "// THE invariant the lock has to buy back.",
            "ALONE",
            argv=["python3", "scripts/check-isolation.py",
                  "--only", "TestSelfTestNeedsANeighboursCourt"])

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
