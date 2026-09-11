#!/usr/bin/env python3
"""Draw a star plate in the rail's own visual language.

THE RAIL'S PLATE WAS HAND-AUTHORED AND THIS IS NOT A REWRITE OF IT. --skyplate in
web/index.html stays exactly as it is; this script exists because the chat panel
needed the sky that CONTINUES from it, and a second plate drawn by eye would not
have continued from anything.

The rail's plate turned out to be fully recoverable. Its eleven figure lines are
Leo, its ten vertices are Leo's ten named stars, and fitting those ten gives

    x = 2956.716 - 16.42665 * RA(deg)        y = 850.113 - 16.99803 * Dec(deg)

to a worst residual of half a pixel. Under that mapping its 640x1190 viewBox is
RA 180..141 and Dec +50..-20 -- round numbers, so that was the authored window --
and all 291 of its circles land within a quarter degree of a catalogued star. It
is not a starfield in the style of the sky; it is the sky, complete to magnitude
6.30, which is the naked-eye limit.

So everything below is that same drawing, re-derived rather than imitated: the
tiers, the opacities, the colour cuts and the blooms are read off the plate, and
the projection is the plate's own. Point it at the next window west and the two
line up along their shared edge because they are one coordinate system.

Catalogue: HYG v3.8 (astronexus/HYG-Database). Star positions are measurements,
not authorship. Run with --help for usage.
"""
import argparse, csv, math, sys

# ---- the plate's own drawing rules, read off the rail's SVG -----------------
# mag < hi -> (radius, group opacity). The rail's plate stops at 6.30.
TIERS = [(2.5, 3.0, "0.95"), (3.5, 2.2, "0.88"), (4.25, 1.6, "0.74"),
         (5.0, 1.15, "0.58"), (5.7, 0.8, "0.44"), (6.3, 0.55, "0.3")]
# a bloom behind the two brightest tiers only, radius and opacity by tier index
BLOOM = {0: (9.0, "0.13"), 1: (5.5, "0.08")}
# B-V colour index -> fill. Fainter tiers take the group's #fff and are left
# uncoloured, which is what the rail does: "the anonymous field is still white".
COLOUR = [(-0.05, "#aabfff"), (0.15, "#cad7ff"), (0.45, "#f8f7ff"),
          (1.00, "#fff4ea"), (99.0, "#ffd2a1")]
COLOUR_TIERS = 4            # tiers that carry a colour at all
FIGURE_OPEN = ('<g stroke="#b3a2ff" stroke-opacity=".22" stroke-width="1"'
               ' fill="none" stroke-linecap="round">')

AX, BX = 2956.716, -16.42665
AY, BY = 850.113, -16.99803
proj = lambda ra, dec: (AX + BX * ra, AY + BY * dec)


def colour_for(ci):
    if ci is None:
        return None
    for hi, c in COLOUR:
        if ci < hi:
            return c
    return COLOUR[-1][1]


def load(path, ra_lo, ra_hi, dec_lo, dec_hi, maglim):
    """Every catalogued star in the window, brightest first.

    RA is stored in hours and the window may wrap through 0h, which is why the
    test is written as a membership question rather than a comparison: a plate
    that runs 141..20 degrees does not wrap, but one running 20..340 would, and
    silently dropping half its stars is the kind of bug that looks like a design
    choice."""
    out = []
    wrap = ra_lo < ra_hi           # window crosses 0h
    with open(path) as f:
        for r in csv.DictReader(f):
            try:
                ra = float(r["ra"]) * 15.0
                dec = float(r["dec"])
                mag = float(r["mag"])
            except (TypeError, ValueError):
                continue
            inside = (ra <= ra_lo or ra >= ra_hi) if wrap else (ra_hi <= ra <= ra_lo)
            if not inside or not (dec_lo <= dec <= dec_hi) or mag >= maglim:
                continue
            # AND THE WRAPPED HALF IS DRAWN AS NEGATIVE RA, not as 340-odd
            # degrees. proj() is linear in RA with no notion of the 0h seam, so a
            # star at 350 would otherwise land two thousand units to the LEFT of
            # the window it belongs to -- off the plate, silently.
            if wrap and ra >= ra_hi:
                ra -= 360.0
            try:
                ci = float(r["ci"])
            except (TypeError, ValueError):
                ci = None
            out.append({"ra": ra, "dec": dec, "mag": mag, "ci": ci,
                        "bf": (r.get("bf") or "").strip(),
                        "proper": (r.get("proper") or "").strip()})
    out.sort(key=lambda s: s["mag"])
    return out


def by_bayer(stars):
    """(greek, constellation) -> star, brightest wins.

    Brightest wins because the catalogue carries components separately: Castor is
    in there twice as 66Alp Gem at 1.58 and 2.85, and a figure that picked the
    second would draw a line to a point a reader cannot see."""
    idx = {}
    for s in stars:
        bf = s["bf"]
        if len(bf) < 4:
            continue
        # THE SEPARATOR IS NOT RELIABLE. Most rows read "17Eps Leo", but a star
        # with a component letter drops the space entirely: Algieba is "41Gam1Leo".
        # Splitting on whitespace loses exactly the doubles -- which are the
        # BRIGHT stars, so the figures that vanish are the ones a reader would
        # notice. The constellation abbreviation is always the last three
        # characters, so take it from the end and never look for a space.
        rest = bf.lstrip("0123456789")
        con, greek = rest[-3:], rest[:-3].strip().rstrip("123")
        if not greek:
            continue
        k = (greek[:3].title(), con)
        if k not in idx or s["mag"] < idx[k]["mag"]:
            idx[k] = s
    return idx


def emit(stars, figures, x0, y0, w, h, extra_from=None):
    body = []
    if figures:
        body.append(FIGURE_OPEN)
        for (x1, y1), (x2, y2) in figures:
            body.append(f'<line x1="{x1-x0:.0f}" y1="{y1-y0:.0f}"'
                        f' x2="{x2-x0:.0f}" y2="{y2-y0:.0f}"/>')
        body.append("</g>")

    tiered = [[] for _ in TIERS]
    for s in stars:
        for i, (hi, _, _) in enumerate(TIERS):
            if s["mag"] < hi:
                tiered[i].append(s)
                break

    # THE BLOOMS COME FIRST so they sit behind their own stars, which is the
    # order the rail's plate uses and one its check asserts.
    blooms = []
    for i, (br, bo) in BLOOM.items():
        for s in tiered[i]:
            x, y = proj(s["ra"], s["dec"])
            c = colour_for(s["ci"]) or "#ffffff"
            blooms.append(f'<circle cx="{x-x0:.0f}" cy="{y-y0:.0f}" r="{br}"'
                          f' fill="{c}" opacity="{bo}"/>')
    if blooms:
        body.append("<g>" + "".join(blooms) + "</g>")

    for i, (hi, rad, op) in enumerate(TIERS):
        if not tiered[i]:
            continue
        parts = [f'<g fill="#fff" opacity="{op}">']
        for s in tiered[i]:
            x, y = proj(s["ra"], s["dec"])
            c = colour_for(s["ci"]) if i < COLOUR_TIERS else None
            f = f' fill="{c}"' if c else ""
            parts.append(f'<circle cx="{x-x0:.0f}" cy="{y-y0:.0f}" r="{rad}"{f}/>')
        parts.append("</g>")
        body.append("".join(parts))

    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w:.0f} {h:.0f}">'
            + "".join(body) + "</svg>")


# ---- the figures -----------------------------------------------------------
# Greek-letter pairs, resolved against the catalogue at run time rather than
# written as coordinates, so a figure cannot drift away from its own stars.
FIGURES = {
    "Ori": [("Alp", "Gam"), ("Gam", "Del"), ("Del", "Eps"), ("Eps", "Zet"),
            ("Zet", "Alp"), ("Del", "Bet"), ("Zet", "Kap"),
            ("Alp", "Lam"), ("Lam", "Gam")],
    "Tau": [("Bet", "Eps"), ("Eps", "Del"), ("Del", "Gam"), ("Gam", "Lam"),
            ("Eps", "Alp"), ("Alp", "Zet")],
    "Gem": [("Alp", "Tau"), ("Tau", "Eps"), ("Eps", "Mu"), ("Mu", "Eta"),
            ("Bet", "Ups"), ("Ups", "Del"), ("Del", "Zet"), ("Zet", "Gam"),
            ("Eps", "Ups")],
    "CMi": [("Alp", "Bet")],
    "Cnc": [("Del", "Bet"), ("Del", "Gam"), ("Gam", "Iot"), ("Del", "Alp")],
    "Aur": [("Alp", "Bet"), ("Bet", "The"), ("The", "Iot"), ("Iot", "Eps"),
            ("Eps", "Alp")],
    "Per": [("Alp", "Gam"), ("Alp", "Del"), ("Del", "Eps"), ("Alp", "Bet"),
            ("Bet", "Rho"), ("Gam", "Eta")],
    "Ari": [("Alp", "Bet"), ("Bet", "Gam")],
    "CMa": [("Alp", "Bet")],
    "Leo": [("Eps", "Mu"), ("Mu", "Zet"), ("Zet", "Gam"), ("Gam", "Eta"),
            ("Eta", "Alp"), ("Gam", "Del"), ("Del", "Bet"), ("Bet", "The"),
            ("The", "Del"), ("The", "Alp"), ("Lam", "Eps")],
}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--hyg", required=True, help="path to hyg CSV")
    ap.add_argument("--ra", required=True, help="RA window in degrees, high,low")
    ap.add_argument("--dec", default="-20,50", help="Dec window in degrees, low,high")
    ap.add_argument("--maglim", type=float, default=6.30)
    ap.add_argument("--figures", default="", help="comma-separated constellations")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    ra_lo, ra_hi = (float(v) for v in a.ra.split(","))
    dec_lo, dec_hi = (float(v) for v in a.dec.split(","))
    stars = load(a.hyg, ra_lo, ra_hi, dec_lo, dec_hi, a.maglim)

    idx = by_bayer(stars)
    figures, missing = [], []
    for con in [c for c in a.figures.split(",") if c]:
        for g1, g2 in FIGURES.get(con, []):
            s1, s2 = idx.get((g1, con)), idx.get((g2, con))
            if not s1 or not s2:
                missing.append(f"{con} {g1}-{g2}")
                continue
            figures.append((proj(s1["ra"], s1["dec"]), proj(s2["ra"], s2["dec"])))

    x0, _ = proj(ra_lo, 0)
    x1, _ = proj(ra_hi if ra_hi < ra_lo else ra_hi - 360, 0)
    _, y0 = proj(0, dec_hi)
    _, y1 = proj(0, dec_lo)
    svg = emit(stars, figures, x0, y0, x1 - x0, y1 - y0)
    with open(a.out, "w") as f:
        f.write(svg)

    print(f"  {a.out}: {len(stars)} stars to mag {a.maglim}, {len(figures)} figure lines,"
          f" {len(svg)} bytes")
    # A FIGURE LINE THAT COULD NOT BE RESOLVED IS REPORTED, NOT DROPPED. Silence
    # here would read as "the constellation has no such line" rather than "its
    # star was fainter than the limit and is not on this plate".
    if missing:
        print(f"  unresolved ({len(missing)}): {', '.join(missing)}", file=sys.stderr)


if __name__ == "__main__":
    main()
