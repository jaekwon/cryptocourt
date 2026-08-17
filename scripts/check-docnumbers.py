#!/usr/bin/env python3
"""Hold doc.gno's numbers to the ones the code actually uses.

The terms every early decision clears are written twice: once as Go in
governor.gno's init, and once as a table in doc.gno for the person deciding
whether to launch on them. That is a duplicated RULE, which VERIFYING.md says
to collapse — and this one cannot be collapsed, because a realm cannot read its
own source and a doc comment cannot call a function. So it is pinned instead.

It matters more than most of the duplications in this realm. The table is what
somebody reads before launching, the numbers decide whether their first
adoption can pass at all, and a stale table is invisible: the realm keeps
working, the tests keep passing, and the only symptom is a launch that fails on
a quorum nobody was told about.

The code side is arithmetic rather than literals — `7 * 24 * 60 * 60 / 5` for a
week of blocks — which is deliberate, and is exactly why the doc repeats the
product. Both sides are evaluated here rather than compared as text.

    python3 scripts/check-docnumbers.py

Needs no toolchain; it reads the two files.
"""

import ast
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import repolock

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# doc.gno is the realm's; the numbers it quotes are the engine's. Two trees
# now, which is the whole reason this guard exists: the table and the code it
# describes no longer live in the same package, so nothing but this holds them
# together.
GOVERN = os.path.join(REPO, "realm/r/govern")
ENGINE = os.path.join(REPO, "realm/p/governor")

# doc-table name -> the field init sets. propose is absent from the literal on
# purpose, so its expected value is the Go zero.
FIELDS = {
    "quorum": "QuorumBps",
    "threshold": "ThresholdBps",
    "voting": "VotingBlocks",
    "delay": "DelayBlocks",
    "grace": "GraceBlocks",
    "propose": "ProposeBps",
}


def arithmetic(expr):
    """Evaluate a Go integer expression like `7 * 24 * 60 * 60 / 5`.

    ast.literal_eval will not do it — it refuses operators — so the tree is
    walked and anything that is not integer arithmetic is refused rather than
    executed. A checker that eval()s a source file is a checker that runs
    whatever somebody put there.
    """
    node = ast.parse(expr.strip(), mode="eval").body

    def go(n):
        if isinstance(n, ast.Constant) and isinstance(n.value, int):
            return n.value
        if isinstance(n, ast.BinOp) and isinstance(n.op, (ast.Add, ast.Sub, ast.Mult, ast.Div)):
            a, b = go(n.left), go(n.right)
            if isinstance(n.op, ast.Add):
                return a + b
            if isinstance(n.op, ast.Sub):
                return a - b
            if isinstance(n.op, ast.Mult):
                return a * b
            return a // b  # Go integer division
        raise ValueError(f"not integer arithmetic: {expr!r}")

    return go(node)


# The other numbers doc.gno states twice: the bounds on a proposal's three
# strings, in the same table shape as the terms. Named constants rather than a
# struct literal, so they are read differently and compared the same way.
BOUNDS = {
    "title": ("governor.gno", "maxTitle"),
    "payload": ("governor.gno", "maxPayload"),
    "kind": ("governor.gno", "maxKindName"),
}


def const_values():
    out = {}
    for name, (fname, const) in BOUNDS.items():
        src = open(os.path.join(ENGINE, fname)).read()
        m = re.search(rf"^const {const} = (?:int64\()?([^\n)]+)\)?$", src, flags=re.M)
        if not m:
            raise SystemExit(f"check-docnumbers: no `const {const}` in {fname}")
        out[name] = arithmetic(m.group(1))
    return out


def code_values():
    src = open(os.path.join(ENGINE, "governor.gno")).read()
    i = src.index("func BootstrapRules() Rules {")
    body = src[i:src.index("\n}", i)]
    out = {f: 0 for f in FIELDS.values()}
    for field in FIELDS.values():
        m = re.search(rf"\b{field}:\s*([^,\n]+),", body)
        if m:
            out[field] = arithmetic(m.group(1))
    return out


def doc_values():
    """Every `//\tname   N` row in doc.gno's tables, by name.

    Both tables are read at once: the bootstrap terms and the string bounds are
    written in the same shape, and scanning only the names one caller expects is
    how the bounds were silently absent from this check when it first grew to
    cover them.
    """
    src = open(os.path.join(GOVERN, "doc.gno")).read()
    out = {}
    for name in list(FIELDS) + list(BOUNDS):
        m = re.search(rf"^//\t{name}\s+(-?\d+)", src, flags=re.M)
        if m:
            out[name] = int(m.group(1))
    return out


def main():
    repolock.refuse_if_held("check-docnumbers")
    code, doc = code_values(), doc_values()
    bad = 0
    for name, want in const_values().items():
        got = doc.get(name)
        if got is None:
            print(f"MISSING doc.gno states no bound for {name!r}; the code says {want}.")
            bad += 1
        elif got != want:
            print(f"STALE   doc.gno says a {name} may be {got} bytes; the code "
                  f"allows {want}. This is the table somebody reads before "
                  f"finding out by transaction.")
            bad += 1
    for name, field in FIELDS.items():
        if name not in doc:
            print(f"MISSING doc.gno's bootstrap table has no row for {name!r}. "
                  f"init sets it to {code[field]}.")
            bad += 1
            continue
        if doc[name] != code[field]:
            print(f"STALE   doc.gno says {name} is {doc[name]}; init sets "
                  f"{field} to {code[field]}. The table is what somebody reads "
                  f"before launching on these terms.")
            bad += 1
    if bad:
        print(f"\n{bad} number(s) disagree between the code and the tables "
              f"documenting it.", file=sys.stderr)
        return 1
    print(f"check-docnumbers: {len(FIELDS)} bootstrap terms and "
          f"{len(BOUNDS)} string bounds match the code.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
