#!/usr/bin/env python3
"""Check that every guard in scripts/ is named in selftest-checks.py.

`make selftest` already refuses a guard with no control arm — it globs
scripts/check-*.py and fails the run when one has nothing that breaks it. The
problem is WHEN it says so. selftest rewrites repository files in place, so it
must run alone and is therefore run periodically rather than per commit, and an
unarmed guard sits in the tree until somebody remembers. That has now happened
twice in one week, both times to a guard written by another session:
check-demo-physics landed with no arms, and check-live-reads after it. Each time
the next selftest failed for a reason that had nothing to do with what its author
was doing.

So this is the cheap half, safe to run in `make check`: no arms are executed and
no file is touched, only the question of whether each guard is REGISTERED. It
costs a directory listing and answers at commit time instead of days later.

ONLY TRACKED FILES COUNT. A guard still being written is not yet an obligation on
anybody, and failing a shared gate because of an untracked work-in-progress file
would make this the very kind of nuisance that gets a check switched off. `git
ls-files` is the line: the moment a guard is committed, it owes the tree a
control arm.

This file is itself a scripts/check-*.py and so is subject to its own rule, which
is the intended shape rather than an accident — a registration check that forgot
to register itself would be the exact failure it exists to catch.

    python3 scripts/check-guards-armed.py
"""

import glob
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import repolock  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SELFTEST = os.path.join(REPO, "scripts", "selftest-checks.py")


def tracked(paths):
    """The subset of paths git knows about, as basenames."""
    if not paths:
        return set()
    r = subprocess.run(["git", "ls-files", "--"] + paths, cwd=REPO,
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("check-guards-armed: git ls-files failed, so nothing was checked:\n"
              f"{r.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return {os.path.basename(p) for p in r.stdout.split()}


def main():
    # It only reads, but a selftest running beside it rewrites these very files,
    # and a guard reporting another guard's deliberate breakage as its own finding
    # is what repolock exists to prevent.
    repolock.refuse_if_held("check-guards-armed")

    if not os.path.isfile(SELFTEST):
        print(f"check-guards-armed: {SELFTEST} is missing, so every guard below "
              f"is unarmed and this check cannot say which.", file=sys.stderr)
        return 1
    # COMMENT LINES DO NOT COUNT. Registration means a line of code naming the
    # guard — a const, a path, an argv entry — because selftest-checks.py
    # discusses guards in its prose constantly, and a mention in a paragraph
    # about a guard is exactly the false positive that would make this check
    # report "armed" for one that is not. It still cannot tell a naming from a
    # working arm; only selftest itself runs the arms, and that is the division
    # of labour here: this says REGISTERED, selftest says BROKEN CONTROL.
    body = "\n".join(l for l in open(SELFTEST).read().split("\n")
                     if not l.lstrip().startswith("#"))

    found = sorted(glob.glob(os.path.join(REPO, "scripts", "check-*.py")))
    if not found:
        # Fail CLOSED. An empty scan reported as a clean one is how
        # check-isolation came to sweep 39% of the suite while printing success.
        print("check-guards-armed: no scripts/check-*.py found at all — the glob "
              "is wrong, and this check measured nothing.", file=sys.stderr)
        return 1

    known = tracked([os.path.relpath(f, REPO) for f in found])
    bad, skipped = 0, []
    for f in found:
        name = os.path.basename(f)
        if name not in known:
            skipped.append(name)
            continue
        if name not in body:
            print(f"UNARMED {name} is committed and is not named in "
                  f"scripts/selftest-checks.py, so nothing ever breaks it on "
                  f"purpose. A guard nobody can break is a guard nobody has "
                  f"tested.")
            bad += 1

    for name in sorted(skipped):
        # Said out loud rather than passed over: silence here would read as
        # "every guard is armed" when the newest one was simply not counted.
        print(f"ok      {name:<28} untracked, not yet an obligation")
    if not bad:
        print(f"check-guards-armed: {len(known)} committed guard(s) all named in "
              f"selftest-checks.py.")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
