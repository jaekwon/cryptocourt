#!/usr/bin/env python3
"""Every guard in scripts/ is reachable from `make check`, or exempt with a reason.

    python3 scripts/check-guards-run.py

WHY THIS EXISTS. A guard that nothing runs is worse than no guard: it reads like
coverage in the tree and in review, and it reports nothing. There was no check
that the check scripts themselves are wired in — check-guards-armed proves each
one has a control arm, and check-mutation-anchors' routinely_run only validates a
mutation row's "covered elsewhere" excuse. Neither notices a guard dropped out of
the Makefile, and the Makefile is edited by hand: seven web checks had drifted
onto a target named `height-shim`, and moving them is exactly the operation that
loses one.

FAILS CLOSED BOTH WAYS, because the two failures need opposite fixes:

  * a guard reachable from no target is a guard that stopped running — wire it up,
    or exempt it here and say why;
  * an exemption naming a guard that is gone, or one that is now reachable, is an
    excuse nobody rechecked — delete it. An exemption list that only ever grows
    becomes the place unrun guards go to be forgotten, which is the failure this
    file is about.

REACHABILITY, NOT MENTION. The walk starts at `check` and follows prerequisites,
so a guard sitting in a target no one depends on does not count. That is the
distinction that matters: `isolation-test` is a real target with a real recipe,
and `make check` has never called it.
"""

import glob
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Deliberately outside `check`. Each needs a reason, and the reason has to be
# about why running it routinely is wrong — not about it being slow.
EXEMPT = {
    "check-isolation.py":
        "builds a gnoroot sandbox and copies the realm into it, so it needs a gno "
        "toolchain and a writable scratch tree that `check` does not assume. It has "
        "its own target, isolation-test, and the tree's own notes already record "
        "that check does not call it.",
    "check-live-reads.py":
        "reads a LIVE chain over RPC (--remote) and answers a question about a "
        "deployment rather than about the source. In `check` it would fail whenever "
        "the node is down or the branch is ahead of what is deployed, which is most "
        "of the time and never the guard's fault.",
}


def targets(src):
    """Every Makefile target, its prerequisites and its recipe."""
    deps, bodies = {}, {}
    for m in re.finditer(r"^([a-z][a-z0-9-]*):([^\n=]*)\n((?:\t[^\n]*\n)*)", src, re.M):
        deps[m.group(1)] = m.group(2).split()
        bodies[m.group(1)] = m.group(3)
    return deps, bodies


def reachable_recipes(src, root="check"):
    deps, bodies = targets(src)
    if root not in deps:
        sys.exit("check-guards-run: no `%s` target in the Makefile. Fix the parse "
                 "rather than assuming — a parse that finds nothing would pass "
                 "every guard in the tree." % root)
    seen, stack = set(), [root]
    while stack:
        t = stack.pop()
        if t in seen or t not in deps:
            continue
        seen.add(t)
        stack += deps[t]
    return "".join(bodies.get(t, "") for t in seen), len(seen)


def main():
    mk = os.path.join(REPO, "Makefile")
    if not os.path.isfile(mk):
        sys.exit("check-guards-run: no Makefile at %s" % mk)
    src = open(mk, encoding="utf-8", errors="ignore").read()
    body, n_targets = reachable_recipes(src)

    guards = sorted(os.path.basename(p)
                    for p in glob.glob(os.path.join(REPO, "scripts", "check-*.py")))
    if len(guards) < 10:
        sys.exit("check-guards-run: found only %d guard(s) in scripts/ — the scan "
                 "matched too little to be real." % len(guards))

    unrun = [g for g in guards if g not in body and g not in EXEMPT]
    # An exemption is a claim about today, so it is rechecked today.
    gone = [g for g in EXEMPT if g not in guards]
    now_run = [g for g in EXEMPT if g in guards and g in body]

    if unrun or gone or now_run:
        for g in unrun:
            print("check-guards-run: %-34s reachable from no target `check` needs"
                  % g, file=sys.stderr)
        for g in gone:
            print("check-guards-run: %-34s exempt, but no such guard exists"
                  % g, file=sys.stderr)
        for g in now_run:
            print("check-guards-run: %-34s exempt, but `check` runs it now"
                  % g, file=sys.stderr)
        if unrun:
            print("\nWire it into a target `check` depends on, or exempt it in this "
                  "guard with a reason. A guard nothing runs reads like coverage and "
                  "reports nothing.", file=sys.stderr)
        if gone or now_run:
            print("\nDrop the stale exemption. An excuse nobody rechecks is how the "
                  "list becomes the place unrun guards go to be forgotten.",
                  file=sys.stderr)
        return 1

    print("check-guards-run: %d guard(s), %d reachable from `check` across %d target(s), "
          "%d exempt with a reason."
          % (len(guards), len(guards) - len(EXEMPT), n_targets, len(EXEMPT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
