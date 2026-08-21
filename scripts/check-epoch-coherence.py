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
CCWRAP = ROOT / "realm" / "r" / "ccwrap"

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
# ANY Court receiver, not just `c`. Five names are already used with .coin. in this
# tree — c (507 uses), mc (16), c2 (5), m (2), c3 (1) — because the meta court and the
# multi-court paths hold their own Court values. None of them moves coin TODAY, so the
# pinned count is unchanged; but `mc.coin.Transfer(who, ...)` was invisible to a
# pattern that hardcoded `c.`, and mc is not hypothetical, it is sixteen lines away
# doing Mint. Same class of blind spot as leaving Burn out: the regex assumed a
# spelling the file already contradicts elsewhere.
# ARM 8 — a vote-lock row can only ever be created by its own owner.
#
# The whole cost argument for the lock rests on this. voteLockedOf walks one address's
# rows on every mustSpendable path, at a measured 110,245 gas per dead row, so an
# address's row count is a tax on its own transfers. That is acceptable only because
# the rows are SELF-INFLICTED: all three lockVote sites pass cur.Previous().Address(),
# so nobody can grow another holder's row count. A single `lockVote(c, victim, ...)`
# would convert a self-imposed cost into a griefing weapon, and it would read as
# perfectly ordinary code — locking someone's vote is what this function is for.
#
# Three pins, because the address can go wrong in three places. The ARGUMENT must be
# `who`; every BINDING of `who` in a file that locks must come from
# cur.Previous().Address(); and any helper taking `who address` (approve does) must be
# called with cur.Previous().Address() — or with `who` itself, which is the same
# address one frame down and is how votelock.gno's own helpers legitimately pass it
# along — at every site, since the parameter is where a caller-supplied address would
# enter. Passing `who` is safe by induction: the binding pin above forces every `who`
# in a locking file to come from the caller in the first place. The COUNT is pinned too: a fourth lane that
# locks votes has to be argued, exactly as arm 6 pins mustStakable.
LOCKVOTE_CALL = re.compile(r"lockVote\(c, ([A-Za-z_][A-Za-z0-9_.]*),")
WHO_BIND = re.compile(r"^\s*who\s*:?=\s*(.+?)\s*$", re.M)
WHO_PARAM_FN = re.compile(r"^func ([a-zA-Z_][A-Za-z0-9_]*)\(who address", re.M)
CALLER_DERIVED = "cur.Previous().Address()"
LOCKVOTE_CALLS_N = 3  # dispute.gno, modvote.gno, quality.gno — one per lane

# ARM 9 — no comment may present SpendableOf as what a holder can MOVE.
#
# SpendableOf is stake-only and its name predates the vote lock, so it reads like the
# answer to "how much can I spend" and is not. That trap has now been walked into three
# times: once in its own doc, once in AllowanceCC ("the amount actually movable is
# min(AllowanceCC, SpendableOf)" — over-promises by a whole vote commitment), and once
# in ccwrap's WrapRoom ("SpendableOf minus their own vote commitment" — which
# double-counts the overlap and understates the room, since the locks combine with MAX
# not SUM because staked coin still votes). Two errors in OPPOSITE directions from one
# missing instrument, which is what DisposableOf now is.
#
# The pattern is deliberately narrow: SpendableOf on a comment line that also carries a
# formula shape — `min(` or ` minus `. Both real instances match; the passages that
# correctly explain SpendableOf ("what an address may still STAKE", "quoting only
# SpendableOf over-promises") carry no formula and must not be flagged. Prose about the
# figure is fine. Arithmetic with it is what goes wrong.
DOC_MOVABLE = re.compile(r"^\s*//.*\bSpendableOf\b.*(?:min\(| minus )|"
                         r"^\s*//.*(?:min\(| minus ).*\bSpendableOf\b")

# ARM 10 — "a quality question is open" has exactly ONE definition.
#
# The disjunction cs.flagOpen || cs.disputeOpen || cs.counterOpen was written three
# times: the vote lock's release predicate and both weight readers. That is arm 4's
# hazard one level down — a quote that can drift from the charge — and the drift is not
# symmetric. A fourth way to open a quality question that reached the readers but not the
# lock UNDER-locks, freeing coin whose vote can still be counted; one that reached the
# lock but not the readers quotes zero to a holder who can vote right now. Neither copy
# is the safe one to forget, so there is one, qualityQuestionOpen, and this counts it.
#
# TWO lines legitimately hold such a disjunction, and the second is why this arm pins a
# SHAPE rather than a filename. crystallize.gno asks its own question —
# `cs.flagOpen || cs.counterOpen || cs.pendingSlash > 0` — which deliberately excludes
# disputeOpen and adds a pending slash. It is not a copy of ours and must not be
# "simplified" into one. So: exactly two such lines, the definition carries all three
# flags, and the other carries pendingSlash, which is what makes it a different question
# rather than a partial copy of this one. A third line fails closed.
QOPEN_FLAGS = ("cs.flagOpen", "cs.disputeOpen", "cs.counterOpen")
QOPEN_LINES_N = 2

# ARM 11 — the release rule says the same thing in the code and in the handoff spec.
#
# This one polices PROSE, and it earned its place the hard way: the quality release rule
# has gone stale in three documents. All three said a quality vote releases "when its
# tally is superseded", which was the FIRST version of the predicate and was wrong,
# because a tally is superseded only by a new round and nothing makes a round open. The
# worst instance was in VOTEFLOOR.md's web-client section — text written so another
# session could implement the surface "without re-deriving any of it", which would have
# become a UI telling holders the wrong thing about their own coin.
#
# So one clause is canonical and lives in both places: votelock.gno's summary of the
# predicate, and the spec's quote of it. Neither can be edited alone. This does not pin
# the CODE — arms 8 and 10 and the corpus do that — it pins that the sentence humans
# read has not drifted from the sentence the author of the predicate wrote.
#
# Whitespace-normalised, because the code carries it as an aligned comment and the
# document as prose, and an alignment change is not news.
RULE_CLAUSE = "some question is open now OR these weights carry forward"
# EXACT counts, per file. Presence alone was tried first and is too coarse: VOTEFLOOR.md
# states the rule twice — once as the quote implementers work from, once in the record of
# the correction — so a presence check passes when the SPEC's copy is rewritten and the
# historical one is left, which is precisely the failure being guarded. Counted both
# directions on the house rule: too few is the drift, too many is a fresh restatement of
# a rule that has already gone stale three times and should be read before it is added.
RULE_SITES = (("realm/r/kourtv2/votelock.gno", 1), ("VOTEFLOOR.md", 2))

# THE OTHER ARMS WERE AUDITED FOR THE SAME BLIND SPOT AND ARE CLEAN. Three arms have
# now been widened because a regex hardcoded a spelling the tree already used
# elsewhere (arm 7 missed Burn, arm 5 missed tuple assignment, arm 7 missed a non-`c`
# receiver). The obvious next move is to widen everything for symmetry, and that is
# wrong: a pattern loosened for a spelling that does not exist buys nothing and costs
# precision. So the remaining hardcoded spellings were checked against the tree, not
# against imagination:
#
#   arm 3   `^func \(g \*Governor\)`     60 of 60 Governor methods use `g`.
#   arm 6   `mustStakable\(c, `           only `c` is ever passed to either helper.
#   arm 5   `^\s*cs\.`                    `acs` and `dcs` exist but ONLY in _test
#                                          files, which this guard does not scan.
#   arm 4   the floor's `if held := ...`  one form, one site; a second floor written
#                                          differently would still trip arm 1's
#                                          per-file BalanceOf census, which is why
#                                          the two arms are documented as a pair.
#
# Re-run those greps before widening any of them. And run them WITHOUT `-h`: piping
# `grep -rhoE ... | grep -v _test` silently filters nothing, because -h has already
# removed the filenames. That mistake made `acs`/`dcs` look like production code and
# very nearly bought a pointless widening of arm 5.
RECV = r"[a-z][A-Za-z0-9]*"
COIN_OUT = re.compile(r"^\s*" + RECV + r"\.coin\.(?:Transfer|TransferFrom|Burn)\(", re.M)
# The escrow exemption has to generalise with it, or mc.coin.Burn(mc.escrow, ...)
# would start counting as a holder outflow.
ESCROW_SRC = re.compile(RECV + r"\.coin\.(?:Transfer|Burn)\(" + RECV + r"\.escrow")
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

    # Arm 9, its own pass over both realms that expose the figure. Deliberately not
    # folded into the loop below: that loop's file census feeds arms 1 and 2, and
    # adding a directory to it would move counts those arms pin.
    doc_scanned, per_dir = 0, {}
    for d in (KOURTV2, CCWRAP):
        per_dir[d.name] = 0
        for q in sorted(d.glob("*.gno")):
            if q.name.endswith("_test.gno"):
                continue
            doc_scanned += 1
            per_dir[d.name] += 1
            for i, line in enumerate(q.read_text().splitlines()):
                if DOC_MOVABLE.search(line):
                    hits.append(f"[spendable-as-movable] {d.name}/{q.name}:{i+1} does "
                                f"arithmetic with SpendableOf, which is stake-only: "
                                f"what a holder may bond, deposit, transfer or wrap is "
                                f"DisposableOf. Quoting SpendableOf over-promises by a "
                                f"vote commitment; subtracting VoteLockedOf from it "
                                f"understates the room, because the locks combine with "
                                f"MAX not SUM")
    # Arm 11: the canonical release clause, in the code and in the spec that hands
    # the surface to somebody else.
    rule_counts = {}
    for rel, want in RULE_SITES:
        f = ROOT / rel
        if not f.exists():
            hits.append(f"[rule-drift] {rel} is gone, so arm 11 is watching nothing")
            continue
        rule_counts[rel] = n = " ".join(f.read_text().split()).count(RULE_CLAUSE)
        if n != want:
            how = ("has been rewritten somewhere — the rule has gone stale in three "
                   "documents already, always as \"when its tally is superseded\", "
                   "the first version of the predicate and one a probe refuted"
                   if n < want else
                   "is stated somewhere new; a fresh restatement of this rule is "
                   "worth reading before it is added, and the count here is where "
                   "you say you did")
            hits.append(f"[rule-drift] {rel} states the quality release clause "
                        f"{n} time(s), expected {want}: it {how}. Code and spec "
                        f"move together or not at all")

    # Arm 10, over kourtv2 only: the liveness disjunction has one definition.
    qopen = []
    for q in sorted(KOURTV2.glob("*.gno")):
        if q.name.endswith("_test.gno"):
            continue
        for i, line in enumerate(q.read_text().splitlines()):
            if line.lstrip().startswith("//"):
                continue
            n = sum(f in line for f in QOPEN_FLAGS)
            if n >= 2 and "||" in line:
                qopen.append((q.name, i + 1, line.strip(), n))
    if len(qopen) != QOPEN_LINES_N:
        hits.append(f"[qopen-copy] {len(qopen)} line(s) disjoin two or more of the "
                    f"quality-question flags, expected {QOPEN_LINES_N}: "
                    f"{', '.join(f'{f}:{ln}' for f, ln, _, _ in qopen)}. "
                    f"`a quality question is open` has ONE definition, "
                    f"qualityQuestionOpen, because a copy that reaches the weight "
                    f"readers but not the vote lock frees coin whose vote can still "
                    f"be counted")
    else:
        defs = [r for r in qopen if r[3] == 3]
        other = [r for r in qopen if r[3] != 3]
        if len(defs) != 1:
            hits.append(f"[qopen-copy] {len(defs)} line(s) carry all three "
                        f"quality-question flags, expected exactly 1 (the "
                        f"qualityQuestionOpen definition)")
        elif "pendingSlash" not in other[0][2]:
            hits.append(f"[qopen-copy] {other[0][0]}:{other[0][1]} disjoins the "
                        f"quality-question flags without pendingSlash, so it is a "
                        f"partial COPY of qualityQuestionOpen rather than "
                        f"crystallize's own question: {other[0][2][:70]}")

    # PER DIRECTORY, not a total. A total of 20+ is satisfied by kourtv2 alone, so
    # ccwrap could move away and this arm would quietly stop watching the realm where
    # one of the two real instances lived — measured: the control for a moved ccwrap
    # was SILENT against the total-only form.
    for name, n in sorted(per_dir.items()):
        if n < 1:
            print(f"check-epoch-coherence: arm 9 found no non-test .gno under "
                  f"{name}; that tree moved and this arm is measuring nothing "
                  f"there.", file=sys.stderr)
            return 1
    if per_dir.get("kourtv2", 0) < 20:
        print(f"check-epoch-coherence: arm 9 scanned only "
              f"{per_dir.get('kourtv2', 0)} kourtv2 files; the layout moved and "
              f"this arm is measuring nothing.", file=sys.stderr)
        return 1
    arm4 = {"weight_fn": 0, "cap_fn": 0, "floor": 0,
            "verdict_w": 0, "closed_w": 0, "stakable": 0, "coin_out": 0,
            "lockvote": 0}

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

                # Arm 8, per file: a lock row belongs to its own owner.
                calls = LOCKVOTE_CALL.findall(src)
                arm4["lockvote"] += len(calls)
                for arg in calls:
                    if arg != "who":
                        hits.append(f"[foreign-lock] {pkg}/{p.name} locks votes "
                                    f"for `{arg}` rather than `who` — a lock row "
                                    f"taxes its owner's every transfer, so a row "
                                    f"created for an address other than the caller "
                                    f"is a griefing weapon")
                if "lockVote(" in src:
                    for m in WHO_BIND.finditer(src):
                        if m.group(1) != CALLER_DERIVED:
                            hits.append(f"[foreign-lock] {pkg}/{p.name} binds `who` "
                                        f"to `{m.group(1)}` in a file that locks "
                                        f"votes; it must come from "
                                        f"{CALLER_DERIVED} or the lock can be "
                                        f"pointed at a third party")
                    helpers = WHO_PARAM_FN.findall(src)
                    for i, line in enumerate(lines):
                        if line.startswith("func "):
                            continue
                        for fn in helpers:
                            m = re.search(rf"\b{fn}\((.*?),", line)
                            if m and m.group(1).strip() not in (CALLER_DERIVED,
                                                                 "who"):
                                hits.append(f"[foreign-lock] {pkg}/{p.name}:{i+1} "
                                            f"calls {fn}() with "
                                            f"`{m.group(1).strip()}` as the holder; "
                                            f"a helper that reaches lockVote must be "
                                            f"passed {CALLER_DERIVED}")

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
        ("lockvote", LOCKVOTE_CALLS_N, "vote-lock site(s)"),
    ):
        if arm4[key] != want:
            tag = ("terminal" if key.endswith("_w")
                   else "lock-exempt" if key == "stakable"
                   else "ungated-outflow" if key == "coin_out"
                   else "foreign-lock" if key == "lockvote" else "one-weight")
            why = ("a fourth lane locking votes has to be argued: every lock "
                   "row taxes its owner's own transfers, so the address it is "
                   "created for must be the caller and nothing else"
                   if key == "lockvote" else
                   "a new path moving a holder's coin has to be paired with a "
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
          f"{arm4['verdict_w'] + arm4['closed_w']} claim-terminal writer(s), "
          f"{arm4['lockvote']} self-only vote-lock site(s), "
          f"one quality-question definition, release clause in "
          f"{'+'.join(f'{k.split(chr(47))[-1]} {v}' for k, v in rule_counts.items())}, "
          f"{doc_scanned} file(s) clear of SpendableOf arithmetic "
          f"({', '.join(f'{k} {v}' for k, v in sorted(per_dir.items()))}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
