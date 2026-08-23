#!/usr/bin/env python3
"""Two rows must not produce the same MUTANT by different anchors.

check-mutation-anchors compares the `(pkg, file, find, replace)` triple, so two
rows that express one mutation through different anchor text are distinct to it —
one anchored on `} else {\\n\\thalf := ...`, the other on the same line by
indentation alone. Its own author said so when eleven such pairs were found by
hand: "check-mutation-anchors could not see these." This is that check, so the
next pair is found by the tree rather than by somebody deciding to go looking.

WHY A DUPLICATE MUTANT IS WORTH FAILING OVER, given both rows are CAUGHT and
nothing is unsafe:

  1. It costs a full suite run per pass, every pass, for a fact already known.
     At ~75s per row per shard that is real wall clock on every regression run.
  2. It reports one fact twice, so the corpus reads bigger than it is. The count
     is the headline number in every summary — "1199 rows" should mean 1199
     measurements, not 1188 measurements and 11 echoes.
  3. It is a rot signal. Every pair found so far had the same shape: an early
     terse row and a later one naming the function, because a later round
     re-derived a mutation the corpus already had. A pair means two people (or
     two firings) did not see each other's work.

HOW: apply each row's find -> replace to its own source and hash the result,
keyed by file so identical edits to different files do not collide. Same hash
from two rows means the harness would compile and test byte-identical trees
twice.

FAILS CLOSED ON ANY ROW THAT YIELDS NO USABLE MUTANT, which is two cases. A row
whose anchor matches zero or twice is check-mutation-anchors' business and it will
say so, but it is NOT skipped quietly here: its mutant is unknown, and an unknown
mutant cannot be shown to be distinct. Reporting it costs one duplicated complaint
and buys the guarantee that this check saw every row. The second case is a row
that applies perfectly and changes NO BYTES, which is not unappliable at all — it
is a row that tests nothing, and it is caught here because the mutated source is
already in hand.
"""

import collections
import glob
import hashlib
import json
import os
import sys

from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import repolock

# The corpus knows which tree a row's `file` lives in; mutate.py owns that map,
# and it is imported rather than copied so the two cannot drift.
import mutate  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


def main():
    repolock.refuse_if_held("check-mutant-collisions")

    rows = []
    for path in sorted(glob.glob(os.path.join(ROOT, "scripts", "mutations-*.json"))):
        for r in json.load(open(path, encoding="utf-8")):
            rows.append((os.path.basename(path), r))
    if not rows:
        print("check-mutant-collisions: no corpus rows found, so this check is "
              "measuring nothing. The corpus was renamed or moved.",
              file=sys.stderr)
        return 1

    mutants = collections.defaultdict(list)
    unappliable, cache = [], {}
    for corpus, r in rows:
        label = r.get("label", "<unlabelled>")
        entry = getattr(mutate, "PKGS", {}).get(r.get("pkg"))
        if not entry:
            unappliable.append((corpus, label, "pkg %r is not in mutate.py's PKGS map"
                                % r.get("pkg")))
            continue
        path = os.path.join(entry[0], r.get("file", ""))
        if path not in cache:
            try:
                cache[path] = open(path, encoding="utf-8").read()
            except OSError:
                cache[path] = None
        src = cache[path]
        if src is None:
            unappliable.append((corpus, label, "its file does not exist: %s" % r.get("file")))
            continue
        if "find" not in r or "replace" not in r:
            unappliable.append((corpus, label, "the row has no find/replace pair"))
            continue
        n = src.count(r["find"])
        if n != 1:
            unappliable.append((corpus, label, "its anchor matches %dx, so its mutant "
                                               "is unknown (`make anchors` owns that)" % n))
            continue
        mutated = src.replace(r["find"], r["replace"], 1)
        # AND A ROW THAT CHANGES NO BYTES MEASURES NOTHING. Same rule the corpus
        # applies to its own findings — "a mutation that cannot change behaviour is
        # INVALID, not a survivor" — at the textual level, where it is exact rather
        # than an argument. The realistic way in is a re-point after a refactor:
        # `find` is updated to the moved text and the same text lands in `replace`.
        # In the main corpus such a row reports SURVIVED and fails the run, which is
        # loud but misdiagnosed; in KNOWN-GAPS it sits as a recorded gap for ever
        # while testing nothing at all. Free to check here because the mutated
        # source is already in hand. Measured zero across 1199 rows when added.
        if mutated == src:
            unappliable.append((corpus, label, "its replace changes NO BYTES, so the "
                                               "row applies cleanly and tests nothing"))
            continue
        blob = r["file"] + "\0" + mutated
        mutants[hashlib.sha256(blob.encode()).hexdigest()].append((corpus, label))

    collisions = {h: v for h, v in mutants.items() if len(v) > 1}

    if collisions or unappliable:
        if collisions:
            print("check-mutant-collisions: %d group(s) of rows produce the SAME "
                  "mutant by different anchors.\n" % len(collisions), file=sys.stderr)
            for group in collisions.values():
                print("  one mutant, %d rows:" % len(group), file=sys.stderr)
                for corpus, label in group:
                    print("      [%s] %s" % (corpus, label), file=sys.stderr)
            print("\nKeep the row that NAMES THE FUNCTION and the defect — that is the "
                  "line a run prints when the row survives — and fold any reference the "
                  "other carried into it rather than losing it.", file=sys.stderr)
        if unappliable:
            print("\ncheck-mutant-collisions: %d row(s) yielded no usable mutant, so "
                  "this check cannot say their mutants are distinct:"
                  % len(unappliable), file=sys.stderr)
            for corpus, label, why in unappliable:
                print("  [%s] %s\n      %s" % (corpus, label, why), file=sys.stderr)
        return 1

    print("check-mutant-collisions: %d row(s) across %d corpus file(s) produce %d "
          "distinct mutant(s) — no two rows measure the same tree."
          % (len(rows), len({c for c, _ in rows}), len(mutants)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
