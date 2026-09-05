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

# A SECOND RUNNER, AND IT IS NOT IN THIS DIRECTORY. compose_intake.js and
# compose_upload.js take a base URL on argv and refuse without one: they drive a
# real composer against a real archive, so somebody has to own an HTTP server
# first. run.js cannot — it loads file:// pages — and internal/archive/
# browser_test.go can, because it starts the archive it is testing. It registers
# both by name in a []string literal.
#
# COUNTED AS REACHABLE, NOT EXEMPTED. The not-a-check escape hatch would have
# silenced this guard in one line, and it would have been a lie: these are 31 and
# 21 assertions of the paste-and-upload path that docs/CLAIM_MEDIA.md calls "the
# single most important path". Writing "not-a-check" over a real check to quiet a
# guard is exactly how the 157-assertion hole in this file's header opened.
GO_ENTRY = os.path.join("internal", "archive", "browser_test.go")
GO_LIST = re.compile(r"\[\]string\{([^}]*?\.js[^}]*?)\}", re.S)

# A file may legitimately live here without being a check — render_snapshot.js
# prints a snapshot rather than asserting, so putting it in a gate would prove
# nothing. Declared IN THE FILE with a reason, the same shape check-web-selectors
# uses for a deliberately-absent class, so the exemption is reviewable per file
# and cannot quietly become the place unrun checks hide.
#
#     // check-browser-checks: not-a-check — prints a snapshot, asserts nothing
NOTACHECK = re.compile(r"//\s*check-browser-checks:\s*not-a-check\s+—\s*\S")

# A declaration holding an array of .js names — the registration shape this tree
# uses, in the runner and in every wrapper.
#
# ANCHORED TO A DECLARATION, NOT TO THE WORD. The first version matched \bCHECKS
# anywhere, and chat_all.js opens by QUOTING a CHECKS list in prose while
# explaining why it exists — so the parser read a sentence about the bug as the
# registration itself and reported the wrong list. A guard that can be fooled by
# a comment about guards is not one. `^\s*(const|let|var)` cannot match inside a
# `//` line, and every real assignment in this tree is one.
#
# NOT ANCHORED TO THE NAME `CHECKS` EITHER, and that is a repair. It was, and
# then run.js grew ONLY= filtering:
#
#     const ALL    = ["embed_layout.js", ...]
#     const CHECKS = only ? ALL.filter(...) : ALL
#
# The literal moved to a variable called ALL, `CHECKS = [` stopped matching, and
# listed() started returning None for the runner — so this guard reported that
# every check in the tree was unreachable from a runner that in fact runs them.
# Measured: rc=1 naming map_type.js, route_crawl.js, rowscope_layout.js,
# tagrow_layout.js and stripped_boot.js, all of them plainly in ALL. Nothing
# caught it because no target ran this guard (fixed in the same commit) and its
# own selftest arm was anchored to the same reflowed text.
#
# So the question is asked the way it is meant: which .js files does this file
# NAME? A rename cannot break that, and the indirection does not have to be
# resolved — CHECKS can only ever be built out of names that appear literally
# somewhere in the file.
CHECKS = re.compile(
    r"^\s*(?:const|let|var)\s+\w+\s*=\s*\[([^\]]*?\.js[^\]]*?)\]", re.S | re.M)
NAME = re.compile(r"['\"]([^'\"]+\.js)['\"]")


# A WRAPPER BY MECHANISM, so an EMPTY one is still recognisable. CHECKS needs a
# `.js` name inside the brackets to match at all, which means a list emptied to
# `[]` matches nothing, listed() answers None, and the file is filed as a leaf —
# "it asserts, it does not delegate". That made the empty-list branch below
# unreachable and its arm unfirable: the branch existed for "a green line for no
# work done" and could never say it.
#
# Loosening CHECKS to accept `[]` is not the fix. `const x = []` is ordinary
# code, and any file holding one would be read as an empty wrapper.
#
# So a wrapper is identified by what a wrapper DOES: it runs its children as
# child processes. The two markers agree exactly — on chat_all.js and run.js,
# with no file matching one and not the other — and that agreement is CHECKED
# below rather than asserted here, because it was a measurement over "all 18
# files" and there are twenty-seven now. A number in a comment is a claim about
# the day it was written; the loop is a claim about today.
# Nothing else worked as a marker: `module.exports` appears only in harness.js,
# which declares itself not-a-check, and an assertion-shaped grep fires for both
# wrappers AND misses three leaves (compose_upload, route_crawl, stripped_boot),
# so it discriminates in neither direction.
DELEGATES = re.compile(
    r"(?:spawnSync|spawn|execFile\w*)\s*\(\s*process\.execPath")


def listed(path):
    """The .js names a file registers, or None if it registers nothing."""
    src = io.open(path, encoding="utf-8").read()
    # EVERY assignment, not the first. Taking the first would make a file with
    # two lists silently half-walked, which is this guard's own failure mode.
    ms = CHECKS.findall(src)
    if ms:
        return [n for m in ms for n in NAME.findall(m)]
    if DELEGATES.search(src):
        # It spawns siblings and names none of them: a wrapper that runs nothing.
        return []
    return None


if not os.path.isdir(BROWSER):
    sys.exit("check-browser-checks-registered: no web/tests/browser directory")

present = sorted(f for f in os.listdir(BROWSER) if f.endswith(".js"))
if ENTRY not in present:
    sys.exit("check-browser-checks-registered: %s is missing" % ENTRY)

# THE TWO MARKERS AGREE, and this used to be a measurement in a comment rather
# than a check. `listed` reads a name list FIRST and falls back to the spawn, so
# a file carrying a list it never actually runs is walked as a wrapper and its
# children counted as reached — coverage claimed for harnesses nothing invokes,
# which is this guard's own failure mode one level in.
# The other direction is already caught below as an empty wrapper; this catches
# the direction that would report a clean tree.
mismatched = []
for f in present:
    src = io.open(os.path.join(BROWSER, f), encoding="utf-8").read()
    if CHECKS.search(src) and not DELEGATES.search(src):
        mismatched.append(f)
if mismatched:
    for f in mismatched:
        print("check-browser-checks-registered: %-24s names .js files but never spawns one"
              % f, file=sys.stderr)
    sys.exit("\nA file that lists harnesses and does not run them is walked as a "
             "wrapper, so everything it names is counted as reached. Give it a "
             "spawn, or stop it naming .js files it does not invoke.")

# WALK, DO NOT COUNT LEVELS. run.js names wrappers, a wrapper names harnesses,
# and a wrapper of wrappers would be legal too. A recursive walk with a visited
# set costs the same as a hardcoded two-level reach and cannot be silently
# outgrown — the failure a fixed depth would have is precisely the failure this
# guard exists to catch, one level further down.
reach, empty, missing = set(), [], []
# The Go runner is a TRIPWIRE as well as an entry point: if it stops existing or
# stops naming any .js, the two checks it owns become unreachable and this guard
# must say so rather than quietly walk one runner and call the tree clean.
go_path = os.path.join(ROOT, GO_ENTRY)
if not os.path.exists(go_path):
    sys.exit("check-browser-checks-registered: %s is gone; the checks it runs "
             "have no runner left" % GO_ENTRY)
go_names = [n for m in GO_LIST.findall(io.open(go_path, encoding="utf-8").read())
            for n in NAME.findall(m)]
if not go_names:
    sys.exit("check-browser-checks-registered: %s names no .js check; either it "
             "stopped running them or its []string literal moved" % GO_ENTRY)
stack = [ENTRY] + go_names
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
