#!/usr/bin/env python3
"""A seed's media line must describe the bytes committed beside it.

WHY THIS EXISTS. A media item on chain is addressed by its digest: the realm
stores `img|<sha256>|<mime>|<w>|<h>|<bytes>|…` and every reader resolves that
digest to bytes. The seed files one of these for the Fauci set, and the bytes it
describes are committed at scenarios/assets/fauci.jpg.

Those two can drift, and the drift is silent in the worst way. Replace the image
with a better crop and the seed still files the OLD digest: the archive has no
blob at that address, the mirror serves something whose hash does not match, and
every reader gets a broken picture — while the seed, the realm and the checks all
say the filing succeeded. Nothing on the chain is wrong; the address simply
describes bytes that no longer exist.

SO THE FILE IS HASHED AND MEASURED, and compared against what the line claims.
Digest, byte count and pixel dimensions, because all three are in the line and
all three are load-bearing: the page reserves the box from w and h before the
image arrives, so a wrong dimension is a layout that jumps.

NOT A LINT ON THE COMMENT. The comment beside the line says the same numbers;
this reads the actual file, which is the only thing that cannot be wrong about
itself.
"""
import hashlib
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SEED = ROOT / "scenarios" / "covid_demo.py"
ASSETS = ROOT / "scenarios" / "assets"

# `img|<sha>|<mime>|<w>|<h>|<bytes>|<caption>|<mirror>` assembled from adjacent
# string literals, so the source is joined before it is read.
LINE = re.compile(
    r'"img"\s*"\|(?P<sha>[0-9a-f]{64})"\s*'
    r'"\|(?P<mime>[a-z/+-]+)\|(?P<w>\d+)\|(?P<h>\d+)\|(?P<bytes>\d+)"'
    r'[\s\S]{0,400}?"\|(?P<mirror>https://[^"]+)"')


def jpeg_size(b):
    """Width and height from the first start-of-frame marker."""
    if b[:2] != b"\xff\xd8":
        return None
    i = 2
    while i < len(b) - 9:
        if b[i] != 0xFF:
            i += 1
            continue
        m = b[i + 1]
        if m in (0xC0, 0xC1, 0xC2, 0xC3):
            h, w = struct.unpack(">HH", b[i + 5:i + 9])
            return w, h
        if m in (0xD8, 0xD9) or 0xD0 <= m <= 0xD7:
            i += 2
            continue
        i += 2 + struct.unpack(">H", b[i + 2:i + 4])[0]
    return None


def main():
    if not SEED.exists():
        print("check-seed-assets: no seed to check")
        return 0
    src = SEED.read_text(encoding="utf8")
    lines = list(LINE.finditer(src))
    if not lines:
        print("check-seed-assets: the seed files no media line; nothing to hold "
              "against the committed bytes.")
        return 0

    bad = []
    for m in lines:
        # The mirror's last segment names the file that must be committed.
        name = m.group("mirror").rsplit("/", 1)[-1]
        path = ASSETS / name
        if not path.exists():
            bad.append(f"{name}: the seed files it and scenarios/assets/{name} "
                       f"is not in the repo — the mirror serves nothing")
            continue
        b = path.read_bytes()
        got = hashlib.sha256(b).hexdigest()
        if got != m.group("sha"):
            bad.append(f"{name}: seed says sha256 {m.group('sha')[:16]}…, "
                       f"the file is {got[:16]}…")
        if len(b) != int(m.group("bytes")):
            bad.append(f"{name}: seed says {int(m.group('bytes')):,} bytes, "
                       f"the file is {len(b):,}")
        wh = jpeg_size(b)
        if wh and (wh[0], wh[1]) != (int(m.group("w")), int(m.group("h"))):
            bad.append(f"{name}: seed says {m.group('w')}x{m.group('h')}, "
                       f"the file is {wh[0]}x{wh[1]}")

    if bad:
        print("check-seed-assets: %d seed media line(s) do not describe the "
              "committed bytes:" % len(bad))
        for b in bad:
            print("  " + b)
        print("\n  A media item is addressed BY its digest. A line that names one "
              "the\n  file does not have is a filing that succeeds and a picture "
              "that never\n  loads: the archive has no blob at that address and "
              "the mirror serves\n  something else. Re-measure the file and put "
              "its own numbers in the line.")
        return 1
    print("check-seed-assets: %d seed media line(s), each describing the bytes "
          "committed beside it — digest, size and dimensions." % len(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
