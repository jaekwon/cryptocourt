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
# BACK TO A FLAT ZERO, and the refactor that allowed it is the point.
#
# For a while these carried per-file COUNTS, because `w = min(PastVotes(who, Q),
# BalanceOf(who))` needs a live read and three lanes each had their own copy. Then
# the expression moved into voteweight.gno — one function, four callers, plus
# voteCap for the lane that must hand the governor a ceiling instead of a weight —
# and every tally file went back to zero live reads. A guard that had to be
# weakened to admit a fix is now stronger than before it, which is the shape to
# aim for: the fix was not an exception to the rule, it was a missing abstraction.
#
# Arm 4 below pins that there is exactly ONE such expression, so this zero cannot
# be satisfied by a second copy hiding in a non-tally file.
# Keyed by (pkg, file) like LIVE_ALLOWED below, not by bare filename. The set this
# replaced was filename-only, which was harmless while it meant "zero everywhere";
# now that the value is an ALLOWANCE, a governor/meta.gno appearing one day would
# silently inherit kourtv2's — misattribution that grants permission rather than
# denying it, which is the direction that does not announce itself.
TALLY_LIVE_ALLOWED = {
    ("kourtv2", "dispute.gno"): 0,
    ("kourtv2", "quality.gno"): 0,
    ("kourtv2", "modvote.gno"): 0,
    ("kourtv2", "crystallize.gno"): 0,
    ("kourtv2", "meta.gno"): 0,
}

# Legitimate live readers, pinned at their measured counts. A render surface or a
# spendable() check is not a tally; a NEW one still has to be deliberate.
LIVE_ALLOWED = {
    ("kourtv2", "buy.gno"): 1,        # CoinBalanceOf, a read entrypoint
    ("kourtv2", "court.gno"): 1,      # CoinSupply
    ("kourtv2", "emission.gno"): 1,   # the budget base
    ("kourtv2", "lock.gno"): 2,       # spendable() and disposable()
    ("kourtv2", "render.gno"): 2,     # the page
    ("kourtv2", "testclock.gno"): 1,  # the virgin-realm guard
    # THE one weight expression, plus the one ceiling the dispute lane supplies.
    # Arm 4 pins that these are the only two and that nothing else recomputes them.
    ("kourtv2", "voteweight.gno"): 2,
    ("governor", "governor.gno"): 2,  # render only
}

# ARM 2 — one sealed-epoch expression per function. A function that reads two
# different epochs is computing a numerator and a denominator that cannot be
# compared, which is the defect in its purest form.
SEALED = re.compile(r"\.(PastVotes|PastTotal|EngagedTotal)\(\s*([^)]*?)\s*\)")
FUNC = re.compile(r"^func\s+(?:\([^)]*\)\s*)?([A-Za-z0-9_]+)", re.M)
# Measured; fail closed if the surface shrinks. It DID shrink, from 9 to 8, when the
# three inline min(PastVotes, BalanceOf) copies were replaced by voteweight.gno's
# single votingWeight — two call sites gone, one added. Lowering a fail-closed
# threshold is normally how a guard dies quietly, so the drop is named here with its
# cause, and arm 4 below is what makes the centralisation itself the invariant. If
# this number falls again without a matching arm-4 change, that is the bad case.
#
# The NINE, so a future drop can be diagnosed rather than guessed at. (It was eight
# for one commit; credWeightFloorAt then arrived reading EngagedTotal, and the
# enumeration went stale the moment it was written — which is the argument for the
# threshold being a floor rather than an equality.)
#   court.gno:supplyFloor        dispute.gno:VotableSupply   dispute.gno:quorumFloor
#   dispute.gno:credWeightFloorAt  modvote.gno:votableAt     quality.gno:qualityBars
#   voteweight.gno:votingWeight  governor.gno:propose        governor.gno:castVote
MIN_SEALED_FUNCS = 8

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

# ARM 4 — the vote-weight expression has exactly one definition and the right
# SHAPE.
#
# Three lanes charge min(snapshot, held) and a reader quotes it back to the elector.
# A quote that can drift from the charge is worse than no quote: the holder plans
# against a number the vote will not honour.
#
# WHAT THIS ARM ACTUALLY CATCHES, stated exactly, because the first version of this
# comment claimed more than the code did and was wrong within the hour:
#
#   CAUGHT, and by this arm ALONE — the floor's comparison reversed, `held <`
#   becoming `held >`. Arm 1's census still counts two BalanceOf reads and says
#   nothing, so the shape check is the only thing between a ceiling and a floor.
#   Measured: [one-weight] fires, [live-census] does not.
#
#   CAUGHT, but by ARM 1 and not here — a second INLINE copy of the expression.
#   Any real second implementation has to read a live balance, which trips that
#   file's census. So the two arms cover it between them, and neither alone.
#
#   NOT CAUGHT — a wrapper that merely forwards, e.g. `func effectiveWeight(...)
#   { return votingWeight(...) }`. It adds no live read and does not match the
#   name family below. That is a readability problem rather than a correctness
#   one: a forwarder cannot disagree with what it forwards to. If one ever grows
#   its own arithmetic it stops forwarding, and then it needs a BalanceOf and arm
#   1 has it.
#
# The name family is deliberately a PREFIX match, so votingWeightV2 or voteCap2
# fail closed rather than sliding past — the same fail-closed shape as arm 3's
# int64 parameter allowlist.
WEIGHT_FN = re.compile(r"^func votingWeight[A-Za-z0-9_]*\(", re.M)
CAP_FN = re.compile(r"^func voteCap[A-Za-z0-9_]*\(", re.M)
# The floor's shape, wherever it appears. Exactly one, inside votingWeight.
FLOOR_SHAPE = re.compile(r"if held := c\.coin\.BalanceOf\([a-z]+\); held < ")

# ARM 5 — the quality vote lock releases on "the claim is terminal", and its idea of
# terminal is `cs.verdictAt != 0 || cs.closed`. That is only correct while those two
# fields are the COMPLETE set of ways a claim can end.
#
# claim.gno says so in prose — "VERDICT_FINAL (P4): set by SettleUndisputed,
# Finalize, or provClose" — and prose is what this arm replaces. A fourth terminal
# path that ended a claim some other way would leave every quality vote cast into a
# frozen tally locked FOREVER, with no error anywhere: the predicate would simply
# keep answering "still open" about a claim that is over. Nothing else in the tree
# would notice, because nothing else asks.
#
# So the writers are counted. A change here is not necessarily wrong — it just has
# to be made by someone who has read votelock.gno's voteLockQuality arm.
# ANY assignment form, and requiring ` = ` was this arm's blind spot. Five places in
# this realm already assign cs fields in TUPLE form (answer.gno's stake freeze,
# dispute.gno's carrot record twice, quality.gno's tally reset, stake.gno's
# conviction), so `cs.verdictAt, cs.verdictAtTime = now, t` is the idiomatic way to
# write a new terminal path here — and under the old pattern an ADDED one left the
# count at three and went unseen. Converting an existing one would have fired, by
# dropping the count, which is the kind of half-coverage that reads as coverage.
#
# `\b` after the field name matters: cs.verdictAtTime is a DIFFERENT field, assigned
# in its own right, and must not be counted as a terminal write.
TERMINAL_VERDICT = re.compile(r"^\s*cs\.verdictAt\b[^=\n]*=", re.M)
TERMINAL_CLOSED = re.compile(r"^\s*cs\.closed\b[^=\n]*=", re.M)
TERMINAL_VERDICT_N = 3  # dispute.gno provClose + Finalize, session.gno settle
TERMINAL_CLOSED_N = 1   # claim.gno dead-claim close

# ARM 6 — mustStakable has exactly ONE caller, and that is a safety invariant.
#
# Every mustSpendable call site moves coin OUT of a holder's balance, so all of them
# respect the vote lock. Stake is the single deliberate exemption: it is a pure lock
# that leaves the coin where it is and keeps it voting, so a pending vote is no
# reason to refuse it, and it calls mustStakable instead.
#
# A SECOND caller would be a second path escaping the vote lock, and it would do so
# silently — mustStakable is a legitimate-looking helper with a reassuring name, and
# reaching for it is the natural mistake when a new path hits the vote lock and the
# author decides the lock is being unhelpful. So the count is pinned, and the
# exemption has to be argued rather than copied.
STAKABLE_CALL = re.compile(r"mustStakable\(c, ")
STAKABLE_CALLS_N = 1  # stake.gno:Stake

# ARM 7 — every coin movement OUT of a user's balance is immediately preceded by a
# gate.
#
# This is the structural form of a thing that was being checked one path at a time.
# The vote lock and the stake lock both live in mustSpendable, so a new path that
# moves a holder's coin without calling it bypasses BOTH — silently, because the
# transfer succeeds and no arithmetic goes wrong. It is the natural shape of the
# mistake: a feature that needs to take a bond writes the Transfer and forgets the
# line above it.
#
# Audited by hand first, which is how the pairing turned out to be exact: seven
# user-sourced movements (the claim deposit, the answer bond, the dispute bond, the
# flag bond, the election nomination bond, and the two transfer paths), each with its
# gate on the line before. Movements sourced from c.escrow are exempt and must be:
# the escrow is not a voter, holds no lock, and its outflows are refunds and burns
# that the lanes owning them dispose of.
#
# Two pins, because either alone is weak. The COUNT fails closed on a new movement
# even if somebody gates it in an unusual way, and the ADJACENCY catches the ordinary
# omission. Together they mean a new outflow has to be looked at.
# Burn is in here, and leaving it out was this arm's own blind spot for one commit.
# lock.gno's spendable() clamp carries the comment "only reachable if a burn ever
# took coins out from under a lock. It does not today (nothing burns a user's
# balance)" — an anticipated hazard with nothing enforcing its non-occurrence, which
# is the exact shape this whole guard exists for. All eleven Burn sites are escrow-
# sourced today so the pinned count is unchanged; what changes is that a user-sourced
# burn can no longer arrive unnoticed. It would be worse than an ungated transfer:
# a transfer moves locked coin, a burn destroys it.
COIN_OUT = re.compile(r"^\s*c\.coin\.(?:Transfer|TransferFrom|Burn)\(", re.M)
ESCROW_SRC = re.compile(r"c\.coin\.(?:Transfer|Burn)\(c\.escrow")
GATE = re.compile(r"must(?:Spendable|Stakable)\(")
COIN_OUT_N = 7  # see the audit above


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
    arm4 = {"weight_fn": 0, "cap_fn": 0, "floor": 0,
            "verdict_w": 0, "closed_w": 0, "stakable": 0, "coin_out": 0}

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

            # Arm 4 — accumulated across the kourtv2 tree, checked after the loop.
            if pkg == "kourtv2":
                arm4["weight_fn"] += len(WEIGHT_FN.findall(src))
                arm4["cap_fn"] += len(CAP_FN.findall(src))
                arm4["floor"] += len(FLOOR_SHAPE.findall(src))
                arm4["verdict_w"] += len(TERMINAL_VERDICT.findall(src))
                arm4["closed_w"] += len(TERMINAL_CLOSED.findall(src))
                arm4["stakable"] += len(STAKABLE_CALL.findall(src))
                # Arm 7, per file: count user-sourced outflows and require a gate
                # within the three lines above each.
                lines = src.splitlines()
                for i, line in enumerate(lines):
                    if not COIN_OUT.match(line) or ESCROW_SRC.search(line):
                        continue
                    arm4["coin_out"] += 1
                    if not any(GATE.search(l) for l in lines[max(0, i - 3):i]):
                        hits.append(f"[ungated-outflow] {pkg}/{p.name}:{i+1} moves "
                                    f"a holder's coin with no mustSpendable within "
                                    f"three lines above it — the vote lock and the "
                                    f"stake lock both live in that call, so this "
                                    f"path bypasses both and nothing else notices")

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

    # Arm 4, after the whole kourtv2 tree has been read.
    for key, want, what in (
        ("weight_fn", 1, "votingWeight definition(s)"),
        ("cap_fn", 1, "voteCap definition(s)"),
        ("floor", 1, "min(snapshot, held) floor expression(s)"),
        ("verdict_w", TERMINAL_VERDICT_N, "cs.verdictAt writer(s)"),
        ("closed_w", TERMINAL_CLOSED_N, "cs.closed writer(s)"),
        ("stakable", STAKABLE_CALLS_N, "mustStakable caller(s)"),
        ("coin_out", COIN_OUT_N, "user-sourced coin movement(s)"),
    ):
        if arm4[key] != want:
            tag = ("terminal" if key.endswith("_w")
                   else "lock-exempt" if key == "stakable"
                   else "ungated-outflow" if key == "coin_out" else "one-weight")
            why = ("a new path moving a holder's coin has to be paired with a "
                   "gate deliberately; mustSpendable is where both locks live"
                   if key == "coin_out" else
                   "Stake is the ONE deliberate exemption from the vote lock; a "
                   "second mustStakable caller is a second path disposing of "
                   "committed coin, and it would look entirely reasonable"
                   if key == "stakable" else
                   "the quality vote lock releases on `verdictAt != 0 || closed`, "
                   "so a new way for a claim to END leaves those votes locked "
                   "forever and silently — read votelock.gno's voteLockQuality arm"
                   if key.endswith("_w") else
                   "vote weight is charged by three lanes and QUOTED to the "
                   "elector, so a second copy is a quote that can drift from the "
                   "charge")
            hits.append(f"[{tag}] kourtv2 has {arm4[key]} {what}, expected "
                        f"{want} — {why}")
    if hits:
        print("check-epoch-coherence: a tally and its bar may no longer share an "
              "epoch.\n", file=sys.stderr)
        for h in hits:
            print(f"  {h}", file=sys.stderr)
        return 1

    if sealed_funcs < MIN_SEALED_FUNCS:
        print(f"check-epoch-coherence: only {sealed_funcs} functions read a sealed "
              f"epoch, expected at least {MIN_SEALED_FUNCS}. Either the surface "
              f"moved or the regex stopped matching — this check is measuring "
              f"nothing.", file=sys.stderr)
        return 1

    print(f"check-epoch-coherence: {scanned} files, {sealed_funcs} sealed-epoch "
          f"function(s) each reading one epoch, no live weight in any tally, one "
          f"weight source in the engine, one vote-weight expression, "
          f"{arm4['verdict_w'] + arm4['closed_w']} claim-terminal writer(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
