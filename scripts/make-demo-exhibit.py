#!/usr/bin/env python3
"""Build the one exhibit the OFFLINE demo shows, as an inline data: URI.

    scripts/make-demo-exhibit.py           # print the line to paste
    scripts/make-demo-exhibit.py --check   # verify the page still carries it

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


def exhibit():
    rows = [[PAPER] * W for _ in range(H)]

    def rect(x0, y0, x1, y1, colour):
        for y in range(max(0, y0), min(H, y1)):
            for x in range(max(0, x0), min(W, x1)):
                rows[y][x] = colour

    # the page's own edge, so the sample reads as a sheet rather than a swatch
    rect(0, 0, W, 1, EDGE)
    rect(0, H - 1, W, H, EDGE)
    rect(0, 0, 1, H, EDGE)
    rect(W - 1, 0, W, H, EDGE)

    rect(20, 18, 132, 27, HEAD)          # title
    rect(20, 33, 96, 37, INK)            # subtitle

    y = 56                               # a table: label column, value column
    for i in range(6):
        rect(20, y, 88, y + 5, MARK if i == 3 else INK)
        rect(100, y, 100 + (78 if i % 2 else 54), y + 5, MARK if i == 3 else INK)
        y += 16

    return png(W, H, rows)


def line():
    body = exhibit()
    uri = "data:image/png;base64," + base64.b64encode(body).decode()
    return body, uri


def main():
    body, uri = line()
    digest = hashlib.sha256(body).hexdigest()
    if "--check" in sys.argv:
        with open(PAGE, encoding="utf-8") as fh:
            page = fh.read()
        if uri not in page:
            print("make-demo-exhibit: web/index.html does not carry these bytes.\n"
                  "Run scripts/make-demo-exhibit.py and paste the inline: field.", file=sys.stderr)
            return 1
        if digest not in page:
            print("make-demo-exhibit: the page carries the bytes but not their sha256 %s"
                  % digest, file=sys.stderr)
            return 1
        print("make-demo-exhibit: ok (%d bytes, %s)" % (len(body), digest[:12]))
        return 0
    print("bytes  : %d" % len(body))
    print("sha256 : %s" % digest)
    print("inline : %s" % uri)
    return 0


if __name__ == "__main__":
    sys.exit(main())
