#!/usr/bin/env python3
"""Every browser check must be reachable from the runner that claims to run them.

WHY THIS EXISTS, and it is a measured cost rather than a worry. `run.js` carried
CHECKS = [banner_layout, embed_layout, tagrow_layout, route_crawl]. Beside them
sat five more files, four of them asserting harnesses for the chat panel, and no
runner named any of them. They ran only when somebody typed their name.

`chat_all.js` was written to fix exactly this — its own header says so, and says
why it stopped short: "run.js is not mine to edit while it is uncommitted, so
this wraps the four instead: one entry added to CHECKS later picks all of them
up." The entry was never added. A wrapper nobody calls is a check nobody runs.

WHAT IT COST. 157 assertions sat unrun. Three of them had gone false:
`chat_render.js` asserted the moniker input's maxlength equalled the server's
limit, which stopped being true when the limit moved to counting letters; and
`chat_page.js` asserted CFG.chat === undefined after blanking the chat field,
which since 81f93f8 asserts that turning chat off turns it back on. Each was
wrong for days. A suite that does not run cannot go red, and a check nothing
runs is indistinguishable from a check that passes.

This is the browser-side twin of check-guards-armed.py, which enforces the same
property for the Python guards: a guard that is not registered is not a guard.
It is static — no puppeteer, no page load — so it belongs in `make check` even
though the checks it polices deliberately do not.

    python3 scripts/check-browser-checks-registered.py
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BROWSER = os.path.join(ROOT, "web", "tests", "browser")
ENTRY = "run.js"

# A file may legitimately live here without being a check — render_snapshot.js
# prints a snapshot rather than asserting, so putting it in a gate would prove
# nothing. Declared IN THE FILE with a reason, the same shape check-web-selectors
# uses for a deliberately-absent class, so the exemption is reviewable per file
# and cannot quietly become the place unrun checks hide.
#
#     // check-browser-checks: not-a-check — prints a snapshot, asserts nothing
NOTACHECK = re.compile(r"//\s*check-browser-checks:\s*not-a-check\s+—\s*\S")

# CHECKS = ["a.js", "b.js"] — the one registration shape this tree uses, in the
# runner and in every wrapper.
#
# ANCHORED TO A DECLARATION, NOT TO THE WORD. The first version matched \bCHECKS
# anywhere, and chat_all.js opens by QUOTING a CHECKS list in prose while
# explaining why it exists — so the parser read a sentence about the bug as the
# registration itself and reported the wrong list. A guard that can be fooled by
# a comment about guards is not one. `^\s*(const|let|var)` cannot match inside a
# `//` line, and every real assignment in this tree is one.
CHECKS = re.compile(r"^\s*(?:const|let|var)\s+CHECKS\s*=\s*\[(.*?)\]", re.S | re.M)
NAME = re.compile(r"['\"]([^'\"]+\.js)['\"]")


def listed(path):
    """The .js names a file registers, or None if it registers nothing."""
    src = io.open(path, encoding="utf-8").read()
    # EVERY assignment, not the first. Taking the first would make a file with
    # two lists silently half-walked, which is this guard's own failure mode.
    ms = CHECKS.findall(src)
    if not ms:
        return None
    return [n for m in ms for n in NAME.findall(m)]


if not os.path.isdir(BROWSER):
    sys.exit("check-browser-checks-registered: no web/tests/browser directory")

present = sorted(f for f in os.listdir(BROWSER) if f.endswith(".js"))
if ENTRY not in present:
    sys.exit("check-browser-checks-registered: %s is missing" % ENTRY)

# WALK, DO NOT COUNT LEVELS. run.js names wrappers, a wrapper names harnesses,
# and a wrapper of wrappers would be legal too. A recursive walk with a visited
# set costs the same as a hardcoded two-level reach and cannot be silently
# outgrown — the failure a fixed depth would have is precisely the failure this
# guard exists to catch, one level further down.
reach, empty, missing = set(), [], []
stack = [ENTRY]
while stack:
    f = stack.pop()
    if f in reach:
        continue
    reach.add(f)
    p = os.path.join(BROWSER, f)
    if not os.path.exists(p):
        missing.append(f)
        continue
    names = listed(p)
    if names is None:
        continue  # a leaf: it asserts, it does not delegate
    if not names:
        # A registered wrapper with an empty list runs nothing while reporting
        # "0 browser check(s) pass" — a green line for no work done.
        empty.append(f)
    stack.extend(names)

unrun = []
for f in present:
    if f in reach:
        continue
    src = io.open(os.path.join(BROWSER, f), encoding="utf-8").read()
    if NOTACHECK.search(src):
        continue
    unrun.append(f)

bad = False
if unrun:
    bad = True
    print("check-browser-checks-registered: a browser check no runner runs",
          file=sys.stderr)
    for f in unrun:
        print("  %-22s not reachable from %s" % (f, ENTRY), file=sys.stderr)
    print("  Add it to a CHECKS list, or declare it with "
          "`// check-browser-checks: not-a-check — <reason>`.", file=sys.stderr)
if missing:
    bad = True
    print("check-browser-checks-registered: a runner lists a file that is not here",
          file=sys.stderr)
    for f in missing:
        print("  %s is registered but does not exist" % f, file=sys.stderr)
if empty:
    bad = True
    print("check-browser-checks-registered: a registered wrapper runs nothing",
          file=sys.stderr)
    for f in empty:
        print("  %s has an empty CHECKS list" % f, file=sys.stderr)
if bad:
    sys.exit(1)

# The tripwire. A guard that policed an empty directory would report a clean
# tree forever, which is the same vacuity it exists to catch in the checks.
leaves = len([f for f in reach if listed(os.path.join(BROWSER, f)) is None])
if len(present) < 3 or leaves < 2:
    sys.exit("check-browser-checks-registered: %d file(s), %d leaf check(s) — too "
             "few to be a real scan, which is a broken guard rather than a clean "
             "tree" % (len(present), leaves))

print("check-browser-checks-registered: %d browser file(s), all reachable from %s "
      "(%d leaf check(s), %d declared not-a-check)."
      % (len(present), ENTRY, leaves, len(present) - len(reach)))
