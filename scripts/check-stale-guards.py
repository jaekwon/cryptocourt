#!/usr/bin/env python3
"""Check that every crossing entrypoint refuses a stale realm frame.

Every `func F(cur realm, ...)` in this repo opens by refusing a frame that has
already returned:

    if !cur.IsCurrent() {
        panic(errStaleRealm)
    }

WHY A GUARD THAT READS RATHER THAN A TEST THAT RUNS. There is no test for this and
there cannot be one. realm/r/govern/token_test.gno worked it out first, for its own
fourteen entrypoints: the harness has no way to hand an entrypoint a realm value
from a frame that has returned, because `cross()` is IsCurrent-strict and a
function literal cannot take a realm argument under any name but `cur`. Its
conclusion — "an assertion that cannot fail is worse than none, so there is not
one" — is right, and so is the sentence after it: what actually holds the
invariant is that the entrypoints are "one line each, checkable by reading".

This is that reading, done by a machine instead of by whoever remembers. It was
written after a mutation row deleting the check from kourtv2's mustDeployer
SURVIVED the entire corpus, which is the correct verdict from a harness that
cannot reach the line and no comfort at all about the ~60 other sites.

TWO FORMS ARE ACCEPTED, and the second is verified rather than trusted:

  * the check itself, as the first statement.
  * a call to a `mustX(cur)` helper whose OWN first statement is the check. A
    delegation is only as good as its delegate, so the delegate is looked up in
    the same package and checked; a call to a helper that skips the check is a
    failure naming both. Today there is exactly one such helper
    (kourtv2/mustDeployer) carrying four call sites.

Exemptions are named individually with a reason, and a stale one — naming a
function that no longer exists — is a failure. An exemption list that silently
rots is how a guard comes to watch nothing.

    python3 scripts/check-stale-guards.py
"""

import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import repolock  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECK = "!cur.IsCurrent()"

# Every crossing entrypoint that does NOT open with the check, with why it is
# allowed not to. Measured, not assumed: at the time of writing there are 105
# crossing entrypoints under realm/r — 98 open with the check directly, 4 via
# mustDeployer, and these 3.
EXEMPT = {
    "govern/govern.gno:dispatch":
        "not an entrypoint — it RETURNS a closure and performs no realm work "
        "itself; the returned function's callers are the ones that act.",
    "kourtv1/buy.gno:refundGNOT":
        "unexported, and kourtv1 is behaviourally frozen. Its callers are "
        "exported entrypoints in the same file that do open with the check, so "
        "the frame is already verified by the time this runs.",
    "offerer/offerer.gno:OfferNamed":
        "its first statement is a cross-call into govern, which performs its own "
        "IsCurrent check at the boundary it matters for. offerer is a demo realm "
        "holding no value.",
}

ENTRY = re.compile(r"^func (\w+)\(cur realm[,)]")
HELPER_CALL = re.compile(r"^(must\w+)\(cur\)$")


def first_statement(lines, i):
    """The first non-blank, non-comment line of the body opening at line i."""
    j = i + 1
    while j < len(lines) and (not lines[j].strip() or lines[j].strip().startswith("//")):
        j += 1
    return lines[j].strip() if j < len(lines) else ""


def scan():
    """(entrypoints, verified helper names per package)."""
    entries, helpers = [], {}
    for path in sorted(glob.glob(os.path.join(REPO, "realm/r/*/*.gno"))):
        base = os.path.basename(path)
        if base.endswith("_test.gno") or "_filetest" in base:
            continue
        pkg = os.path.basename(os.path.dirname(path))
        lines = open(path).read().split("\n")
        for i, ln in enumerate(lines):
            m = ENTRY.match(ln)
            if not m:
                continue
            name, first = m.group(1), first_statement(lines, i)
            entries.append((f"{pkg}/{base}:{name}", first))
            # A helper is itself a crossing function, so it is picked up here too;
            # record whether it opens with the check.
            if name.startswith("must"):
                helpers.setdefault(pkg, {})[name] = CHECK in first
    return entries, helpers


def main():
    # It only reads, but a selftest running beside it rewrites these very files
    # to break them on purpose, and reporting that as this guard's finding is the
    # false-failure-in-another-gate case repolock exists for.
    repolock.refuse_if_held("check-stale-guards")

    entries, helpers = scan()
    if not entries:
        # Fail CLOSED. An empty scan reported as a clean one is how check-isolation
        # came to sweep 39% of the suite while printing success.
        print("check-stale-guards: no crossing entrypoints found under realm/r — "
              "the pattern is wrong and nothing was checked.", file=sys.stderr)
        return 1

    bad, seen_exempt = 0, set()
    direct = delegated = 0
    for ident, first in entries:
        if ident in EXEMPT:
            seen_exempt.add(ident)
            continue
        if CHECK in first:
            direct += 1
            continue
        m = HELPER_CALL.match(first)
        if m:
            pkg = ident.split("/")[0]
            verified = helpers.get(pkg, {}).get(m.group(1))
            if verified:
                delegated += 1
                continue
            if verified is False:
                print(f"DELEGATED {ident} defers to {m.group(1)}, which does not "
                      f"open with the check itself. A delegation is only as good "
                      f"as its delegate.")
            else:
                print(f"UNKNOWN   {ident} defers to {m.group(1)}, which is not a "
                      f"crossing helper in {pkg}. It cannot be verifying the frame.")
            bad += 1
            continue
        print(f"UNGUARDED {ident} does not refuse a stale realm frame. Open it "
              f"with `if {CHECK} {{ panic(errStaleRealm) }}`, delegate to a "
              f"mustX(cur) helper that does, or add it to EXEMPT with a reason.")
        bad += 1

    for ident in sorted(set(EXEMPT) - seen_exempt):
        print(f"STALE     EXEMPT names {ident}, which is no longer a crossing "
              f"entrypoint. Drop the row — an exemption list that rots is how a "
              f"guard comes to watch nothing.")
        bad += 1

    if not bad:
        print(f"check-stale-guards: {len(entries)} crossing entrypoint(s) — "
              f"{direct} open with the check, {delegated} delegate to a verified "
              f"mustX(cur) helper, {len(seen_exempt)} exempt with a reason.")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
