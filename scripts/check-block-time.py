#!/usr/bin/env python3
"""One block is five seconds, and this repo says so in four places.

WHY THIS EXISTS, and it is a repair rather than a worry — the drift it guards
against already happened once, in the direction this catches.

Three deadlines in kourtv2 are written down TWICE, once in blocks and once in
seconds, because the realm gates on whichever the record carries: a claim
decided before the stamps existed keeps the height it was decided under, and
everything since is judged on the clock. openrewards.gno spells the pattern out
where finalizeGrace is read — "Seconds first, blocks only for a claim whose
verdict predates the stamp, so a record keeps the deadline it was decided
under."

That is a good design and it has a cost: the two halves are one duration, and
NOTHING made them stay one duration. Change finalizeGraceSecs alone and old
records get a week while new ones get whatever you typed — silently, correctly
per the code, and wrong.

THE SAME SPLIT COST THREE SCENARIOS. p/governor moved its vote deadline from a
height to a stamp (closesTime, read by votingClosed); scn_covid, scn_dispute and
scn_rewards_demo went on advancing only the height, and a week-long vote stayed
open at ANY height for as long as the suite was red. That was a test bug, but it
was the same bug: two representations of one instant, kept in step by hand.

WHAT IT CHECKS, both halves of the conversion:

  1. The block time itself is ONE number. It is declared in the overlay
     (BLOCK_SECS), in p/governor (secsPerBlock, which converts VotingBlocks into
     the closesTime stamp) and in the scenario generator (BLOCK_SECS, which is
     how a scenario turns an advance_height into a span). Three copies, no
     import between them — they are three languages — so the only thing that can
     hold them together is a check.

  2. Every `<name>Blocks` / `<name>Secs` pair in the realm satisfies
     secs == blocks * that block time. Discovered by NAME, not from a list, so a
     third pair added tomorrow is covered the day it is written and nobody has
     to remember this file exists.

WHAT IT DOES NOT CHECK. That five seconds is the right number for gno.land, or
that any given deadline is the right length. It checks that the repo AGREES with
itself, which is the failure that arrives without anyone deciding to make it.

    python3 scripts/check-block-time.py
"""
import glob
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The three declarations of one block's duration. Each is matched on its own
# spelling rather than a shared pattern: they are JavaScript, Gno and Python, and
# a pattern loose enough for all three would match things that are not this.
SOURCES = [
    ("web/index.html", r"^const BLOCK_SECS = (\d+);", "the overlay"),
    ("realm/p/governor/governor.gno", r"^const secsPerBlock = int64\((\d+)\)",
     "p/governor, which stamps closesTime"),
    ("scripts/scenario.py", r"^\s*BLOCK_SECS = (\d+)$",
     "the scenario generator"),
]

found = {}
for relpath, pattern, why in SOURCES:
    path = os.path.join(ROOT, relpath)
    if not os.path.exists(path):
        sys.exit("check-block-time: %s is missing" % relpath)
    m = re.search(pattern, io.open(path, encoding="utf-8").read(), re.M)
    if not m:
        sys.exit("check-block-time: %s no longer declares a block time the way "
                 "this guard reads it (%s). Fix the pattern here rather than "
                 "deleting the source — a guard that cannot find its subject "
                 "reports a clean tree." % (relpath, why))
    found[relpath] = (int(m.group(1)), why)

values = {v for v, _ in found.values()}
if len(values) != 1:
    print("check-block-time: the repo disagrees with itself about how long a "
          "block is", file=sys.stderr)
    for relpath, (v, why) in found.items():
        print("  %-38s %d second(s)  — %s" % (relpath, v, why), file=sys.stderr)
    print("  These convert heights into deadlines. While they differ, the same "
          "window is a different length depending on which one read it.",
          file=sys.stderr)
    sys.exit(1)

BLOCK_SECS = values.pop()

# ---------------------------------------------------------------------------
# And the pairs. `const X = int64(1_2)`, `X = int64(7 * 86400)` and a bare
# `X = 120960` are all declarations here; the arithmetic is evaluated rather
# than matched, because `7 * 86400` is how a week should be written and a guard
# that forced it to be 604800 would be making the code worse to be checkable.
DECL = re.compile(
    r"^\s*(?:const\s+)?(\w+)\s*(?:int64\s*)?=\s*(?:int64\()?"
    r"([0-9_]+(?:\s*\*\s*[0-9_]+)*)\)?\s*(?://.*)?$", re.M)

consts = {}
for path in sorted(glob.glob(os.path.join(ROOT, "realm", "**", "*.gno"),
                             recursive=True)):
    if path.endswith("_test.gno"):
        continue
    for m in DECL.finditer(io.open(path, encoding="utf-8").read()):
        name, expr = m.group(1), m.group(2).replace("_", "")
        if name in ("const", "var"):
            continue
        try:
            # Digits and `*` only, by construction of DECL.
            consts[name] = (eval(expr), os.path.relpath(path, ROOT))
        except Exception:
            continue

SUFFIX = {"Blocks": "blocks", "Secs": "secs", "Seconds": "secs"}
stems = {}
for name, (value, relpath) in consts.items():
    for suffix, half in SUFFIX.items():
        if name.endswith(suffix) and len(name) > len(suffix):
            stems.setdefault(name[:-len(suffix)], {})[half] = (value, name, relpath)

pairs = {stem: halves for stem, halves in stems.items() if len(halves) == 2}

wrong = []
for stem, halves in sorted(pairs.items()):
    blocks, bname, bfile = halves["blocks"]
    secs, sname, sfile = halves["secs"]
    if secs != blocks * BLOCK_SECS:
        wrong.append((stem, bname, blocks, bfile, sname, secs, sfile))

if wrong:
    print("check-block-time: a deadline written in blocks and in seconds is two "
          "different deadlines", file=sys.stderr)
    for stem, bname, blocks, bfile, sname, secs, sfile in wrong:
        print("  %s\n      %s = %d blocks x %d = %d\n      %s = %d  (%s, %s)"
              % (stem, bname, blocks, BLOCK_SECS, blocks * BLOCK_SECS,
                 sname, secs, bfile, sfile), file=sys.stderr)
    print("  The realm reads whichever half the record carries, so this does not "
          "fail — it gives an old record and a new one different windows.",
          file=sys.stderr)
    sys.exit(1)

# Fails closed. A regex that stops matching turns this file into a program that
# prints a reassuring line, which is worse than not having it: the pairs are
# found by NAME, so a rename is exactly how they would vanish silently.
if len(pairs) < 2:
    sys.exit("check-block-time: found %d block/seconds pair(s) among %d realm "
             "constant(s) — there are at least two (finalizeGrace, "
             "priorityWindow), so the scan matched too little to be real. That "
             "is a broken guard, not a clean tree." % (len(pairs), len(consts)))

print("check-block-time: a block is %d second(s) in all %d places that convert "
      "one into the other (%s), and %d deadline(s) written both ways agree (%s)."
      % (BLOCK_SECS, len(found), ", ".join(sorted(found)), len(pairs),
         ", ".join(sorted(pairs))))
