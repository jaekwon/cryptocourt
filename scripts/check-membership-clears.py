#!/usr/bin/env python3
"""Every function that changes a moderator set's membership must discard its
pending m-of-n approvals.

Approvals record ADDRESSES and are never re-validated at fire time, so any entry
left standing across a membership change lets a moderator who is no longer a
member still count toward the threshold — including toward an irreversible purge.
That was a real vulnerability (v0.25): the outgoing set banked m-1 approvals on a
hide, the electorate replaced them with a disjoint set, and one member of the
incoming set fired it on the deposed signatures.

Three functions currently write `cm.members` or `cm.n`, and all three clear:
AppointMods, ResetModSet, and installModSet. This script exists to keep that
exhaustive.

WHY A SCRIPT AND NOT A TEST. Two of the three are pinned by tests
(TestAppointModsDiscardsTheOutgoingSetsApprovals and
TestInstallModSetDiscardsTheDeposedSetsApprovals, the latter needing a court whose
voting window is short enough to finish inside pendingTTLBlocks, or it proves
nothing). ResetModSet's clear CANNOT be pinned by any test, and that is a fact
about the design rather than a gap: it empties the set, so nobody can act until
AppointMods or installModSet re-installs one, and both of those clear on the way
in. Its effect is always superseded. A mutation deleting it therefore survives
every possible test, and always will.

So the clear in ResetModSet is defence in depth, and the only thing that could
make it load-bearing is somebody adding a FOURTH way to install members. That is
exactly the kind of drift a test cannot see and a structural check can. If this
script ever fires, either add the clear or — if the new path genuinely cannot
leave a stale approval — say why, here, in this file.
"""

import re
import sys

from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import repolock

ROOT = Path(__file__).resolve().parent.parent
REALM = ROOT / "realm" / "r" / "kourtv2"

# A write that can change who is in a set. `cm.m` is deliberately NOT here: the
# THRESHOLD moving is handled by its own clear in SetPurgeThreshold for the global
# body, and a per-court threshold only ever moves together with membership.
MEMBERSHIP_WRITE = re.compile(r"^\s*cm\.(members\s*=|n\s*=|n\+\+|n--)")
CLEAR = "clearPendingOnMembershipChange"


def functions(src):
    """Split a .gno source into (name, body) pairs on top-level func declarations."""
    out, name, buf = [], None, []
    for line in src.split("\n"):
        if line.startswith("func "):
            if name is not None:
                out.append((name, "\n".join(buf)))
            name = line[len("func "):].split("(")[0].strip()
            buf = [line]
        elif name is not None:
            buf.append(line)
    if name is not None:
        out.append((name, "\n".join(buf)))
    return out


def main() -> int:
    repolock.refuse_if_held("check-membership-clears")
    files = [p for p in sorted(REALM.glob("*.gno")) if not p.name.endswith("_test.gno")]
    if not files:
        # A silent zero here would make this check report success forever.
        print(f"check-membership-clears: no .gno files under {REALM}; the layout "
              f"moved and this check is measuring nothing.", file=sys.stderr)
        return 1

    found, bad = [], []
    for p in files:
        for name, body in functions(p.read_text()):
            if any(MEMBERSHIP_WRITE.match(l) for l in body.split("\n")):
                found.append(f"{p.name}:{name}")
                if CLEAR not in body:
                    bad.append((p.name, name))

    if not found:
        # The writes themselves vanished, which means the pattern stopped matching
        # the code rather than that the code stopped needing the rule.
        print(f"check-membership-clears: found no membership writes at all, which "
              f"cannot be right — the pattern has drifted from the code.",
              file=sys.stderr)
        return 1

    if bad:
        print("check-membership-clears: a moderator set's membership changes "
              "without discarding its pending approvals.\n", file=sys.stderr)
        for f, name in bad:
            print(f"  {f}:{name}", file=sys.stderr)
        print(f"\nApprovals record addresses and are never re-validated when they "
              f"fire, so a stale entry lets a former member still count toward the "
              f"threshold — the v0.25 vulnerability. Call {CLEAR} on this path, or "
              f"record in this script why the path cannot leave one.",
              file=sys.stderr)
        return 1

    print(f"check-membership-clears: {len(found)} membership-changing function(s) "
          f"all discard pending approvals ({', '.join(found)}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
