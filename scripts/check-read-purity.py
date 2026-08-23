#!/usr/bin/env python3
"""An exported read must never allocate and persist state as a side effect of
being asked a question.

`mustModRead` exists precisely to state this rule: it is the READ-ONLY
counterpart of `ensureMod`, so a query that needs a court's moderation state
panics when there is none instead of creating one. Three helpers in kourtv2
allocate and persist: `ensureMod`, `ensureGlobalDAO` and `ensureClaimMod`. None
of them belongs on a read path.

WHY IT MATTERS, in the order the harm arrives:

  1. THE SAME QUESTION ANSWERS TWO WAYS. This already happened once, and the
     fix is recorded at `FolderPurged` in folders.gno: it used to return false
     for a nonexistent folder, so the answer depended on whether the court
     happened to hold any moderation state at all. A read that allocates has the
     same shape — the first caller changes what the second caller sees.
  2. UNPAID STATE GROWTH. A query is not a transaction and carries no storage
     deposit, so a read that persists a struct lets anyone grow the realm for
     free. Every other flood surface in this design is priced; this one would
     not be.
  3. A QUERY THAT WRITES IS NOT A QUERY. Reads are reached without a crossing
     call and must be safe to serve from any node at any height.

WHY A SCRIPT AND NOT A TEST. The rule is a property of every read that exists,
including the next one somebody adds — 100 of them at the time of writing, and a
test can only ever assert it about the reads it names. The failure mode is drift:
a new read reaches for `ensureMod` because that is the helper the writes use, and
nothing in the suite notices, because allocating makes the read SUCCEED where it
should have panicked. Nothing goes red. A structural check is the only thing that
sees the whole surface.

A read is identified as an exported TOP-LEVEL function with no `cur realm`
parameter. Both halves of that matter. A crossing function takes `cur realm` and
is a write, so the parameter is the discriminator the language gives us; and a
query reaches exported top-level functions only, never a method on an internal
type. Methods are excluded deliberately, not incidentally: `dispute.gno` carries
`Check`, `Describe`, `Do` and `Name` on an internal action type implementing the
governor interface, and `Do` EXECUTES the action. It takes no `cur realm` because
the governor calls it, not a user — so counting methods would put a write on the
read list and make this check fire on correct code.

If this script ever fires, either use the `must*` read counterpart on that path
or — if the new read genuinely must allocate — say why, here, in this file.
"""

import re
import sys

from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import repolock

ROOT = Path(__file__).resolve().parent.parent
REALM = ROOT / "realm" / "r" / "kourtv2"

# Helpers that allocate a struct AND persist it into realm state.
# getPos joins them for the same reason and was found missing by review: it Sets a
# *stakePos on access (stake.gno), so an exported read reaching it persists a struct.
# Measured before adding it — an exported read calling getPos passed this guard green.
# requireEdgeRemover is not an ensureX and allocates nothing itself; it is here
# because it CALLS ensureMod, so a read reaching it would allocate while naming
# none of the words above. The scan is textual, so an allocator behind one hop
# has to be named or the hop is a hole. It was added the moment that hop was.
ALLOCATORS = ("ensureMod", "ensureGlobalDAO", "ensureClaimMod", "getPos", "ensureArgs",
              "ensureSup", "requireEdgeRemover")

# An exported TOP-LEVEL declaration: `func Name(`. A receiver is not matched on
# purpose — see the module docstring on dispute.gno's Do.
EXPORTED = re.compile(r"^func ([A-Z]\w*)\(([^)]*)\)")
CROSSING = re.compile(r"\bcur\s+realm\b")

# AND AN EXPORTED READ MUST NOT HAND OUT A POINTER, which is the second half of
# the same rule and was enforced by nothing. Three places in kourtv2 cite "borrow
# rule #2" for it — court.gno on /p/ pointers, strips.gno on realm state, and
# folders.gno most explicitly, at FolderItems: "returns a copy of a folder's
# claim-ID list (a value slice — never a pointer into realm state, borrow rule
# #2)". Nothing checked that the next read keeps the promise.
#
# The harm is not a wrong answer. A pointer handed across the realm boundary is
# mutable by whoever holds it, and a write through it commits under THIS realm's
# authority, so a reader becomes a writer without a crossing call and without a
# storage deposit. That is a different and worse failure than the allocation one
# above, which only grows state.
#
# NO POINTER AT ALL is deliberately stricter than "no pointer into realm state".
# Distinguishing a freshly-allocated return from an escaping one is not something
# a static reader can do honestly, and the strict form is the property that
# actually holds: measured, ZERO of the exported reads return a pointer, while
# nine UNEXPORTED helpers do (mustClaim, mustFolder, getPos and the like) and are
# untouched by this because they never cross the boundary. A read that genuinely
# needs to return a fresh pointer goes in the allowlist with its reason, which is
# the census pattern the other guards here use.
POINTER_RETURN_OK = {}

# AND THE OTHER HALF OF POINTER DISCIPLINE: a p/ type held in realm state BY
# POINTER, which is the shape the arm above stops from ever being handed out.
#
# twap.gno states it as a property of the whole realm: the Ring "is never a heap
# object of its own, and never held by pointer in realm state: every method takes a
# Ring by value", and gives the reason — a Ring inline in a claim "costs nothing
# extra to keep, whereas a *Ring would be a second object". Nothing enforced it.
# Two consequences, not one: a second allocation per field, and borrow rule #2 if
# such a pointer ever escaped through a read, because a pointer across the realm
# boundary is mutable by its holder and the write commits under this realm's
# authority.
#
# NARROW ON PURPOSE, AND THE MEASUREMENT IS WHY. The obvious guard — "no pointer to
# a p/ type in realm state" — would be simply wrong here: kourtv2 holds 33 such
# fields and nearly all are *bptree.BPTree, which is what a tree IS, plus
# *grc20votes.Ledger, *governor.Governor and *checkpoint.Archive. Writing that
# census would have meant a 33-entry allowlist and no property. So this pins the one
# type whose own package states the claim, and nothing more.
#
# ANCHORING IS SAFE HERE, unlike the call censuses in check-epoch-coherence that
# were unanchored for missing `if pv := cs.stakers.Remove(...)`. A Go struct field
# declaration is always the start of its line; there is no mid-line form to miss.
# Do not "fix" this into a `.*` shape.
#
# THE COUNT IS 2, NOT 4, and how I got that wrong is worth the two lines. A first
# pass over every realm printed four Ring fields as `claim.gno:34, :35, :81, :82`
# and I read them as one file — but two of them are in kourtv1/claim.gno and two in
# kourtv2/claim.gno. The output was BASENAMES, so the directory that distinguished
# them was the column not printed. Same shape as `grep -h` defeating a path filter:
# confirm the instrument before believing its report. kourtv1 is behaviourally
# frozen and this guard is kourtv2-scoped by design, so its two are out of scope
# here rather than uncounted.
RING_PTR = re.compile(r"^\s*\w+\s+\*twap\.Ring\b", re.M)
RING_VAL = re.compile(r"^\s*\w+\s+twap\.Ring\b", re.M)
RING_VAL_N = 2  # kourtv2/claim.gno: oi and yes, both on the pool


def functions(src):
    """Split a .gno source into (decl, name, body) triples on top-level funcs."""
    out, decl, name, buf = [], None, None, []
    for line in src.split("\n"):
        if line.startswith("func "):
            if name is not None:
                out.append((decl, name, "\n".join(buf)))
            m = EXPORTED.match(line)
            decl, name = line, (m.group(1) if m else None)
            buf = [line]
        elif name is not None or decl is not None:
            buf.append(line)
    if decl is not None:
        out.append((decl, name, "\n".join(buf)))
    return out


def main() -> int:
    repolock.refuse_if_held("check-read-purity")
    files = [p for p in sorted(REALM.glob("*.gno")) if not p.name.endswith("_test.gno")]
    if not files:
        # A silent zero here would make this check report success forever.
        print(f"check-read-purity: no .gno files under {REALM}; the layout moved "
              f"and this check is measuring nothing.", file=sys.stderr)
        return 1

    # The allocators must still exist under these names, or the scan is looking
    # for something the code no longer calls and can never fire again.
    corpus = "\n".join(p.read_text() for p in files)
    missing = [a for a in ALLOCATORS if f"func {a}(" not in corpus]
    if missing:
        print(f"check-read-purity: {', '.join(missing)} no longer exist(s) under "
              f"that name, so this check is scanning for a call that cannot "
              f"appear. Re-point ALLOCATORS at the helpers that allocate now.",
              file=sys.stderr)
        return 1

    # The Ring census, per file so a violation can be named by line.
    ring_ptr, ring_val = [], 0
    for p in files:
        for i, line in enumerate(p.read_text().split("\n"), 1):
            if RING_PTR.match(line):
                ring_ptr.append((p.name, i, line.strip()))
            elif RING_VAL.match(line):
                ring_val += 1

    if ring_ptr:
        print("check-read-purity: a twap.Ring is held in realm state BY POINTER.\n",
              file=sys.stderr)
        for fn, ln, text in ring_ptr:
            print(f"  {fn}:{ln}  {text}", file=sys.stderr)
        print("\ntwap.gno states the opposite as a property of the whole realm — the "
              "Ring \"is never a heap object of its own, and never held by pointer in "
              "realm state: every method takes a Ring by value\" — and gives the "
              "reason: inline it costs nothing extra to keep, where a *Ring is a "
              "second object per field. It is also borrow rule #2 waiting to happen, "
              "because a pointer that ever escaped through a read would let its holder "
              "write under this realm's authority. Hold it by value.", file=sys.stderr)
        return 1

    if ring_val != RING_VAL_N:
        print(f"check-read-purity: {ring_val} twap.Ring field(s) held by value, "
              f"expected {RING_VAL_N}. Either a Ring was added or removed — update "
              f"RING_VAL_N and say which — or the field pattern has drifted off the "
              f"code, in which case the pointer arm above is measuring nothing and "
              f"would stay silent on a real violation.", file=sys.stderr)
        return 1

    reads, bad, ptr = 0, [], []
    for p in files:
        for decl, name, body in functions(p.read_text()):
            m = EXPORTED.match(decl)
            if not m or CROSSING.search(m.group(2)):
                continue
            reads += 1
            hit = sorted({a for a in ALLOCATORS if f"{a}(" in body})
            if hit:
                bad.append((p.name, name, hit))
            # The return type only: EXPORTED consumes the parameter list, so a
            # pointer PARAMETER cannot be mistaken for a pointer return.
            ret = decl[m.end():].strip().rstrip("{").strip()
            if "*" in ret and name not in POINTER_RETURN_OK:
                ptr.append((p.name, name, ret))

    if not reads:
        # Every exported read vanished, which means the pattern stopped matching
        # the code rather than that the code stopped needing the rule.
        print(f"check-read-purity: found no exported reads at all, which cannot "
              f"be right — the pattern has drifted from the code.", file=sys.stderr)
        return 1

    if ptr:
        print("check-read-purity: an exported read hands out a POINTER.\n",
              file=sys.stderr)
        for fn, name, ret in ptr:
            print(f"  {fn}:{name} returns {ret}", file=sys.stderr)
        print("\nA pointer that crosses the realm boundary is mutable by whoever "
              "holds it, and a write through it commits under THIS realm's authority "
              "— a reader becomes a writer with no crossing call and no storage "
              "deposit (borrow rule #2, cited at FolderItems in folders.gno). Return "
              "a value or a copy. If the pointer is genuinely freshly allocated and "
              "cannot alias realm state, add the read to POINTER_RETURN_OK with that "
              "reason.", file=sys.stderr)
        return 1

    if bad:
        print("check-read-purity: an exported read allocates and persists state.\n",
              file=sys.stderr)
        for f, name, hit in bad:
            print(f"  {f}:{name} calls {', '.join(hit)}", file=sys.stderr)
        print(f"\nA query carries no storage deposit and must be safe to serve at "
              f"any height, and a read that allocates makes the first caller "
              f"change what the second one sees — the bug already fixed once at "
              f"FolderPurged. Use the must* read counterpart (mustModRead, "
              f"mustCourt, mustClaim), or record in this script why this read "
              f"must allocate.", file=sys.stderr)
        return 1

    print(f"check-read-purity: {reads} exported read(s), none hands out a pointer, "
          f"none allocates "
          f"({', '.join(ALLOCATORS)} all confined to write paths); "
          f"{ring_val} twap.Ring field(s), every one held by value.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
