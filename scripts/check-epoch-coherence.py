#!/usr/bin/env python3
"""Trip if a vote tally and the bar it is judged against stop sharing an epoch.

WHY THIS EXISTS. A change making vote weight LIVE (the voter's balance at the
moment they vote) was built, reviewed by three panels, and reverted. It was not
killed by a bug list. It was killed because every safety bar in this realm is a
FROZEN snapshot, deliberately — "a bar cannot move under an open vote" is asserted
in four separate files — and a live numerator against a frozen denominator gave
turnout at 200-400% of its own bar in several lanes. Six sites, one root cause.

Arm 1 below fires on exactly the three lines that change did, so it would have
tripped on its first commit, before a single test ran. That is the whole point:
this class is cheap to catch lexically and expensive to catch by review.

WHAT IT DOES NOT CATCH, stated so nobody over-trusts it. Two frozen quantities
frozen at DIFFERENT epochs (weighing a verdict at the answer's epoch while the
credential bar still reads the proposal's) are invisible to arms 1-3; that needs a
declared epoch per site, which is a convention this repo has not adopted. See
VOTELOCK.md's tension map before relying on this guard for a redesign.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import repolock  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
KOURTV2 = ROOT / "realm" / "r" / "kourtv2"
GOVERNOR = ROOT / "realm" / "p" / "governor"

# ARM 1 — no LIVE weight read may appear in a file that computes a tally or a bar.
LIVE = re.compile(r"\.(BalanceOf|VotesOf|TotalSupply)\(")

# Files that decide something by weight. Pinned at zero: a live read here is the
# reverted design's exact shape.
TALLY_FILES = {"dispute.gno", "quality.gno", "modvote.gno", "crystallize.gno",
               "meta.gno"}

# Legitimate live readers, pinned at their measured counts. A render surface or a
# spendable() check is not a tally; a NEW one still has to be deliberate.
LIVE_ALLOWED = {
    ("kourtv2", "buy.gno"): 1,        # CoinBalanceOf, a read entrypoint
    ("kourtv2", "court.gno"): 1,      # CoinSupply
    ("kourtv2", "emission.gno"): 1,   # the budget base
    ("kourtv2", "lock.gno"): 1,       # spendable()
    ("kourtv2", "render.gno"): 2,     # the page
    ("kourtv2", "testclock.gno"): 1,  # the virgin-realm guard
    ("governor", "governor.gno"): 2,  # render only
}

# ARM 2 — one sealed-epoch expression per function. A function that reads two
# different epochs is computing a numerator and a denominator that cannot be
# compared, which is the defect in its purest form.
SEALED = re.compile(r"\.(PastVotes|PastTotal|EngagedTotal)\(\s*([^)]*?)\s*\)")
FUNC = re.compile(r"^func\s+(?:\([^)]*\)\s*)?([A-Za-z0-9_]+)", re.M)
MIN_SEALED_FUNCS = 9  # measured; fail closed if the surface shrinks

# ARM 3 — the engine has exactly ONE weight source. The reverted design added
# VoteWithWeight, which let `cast` exceed `p.total` and made `rest := p.total -
# cast` negative, dropping `no` out of the early-decide test entirely. That was a
# permissionless verdict flip, and it is the single most expensive thing this
# guard is here to prevent recurring.
SUPPLIED_WEIGHT = re.compile(
    r"^func \(g \*Governor\) [A-Z][A-Za-z0-9_]*\([^)]*\b(weight|w)\s+int64", re.M)
WEIGHT_SOURCE = re.compile(r"^\s*w\s*:?=\s*g\.voters\.PastVotes\(", re.M)


def funcs_with_epochs(src):
    """Map function name -> set of epoch expressions it reads."""
    bounds = [(m.start(), m.group(1)) for m in FUNC.finditer(src)]
    out = {}
    for m in SEALED.finditer(src):
        name = None
        for pos, nm in bounds:
            if pos < m.start():
                name = nm
            else:
                break
        if name:
            # The EPOCH is always the last argument: PastVotes(who, at) and
            # PastTotal(at) both end in it. Taking the whole arg list instead
            # made PastVotes(c.escrow, at) and PastTotal(at) look like different
            # epochs, which is a false positive on every votable computation in
            # the realm — they are the same instant by construction, and that is
            # exactly the property worth checking.
            epoch = m.group(2).rsplit(",", 1)[-1].strip()
            out.setdefault(name, set()).add(epoch)
    return out


def main() -> int:
    repolock.refuse_if_held("check-epoch-coherence")
    hits, scanned, sealed_funcs = [], 0, 0

    for pkg, d in (("kourtv2", KOURTV2), ("governor", GOVERNOR)):
        files = [p for p in sorted(d.glob("*.gno"))
                 if not p.name.endswith("_test.gno")]
        if not files:
            print(f"check-epoch-coherence: no .gno files under {d}; the layout "
                  f"moved and this check is measuring nothing.", file=sys.stderr)
            return 1
        for p in files:
            scanned += 1
            src = p.read_text()

            # Arm 1
            n = len(LIVE.findall(src))
            if p.name in TALLY_FILES:
                if n:
                    hits.append(f"[live-in-tally] {pkg}/{p.name}: {n} live weight "
                                f"read(s) in a file that decides by weight")
            else:
                want = LIVE_ALLOWED.get((pkg, p.name), 0)
                if n != want:
                    hits.append(f"[live-census] {pkg}/{p.name}: {n} live weight "
                                f"read(s), expected {want}")

            # Arm 2
            for name, epochs in funcs_with_epochs(src).items():
                sealed_funcs += 1
                if len(epochs) > 1:
                    hits.append(f"[two-epochs] {pkg}/{p.name}:{name} reads "
                                f"{sorted(epochs)} — a numerator and a bar taken "
                                f"at different instants cannot be compared")

            # Arm 3
            if p.name == "governor.gno":
                for m in SUPPLIED_WEIGHT.finditer(src):
                    hits.append(f"[supplied-weight] {pkg}/{p.name}: "
                                f"{m.group(0).strip()[:60]}... — the engine must "
                                f"derive weight, never be told it")
                srcs = len(WEIGHT_SOURCE.findall(src))
                if srcs != 1:
                    hits.append(f"[weight-sources] {pkg}/{p.name}: {srcs} weight "
                                f"assignments from g.voters, expected exactly 1")

    if hits:
        print("check-epoch-coherence: a tally and its bar may no longer share an "
              "epoch.\n", file=sys.stderr)
        for h in hits:
            print("  " + h, file=sys.stderr)
        print("\nEvery bar in this realm is frozen so it cannot move under an open "
              "vote — asserted in governor.gno, rules.gno, dispute.gno and "
              "quality.gno. A LIVE numerator against a frozen bar produced turnout "
              "at 200-400% of its own bar and a permissionless verdict flip; the "
              "work was reverted. If this is deliberate, VOTELOCK.md's tension map "
              "is the argument to answer first, then change this check.",
              file=sys.stderr)
        return 1

    if sealed_funcs < MIN_SEALED_FUNCS:
        print(f"check-epoch-coherence: only {sealed_funcs} functions read a sealed "
              f"epoch, expected at least {MIN_SEALED_FUNCS}. Either the surface "
              f"moved or the regex stopped matching — this check is measuring "
              f"nothing.", file=sys.stderr)
        return 1

    print(f"check-epoch-coherence: {scanned} files, {sealed_funcs} sealed-epoch "
          f"function(s) each reading one epoch, no live weight in any tally, one "
          f"weight source in the engine.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
