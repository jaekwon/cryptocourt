#!/usr/bin/env python3
"""Every realm constant the overlay RESTATES must still equal the realm's.

SCOPE, STATED NARROWLY because a guard that leaves it vague costs a bug (see
check-web-css, which learned that). This reads named `const NAME = <int>;`
declarations in web/index.html's script and compares each against ONE named
constant in the realm source. It says nothing about demo data — the demo
dataset is check-demo-physics' job — and nothing about any other duplication.

WHY IT IS A GUARD AND NOT A CONVENTION. `const WEEK = 120960` is not a display
figure. The overlay passes it INTO realm reads:

    tup(`TrailingOI(${s},${cl.id},${WEEK})`)
    tup(`TrailingYes(${s2},${cl.id},${WEEK})`)

so if periodBlocks moved, the page would keep working and keep looking right
while querying a trailing window that no longer matched the emission period —
the numbers would be over the wrong span, with nothing to notice. That is the
same shape as check-docnumbers' stale bootstrap table: "the realm keeps
working, the tests keep passing, and the only symptom is" a reader trusting a
number nobody checked.

VERIFYING.md would rather this were collapsed to one definition than pinned. It
cannot be: the overlay is a static file that cannot read gno source, and the
realm cannot read its own. Collapsing it would mean an exported read and an RPC
per page to fetch a constant that changes approximately never. So it is pinned,
which is the same trade check-docnumbers made for the same reason.
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB = os.path.join(REPO, "web", "index.html")

# web symbol -> (realm file, the constant's name there)
MIRRORS = {
    "WEEK": ("realm/r/kourtv2/court.gno", "periodBlocks"),
}


def realm_value(relpath, name):
    """The int a `name = int64(N)` or `name = N` declaration holds, or None."""
    src = open(os.path.join(REPO, relpath), encoding="utf-8").read()
    m = re.search(r"\b%s\s*=\s*(?:int64\()?([0-9][0-9_]*)" % re.escape(name), src)
    return int(m.group(1).replace("_", "")) if m else None


def main():
    if not os.path.exists(WEB):
        print(f"check-web-constants: no overlay at {WEB}", file=sys.stderr)
        return 2
    web = open(WEB, encoding="utf-8").read()
    bad = 0
    for sym, (relpath, name) in sorted(MIRRORS.items()):
        m = re.search(r"^\s*const\s+%s\s*=\s*([0-9][0-9_]*)\s*;" % re.escape(sym),
                      web, re.M)
        if not m:
            print(f"check-web-constants: the overlay no longer declares "
                  f"`const {sym} = <int>;` — it mirrors {name} and this guard "
                  f"cannot see it any more. Restore the declaration or drop the "
                  f"mirror from MIRRORS.", file=sys.stderr)
            bad += 1
            continue
        got = int(m.group(1).replace("_", ""))
        want = realm_value(relpath, name)
        if want is None:
            print(f"check-web-constants: {relpath} no longer declares {name}, "
                  f"which the overlay mirrors as {sym}. The anchor moved: fix "
                  f"MIRRORS rather than deleting the check.", file=sys.stderr)
            bad += 1
        elif got != want:
            print(f"check-web-constants: the overlay's {sym} is {got} and "
                  f"{name} is {want}. The overlay passes {sym} into realm reads, "
                  f"so a page that disagrees queries the wrong window and still "
                  f"looks right.", file=sys.stderr)
            bad += 1
    if bad:
        return 1
    print(f"check-web-constants: {len(MIRRORS)} mirrored constant(s) match the "
          f"realm — " + ", ".join(f"{s}={realm_value(*v)}"
                                  for s, v in sorted(MIRRORS.items())) + ".")
    return 0


if __name__ == "__main__":
    sys.exit(main())
