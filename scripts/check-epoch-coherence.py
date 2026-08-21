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

# Files that decide something by weight, pinned at their permitted live-read
# count. Zero everywhere today.
#
# WHY A COUNT AND NOT A FLAT ZERO. `w = min(PastVotes(who, Q), BalanceOf(who))`
# puts a live read in a tally file on purpose, and it is NOT the reverted design:
# there the live figure WAS the numerator, so a live numerator met a frozen bar.
# Here it is a CEILING on a frozen numerator, so
#
#     Σ min(PastVotes(·,Q), BalanceOf(·))  ≤  Σ PastVotes(·,Q)  ≤  PastTotal(Q)
#
# and the bar keeps the same instant as the thing measured against it. The live
# read can only ever lower a figure that was already coherent.
#
# So the property worth pinning is not "no live read" — that would forbid the fix.
# It is "no UNDECLARED live read": each one is counted here, a new one fails, and
# arm 3 separately pins that the engine can only be handed a lowering cap. Neither
# arm alone is enough; the pair is.
# Keyed by (pkg, file) like LIVE_ALLOWED below, not by bare filename. The set this
# replaced was filename-only, which was harmless while it meant "zero everywhere";
# now that the value is an ALLOWANCE, a governor/meta.gno appearing one day would
# silently inherit kourtv2's — misattribution that grants permission rather than
# denying it, which is the direction that does not announce itself.
TALLY_LIVE_ALLOWED = {
    # VoteDispute's cap, handed to the governor's VoteWithCap rather than
    # clamped locally — the tally is the governor's invariant to keep.
    ("kourtv2", "dispute.gno"): 1,
    # VoteQuality's floor: min(PastVotes(who,Q1), BalanceOf(who)). A CEILING on a
    # frozen numerator, not a live numerator — see the derivation above.
    ("kourtv2", "quality.gno"): 1,
    # approve()'s floor, derived once per election and reused. Same shape as
    # quality.gno: a ceiling on a frozen numerator, not a live numerator.
    ("kourtv2", "modvote.gno"): 1,
    ("kourtv2", "crystallize.gno"): 0,
    ("kourtv2", "meta.gno"): 0,
}

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

# ARM 3 — the engine derives its own weight, and a consumer may only LOWER it.
#
# The reverted design added VoteWithWeight, which took the figure to tally. A
# supplied weight is not drawn from p.total, so `cast` could exceed it and
# `rest := p.total - cast` went negative, dropping `no` out of the early-decide
# test entirely — a permissionless verdict flip, and the most expensive thing this
# guard exists to prevent recurring.
#
# SHAPE, NOT NAME. The first version matched a parameter literally called `weight`
# or `w`, which a review showed was naming-sensitive rather than shape-sensitive:
# `VoteWithCap(..., cap int64)` passed untouched, and so would a raw weight under
# any other name. So the rule is now positive — the ONE permitted supplied-value
# signature and the ONE permitted use of it are both pinned exactly — plus a
# blacklist of the shapes that raise instead of lower.
SUPPLIED_OK = (
    "func (g *Governor) VoteWithCap(who address, id int64, choice string, "
    "cap int64) {")
CLAMP_OK = "\tif cap > 0 && cap < w {\n\t\tw = cap\n\t}"
# Every int64 parameter on an exported *Governor method must appear in this exact
# allowlist. It is a NAME list on purpose: the point is not that these three names
# are safe, it is that a FOURTH int64 parameter cannot appear without someone
# editing this line and saying why. Fails closed on anything new.
#
#   id          — a proposal identifier. Not a quantity at all.
#   cap         — a ceiling, and the clamp below pins that it may only lower.
#   quorumFloor — a bar, supplied ONCE at propose time and frozen there. That is
#                 the design: bars are frozen so they cannot move under an open
#                 vote. A supplied bar at PROPOSE time and a supplied weight at
#                 VOTE time are opposite things, and only the second is the defect.
#
# The first attempt matched a trailing int64 outright, which fired on ReleaseRoll,
# Settle and Cancel — `id int64` is an identifier, not a quantity. Naming the
# legitimate roles is both narrower and more honest than matching on position.
GOV_METHOD = re.compile(
    r"^func \(g \*Governor\) ([A-Z][A-Za-z0-9_]*)\(([^)]*)\)", re.M)
INT64_PARAM_OK = {"id", "cap", "quorumFloor"}
# Shapes that would let a consumer RAISE the derived figure.
RAISERS = (
    "w = cap\n",      # an unconditional assignment outside the clamp
    "w += cap",
    "w = max(",
    "cap > w {",
    "cap >= w {",
)
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
            if (pkg, p.name) in TALLY_LIVE_ALLOWED:
                want = TALLY_LIVE_ALLOWED[(pkg, p.name)]
                # EXACT, not a ceiling. Too many is an undeclared live read; too
                # FEW means a declared cap was deleted, which is the fix being
                # quietly removed — and that direction is the one a test suite is
                # least likely to notice, since a missing ceiling only shows up
                # against an adversary.
                if n != want:
                    hits.append(f"[live-in-tally] {pkg}/{p.name}: {n} live weight "
                                f"read(s) in a file that decides by weight, "
                                f"expected exactly {want}")
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
                for m in GOV_METHOD.finditer(src):
                    name, params = m.group(1), m.group(2)
                    for part in params.split(","):
                        part = part.strip()
                        if not part.endswith("int64"):
                            continue
                        pname = part.split()[0]
                        if pname in INT64_PARAM_OK:
                            continue
                        hits.append(f"[supplied-weight] {pkg}/{p.name}: "
                                    f"{name}(... {part}) — the engine must DERIVE "
                                    f"weight; an int64 parameter may only be an "
                                    f"`id` or a `cap`")
                if src.count(SUPPLIED_OK) != 1 or src.count(CLAMP_OK) != 1:
                    hits.append(f"[cap-shape] {pkg}/{p.name}: the cap signature "
                                f"({src.count(SUPPLIED_OK)}) or its clamp "
                                f"({src.count(CLAMP_OK)}) is not present exactly "
                                f"once — a reshaped clamp is how a ceiling becomes "
                                f"a floor")
                # The clamp itself contains `w = cap`, so one occurrence is
                # expected and any second is a raise.
                for bad in RAISERS:
                    want = 1 if bad == "w = cap\n" else 0
                    if src.count(bad) != want:
                        hits.append(f"[cap-raises] {pkg}/{p.name}: {bad!r} appears "
                                    f"{src.count(bad)} time(s), expected {want} — "
                                    f"a supplied cap must only ever lower")
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
