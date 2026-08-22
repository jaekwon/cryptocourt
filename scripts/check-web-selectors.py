#!/usr/bin/env python3
"""Every class a browser check queries must still exist in the overlay.

WHY THIS EXISTS. `make web-visual` needs puppeteer, so it is deliberately NOT in
`make check` — the Makefile already learned that lesson with realm-test, whose
guards were silently skipped on a machine with no gno toolchain. The cost of
keeping it out is that browser assertions rot unseen, and three of them did:

  * embed_layout.js queried `.eline`, `.efill` and `.e50` — the private class
    names the share card's chart used BEFORE it started sharing the claim page's
    `.ln` / `.ar` / `.mid`. Sharing them was the entire point of that change, and
    the probe kept asking for the old ones for a day.

A querySelector for a class that no longer exists does not fail. It returns null,
the check reads `!!null` as false or short-circuits, and the assertion goes on
reporting on nothing — the vacuity problem this repo cares about everywhere else.

So this is the cheap half, safe to run in `check`: no browser, no puppeteer, no
page load. It only asks whether each class a check NAMES still appears in the one
file those checks are pointed at. It cannot tell whether an assertion still means
what it meant — the grid and the lit-lip assertions that rotted alongside these
were computed-style regexes, not selectors, and nothing static would have caught
them. It closes the half that is closable.

    python3 scripts/check-web-selectors.py
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# BOTH shipped files. The overlay is one page plus exactly one local script, and
# the chat panel's classes live in chat.js — a guard that knew only about
# index.html called every chat selector stale, which is the guard being wrong
# rather than the tests.
PAGES = [os.path.join(ROOT, "web", "index.html"),
         os.path.join(ROOT, "web", "chat.js")]
BROWSER = os.path.join(ROOT, "web", "tests", "browser")

# Classes the overlay never writes into its own source because the BROWSER or a
# test fixture creates them. Each needs a reason, or this list becomes the place
# stale selectors go to hide.
ALLOWED = {
    "js": "set on <html> by the page's own bootstrap, not present as a literal",
}

# CLASSES ONLY, NOT IDS. Every `#foo` in these checks is a MOUNT POINT the test
# creates for itself — #livechat, #demochat, #courtchat — so requiring them in
# the shipped source would flag the test for doing its own setup. Classes are the
# ones the page owns and therefore the ones that can go stale under a test.

page = ""
for f in PAGES:
    if not os.path.exists(f):
        sys.exit("check-web-selectors: %s is missing" % f)
    page += io.open(f, encoding="utf-8").read()
if len(page) < 100_000:
    sys.exit("check-web-selectors: the shipped sources total only %d bytes — "
             "refusing to pass vacuously" % len(page))

if not os.path.isdir(BROWSER):
    sys.exit("check-web-selectors: no web/tests/browser directory")

# querySelector('.foo .bar'), querySelectorAll("#baz .qux"), closest('.row')
CALL = re.compile(r"""(?:querySelectorAll|querySelector|closest)\(\s*(['"])(.*?)\1""")
TOKEN = re.compile(r"\.([A-Za-z][-A-Za-z0-9_]*)")

# A check may legitimately name a class in order to assert it is GONE — the chat
# panel's dry-run notice was removed at the owner's word, and the test that keeps
# it removed has to say the word to do so. That is indistinguishable from rot by
# reading the selector, so the file declares it:
#
#     // check-web-selectors: gone chatdry — the dry-run notice, removed in 6e5c1e1
#
# Declared per file, with a reason on the same line, so the exemption is
# reviewable and cannot quietly become the place stale selectors hide.
GONE = re.compile(r"//\s*check-web-selectors:\s*gone\s+([A-Za-z][-A-Za-z0-9_]*)\s+—\s*\S")

bad, checked, files, exempt = [], 0, 0, 0
for name in sorted(os.listdir(BROWSER)):
    if not name.endswith(".js") or name == "run.js":
        continue
    files += 1
    src = io.open(os.path.join(BROWSER, name), encoding="utf-8").read()
    gone = set(GONE.findall(src))
    exempt += len(gone)
    for _, sel in CALL.findall(src):
        for tok in TOKEN.findall(sel):
            checked += 1
            if tok in ALLOWED:
                continue
            if tok in gone:
                # Declared absent on purpose. The check still has teeth: if the
                # class comes BACK, the declaration is the thing that now reads
                # false, and the assertion beside it fails on its own.
                continue
            # A class is present if the overlay mentions it at all — in markup,
            # in a stylesheet rule, or in a classList call. Anything narrower
            # would start arguing with how the page builds its own HTML.
            if not re.search(r"[.\"' ]%s\b" % re.escape(tok), page):
                bad.append((name, sel, tok))

if bad:
    print("check-web-selectors: a browser check queries something the overlay no "
          "longer has", file=sys.stderr)
    for name, sel, tok in bad:
        print("  %-22s %-28s -> `%s` appears in neither shipped file"
              % (name, sel, tok), file=sys.stderr)
    print("  A querySelector for a class that does not exist returns null and the "
          "assertion silently measures nothing.", file=sys.stderr)
    sys.exit(1)

if files == 0 or checked == 0:
    sys.exit("check-web-selectors: found %d file(s) and %d selector(s) — the scan "
             "matched nothing, which is a broken check rather than a clean tree"
             % (files, checked))

print("check-web-selectors: %d selector token(s) across %d browser check(s), every "
      "one still present in the shipped source (%d declared gone on purpose)."
      % (checked, files, exempt))
