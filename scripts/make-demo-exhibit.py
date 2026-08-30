#!/usr/bin/env python3
"""Build the one exhibit the OFFLINE demo shows, as an inline data: URI.

    scripts/make-demo-exhibit.py            # print the first sheet's line
    scripts/make-demo-exhibit.py --claim3   # the whole media block for orem/3
    scripts/make-demo-exhibit.py --covers   # the folder faces
    scripts/make-demo-exhibit.py --check    # verify the page still carries them

WHY THE DEMO NEEDS ITS OWN BYTES. web/README.md promises one self-contained file
that runs from file:// and makes no network calls in demo mode. A real exhibit
resolves to https://<site>/m/<sha256> — the archive — so putting a real one in
the sample would break exactly that promise, and off a network it would draw a
broken-image icon instead of evidence. Bytes carried in the page are the only
kind an offline demo can honestly show.

WHY IT IS ABSTRACT. It stands in for a scan of an inspection report. It does NOT
render one: a plausible-looking government document with legible findings is a
fabricated record, and this project is a court. Grey bars are what a page of
text looks like at thumbnail size anyway, which is the size that matters on a
map node — so the honest version is also the one that reads correctly.

The generator is committed rather than just its output so the blob in
web/index.html has provenance: you can see what the bytes are without decoding
them, and --check proves the page still carries what this file describes.
"""
import base64
import hashlib
import os
import re
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAGE = os.path.join(ROOT, "web", "index.html")

W, H = 240, 160
PAPER = (0xF3, 0xF0, 0xE9)
EDGE = (0xD9, 0xD3, 0xC6)
INK = (0xA8, 0xA1, 0x93)   # a line of body text, seen from too far to read
HEAD = (0x6B, 0x64, 0x57)  # the heading block
MARK = (0xC2, 0x6B, 0x3A)  # the one row an exhibit is filed to point at


def png(width, height, pixels):
    """Encode RGB rows as a PNG. Filter 0 on every scanline: the image is flat
    rectangles, so zlib finds the runs without help and the extra filter modes
    would only make this function longer."""
    raw = b"".join(b"\x00" + b"".join(struct.pack("BBB", *p) for p in row) for row in pixels)

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


# THE FOUR SHEETS CLAIM 3 CARRIES. One was enough while a map node showed a
# single corner badge; the strip under a node's title shows up to four, and a
# sample that files one cannot demonstrate the thing the reader is looking at.
# They are the same abstract sheet at four sizes, with a different row marked —
# what a set of pages filed about one bridge rating looks like from too far to
# read. The sizes differ on purpose: a tile is a centre crop, and a wide sheet
# and a tall one crop differently.
#
# INDEX 0 IS THE ORIGINAL, byte for byte. Its sha256 is quoted in the page, in
# this file's --check and in the browser harnesses; regenerating it differently
# would be a silent edit to evidence the sample says was fingerprinted.
EXHIBITS = [
    # w,   h,   marked row, caption
    (240, 160, 3, "north span rating, 2025 inspection report"),
    (320, 120, 1, "load posting, county maintenance log"),
    (240, 160, 5, "deck survey, page 2"),
    (200, 260, 2, "span elevation, filed with the rating"),
]


def exhibit(n=0):
    w, h, marked, _ = EXHIBITS[n]
    rows = [[PAPER] * w for _ in range(h)]

    def rect(x0, y0, x1, y1, colour):
        for y in range(max(0, y0), min(h, y1)):
            for x in range(max(0, x0), min(w, x1)):
                rows[y][x] = colour

    # the page's own edge, so the sample reads as a sheet rather than a swatch
    rect(0, 0, w, 1, EDGE)
    rect(0, h - 1, w, h, EDGE)
    rect(0, 0, 1, h, EDGE)
    rect(w - 1, 0, w, h, EDGE)

    rect(20, 18, 132, 27, HEAD)          # title
    rect(20, 33, 96, 37, INK)            # subtitle

    # As many table rows as the sheet has room for, so a tall page reads as a
    # longer document rather than as the same page with white space under it.
    nrows = min(8, max(3, (h - 56) // 16))
    y = 56                               # a table: label column, value column
    for i in range(nrows):
        rect(20, y, 88, y + 5, MARK if i == marked else INK)
        rect(100, y, 100 + (78 if i % 2 else 54), y + 5, MARK if i == marked else INK)
        y += 16

    return png(w, h, rows)


# The faces the demo's folders wear on the map. A folder is a heading, not a
# claim — it argues nothing — so these are deliberately ABSTRACT: bands of colour
# that read as a cover at 164x44 and as nothing in particular up close. The same
# rule as the exhibit above, for the same reason: a plausible-looking document is
# a fabricated record, and this is a court.
COVERS = [
    ((0x1E, 0x2E, 0x4A), (0x3E, 0x6A, 0x8E), (0xC2, 0x6B, 0x3A)),  # municipal blue
    ((0x24, 0x3A, 0x30), (0x3F, 0x6B, 0x55), (0xD7, 0xB2, 0x64)),  # infrastructure green
    ((0x3A, 0x2A, 0x30), (0x6B, 0x45, 0x52), (0xE0, 0x8B, 0x7C)),  # filings plum
]


def cover(n):
    """One folder face. 164x44 is the drawn size, at about a third opacity behind
    a heading — so the shapes are BROAD. An earlier version put three small marks
    on a wash and at that size they read as grime on the box rather than as a
    picture. Two large fields split by a diagonal and one wide band survive the
    reduction: what reaches the reader is a clean two-tone tint, different per
    folder, which is the whole job a face has on a map."""
    w, h = 328, 88
    base, mid, mark = COVERS[n % len(COVERS)]
    # The diagonal's lean, per cover, so the three do not read as one template.
    slope = (0.9, -1.4, 2.1)[n % 3]
    edge = (0.34, 0.62, 0.46)[n % 3]
    rows = []
    for y in range(h):
        t = y / (h - 1)
        cut = (edge + slope * (t - 0.5) * 0.5) * w
        row = []
        for x in range(w):
            if x < cut:
                # the darker field, with a slight vertical wash for depth
                row.append(tuple(int(base[i] + (mid[i] - base[i]) * t * 0.55) for i in range(3)))
            else:
                row.append(tuple(int(mid[i] + (base[i] - mid[i]) * (1 - t) * 0.30) for i in range(3)))
        rows.append(row)

    # One band, full width, the accent colour: the only small shape, and it is
    # small in one dimension only. Kept out of the middle third, because the
    # heading is drawn there and a band behind it reads as a strikethrough.
    y0 = int(h * (0.10, 0.82, 0.15)[n % 3])
    for y in range(y0, min(h, y0 + max(3, h // 14))):
        rows[y] = [mark] * w
    return png(w, h, rows)


def line():
    body = exhibit()
    uri = "data:image/png;base64," + base64.b64encode(body).decode()
    return body, uri


def claim3():
    """The whole DEMO_OVERLAY.media entry for orem/3, ready to paste.

    Printed rather than hand-kept because every sheet carries four numbers the
    page repeats — w, h, bytes and the sha256 — and four of those hand-copied is
    four chances to write down a fingerprint that is not the bytes'. The court's
    whole media design rests on that number meaning something."""
    out = ['  media:{"orem/3":[']
    for i, (w, h, _, cap) in enumerate(EXHIBITS):
        body = exhibit(i)
        out.append('    {kind:"img", mime:"image/png", w:%d, h:%d, bytes:%d,' % (w, h, len(body)))
        out.append('     sha256:"%s",' % hashlib.sha256(body).hexdigest())
        out.append('     caption:"%s",' % cap)
        out.append('     mirrors:[], purged:false, inline:"data:image/png;base64,%s"}%s'
                   % (base64.b64encode(body).decode(), "," if i + 1 < len(EXHIBITS) else ""))
    out.append("  ]},")
    return "\n".join(out)


def main():
    body, uri = line()
    digest = hashlib.sha256(body).hexdigest()
    if "--check" in sys.argv:
        with open(PAGE, encoding="utf-8") as fh:
            page = fh.read()
        # Every sheet, and every sheet's fingerprint. A page carrying bytes whose
        # sha256 it does not also carry is the one failure this whole design
        # exists to make impossible, so it is checked per exhibit rather than
        # once for the first one.
        for i in range(len(EXHIBITS)):
            b = exhibit(i)
            u = "data:image/png;base64," + base64.b64encode(b).decode()
            if u not in page:
                print("make-demo-exhibit: web/index.html does not carry exhibit %d's bytes.\n"
                      "Run scripts/make-demo-exhibit.py --claim3 and paste the block." % i,
                      file=sys.stderr)
                return 1
            if hashlib.sha256(b).hexdigest() not in page:
                print("make-demo-exhibit: exhibit %d's bytes are in the page but not its sha256 %s"
                      % (i, hashlib.sha256(b).hexdigest()), file=sys.stderr)
                return 1
        for i in range(len(COVERS)):
            u = "data:image/png;base64," + base64.b64encode(cover(i)).decode()
            if u not in page:
                print("make-demo-exhibit: web/index.html does not carry folder cover %d.\n"
                      "Run scripts/make-demo-exhibit.py --covers and paste it." % i,
                      file=sys.stderr)
                return 1
        print("make-demo-exhibit: ok (%d exhibit(s), first %d bytes / %s, +%d folder cover(s))"
              % (len(EXHIBITS), len(body), digest[:12], len(COVERS)))
        return 0
    if "--claim3" in sys.argv:
        print(claim3())
        return 0
    if "--covers" in sys.argv:
        for i in range(len(COVERS)):
            c = cover(i)
            print("cover%d : data:image/png;base64,%s" % (i, base64.b64encode(c).decode()))
        return 0
    print("bytes  : %d" % len(body))
    print("sha256 : %s" % digest)
    print("inline : %s" % uri)
    return 0


if __name__ == "__main__":
    sys.exit(main())
