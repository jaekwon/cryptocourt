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
ALLOCATORS = ("ensureMod", "ensureGlobalDAO", "ensureClaimMod", "getPos", "ensureArgs")

# An exported TOP-LEVEL declaration: `func Name(`. A receiver is not matched on
# purpose — see the module docstring on dispute.gno's Do.
EXPORTED = re.compile(r"^func ([A-Z]\w*)\(([^)]*)\)")
CROSSING = re.compile(r"\bcur\s+realm\b")


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

    reads, bad = 0, []
    for p in files:
        for decl, name, body in functions(p.read_text()):
            m = EXPORTED.match(decl)
            if not m or CROSSING.search(m.group(2)):
                continue
            reads += 1
            hit = sorted({a for a in ALLOCATORS if f"{a}(" in body})
            if hit:
                bad.append((p.name, name, hit))

    if not reads:
        # Every exported read vanished, which means the pattern stopped matching
        # the code rather than that the code stopped needing the rule.
        print(f"check-read-purity: found no exported reads at all, which cannot "
              f"be right — the pattern has drifted from the code.", file=sys.stderr)
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

    print(f"check-read-purity: {reads} exported read(s), none allocates "
          f"({', '.join(ALLOCATORS)} all confined to write paths).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
