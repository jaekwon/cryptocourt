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
    # The composer's byte counter. Same argument as WEEK's, one step worse: this
    # number is not passed into a read, it is shown to somebody who is still
    # typing. If it drifts above the realm's, they finish a comment and lose it
    # at signing; below, they are stopped from writing something that would have
    # been accepted. Either way the page is the only warning they get.
    "MAX_COMMENT_CHARS": ("realm/r/kourtv2/board.gno", "maxBoardTextLen"),
    # The participant-priority window on Crystallize. The page greys "Open the
    # rewards" for a reader it can prove is outside it, quoting the realm's own
    # refusal — so if the realm's window moved and the page's did not, the page
    # would grey a button that works, or offer one that panics in the wallet.
    # It equals periodBlocks today; that is a coincidence, not a definition.
    "FINALIZE_GRACE": ("realm/r/kourtv2/dispute.gno", "finalizeGraceBlocks"),
}

# A PHRASE THE OVERLAY MATCHES ON, and the realm string it has to be found in.
#
# noCoinHelp tells "buy some, it counts next time" apart from "buying cannot
# help this round" by testing the realm's own explanation for one clause. That
# is prose on both sides of a chain boundary, which is the most silent coupling
# in this repo: reword whyWeighed and the dialog does not break, it starts
# offering to sell coin to somebody it cannot help. So the clause is pinned.
PHRASES = {
    "you had none when this vote started": "realm/r/kourtv2/voteweight.gno",
}

# web symbol -> (the call the realm counts it with, the call the overlay does)
#
# THE UNIT, NOT ONLY THE NUMBER. maxBoardTextLen went from bytes to characters
# and stayed 2000 throughout, so a guard watching the figure alone stayed green
# while the realm and the composer meant different things by it — the composer
# would have stopped a writer at 2000 bytes for a cap the chain applies at 2000
# code points, which for any non-Latin script is roughly half.
# Plain substrings on both sides, not regexes: the overlay's expression contains
# quotes and brackets, and an escaping slip in the pattern reads as a real
# failure. It cost one run here already.
UNITS = {
    "MAX_COMMENT_CHARS": ("realm/r/kourtv2/board.gno",
                          "runeLen(text) > maxBoardTextLen",
                          "const commentChars = s => [...String(s == null ? \"\" : s)].length;"),
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
    for sym, (relpath, realm_expr, web_re) in sorted(UNITS.items()):
        src = open(os.path.join(REPO, relpath), encoding="utf-8").read()
        if realm_expr not in src:
            print(f"check-web-constants: {relpath} no longer counts {sym} with "
                  f"`{realm_expr}`. If the realm changed its UNIT, the overlay's "
                  f"counter has to change with it — the number staying the same "
                  f"is exactly why this is checked separately.", file=sys.stderr)
            bad += 1
        if web_re not in web:
            print(f"check-web-constants: the overlay no longer counts {sym} the way "
                  f"the realm does. Both must count the same thing or a writer is "
                  f"stopped short of, or past, the cap the chain applies.",
                  file=sys.stderr)
            bad += 1
    for phrase, relpath in sorted(PHRASES.items()):
        src = open(os.path.join(REPO, relpath), encoding="utf-8").read()
        in_realm = phrase in src
        in_web = phrase in web
        if not in_realm:
            print(f"check-web-constants: {relpath} no longer contains the phrase "
                  f"{phrase!r}. The overlay matches on it to tell a fixable "
                  f"refusal from one no purchase can fix; reworded on one side "
                  f"only, the dialog offers to sell coin to somebody it cannot "
                  f"help — and nothing else fails. Reword both, or drop the "
                  f"pairing from PHRASES.", file=sys.stderr)
            bad += 1
        if not in_web:
            print(f"check-web-constants: the overlay no longer matches on "
                  f"{phrase!r}, which {relpath} still produces. Half a rename is "
                  f"worse than none.", file=sys.stderr)
            bad += 1
    if bad:
        return 1
    print(f"check-web-constants: {len(PHRASES)} mirrored phrase(s) still agree "
          f"across the boundary.")
    print(f"check-web-constants: {len(MIRRORS)} mirrored constant(s) match the "
          f"realm — " + ", ".join(f"{s}={realm_value(*v)}"
                                  for s, v in sorted(MIRRORS.items())) + ".")
    return 0


if __name__ == "__main__":
    sys.exit(main())
