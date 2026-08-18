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

import atexit
import glob
import json
import os
import shutil
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "scripts"))
import repolock  # noqa: E402

# This run rewrites the working tree, one guard at a time. Announce it so a
# concurrent `make check` refuses instead of reporting our breakage as its own.
_treelock = repolock.hold().__enter__()
# Release on ANY exit, including a failing run. Without this the lockfile
# outlives the process and the next reader has to notice the pid is dead before
# it will proceed — correct, but it makes a stale lock the normal case.
atexit.register(_treelock.__exit__, None, None, None)
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
READPURE = "scripts/check-read-purity.py"
PATHS = "scripts/check-paths.py"
ANCHORS = "scripts/check-mutation-anchors.py"
MUTS = "scripts/mutations-kourtv2.json"
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

print("\ncheck-read-purity")
# The guard's failure mode is a read that allocates SUCCEEDING where it should
# have panicked, so nothing in the suite goes red — the drift is invisible to
# tests by construction. The control has to inject a whole read rather than edit
# one, because every existing read is already correct.
control("a read that allocates state", f"{KOURTV2}/modvote.gno",
        "func ElectionOpen(",
        "func SelfTestAllocatingRead(courtSlug string) bool {\n"
        "\tcm := ensureMod(mustCourt(courtSlug))\n\t_ = cm\n\treturn true\n}\n\n"
        "func ElectionOpen(",
        "allocates and persists state",
        argv=["python3", READPURE])
# Fail CLOSED, both ways. An allocator that gets renamed leaves the scan looking
# for a call that can no longer appear, and a read pattern that drifts leaves it
# scanning nothing — either would report clean forever.
control("an allocator renamed out from under the scan", READPURE,
        'ALLOCATORS = ("ensureMod", "ensureGlobalDAO", "ensureClaimMod")',
        'ALLOCATORS = ("ensureModGone", "ensureGlobalDAO", "ensureClaimMod")',
        "cannot appear",
        argv=["python3", READPURE])
control("a read pattern that drifted off the code", READPURE,
        r'EXPORTED = re.compile(r"^func ([A-Z]\w*)\(([^)]*)\)")',
        r'EXPORTED = re.compile(r"^funcNOPE ([A-Z]\w*)\(([^)]*)\)")',
        "cannot be right",
        argv=["python3", READPURE])

print("\ncheck-paths")
# Every want below NAMES THE FILE the mutation exposes. An earlier version of
# these arms wanted bare "STALE" and "ALLOWLIST", which the baseline output
# already contained while two real stale paths were outstanding — so two arms
# printed "fires" without their mutation doing anything. A fixture that cannot
# distinguish the arm it names proves nothing.
control("a retired path in a file nobody exempted", PATHS,
        '    "MODERATION.md": (1,',
        '    "MODERATION-gone.md": (1,', "STALE MODERATION.md",
        argv=["python3", PATHS])
# The count is the pin, because an allowlisted file can acquire a NEW stale
# mention alongside its deliberate ones — gnoroot.py did exactly that, carrying
# an intentional spelling and a rotted docstring in the same file.
control("an allowlist count that drifted", PATHS,
        '    "PLAN.md": (2,',
        '    "PLAN.md": (9,', "PLAN.md carries 2 retired-path mention(s), pinned at 9",
        argv=["python3", PATHS])
# An exemption for a file with nothing to exempt shrinks coverage silently,
# which is the failure check-citations names about its own stale manifest rows.
control("an exemption that guards nothing", PATHS,
        '    "PLAN.md": (2,',
        '    "Makefile": (2,', "Makefile is exempt",
        argv=["python3", PATHS])
# Fail CLOSED on a rotted regex. This is not hypothetical: the half-rename
# pattern shipped as `kourt/court(?![a-z0-9])`, which matched `kourt/court` and
# therefore NOT `kourt/courtv2` — the V2 half-rename escaped the pattern written
# for half-renames. The fixtures are what turn that into a build break.
control("a retired pattern that can no longer match", PATHS,
        r'(re.compile(r"(?:[pr]|\{p,r\})/cryptocourt"),',
        r'(re.compile(r"(?:[pr]|\{p,r\})/cryptocourtZZZ"),',
        "SELFTEST no pattern fires", argv=["python3", PATHS])
# And fail closed the OTHER way: a pattern that grew too greedy would flag
# correct paths, and a guard that cries wolf gets switched off faster than one
# with a known edge.
control("a pattern that grew greedy enough to flag correct paths", PATHS,
        r'(re.compile(r"kourt/court"),',
        r'(re.compile(r"kourt/"),',
        "fires on", argv=["python3", PATHS])

print("\ncheck-mutation-anchors")
# Each arm PREPENDS a row to the real corpus and wants a verdict that NAMES the
# injected row, so no arm can be satisfied by a pre-existing problem elsewhere in
# the 863. The guard's own fixtures pin each verdict behind an INJECTED resolver,
# which proves nothing about the real one — these arms are what exercise the pkg
# lookup, the path join and the file read against the actual tree.
#
# Written as a JSON round-trip, not a string splice. The first version anchored on
# the literal "[\n {\n", which is the corpus's `indent=1` head — and the corpus is
# `indent=2`. Re-serialising it at the right indent silently turned all six arms
# into BROKEN CONTROL. An arm must not depend on the whitespace of the file it
# edits.
def inject(label, rows, want):
    backup = MUTS + ".selftest-backup"
    exercised.add(os.path.basename(ANCHORS))
    shutil.copy(MUTS, backup)
    try:
        with open(MUTS, "w") as fh:
            json.dump(rows + json.load(open(backup)), fh,
                      indent=2, ensure_ascii=False)
            fh.write("\n")
        r = subprocess.run(["python3", ANCHORS], capture_output=True, text=True)
        out = r.stdout + r.stderr
        if want in out:
            print(f"  {label:<44} fires")
        else:
            print(f"  {label:<44} SILENT — the guard did not notice")
            failures.append(label)
    finally:
        shutil.move(backup, MUTS)


def srow(label, **kw):
    r = {"pkg": "kourtv2", "file": "buy.gno", "label": label,
         "find": "NoSourceLineSaysThis", "replace": "x"}
    r.update(kw)
    return r


inject("a row whose anchor has rotted away", [srow("SELFTEST rotted")],
       "matched 0x on 'SELFTEST rotted'")
inject("a row whose anchor is ambiguous",
       [srow("SELFTEST ambiguous", find="\t")],
       # Names the row rather than pinning a count: a bare tab occurs hundreds of
       # times in buy.gno, and only a BAD ANCHOR verdict prints "matched Nx on".
       "on 'SELFTEST ambiguous'")
# The check the batch cannot make: it sees one row at a time, so two rows holding
# the same mutation both report caught and the corpus reads bigger than it is.
# Not hypothetical — a merge left 18 such pairs, each carrying two different
# labels for one identical mutation.
inject("two rows carrying one identical mutation",
       [srow("SELFTEST twin A"), srow("SELFTEST twin B")],
       "SELFTEST twin A")
inject("two rows sharing one label",
       [srow("SELFTEST shared"), srow("SELFTEST shared", find="AlsoAbsentHere")],
       "DUPLICATE LABEL 'SELFTEST shared'")
# An unknown pkg is worse than a missing one: mutate.py's OBSERVERS lookup falls
# back to EVERY package, so any unrelated red suite reads as this row's catch.
inject("a pkg mutate.py cannot stage",
       [srow("SELFTEST unknown pkg", pkg="nosuchpkg")],
       "UNKNOWN PKG 'nosuchpkg'")
inject("an `elsewhere` excuse pointing at a deleted file",
       [srow("SELFTEST stale excuse",
             elsewhere="gnoland/testdata/no_such_file.txtar")],
       "STALE ELSEWHERE 'gnoland/testdata/no_such_file.txtar'")
# A row that is not shaped like a row used to crash with a KeyError, and one
# missing only `file` was reported as UNKNOWN PKG — naming a package that was
# right there in the map.
inject("a row that is not shaped like a row",
       [{"pkg": "kourtv2", "label": "SELFTEST malformed", "find": "x"}],
       "MALFORMED ROW 'SELFTEST malformed'")
# Fail CLOSED when the pkg map moves. It is IMPORTED from mutate.py so there is
# only one copy; the cost is a guard that resolves nothing if the name goes away,
# and resolving nothing must never read as clean.
control("a pkg map this guard can no longer find", ANCHORS,
        'getattr(mutate, "PKGS", None)', 'getattr(mutate, "PKGS_MOVED", None)',
        "could not read PKGS", argv=["python3", ANCHORS])
# And fail closed on the fixtures themselves, the way check-paths does: a verdict
# that has quietly stopped being produced must break the build, not report clean.
control("a verdict the guard no longer produces", ANCHORS,
        '"UNKNOWN PKG"),', '"UNKNOWN PKG THAT IS NEVER PRINTED"),',
        "SELFTEST no row verdict contains", argv=["python3", ANCHORS])

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
    # A row annotated `elsewhere` says "this guard is covered by a suite mutate.py
    # does not run" — today only the txtar tests. It must never be able to hide a
    # finding, so both directions are controlled: an annotated row that SURVIVES is
    # reported in its own block rather than vanishing, and one that turns out to be
    # caught here says so, since a stale excuse would mask a future regression.
    # A no-op replacement is the deterministic way to force a survivor: it applies
    # cleanly (so it is not a BAD ANCHOR) and changes nothing (so no test can object).
    noop = {"pkg": "governor", "file": "governor.gno",
            "label": "a row that cannot fail here",
            "find": "const maxLive = 64", "replace": "const maxLive = 64",
            "elsewhere": "somewhere this harness cannot run"}
    feed("an `elsewhere` row is named on its own line", [noop], "covered elsewhere")
    feed("and listed in the summary, never omitted", [noop], "survive here BY DESIGN")
    # The other direction: an annotation that is no longer true must say so, or a
    # stale excuse would mask a future regression.
    feed("a STALE `elsewhere` annotation is called out", [{
        "pkg": "governor", "file": "governor.gno",
        "label": "a row that IS caught here",
        "find": "const maxLive = 64", "replace": "const maxLive = 65",
        "elsewhere": "somewhere this harness cannot run"}], "drop its `elsewhere`")

    control("a suite that is already failing", f"{GOVERN}/clock_test.gno",
            "func resumeClock() { advanceBlocks(0) }",
            "func resumeClock() { advanceBlocks(0) }\n\nfunc TestSelfTestDeliberateFailure(t *testing.T) {\n\tt.Error(\"deliberate\")\n}",
            "BASELINE IS RED",
            argv=["python3", os.path.join(REPO, "scripts/mutate.py")],
            stdin='[{"pkg":"governor","file":"governor.gno","label":"x","find":"const maxLive = 64","replace":"const maxLive = 63"}]',
            cwd=os.path.join(REPO, GOVERN))

# --------------------------------------------------------- mutate-parallel --
# The batch is sharded now, so one more way to report a non-result as a result:
# a shard that DIES while its siblings pass. Its rows never ran, and if the driver
# merged what it got it would print a clean verdict over a hole. Both arms below
# feed it a shard that cannot survive and require it to refuse the whole run.
if not have_gno():
    print("\nmutate-parallel: gno not installed - NOT CHECKED")
    failures.append("mutate-parallel arms were not run")
else:
    print("\nmutate-parallel.py")
    exercised.add("mutate-parallel.py")
    bad = json.dumps([
        {"pkg": "governor", "file": "governor.gno", "label": "a row that runs",
         "find": "const maxLive = 64", "replace": "const maxLive = 63"},
        {"pkg": "nosuchpkg", "file": "x.gno", "label": "a shard that must die",
         "find": "a", "replace": "b"},
    ])
    r = subprocess.run(["python3", "scripts/mutate-parallel.py", "--shards", "2"],
                       input=bad, capture_output=True, text=True)
    out = r.stdout + r.stderr
    if "NOT a result" in out:
        print(f"  {'a dead shard fails the whole run':<44} fires")
    else:
        print(f"  {'a dead shard fails the whole run':<44} SILENT — merged anyway")
        failures.append("a dead shard fails the whole run")
    if r.returncode != 0:
        print(f"  {'and the exit code says so':<44} fires")
    else:
        print(f"  {'and the exit code says so':<44} SILENT — exited 0")
        failures.append("a dead shard exits nonzero")

# ----------------------------------------------------------------- gnoroot --
# Each runner now gets its OWN GNOROOT — symlinks to everything but a private copy
# of examples/ — which is what lets two worktrees test at the same time. Two ways
# that can go wrong silently, so both get a control.
#
# If the isolation stops working, the runners are sharing a tree again and the
# collisions this replaced come back, with nothing to announce it. And remove()
# deletes a tree recursively whose entries are symlinks INTO a real gno checkout:
# if it ever followed one, or accepted a path that is not a shadow, it would
# delete the monorepo. No test in this repo would survive to report it.
print("\nrepolock.py")
# The mutating runner announces itself so the readers refuse instead of reporting
# its deliberate breakage as their own finding. This existed because `make check`
# beside a selftest printed two citation errors naming files nobody had touched --
# a false failure in a DIFFERENT gate, which is the worst kind to debug.
#
# selftest holds the lock for its own run, so a refusal arm has to stand up a
# DIFFERENT live holder and call the reader without the inherited owner pid.
def _lockcase(label, ok):
    exercised.add("repolock.py")
    print(f"  {label:<44} " + ("fires" if ok else "WRONG"))
    if not ok:
        failures.append(label)


_saved_owner = os.environ.get(repolock.ENV)
_ghost = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(20)"])
try:
    with open(repolock.LOCK, "w") as f:
        f.write(str(_ghost.pid))
    _noenv = {k: v for k, v in os.environ.items() if k != repolock.ENV}
    r = subprocess.run([sys.executable, os.path.join(REPO, CITE)],
                       capture_output=True, text=True, env=_noenv)
    _lockcase("a reader refuses while the tree is rewritten",
              r.returncode == 1 and "rewriting the working tree" in r.stderr)
    # Re-entrancy: selftest runs the readers AS its controls, so an inherited owner
    # pid must pass straight through or this file could not test anything at all.
    r = subprocess.run([sys.executable, os.path.join(REPO, CITE)],
                       capture_output=True, text=True,
                       env={**os.environ, repolock.ENV: str(_ghost.pid)})
    _lockcase("the owner's own children are not locked out", r.returncode == 0)
finally:
    _ghost.kill()
    _ghost.wait()
# A dead holder must CLEAR, not refuse forever: leaving it behind would wedge every
# reader, which is worse than the race it prevents.
with open(repolock.LOCK, "w") as f:
    f.write(str(_ghost.pid))
r = subprocess.run([sys.executable, os.path.join(REPO, CITE)],
                   capture_output=True, text=True,
                   env={k: v for k, v in os.environ.items() if k != repolock.ENV})
_lockcase("a dead holder clears instead of wedging", r.returncode == 0)
# Put selftest's own claim back for the rest of the run.
with open(repolock.LOCK, "w") as f:
    f.write(str(os.getpid()))
if _saved_owner is not None:
    os.environ[repolock.ENV] = _saved_owner

print("\ngnoroot.py")
sys.path.insert(0, os.path.join(REPO, "scripts"))
import gnoroot  # noqa: E402


def rootcase(label, ok):
    exercised.add("gnoroot.py")
    print(f"  {label:<44} " + ("fires" if ok else "WRONG"))
    if not ok:
        failures.append(label)


if not have_gno():
    print("  gnoroot arms need a gno toolchain - NOT CHECKED")
    failures.append("gnoroot arms were not run")
else:
    real = gnoroot.real_root()
    a = gnoroot.build(real, "selftest-a")
    b = gnoroot.build(real, "selftest-b")
    # Two roots, one file: staging into one must not be visible in the other.
    mark = "examples/gno.land/p/kourt/selftest-marker"
    os.makedirs(os.path.join(a, mark))
    rootcase("two shadows are isolated", not os.path.exists(os.path.join(b, mark)))
    rootcase("and neither leaks into the real root",
             not os.path.exists(os.path.join(real, mark)))

    # The dangerous direction: anything that is not a shadow must be refused.
    rootcase("removing the real root is refused", gnoroot.remove(real) == 1)
    rootcase("removing a non-shadow under the base is refused",
             gnoroot.remove(os.path.join(gnoroot.BASE, "not-a-shadow")) == 1)

    # The reaper must take an ABANDONED root and leave a live one alone. Getting
    # this backwards deletes the tree a running suite is testing against, which
    # is the same collision the whole module exists to remove.
    dead = subprocess.Popen([sys.executable, "-c", "pass"])
    dead.wait()
    ghost = os.path.join(gnoroot.BASE, f"{gnoroot.PREFIX}selftest-ghost-{dead.pid}")
    os.makedirs(ghost, exist_ok=True)
    gnoroot.reap()
    rootcase("an abandoned root is reaped", not os.path.exists(ghost))
    rootcase("a live root survives the reaper", os.path.isdir(a) and os.path.isdir(b))

    # And removal must unlink the symlinks rather than follow them.
    before = sorted(os.listdir(real))
    gnoroot.remove(a)
    gnoroot.remove(b)
    rootcase("removal leaves the real root intact", sorted(os.listdir(real)) == before)
    rootcase("removal leaves the real stdlibs intact",
             os.path.isdir(os.path.join(real, "gnovm", "stdlibs")))

# Every guard in scripts/ must have been pointed at by at least one control.
#
# check-*.py by name, plus the runners that are guards in everything but
# spelling: mutate.py decides whether a mutation counted, gnoroot.py decides
# whether a suite ran against its own staged tree. Naming them explicitly is
# the same opt-in coverage this file complains about elsewhere, but the
# alternative — every scripts/*.py — demands a control for this file itself,
# and a self-test that must break itself to prove it works is a worse trade.
RUNNERS = {"mutate.py", "gnoroot.py", "mutate-parallel.py"}
print("\ncoverage")
guards = {os.path.basename(p) for p in glob.glob(os.path.join(REPO, "scripts/check-*.py"))}
guards |= RUNNERS
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
