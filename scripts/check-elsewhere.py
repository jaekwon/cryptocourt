#!/usr/bin/env python3
"""An `elsewhere` annotation must name a harness that ACTUALLY OBJECTS.

A corpus row carrying `elsewhere` says: this mutation survives the mutation
harness BY DESIGN, because the property is held somewhere the harness does not
look. That claim has three levels, and each one was hollow until it was checked:

  1. Does the path RESOLVE? check-mutation-anchors has always asked that — "an
     excuse pointing at nothing is worse than no excuse".
  2. Does anything in `make check` RUN it? Until txtar-test was added to check,
     SIX of the seven rows named txtar scripts that the routine never ran.
  3. Does the harness ASSERT the property? This script. A txtar that runs and
     says nothing about the mutation leaves the excuse exactly as hollow as an
     unrun one, and nothing else can notice: the row goes on surviving in
     `make gaps`, which is precisely what it is supposed to do.

WHY THIS IS CHEAP, and why the reason first given for not building it was wrong.
The claim was that the two harness kinds need different plumbing — a txtar runs
against a staged GNOROOT while a python guard reads the repo. They do not. The
txtar harness stages realms into GNOROOT/examples FROM THE REPO, and the guards
read the repo directly, so BOTH kinds see a mutation applied to realm/ in place.
One code path serves both: mutate the repo, run the named harness, require it to
fail, restore. Measured at ~2.4s per txtar script, so the whole sweep is seconds.

MUTATING THE REPO IS THE RISK, and mutate.py refuses to do it for good reason: a
killed run leaves a mutation in the tree, invisible in `git status` if the file
was already dirty. So every write here is paired with a restore in a `finally`,
and the bytes are compared afterwards — a mismatch is reported as a failure of
this script rather than as a finding about the row. Run it on a clean tree.
"""

import glob
import json
import os
import re
import subprocess
import sys

from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import repolock

ROOT = Path(__file__).resolve().parent.parent

# The corpus knows which tree a row's `file` lives in; mutate.py owns that map.
import mutate  # noqa: E402


def target_path(row):
    """Absolute path of the source a row mutates, via mutate.py's own PKGS map."""
    entry = getattr(mutate, "PKGS", {}).get(row.get("pkg"))
    if not entry:
        return None
    return os.path.join(entry[0], row["file"])


def run_harness(where, gnoroot):
    """Run the harness a row names. Returns (exit_code, tail_of_output)."""
    if where.endswith(".txtar"):
        script = os.path.basename(where)[: -len(".txtar")]
        env = dict(os.environ, GNOROOT=gnoroot)
        r = subprocess.run(
            ["go", "test", "-tags", "txtar", "-count=1", "-timeout", "10m",
             "-run", "TestCourtTxtar/" + script, "./gnoland/"],
            cwd=str(ROOT), capture_output=True, text=True, env=env)
        return r.returncode, (r.stdout + r.stderr)
    if where.endswith(".py"):
        r = subprocess.run(["python3", where], cwd=str(ROOT),
                           capture_output=True, text=True)
        return r.returncode, (r.stdout + r.stderr)
    return None, "unrecognised harness kind"


# A HARNESS THAT DIES OBJECTS TO NOTHING, and "exited nonzero" cannot tell the two
# apart. The check below is that the named harness FAILS under the mutation — which
# a mutation that merely stops the realm building also satisfies, without the
# property ever being evaluated. Same shape as a mutation that fails to compile
# being scored as caught: invalid, not a result.
#
# WHAT THAT ACTUALLY LOOKS LIKE HAD TO BE MEASURED, because the obvious guess was
# wrong. A first version of this scanned for compiler text — "build error",
# "undefined:", "syntax error" — and an ablation planted an unclosed paren in
# emission.gno to check it. The guard accepted the row anyway: gno never prints a
# compiler message here. The unbuildable realm kills the in-memory NODE during
# genesis, and the output is a tm2 goroutine dump ending in `FAIL\tpkg` with no
# mention of the realm at all. The txtar script never runs.
#
# So the discriminator is not the failure's text but whether the harness named a
# LOCATION. A real objection points at a line — `FAIL: testdata/x.txtar:82` from a
# txtar, `stakeindex.gno:StakedPage calls getPos` from a python guard. A death
# points at nothing. That rule covers the node panic and whatever the next mode
# turns out to be, which a list of compiler spellings would not.
LOCATED = (r"FAIL: testdata/\S+:\d+: .*", r"^\s+\S+\.gno:\S+ .*")


def complaint(out):
    """The located line the harness produced, or None if it named nothing."""
    for pat in LOCATED:
        m = re.search(pat, out, re.M)
        if m:
            return m.group(0).strip()[:96]
    return None


def main():
    repolock.refuse_if_held("check-elsewhere")

    rows = []
    for f in sorted(glob.glob(os.path.join(ROOT, "scripts", "mutations-*.json"))):
        for r in json.load(open(f)):
            if r.get("elsewhere"):
                rows.append(r)
    if not rows:
        print("check-elsewhere: no rows carry an `elsewhere`, so this check is "
              "measuring nothing. Either the annotation was renamed or the corpus "
              "moved.", file=sys.stderr)
        return 1

    needs_gnoroot = any(r["elsewhere"].endswith(".txtar") for r in rows)
    gnoroot, bad = "", []
    if needs_gnoroot:
        r = subprocess.run(["python3", "scripts/gnoroot.py", "build",
                            "--label", "elsewhere", "--pid", str(os.getpid())],
                           cwd=str(ROOT), capture_output=True, text=True)
        gnoroot = r.stdout.strip()
        if r.returncode or not gnoroot:
            print("check-elsewhere: could not stage a GNOROOT, so the txtar rows "
                  "cannot be checked:\n" + r.stdout + r.stderr, file=sys.stderr)
            return 1

    ok = []
    try:
        for row in rows:
            where, label = row["elsewhere"], row.get("label", "<unlabelled>")
            path = target_path(row)
            if not path or not os.path.isfile(path):
                bad.append((label, where, "its `file` does not resolve through "
                                          "mutate.py's PKGS map"))
                continue
            original = open(path, "rb").read()
            src = original.decode()
            if src.count(row["find"]) != 1:
                bad.append((label, where, "its `find` no longer matches exactly "
                                          "once — `make anchors` should have said so"))
                continue
            try:
                open(path, "w").write(src.replace(row["find"], row["replace"], 1))
                code, out = run_harness(where, gnoroot)
            finally:
                open(path, "wb").write(original)
            if open(path, "rb").read() != original:
                print("check-elsewhere: FAILED TO RESTORE %s. Fix the tree before "
                      "trusting anything else." % path, file=sys.stderr)
                return 1
            if code is None:
                bad.append((label, where, "this script does not know how to run a "
                                          "%s harness" % os.path.splitext(where)[1]))
            elif code == 0:
                bad.append((label, where, "the harness PASSED under the mutation, so "
                                          "it does not assert this property"))
            else:
                c = complaint(out)
                if c is None:
                    # The most failure-shaped line, not the last one: the last line of
                    # a dead txtar run is usually a linker warning from the go build,
                    # which says nothing about why it died.
                    # Prefer a line that SAYS something: a bare `FAIL` is the last
                    # failure-shaped line of a dead txtar and carries no information.
                    hint, fallback = None, "(no output)"
                    for l in out.strip().split("\n"):
                        if hint is None and re.search(r"panic|error:|Error:", l):
                            hint = l.strip()[:64]
                        if re.match(r"\s*(FAIL|--- FAIL)", l) and len(l.strip()) > 8:
                            fallback = l.strip()[:64]
                    hint = hint or fallback
                    bad.append((label, where,
                                "the harness FAILED WITHOUT NAMING A LINE, so nothing "
                                "says it evaluated the property. An unbuildable "
                                "mutation looks exactly like this — it kills the "
                                "in-memory node during genesis and the script never "
                                "runs. Failed at: %s" % hint))
                else:
                    ok.append((label, where, c))
    finally:
        if gnoroot:
            subprocess.run(["python3", "scripts/gnoroot.py", "remove",
                            "--path", gnoroot], cwd=str(ROOT),
                           capture_output=True, text=True)

    if bad:
        print("check-elsewhere: an `elsewhere` names a harness that does not hold "
              "the property.\n", file=sys.stderr)
        for label, where, why in bad:
            print("  %s\n      -> %s: %s" % (label, where, why), file=sys.stderr)
        print("\nA row with `elsewhere` is excused from the mutation harness on the "
              "grounds that something else objects. If that something does not "
              "object, the row is an unrecorded survivor wearing an excuse — and "
              "`make gaps` cannot see it, because the row surviving there is the "
              "expected result.", file=sys.stderr)
        return 1

    print("check-elsewhere: %d `elsewhere` row(s), every named harness objects:" % len(ok))
    for label, where, c in ok:
        print("  %-52s %s" % (label[:52], os.path.basename(where)))
        # THE COMPLAINT IS PRINTED, not just computed. It was extracted and
        # discarded, which hid the one thing a reader needs to judge the result:
        # this script accepts ANY nonzero exit as an objection, so a mutation that
        # merely stops the realm building would pass as "the harness holds the
        # property". Showing the line lets that be told apart at a glance — a
        # `FAIL: testdata/x.txtar:NN` is an assertion, anything else is a lead.
        print("      %s" % c)
    return 0


if __name__ == "__main__":
    sys.exit(main())
