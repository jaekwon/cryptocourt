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
    a = ap.parse_args()

    muts = json.load(open(a.batch)) if a.batch else json.load(sys.stdin)
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
    notcaught, elsewhere, total, broken = [], [], 0, []
    for i, res in enumerate(out):
        if res is None:
            broken.append(f"shard {i} produced nothing")
            continue
        code, stdout, stderr = res
        if "BASELINE IS RED" in stderr or code == 2:
            broken.append(f"shard {i}: baseline is red")
        elif code != 0:
            broken.append(f"shard {i}: exited {code}")
        for line in stdout.split("\n"):
            if ROW.search(line):
                print(line)
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
    return 0


if __name__ == "__main__":
    sys.exit(main())
