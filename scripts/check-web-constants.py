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
    # The participant-priority window on OpenRewards. The page greys "Open the
    # rewards" for a reader it can prove is outside it, quoting the realm's own
    # refusal — so if the realm's window moved and the page's did not, the page
    # would grey a button that works, or offer one that panics in the wallet.
    # It equals periodBlocks today; that is a coincidence, not a definition.
    "FINALIZE_GRACE": ("realm/r/kourtv2/dispute.gno", "finalizeGraceBlocks"),
    # The bonding curve's denominator, and the strongest reason this file exists.
    # curveCost() and unitsForSpend() divide by it to quote what a buyer pays
    # BEFORE they sign, so a drift here misprices money rather than mislabelling
    # a window. It was unregistered until now, and invisible to boot: MIRRORS
    # demanded a bare integer ending in `;` and this is a BigInt sharing its
    # statement with CURVE_CAP, so no entry could have worked (see main()).
    "CURVE_D": ("realm/r/kourtv2/court.gno", "curveDenom"),
    # The window an undisputed answer waits before it settles. The page works
    # BACKWARDS from the settle deadline to place "answered" on the timeline, so
    # if this moved, the page would put that event at the old height and go on
    # calling it 72 hours. Same shape as FINALIZE_GRACE, which already says so.
    "SETTLE_DELAY": ("realm/r/kourtv2/court.gno", "settleDelay"),
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
    # The platform's own line. It is the first thing on the realm's Render and
    # the first thing in the overlay's rail, and until this entry existed there
    # was nothing to notice when one of them was rewritten — which is how a
    # chain page and the site over it end up introducing the same product with
    # two different sentences.
    "Let Truth be told.": "realm/r/kourtv2/render.gno",
    # The leaderboard's caveat. TopHolders ranks coin HELD, and staked coin is in
    # the court's custody rather than the holder's balance — so a committed
    # staker can rank below somebody who never staked, and nothing in the number
    # says why. The realm carries the sentence in TopHoldersNote so every client
    # says the same thing; this is what notices when one of them is rewritten.
    "Coin staked on a claim sits in the court's custody until the claim resolves": "realm/r/kourtv2/holders.gno",
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
    # CURVE_CAP CANNOT BE A MIRRORS ENTRY, and that is the point of putting it
    # here. realm_value() reads `name = <int>`; curveCap is DERIVED:
    #
    #     curveCap = (int64(9223372036854775807) / grc20votes.Bps) / 2
    #
    # so there is no integer in court.gno to compare the overlay's literal
    # against, and an entry in MIRRORS would report "no longer declares
    # curveCap" for a constant that is declared perfectly.
    #
    # It agrees TODAY: with Bps = 10000 that expression is exactly
    # 461168601842738, which is what the overlay carries. The hazard is that the
    # value depends on Bps, which lives in a different package — change Bps to
    # 1_000_000 and the realm's cap becomes 4611686018427 while the overlay's
    # literal does not move, a factor of a hundred. Nobody editing p/grc20votes
    # would think to look in web/index.html.
    #
    # CURVE_CAP clamps unitsForSpend, so an overstated cap lets the page quote
    # units the realm will refuse to mint. Pinning the DERIVATION is the only
    # thing that notices: if either side is rewritten the guard fires and a
    # human recomputes. This is the same trade MAX_COMMENT_CHARS makes above,
    # where the number stayed 2000 while the unit went from bytes to characters.
    "CURVE_CAP": ("realm/r/kourtv2/court.gno",
                  "curveCap   = (int64(9223372036854775807) / grc20votes.Bps) / 2",
                  "const CURVE_D = 1000000000n, CURVE_CAP = 461168601842738n;"),
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
        # `n?` and `[;,]`: the overlay's curve constants are BigInt literals
        # declared two to a statement — `const CURVE_D = 1000000000n, CURVE_CAP
        # = ...;` — so a pattern demanding a bare integer terminated by `;`
        # could not see them at all, and MIRRORS silently could not hold any
        # BigInt constant. Still anchored to `^\s*const` so a comment quoting a
        # declaration is not mistaken for one.
        m = re.search(r"^\s*const\s+%s\s*=\s*([0-9][0-9_]*)n?\s*[;,]" % re.escape(sym),
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
    # THE FOLDERTREE WIRE FORMAT, both sides of it.
    #
    # FolderTree answers one string for the whole court, "id:parent:flags:bornOf"
    # per folder, comma-joined, and the overlay parses it a row at a time.
    #
    # THIS USED TO DEMAND AN EXACT COUNT — `if(bits.length !== 3) continue;` —
    # and the note here said why: a FOURTH field added realm-side makes every row
    # fail that test, the shape map comes out empty, and the map draws a court
    # with no folders. No error, no console warning, which is the worst shape a
    # failure can take because nothing suggests where to look.
    #
    # A fourth field was then added — bornOf, moved off its own per-folder read —
    # so the overlay takes a MINIMUM now and reads what it recognises. That is
    # the forward-compatible form, and it changes what has to be checked:
    #
    #   the overlay must still SKIP a short row  (a lower bound exists at all)
    #   the realm must never write FEWER fields than that bound
    #   the overlay must READ the last field the realm writes — otherwise the
    #     realm grows a field and nothing consumes it, which is the silent
    #     direction this format now permits and the exact-count check did not.
    #
    # Counted on both sides rather than pattern-matched on one.
    fpath = "realm/r/kourtv2/folders.gno"
    try:
        fol = open(fpath, encoding="utf-8").read()
    except OSError:
        print(f"check-web-constants: cannot read {fpath}", file=sys.stderr)
        bad += 1
        fol = ""
    if fol:
        m = re.search(r"func FolderTree\(courtSlug string\) string \{(.*?)\n\}", fol, re.S)
        if not m:
            print("check-web-constants: FolderTree is no longer declared the way "
                  "this guard reads it, so the wire format it pins is unchecked.",
                  file=sys.stderr)
            bad += 1
        else:
            seps = m.group(1).count('+ ":" +')
            # ANCHORED AT THE FolderTree READ. The overlay has three
            # `bits.length !== N` checks — two `!== 2` for other row formats — and
            # an unanchored search took the first one, so this guard reported the
            # realm and the overlay disagreeing when they agree. The parser that
            # matters is the one right after the read.
            at = web.find("FolderTree(${s2})")
            tail = web[at:] if at >= 0 else ""
            want = re.search(r"if\(bits\.length < (\d+)\) continue;", tail)
            if not want:
                print("check-web-constants: the overlay no longer checks "
                      "bits.length on the FolderTree rows — a malformed row would "
                      "be parsed instead of skipped.", file=sys.stderr)
                bad += 1
            else:
                floor, fields = int(want.group(1)), seps + 1
                if fields < floor:
                    print(f"check-web-constants: FolderTree writes {fields} "
                          f"colon-separated field(s) per row and the overlay skips "
                          f"anything under {floor}. EVERY row would be skipped, the "
                          f"shape map would come out empty, and the map would draw "
                          f"a court with no folders and no error.", file=sys.stderr)
                    bad += 1
                # ...and the last field the realm writes is actually read. With a
                # minimum instead of an exact count, a field added realm-side no
                # longer breaks the parse — it is silently ignored instead, which
                # is cheaper to miss and just as wrong.
                elif f"bits[{fields - 1}]" not in tail[:4000]:
                    print(f"check-web-constants: FolderTree writes {fields} field(s) "
                          f"per row and the overlay never reads bits[{fields - 1}]. "
                          f"The realm pays to send a field nothing consumes, and the "
                          f"minimum-length parse means nothing fails to say so.",
                          file=sys.stderr)
                    bad += 1

    # THE ROUNDING, WHICH IS THE ONE PIECE OF ARITHMETIC BOTH SIDES COMPUTE.
    #
    # The overlay quotes what a buyer will receive before they sign, and the realm
    # decides it after. Both express the same integral: cost = ceil((s1² - s0²) /
    # 2d), rounded UP so a purchase can never mint a unit it did not pay for. The
    # constant is already mirrored above; the ROUNDING was not, and a ceil turned
    # into a floor on one side alone is a receipt that promises a unit the chain
    # will not give — silently, and only on the amounts where the division does
    # not come out even.
    #
    # buy_test.js cross-checks curveQuote against a brute-force reference, but
    # that reference is JAVASCRIPT: it encodes the same intent as the code beside
    # it and would follow it into the same mistake. Nothing tied the overlay to
    # curve.gno until this.
    #
    # SHAPE, NOT VALUE, and the limit is worth stating plainly: this cannot prove
    # the two agree on every input — that needs vectors generated by the realm and
    # kept fresh. It proves both still round the same way and divide by the same
    # 2d, which is the divergence that has a price attached. Either side rewritten
    # fails it, and a rewrite is exactly when somebody should look.
    js_cost = "(s1*s1 - s0*s0 + 2n*CURVE_D - 1n)/(2n*CURVE_D)"
    gno_path = os.path.join(REPO, "realm/p/curve/curve.gno")
    gno = open(gno_path, encoding="utf-8").read()
    gno_marks = [
        "sh1, sl1 := bits.Mul64(uint64(s1), uint64(s1))",   # s1²
        "sh0, sl0 := bits.Mul64(uint64(from), uint64(from))",  # s0²
        "m := uint64(2 * c.d)",                             # the 2d divisor
        "bits.Add64(lo, m-1, 0)",                           # + 2d - 1, i.e. ceil
    ]
    if js_cost not in web:
        print("check-web-constants: the overlay no longer computes cost as "
              "ceil((s1^2 - s0^2) / 2d). If the curve changed, curve.gno changed "
              "too and this guard should be updated with it; if it did not, the "
              "quote and the chain now disagree on what a buyer receives.",
              file=sys.stderr)
        bad += 1
    for mark in gno_marks:
        if mark not in gno:
            print(f"check-web-constants: realm/p/curve/curve.gno no longer carries "
                  f"{mark!r}, so the overlay's copy of the curve is mirroring "
                  f"arithmetic the realm has stopped doing.", file=sys.stderr)
            bad += 1

    if bad:
        return 1
    print("check-web-constants: the curve rounds up on both sides — "
          "cost = ceil((s1^2 - s0^2) / 2d).")
    print(f"check-web-constants: {len(PHRASES)} mirrored phrase(s) still agree "
          f"across the boundary.")
    print(f"check-web-constants: {len(MIRRORS)} mirrored constant(s) match the "
          f"realm — " + ", ".join(f"{s}={realm_value(*v)}"
                                  for s, v in sorted(MIRRORS.items())) + ".")
    return 0


if __name__ == "__main__":
    sys.exit(main())
