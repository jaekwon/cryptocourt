#!/usr/bin/env python3
"""Hold the demo dataset to the realm's own arithmetic.

The demo exists so every screen renders offline. That is only worth having if
what it renders is a state the chain could actually be in — otherwise the
sample teaches the reader something false, and no test notices, because the
demo is data and data has no tests.

It went wrong exactly that way. Every conviction value in `DEMO` was between
6x and 29x ABOVE the realm's maximum for its own stated stake and lifetime --
at the unreachable ceiling; against the launch floor the factors ran to 74x.
Three invariants a human had written down in comments (the burn curve, the
senior-queue sum, the series/pool agreement) all held; the one nobody wrote
down was the one that broke. So they ALL get written down here, as code —
including the three that did hold, because "it holds today" is not a property,
it is an observation. Encoding them immediately found a fourth violation: the
annex court's burn was a round 18,000,000,000 where its own curve says
17,999,760,001, under a comment asserting the value is exact.

The constants are READ FROM THE REALM, never copied. If someone retunes
`r0WeeklyBps` or `periodBlocks`, this check retunes with them; a check that
hardcodes the number it is checking only pins the moment it was written.
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
WEB = ROOT / "web" / "index.html"
REALM = ROOT / "realm" / "r" / "kourtv2"


def die(msg):
    print(f"check-demo-physics: {msg}", file=sys.stderr)
    sys.exit(1)


def realm_const(name, *files):
    """One int constant, read from the realm source."""
    for f in files:
        p = REALM / f
        if not p.exists():
            continue
        # matches both a lone `const x = int64(1)` and an indented member of a
        # `const (...)` block, which is how this realm declares most of them
        m = re.search(rf"^\s*(?:const\s+)?{name}\s*=\s*(?:int64\()?([0-9_]+)\)?",
                      p.read_text(), re.M)
        if m:
            return int(m.group(1).replace("_", ""))
    die(f"could not read {name} from {', '.join(files)} — has the realm moved?")


def demo_region(src):
    """The CHAIN-TRUE half of the dataset.

    Round 28 split DEMO into a generated half (`DEMO_CHAIN`) and a hand-written
    overlay (`DEMO_OVERLAY`: desc, nested folders, relations, voteEndsAt — none
    of which a node can answer). Every invariant here is about chain-derived
    quantities, so this reads the generated half. `const DEMO = {` is still
    accepted so the checker works on a tree from before the split.
    """
    for marker in ("const DEMO_CHAIN = {", "const DEMO = {"):
        a = src.find(marker)
        if a >= 0:
            break
    else:
        die("web/index.html defines neither DEMO_CHAIN nor DEMO")
    for tail in ("/* ===== END GENERATED DEMO DATA", "const DEMO_ME"):
        b = src.find(tail, a)
        if b >= 0:
            return src[a:b]
    die("could not find the end of the dataset region")


def _brace_block(text, start):
    """The {...} beginning at `start` (which must index the '{'), as a string."""
    depth, i = 0, start
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
        i += 1
    return text[start:]


def claims(region):
    """Each claim entry as (key, body-text). Deliberately not a JS parser: the
    entries are one flat object literal per claim and we only read scalars.

    Scoped to the `claims:{...}` block by brace matching. Without that it
    matched every "slug/id" key ANYWHERE in the region — including the
    `positions` block, whose keys have the same shape — so a position could be
    mistaken for a claim and read for fields it does not have.
    """
    h = region.find("claims:{")
    if h < 0:
        h = region.find("claims: {")
    block = _brace_block(region, region.index("{", h)) if h >= 0 else region
    out = []
    for m in re.finditer(r'"([a-z]+/\d+)"\s*:\s*\{', block):
        start = m.end()
        depth, i = 1, start
        while i < len(block) and depth:
            if block[i] == "{":
                depth += 1
            elif block[i] == "}":
                depth -= 1
            i += 1
        out.append((m.group(1), block[start:i]))
    if not out:
        raise SystemExit("check-demo-physics: parsed no claims — DEMO's shape changed")
    return out


def num(body, field):
    m = re.search(rf"\b{field}\s*:\s*([0-9_]+)", body)
    return int(m.group(1).replace("_", "")) if m else None


def timeline_heights(body):
    m = re.search(r'timeline\s*:\s*"([^"]*)"', body)
    if not m:
        return {}
    out = {}
    for seg in m.group(1).split(";"):
        p = seg.split(":")
        if len(p) >= 3 and p[2].isdigit():
            out[p[0]] = int(p[2])
    return out


def courts(region):
    """Each court entry as (slug, body). Same deliberate non-parser as claims()."""
    out = []
    head = region.index("courts:")
    for m in re.finditer(r"^\s{4}([a-z][a-z0-9]*)\s*:\s*\{", region[head:], re.M):
        start = head + m.end()
        depth, i = 1, start
        while i < len(region) and depth:
            if region[i] == "{":
                depth += 1
            elif region[i] == "}":
                depth -= 1
            i += 1
        out.append((m.group(1), region[start:i]))
        if region[i:i + 40].lstrip().startswith("claims:"):
            break
    return out


def ceil_div(n, d):
    return -(-n // d)


def check_burn(region, bad):
    """burned == ceil(minted^2 / 2e9), the curve's exact cost.

    minted is derived as supply - emitted, which is how the demo branch itself
    derives it (web/index.html). That identity holds only because the sample has
    no coin burns; on a real chain it does not, which is a separate known gap.
    """
    for slug, body in courts(region):
        burned, supply, emitted = num(body, "burned"), num(body, "supply"), num(body, "emitted")
        if burned is None or supply is None or emitted is None:
            continue
        minted = supply - emitted
        want = ceil_div(minted * minted, 2_000_000_000)
        if burned != want:
            bad.append((slug, "burned",
                        f"{burned:,} but the curve cost of {minted:,} minted is {want:,}"
                        f" (off by {abs(burned - want):,})"))


def check_senior_queue(region, bad):
    """sum(amount - paid) across a court's queue == that court's seniorOwed.

    Brace-matched rather than line-shaped: the literal closes with `]}}` on one
    line, and an earlier newline-anchored regex silently matched NOTHING — the
    check passed vacuously even when seniorOwed was corrupted on purpose. A
    check that cannot fail is worse than no check, because it reads as coverage.
    """
    owed = {slug: num(body, "seniorOwed") for slug, body in courts(region)}
    h = region.find("seniorQueues:")
    if h < 0:
        bad.append(("seniorQueues", "missing", "DEMO no longer defines seniorQueues"))
        return
    block = _brace_block(region, region.index("{", h))
    seen = 0
    for m in re.finditer(r"([a-z][a-z0-9]*)\s*:\s*\{", block):
        slug = m.group(1)
        if slug not in owed:
            continue
        q = _brace_block(block, m.end() - 1)
        total, entries = 0, 0
        for e in re.finditer(r"\{[^{}]*\}", q):
            amt = num(e.group(0), "amount")
            if amt is None:
                continue
            entries += 1
            total += amt - (num(e.group(0), "paid") or 0)
        if not entries:
            continue
        seen += 1
        if owed[slug] is not None and total != owed[slug]:
            bad.append((slug, "seniorQueue",
                        f"entries owe {total:,} but the court states seniorOwed {owed[slug]:,}"))
    if not seen:
        bad.append(("seniorQueues", "unparsed",
                    "no queue entries were read — the literal's shape changed and this "
                    "check would otherwise pass without checking anything"))


def check_series_tail(region, bad):
    """The last row of seriesH/seriesD must equal the claim's current pools.

    The chart draws the series and the header draws the pools; if they disagree
    the page contradicts itself in two places a reader sees at once.
    """
    for key, body in claims(region):
        for grain in ("seriesH", "seriesD"):
            m = re.search(rf'{grain}\s*:\s*"([^"]*)"', body)
            if not m or ";" not in m.group(1):
                continue
            rows = m.group(1).split(";", 1)[1]
            if not rows.strip():
                continue
            last = rows.split(",")[-1].split(":")
            if len(last) < 3:
                continue
            yes, no = int(last[1]), int(last[2])
            ys, ns = num(body, "yesStake"), num(body, "noStake")
            if (ys, ns) != (yes, no):
                bad.append((key, grain,
                            f"last row is ({yes:,}, {no:,}) but the pools are ({ys:,}, {ns:,})"))


def check_settle_deadline(region, bad, now):
    """settleAt is SettleDeadline (session.gno) = answerHeight + settleDelay.

    Two relations, and the weaker one is the more useful. (a) When a claim's own
    timeline states a `settle` height, the separate `settleAt` field must agree
    with it — otherwise the ladder and the docket clock quote different blocks
    for the same event, on the same page. That is how orem/6 was found: its
    timeline said 4,797,800 and its settleAt said 4,798,000. (b) For a claim
    still in phase "answered" the deadline must be exactly answerHeight +
    settleDelay. Disputed and provisional claims are NOT checked that way: a
    later answer moves the anchor, so a mismatch there is not evidence of a bug.
    """
    delay = realm_const("settleDelay", "court.gno")
    for key, body in claims(region):
        tl = timeline_heights(body)
        settle_at = num(body, "settleAt")
        if settle_at is None:
            settle_at = _rel_to_now(body, now)
        if settle_at is None:
            continue
        if "settle" in tl and tl["settle"] != settle_at:
            bad.append((key, "settleAt",
                        f"{settle_at:,} but this claim's own timeline states settle at "
                        f"{tl['settle']:,} — the ladder and the clock would disagree"))
        phase = re.search(r'phase\s*:\s*"([a-z]+)"', body)
        if phase and phase.group(1) == "answered" and "answered" in tl:
            want = tl["answered"] + delay
            if settle_at != want:
                bad.append((key, "settleAt",
                            f"{settle_at:,} but answered at {tl['answered']:,} + settleDelay "
                            f"{delay:,} is {want:,}"))


def _rel_to_now(body, now):
    """settleAt is often written NOW-2_200 rather than an absolute height."""
    m = re.search(r"settleAt\s*:\s*NOW\s*([+-])\s*([0-9_]+)", body)
    if m:
        d = int(m.group(2).replace("_", ""))
        return now + d if m.group(1) == "+" else now - d
    if re.search(r"settleAt\s*:\s*NOW\b", body):
        return now
    return None


def check_quorum_floor(region, bad):
    """quorumFloor is a max() whose 5%-of-supply arm is a hard lower bound.

    The full formula also takes min(xBarFrozen, votable/3), neither of which the
    demo states — so only the bound is checkable, and that is the arm the demo's
    own comment says is binding here.
    """
    bps = realm_const("quorumSupplyBps", "dispute.gno")
    supply = {slug: num(body, "supply") for slug, body in courts(region)}
    for key, body in claims(region):
        qf = num(body, "quorumFloor")
        if qf is None:
            continue
        slug = key.split("/")[0]
        sup = supply.get(slug)
        if sup is None:
            continue
        floor = sup * bps // 10_000
        if qf < floor:
            bad.append((key, "quorumFloor",
                        f"{qf:,} is below the {bps / 100:g}%-of-supply arm ({floor:,}), "
                        f"which quorumFloor() takes a max() against"))


def check_references(region, bad):
    """Every claim entry names a listed court claim, and vice versa.

    The classic drift: a claim is renamed or removed and something still points
    at it. The page then renders a docket row for a claim with no entry, or
    hides an entry no docket lists.

    SCOPE, stated so nobody reads more coverage into this than it has: only the
    FLAT integer lists are checked — a court's `claims:[...]` against the claim
    entry keys, and the top-level keys of positions/balances/seniorQueues
    against the court set. Nested `folders` and `relations` are NOT checked
    here; they are trees, and half-parsing a tree with regexes is how the
    senior-queue check came to pass while reading nothing (round 14).
    """
    keys = {k for k, _ in claims(region)}
    listed = {}
    for slug, body in courts(region):
        m = re.search(r"claims\s*:\s*\[([0-9,\s_]*)\]", body)
        if not m:
            continue
        ids = [int(x.strip().replace("_", "")) for x in m.group(1).split(",") if x.strip()]
        listed[slug] = ids
        for i in ids:
            if f"{slug}/{i}" not in keys:
                bad.append((slug, "claims", f"lists claim {i}, which has no entry"))
    if not listed:
        bad.append(("courts", "unparsed",
                    "no court claim-lists were read — the literal's shape changed and this "
                    "check would otherwise pass without checking anything"))
        return
    for k in sorted(keys):
        slug, _, ids = k.partition("/")
        if slug not in listed:
            bad.append((k, "claim", f"court {slug} has no claims list"))
        elif int(ids) not in listed[slug]:
            bad.append((k, "claim", f"court {slug} does not list id {ids}"))

    for section in ("positions", "balances", "seniorQueues"):
        h = region.find(section + ":")
        if h < 0:
            continue
        block = _brace_block(region, region.index("{", h))
        for m in re.finditer(r'"?([a-z][a-z0-9]*)(?:/(\d+))?"?\s*:\s*\{', block):
            slug, cid = m.group(1), m.group(2)
            if slug in ("entries",):
                continue
            if cid is not None:
                if f"{slug}/{cid}" not in keys:
                    bad.append((section, slug + "/" + cid, "refers to a claim with no entry"))
            elif slug not in listed:
                bad.append((section, slug, "refers to a court that does not exist"))


def main():
    src = WEB.read_text()
    region = demo_region(src)

    period = realm_const("periodBlocks", "court.gno")
    r0 = realm_const("r0WeeklyBps", "stake.gno")
    budget = realm_const("budgetWeeklyBps", "court.gno")
    now_m = re.search(r"const NOW\s*=\s*([0-9_]+)", src)
    if not now_m:
        die("web/index.html no longer defines NOW")
    now = int(now_m.group(1).replace("_", ""))

    # rateBpsFP (stake.gno): 255 * (r0*1e6 + dEffBpsFP) / 100, and dEffBpsFP is
    # capped at curBudgetBpsFP, which starts at budgetWeeklyBps*1e6 and only
    # ever steps DOWN (emission.gno). So this is the ceiling, for all time.
    ceil_rate = 255 * (r0 * 1_000_000 + budget * 1_000_000) // 100
    # convToCC divides by periodBlocks * 10_000 * 1e6.
    den = period * 10_000 * 1_000_000

    bad, checked, skipped = [], 0, []
    for key, body in claims(region):
        tl = timeline_heights(body)
        if "opened" not in tl:
            # No timeline: the dataset states no lifetime, so nothing to
            # contradict. Reported, not failed — see the note in main's output.
            if num(body, "convYes") or num(body, "convNo"):
                skipped.append(key)
            continue
        end = tl.get("answered", tl.get("now", now))
        life = end - tl["opened"]
        if life <= 0:
            bad.append((key, "timeline", f"life is {life} blocks"))
            continue
        for stake_f, conv_f in (("yesStake", "convYes"), ("noStake", "convNo")):
            stake, conv = num(body, stake_f), num(body, conv_f)
            if not stake or conv is None:
                continue
            checked += 1
            most = stake * ceil_rate * life // den
            if conv > most:
                bad.append((key, conv_f,
                            f"{conv:,} but {life:,} blocks on {stake:,} yields at most {most:,}"
                            f" ({conv / most:.1f}x over)"))

    check_burn(region, bad)
    check_settle_deadline(region, bad, now)
    check_quorum_floor(region, bad)
    check_references(region, bad)
    check_senior_queue(region, bad)
    check_series_tail(region, bad)

    if bad:
        print(f"check-demo-physics: {len(bad)} demo value(s) the realm cannot produce:",
              file=sys.stderr)
        for key, field, why in bad:
            print(f"  {key} {field}: {why}", file=sys.stderr)
        print("\n  Conviction is stake x rate x blocks (stake.gno:46-48, convToCC at :271),\n"
              f"  ceiling rate {ceil_rate} per {period}-block week. Recompute the value or\n"
              "  lengthen the claim's timeline; do not raise the ceiling to fit the data.",
              file=sys.stderr)
        sys.exit(1)

    note = f"; {len(skipped)} claim(s) state no timeline, so their conviction is unconstrained" if skipped else ""
    print(f"check-demo-physics: {checked} conviction value(s) within the realm's ceiling{note}. "
          f"Burn curve, senior-queue sum, series/pool agreement, settle deadlines, "
          f"quorum floors and cross-references all hold.")


if __name__ == "__main__":
    main()
