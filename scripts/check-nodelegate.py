#!/usr/bin/env python3
"""Trip if kourtv2 gains delegation while its vote weight is floored by own balance.

WHY THIS EXISTS. Vote weight in kourtv2 is

    w = min( PastVotes(who, Q), BalanceOf(who) )

and those two readings are NOT the same quantity in general. `PastVotes` is
delegation-aware — grc20votes credits an account with every balance delegated to
it — while `BalanceOf` is strictly the address's own coin. Today the two agree in
kourtv2 for one reason and one only: **kourtv2 exposes no way to delegate**, so
every account is self-delegated and `PastVotes(who, Q)` is exactly who's own past
balance.

The moment kourtv2 exposes delegation, the ceiling starts counting coin the voter
was lent the say over while the floor counts only coin they hold, so **every
delegatee is silently docked to their own balance** — a delegate holding nothing
and trusted with a million votes gets zero. Nothing else in the tree would
complain: the arithmetic stays coherent, every suite stays green, and the loss is
invisible until somebody who delegated wonders why their delegate cannot vote.

That is a comment-shaped hazard, so it gets a machine instead of a comment.

WHY r/govern IS EXEMPT, stated rather than assumed. govern exposes Delegate and
shares the same governor engine, but it calls `Vote`, which applies no cap and
therefore no floor. Delegation and the floor only collide where both are present.
If govern ever adopts VoteWithCap, this guard's scope has to grow with it — which
is what arm 4 is for.

    python3 scripts/check-nodelegate.py
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import repolock  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
KOURTV2 = ROOT / "realm" / "r" / "kourtv2"
GRC20VOTES = ROOT / "realm" / "p" / "grc20votes"
GOVERN = ROOT / "realm" / "r" / "govern"

# The floor's shape, as shipped. Pinned as a COUNT so that deleting the floor
# cannot leave this guard passing vacuously: with no floor there is no asymmetry
# to protect, and a guard still reporting success would be describing a property
# nothing in the tree has.
FLOOR = re.compile(r"if held := c\.coin\.BalanceOf\([a-z]+\); held < w \{")
# The dispute lane does not match FLOOR: it hands the live figure to the governor
# as a cap instead of clamping locally, so its floor is a BalanceOf read feeding
# VoteWithCap. Counted separately rather than loosening the pattern, because a
# looser pattern would also match reads that are not floors at all.
FLOOR_SITES = 2  # quality.gno, modvote.gno
CAP_CALL = re.compile(r"c\.gov\.VoteWithCap\(")
CAP_SITES = 1  # dispute.gno

# A delegation mutator reachable from kourtv2 — either a call into the ledger's
# own Delegate, or an exported kourtv2 entrypoint that offers it.
CALLS_DELEGATE = re.compile(r"\.Delegate\(")
# Capture the name and test it, rather than trying to spell "an exported
# identifier containing Delegate" as one pattern. The first attempt was
#     ^func +[A-Z][A-Za-z0-9_]*[Dd]elegate
# which cannot match a bare `func Delegate(`: the [A-Z] eats the D and leaves
# seven characters for an eight-character [Dd]elegate. It matched only compounds
# like SetDelegate, so the plainest possible spelling of the hazard walked past
# it. Found by the selftest control, not by review, and not by my own ablation —
# which planted a body that called .Delegate() and so fired the OTHER arm. An
# ablation that passes for the wrong reason is not evidence.
EXPORTED_FUNC = re.compile(r"^func +([A-Z][A-Za-z0-9_]*)\(", re.M)


def gno_files(d):
    return [p for p in sorted(d.glob("*.gno")) if not p.name.endswith("_test.gno")]


def main():
    repolock.refuse_if_held("check-nodelegate")
    hits = []

    # ARM 1 — the guard is protecting a real API. If the ledger has no Delegate at
    # all then delegation is not a thing that can happen and this file should be
    # DELETED rather than left reporting success over nothing.
    ledger = "".join(p.read_text() for p in gno_files(GRC20VOTES))
    if "func (l *Ledger) Delegate(" not in ledger:
        print("check-nodelegate: grc20votes has no Delegate mutator, so this "
              "guard is measuring nothing. Delete it or fix the reference.",
              file=sys.stderr)
        return 1

    # ARM 2 — the ceiling really is delegation-aware. The whole hazard rests on
    # PastVotes reading the delegated tally rather than the raw balance; if that
    # changed, the two readings would agree by construction and this guard would
    # be guarding a coincidence.
    if "a.votes.ValueAt(" not in ledger:
        print("check-nodelegate: PastVotes no longer reads the delegated vote "
              "series, so the ceiling/floor asymmetry this guard exists for may "
              "not exist. Re-derive it before trusting this check.",
              file=sys.stderr)
        return 1

    # ARM 3 — the floor exists, at its pinned count.
    v2 = gno_files(KOURTV2)
    if not v2:
        print(f"check-nodelegate: no .gno files under {KOURTV2}; the layout moved "
              f"and this check is measuring nothing.", file=sys.stderr)
        return 1
    floors = sum(len(FLOOR.findall(p.read_text())) for p in v2)
    if floors != FLOOR_SITES:
        hits.append(f"[floor-count] kourtv2 has {floors} own-balance vote floor(s), "
                    f"expected {FLOOR_SITES} — if the floor moved, this guard's "
                    f"premise moved with it")
    caps = sum(len(CAP_CALL.findall(p.read_text())) for p in v2)
    if caps != CAP_SITES:
        hits.append(f"[cap-count] kourtv2 hands the governor a live cap at {caps} "
                    f"site(s), expected {CAP_SITES} — same premise, reached through "
                    f"VoteWithCap rather than a local clamp")

    # ARM 4 — nothing in kourtv2 delegates, and nothing offers to.
    for p in v2:
        src = p.read_text()
        for m in CALLS_DELEGATE.finditer(src):
            line = src[:m.start()].count("\n") + 1
            hits.append(f"[delegates] kourtv2/{p.name}:{line} calls Delegate — the "
                        f"vote ceiling is delegation-aware and the floor is not, so "
                        f"every delegatee is docked to their own balance")
        for m in EXPORTED_FUNC.finditer(src):
            if "delegate" not in m.group(1).lower():
                continue
            line = src[:m.start()].count("\n") + 1
            hits.append(f"[delegates] kourtv2/{p.name}:{line} exports {m.group(1)} "
                        f"— a delegation entrypoint, see above")

    # ARM 5 — govern's exemption is conditional, so check the condition.
    gov = "".join(p.read_text() for p in gno_files(GOVERN))
    if "VoteWithCap(" in gov:
        hits.append("[scope] r/govern now uses VoteWithCap while exposing Delegate, "
                    "which is the exact collision this guard was scoped away from. "
                    "Extend the scope or remove govern's Delegate.")

    if hits:
        print("check-nodelegate: delegation and an own-balance vote floor cannot "
              "coexist unnoticed.\n", file=sys.stderr)
        for h in hits:
            print(f"  {h}", file=sys.stderr)
        print("\nPastVotes counts every balance delegated to an address; BalanceOf "
              "counts only its own. They agree in kourtv2 solely because nothing "
              "there can delegate. If delegation is wanted, the floor has to become "
              "delegation-aware in the same change — read VOTEFLOOR.md first.",
              file=sys.stderr)
        return 1

    print(f"check-nodelegate: {len(v2)} kourtv2 files, no delegation reachable, "
          f"{floors} own-balance vote floor(s) + {caps} capped call(s) pinned. "
          f"The ceiling and the floor "
          f"measure the same coin.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
