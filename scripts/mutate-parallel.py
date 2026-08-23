#!/usr/bin/env python3
"""Run a mutation batch as N concurrent shards, and report ONE verdict.

The batch is now large enough that its wall clock matters: 241 rows took 14m42s,
and it grows with every guard pinned. Where that time goes was measured rather
than guessed — staging a shard costs 0.03s and one courtv2 suite run costs 3.67s,
so staging is 1% and caching it would buy nothing. The cost is irreducibly ONE
SUITE RUN PER MUTATION, which is what mutation testing is.

So the lever is parallelism, and it is available because each runner now builds
its own GNOROOT (scripts/gnoroot.py) and mutations are applied to the staged copy
rather than the repo (scripts/mutate.py). Nothing is shared between shards: not
the staged tree, not the sources, not a lock. That was not true two versions ago,
when two concurrent mutate runs corrupted each other through the backup files.

Rows are split ROUND-ROBIN, not in contiguous blocks, so a shard does not end up
holding every row for one slow package.

The single all-caught number is the point of the batch — it is what makes a run
readable at a glance — so this prints every row as its shard reports it and then
ONE aggregate summary over all of them. A shard that dies, or a baseline that is
red in any shard, fails the whole run: a shard whose rows never ran must not be
able to look like a shard whose rows all passed.

    python3 scripts/mutate-parallel.py scripts/mutations-courtv2.json
    python3 scripts/mutate-parallel.py batch.json --shards 6
"""

import argparse
import json
import os
import re
import subprocess
import sys
import threading

SRC = os.path.dirname(os.path.abspath(__file__))
ROW = re.compile(r"caught:|SURVIVED|BAD ANCHOR|INVALID|covered elsewhere:")
CAUGHT_ROW = re.compile(r"\bcaught:")
SUMMARY = re.compile(r"(\d+) not caught \(survived, invalid, or never applied\), of (\d+)")


def run_shard(rows, index, out):
    """Feed one shard to mutate.py and keep its output."""
    r = subprocess.run([sys.executable, os.path.join(SRC, "mutate.py")],
                       input=json.dumps(rows), capture_output=True, text=True)
    out[index] = (r.returncode, r.stdout, r.stderr)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("batch", nargs="?", default=None,
                    help="a JSON batch file; stdin when omitted")
    ap.add_argument("--shards", type=int, default=0,
                    help="concurrent shards; defaults to a quarter of the cores, "
                         "min 2 max 6 — each shard runs whole gno suites, so more "
                         "of them stops helping well before the core count")
    # THE GAP FILE IS READ THE OTHER WAY ROUND, and until this flag existed the
    # reading was not a check. A main-corpus row is wrong when it stops being
    # caught; a KNOWN-GAPS row is wrong when it STARTS being caught, because the
    # gap has closed and nobody struck it off. `make gaps` ran exactly that batch
    # and then exited 0 whether or not any row was caught — the verdict below is
    # printed unconditionally, so a closed gap was visible only to a reader who
    # did the arithmetic (sent − surviving − by-design) by hand. Which is how it
    # was found: 21 sent, 17 surviving, 4 by-design, and the exit code would have
    # said the same had it been 16 and 4.
    ap.add_argument("--expect-survive", action="store_true",
                    help="invert the verdict: every row is EXPECTED to survive, so "
                         "any row that is caught fails the run. For the KNOWN-GAPS "
                         "batch, where a caught row means the gap closed")
    a = ap.parse_args()

    # A LEGIBLE FAILURE, because the illegible one cost a whole cycle. Omitting
    # the batch argument used to fall through to json.load(sys.stdin), which on an
    # empty or absent stdin raises JSONDecodeError("Expecting value: line 1 column
    # 1") — a decoder traceback for what is actually a usage mistake. Worse, run
    # under `| tail`, the traceback surfaced as a clean exit 0 and the batch read
    # as having passed. Stdin input is deliberate (selftest feeds mutate.py that
    # way), so this distinguishes "nothing arrived" from "what arrived was not
    # JSON" instead of removing the feature.
    if a.batch:
        muts = json.load(open(a.batch))
    else:
        raw = sys.stdin.read() if not sys.stdin.isatty() else ""
        if not raw.strip():
            ap.error("no batch file given and nothing arrived on stdin. Pass a "
                     "corpus (scripts/mutations-kourtv2.json), or pipe a JSON "
                     "batch in. `make mutate` does the former.")
        try:
            muts = json.loads(raw)
        except json.JSONDecodeError as e:
            ap.error(f"stdin was not a JSON batch: {e}")
    # AND THE SAME MISTAKE ONE STEP LATER: `[]` is valid JSON. It survives the
    # decode above, and the run then reports "0 not caught ... of 0" and exits 0 —
    # a green verdict over zero measurements, which is the exact failure this file
    # exists to prevent and which its own docstring forbids ("a shard whose rows
    # never ran must not be able to look like a shard whose rows all passed").
    #
    # The live way to hit it is a FILTER THAT MATCHED NOTHING. Every ad-hoc batch
    # here is built by piping a list comprehension over the corpus, and a `label`
    # that has since been renamed yields `[]` rather than an error. `make gaps` can
    # reach it too, by marking every gap row `slow`. A zero-row run is never a
    # result worth having, so it is refused rather than reported.
    if not muts:
        ap.error("the batch is empty, so this run would measure nothing and still "
                 "exit 0. If a filter built it, the filter matched no rows — check "
                 "the labels against scripts/mutations-kourtv2.json, which renames "
                 "them as the code moves.")
    n = a.shards or max(2, min(6, (os.cpu_count() or 4) // 2))
    n = min(n, len(muts)) or 1

    shards = [muts[i::n] for i in range(n)]
    print(f"mutate: {len(muts)} rows over {n} shards "
          f"({', '.join(str(len(s)) for s in shards)} rows each)", file=sys.stderr)

    out = [None] * n
    threads = [threading.Thread(target=run_shard, args=(s, i, out))
               for i, s in enumerate(shards)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    def section(text, header):
        """The indented block under `header`, up to the first blank line.

        Parsed by header rather than by indentation alone: mutate.py prints TWO
        indented lists — the not-caught rows and the rows covered elsewhere — and an
        indentation-only parser folded the second into the first, which would have
        reported a by-design survivor as a finding.
        """
        i = text.find(header)
        if i < 0:
            return []
        out = []
        for line in text[i:].split("\n")[1:]:
            if not line.startswith("  "):
                break
            if line.strip():
                out.append(line.strip())
        return out

    # Every row, then one verdict. Shard boundaries are an implementation detail
    # and deliberately absent from the output.
    notcaught, elsewhere, total, broken, caught = [], [], 0, [], []
    for i, res in enumerate(out):
        if res is None:
            broken.append(f"shard {i} produced nothing")
            continue
        code, stdout, stderr = res
        # A HUNG BASELINE IS NOT A RED ONE, and they want different things done.
        # Red means a broken test; hung means a suite that never answered, which
        # on this repo usually means somebody has a break armed in the working
        # tree right now. Checked before the red case because the shard prints
        # only one of the two, and named separately so the report says which.
        #
        # (Both a string match AND `code == 2`: the code was dead until mutate.py
        # started passing main()'s return to sys.exit, and the string is what
        # actually fired for the whole time it was dead.)
        if "BASELINE DID NOT FINISH" in stderr:
            broken.append(f"shard {i}: baseline did not finish — a suite ran past "
                          f"its timeout before any mutation was applied")
        elif "BASELINE IS RED" in stderr or code == 2:
            broken.append(f"shard {i}: baseline is red")
        elif code != 0:
            broken.append(f"shard {i}: exited {code}")
        for line in stdout.split("\n"):
            if ROW.search(line):
                print(line)
                # `caught:` with the colon is the per-row verdict; the summary
                # line reads "N not caught (survived, ..." and has no colon, so
                # it cannot be mistaken for one here.
                if CAUGHT_ROW.search(line):
                    caught.append(line.strip())
        m = SUMMARY.search(stdout)
        if not m:
            broken.append(f"shard {i}: no summary line, so its rows are unaccounted for")
            continue
        total += int(m.group(2))
        notcaught += section(stdout, m.group(0))
        elsewhere += section(stdout, "survive here BY DESIGN")

    if broken:
        print("\nmutate: the run is NOT a result:", file=sys.stderr)
        for b in broken:
            print(f"  {b}", file=sys.stderr)
        return 1
    if total != len(muts):
        print(f"\nmutate: {total} rows accounted for, {len(muts)} were sent — the "
              f"difference never ran", file=sys.stderr)
        return 1

    print(f"\n{len(notcaught)} not caught (survived, invalid, or never applied), "
          f"of {total}")
    for s in notcaught:
        print(f"  {s}")
    if elsewhere:
        print(f"\n{len(elsewhere)} row(s) survive here BY DESIGN, covered by a suite "
              f"this harness does not run:")
        for s in elsewhere:
            print(f"  {s}")
    if a.expect_survive and caught:
        print(f"\nmutate: {len(caught)} row(s) were CAUGHT in a batch where every row "
              f"is expected to survive. A recorded gap has closed — strike it off "
              f"KNOWN-GAPS and move it to the main corpus, or the file is claiming a "
              f"hole that is not there:", file=sys.stderr)
        for c in caught:
            print(f"  {c}", file=sys.stderr)
        return 1
    if a.expect_survive:
        print(f"\nevery one of the {total} row(s) still survives — no recorded gap "
              f"has closed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
