#!/usr/bin/env python3
"""The bell's URL must carry the digest of the bell that is shipped.

WHY THIS EXISTS. web/bell.mp3 is served with no cache-control header, and
chat.js fetches it with {cache:"force-cache"} — which is the right thing for an
immutable URL and a trap for a mutable one: the browser will not even revalidate.
So a corrected recording under the same URL never reaches anybody who has
already heard the old one.

MEASURED, TWICE. "the bell rings twice" was reported once when it was true (the
clip had caught a swinging bell's return) and again after the file was fixed,
when the server held a single strike and readers still heard two. The second
report was entirely this cache.

The fix is that the URL changes when the bytes do. The fix's fix is this guard:
a version somebody must remember to bump is a version that is wrong the first
time it matters.
"""
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MP3 = ROOT / "web" / "bell.mp3"
JS = ROOT / "web" / "chat.js"


def main():
    if not MP3.exists() or not JS.exists():
        print("check-bell-version: no bell to check")
        return 0
    src = JS.read_text(encoding="utf8")
    m = re.search(r'CHATBELLSRC = "bell\.mp3\?v=([0-9a-f]+)"', src)
    if not m:
        print("check-bell-version: chat.js does not fetch bell.mp3 under a versioned "
              "URL.\n  Without one, force-cache serves a corrected recording's "
              "predecessor for ever.")
        return 1
    want = hashlib.sha256(MP3.read_bytes()).hexdigest()[:len(m.group(1))]
    if want != m.group(1):
        print("check-bell-version: chat.js asks for bell.mp3?v=%s and the shipped "
              "file is %s." % (m.group(1), want))
        print("  Every browser that has heard the old one will keep hearing it: the "
              "file is\n  served with no cache-control and fetched with force-cache. "
              "Put the new\n  digest in CHATBELLSRC.")
        return 1
    print("check-bell-version: bell.mp3?v=%s matches the %d bytes shipped."
          % (m.group(1), MP3.stat().st_size))
    return 0


if __name__ == "__main__":
    sys.exit(main())
