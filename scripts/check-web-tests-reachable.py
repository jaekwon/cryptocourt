#!/usr/bin/env python3
"""A harness may not print its verdict while assertions are still below it.

WHY THIS EXISTS, and it is a measured loss rather than a worry. folders_test.js
printed its summary and called process.exit in the middle of its own IIFE:

    ok("F4: stale route comment gone", ...);
    console.log(fail? "\\n"+fail+" FAILURES" : "\\nALL PASS");
    process.exit(fail?1:0);
  // NESTING FROM THE CHAIN.
    ...seven assertions...

Seven assertions below that line, unreachable, green for as long as they had
existed. It reported 31 while the file held 38. Nothing could see it: the file
reads top to bottom and every one of those lines looks live, `node
folders_test.js` exits 0, and the runner counts what was PRINTED, which was a
consistent and entirely truthful account of the assertions that ran.

WHAT WAS IN THE DEAD BLOCK is the reason this is a guard and not a fixed typo:
chain folders nest, the child hangs off its parent, a retired folder is not
drawn, a cyclic tree terminates, a subfolder keeps its own fid. That is the
coverage for chain nesting — and chain nesting regressed this week, subfolders
answering "no such folder" while the court page linked to them. The tests were
written for exactly that failure and could not have run.

TWO IDIOMS, AND THE GUARD HAS TO KNOW THEM APART. chart_test.js registers its
summary as an exit hook at the TOP of the file:

    process.on('exit', () => { _log(BAD ? "FAILURES" : "ALL PASS"); ... })

and then asserts for another 34 lines. That is not the defect — it is arguably
the better shape, since the summary cannot be outlived by anything. A guard that
flagged it would be wrong, and the first draft of this one did.

So: a harness whose summary is an exit hook is exempt by construction. A harness
that prints its summary INLINE must do so after its last assertion.

    python3 scripts/check-web-tests-reachable.py
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIRS = [os.path.join(ROOT, "web", "tests"),
        os.path.join(ROOT, "web", "tests", "browser")]
# run.js is a runner: it spawns harnesses and prints their verdicts, so it names
# both the summary and no assertions of its own.
SKIP = {"run.js"}

# THE VERDICT-THEN-EXIT PAIR, not the words on their own. Two reasons it is the
# pair that matters:
#
#   * "ALL PASS" turns up in comments and in commit-message-shaped prose, and a
#     guard that fired on prose would be arguing with the file rather than
#     checking it. A summary is followed by process.exit; a sentence is not.
#   * the FIRST such pair is the one that ends the run. Matching the last one
#     made this guard unarmable — reintroducing an early summary left a later
#     pair standing, nothing followed THAT, and the guard reported a clean tree
#     while looking straight at the defect. It went silent on its own bug.
#
# A COMPUTED VERDICT, NOT A CONSTANT ONE, which is what separates the end of a
# run from a skip. chat_live and chat_moderation both print a bare "ALL PASS"
# and exit early when there is no model, no puppeteer or no go toolchain — a
# skip, deliberately not a failure, with 54 and 18 live assertions below it that
# run whenever the environment is there. The real verdict is derived from the
# run's own failure count:
#
#     console.log(fail ? `\n${fail} FAILURES` : "\nALL PASS");
#
# so the `?` on the line is the discriminator, and it needs no list of names.
SUMMARY = re.compile(
    r"[^\n]*\?[^\n]*(?:ALL PASS|FAILURES)[^\n]*\n(?:[^\n]*\n){0,3}?[^\n]*process\.exit\(")
# The exit-hook idiom, which makes the ordering question moot.
HOOK = re.compile(r"""process\.on\(\s*['"]exit['"]""")
ASSERT = re.compile(r"\bok\(")

bad, scanned, hooked = [], 0, 0
for d in DIRS:
    if not os.path.isdir(d):
        sys.exit("check-web-tests-reachable: %s is missing" % d)
    for name in sorted(os.listdir(d)):
        if not name.endswith(".js") or name in SKIP:
            continue
        rel = os.path.relpath(os.path.join(d, name), ROOT)
        src = io.open(os.path.join(d, name), encoding="utf-8").read()
        if HOOK.search(src):
            hooked += 1
            continue
        # The FIRST verdict-then-exit is where this file stops. Anything below it
        # that still tries to assert is dead code reporting into a summary that
        # has already been printed.
        m = SUMMARY.search(src)
        if m is None:
            continue  # a file with no verdict of its own is the runner's problem
        scanned += 1
        n = len(ASSERT.findall(src[m.end():]))
        if n:
            bad.append((rel, n))

if bad:
    print("check-web-tests-reachable: a harness prints its verdict with "
          "assertions still below it", file=sys.stderr)
    for rel, n in bad:
        print("  %-34s %d assertion(s) after the summary" % (rel, n), file=sys.stderr)
    print("  Those lines never run, and the file reports a clean pass over the "
          "ones that did. Move the summary to the end.", file=sys.stderr)
    sys.exit(1)

if scanned < 5:
    sys.exit("check-web-tests-reachable: only %d harness(es) with an inline "
             "summary — too few to be a real scan, which is a broken guard "
             "rather than a clean tree" % scanned)

print("check-web-tests-reachable: %d harness(es) print their verdict last "
      "(%d more register it as an exit hook, where order cannot matter)."
      % (scanned, hooked))
