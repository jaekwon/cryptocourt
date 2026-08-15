#!/usr/bin/env python3
"""Check what the filetests cost, so a gas regression fails the ordinary test run.

`gno test -v` reports the storage each filetest wrote, per realm:

    --- PASS: ./z_write_filetest.gno (... storage: gno.land/r/cryptocourt/govern:+6328b)

That is the same number a chain charges a deposit for, available without a node
and on every `make realm-test`. Everything else measuring gas in this repo needs
a gnodev, takes seventy seconds, and is therefore run by hand and occasionally.

Two kinds of claim are checked.

The read filetest must write NOTHING. It exercises the whole read surface from
outside the package and its storage line must be absent entirely — not small,
absent. A read that starts writing is the defect this guards against, and it
has a specific shape here: settle running inside State and Render. The
transitions it computes are thrown away with the query, so the only visible
symptom is slots that never come back, months later, under load.

The writing filetests must stay under a ceiling. Ceilings rather than exact
figures, because a byte or two moves whenever a string in the realm changes and
a test that fails on that gets deleted rather than read. These are set well
above what they cost today and well below anything that would count as a
regression.

    python3 scripts/check-storage.py
"""

import os
import re
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REALM = os.path.join(REPO, "realm/r/govern")
DEPS = [
    (os.path.join(REPO, "realm/p/checkpoint"), "examples/gno.land/p/cryptocourt/checkpoint/v0"),
    (os.path.join(REPO, "realm/p/grc20votes"), "examples/gno.land/p/cryptocourt/grc20votes/v0"),
]
DEST = "examples/gno.land/r/cryptocourt/govern"

# filetest -> ceiling in bytes written to the govern realm, or None for "must
# write nothing at all".
BUDGETS = {
    "z_use_filetest.gno": None,
    "z_offer_filetest.gno": 4_000,
    "z_write_filetest.gno": 12_000,
}


def stage(root):
    for src, rel in DEPS + [(REALM, DEST)]:
        dst = os.path.join(root, rel)
        shutil.rmtree(dst, ignore_errors=True)
        os.makedirs(dst)
        for f in os.listdir(src):
            if f.endswith(".gno") or f == "gnomod.toml":
                shutil.copy(os.path.join(src, f), dst)


def main():
    try:
        root = subprocess.run(["gno", "env", "GNOROOT"], capture_output=True,
                              text=True, timeout=30).stdout.strip()
    except (FileNotFoundError, subprocess.SubprocessError):
        root = ""
    if not root or not os.path.isdir(root):
        if os.environ.get("REQUIRE_GNO"):
            print("check-storage: gno not installed", file=sys.stderr)
            return 1
        print("check-storage: gno not installed - skipping")
        return 0

    stage(root)
    base = os.path.join(root, DEST)
    r = subprocess.run(["gno", "test", "-v", "."], cwd=base,
                       capture_output=True, text=True)
    out = r.stdout + r.stderr
    shutil.rmtree(base, ignore_errors=True)
    shutil.rmtree(os.path.join(root, "examples/gno.land/p/cryptocourt"), ignore_errors=True)

    if r.returncode != 0:
        print("check-storage: the suite does not pass, so its costs mean "
              "nothing. Fix the tests first.", file=sys.stderr)
        return 1

    seen, bad = {}, 0
    for line in out.split("\n"):
        m = re.search(r"(z_\w+_filetest\.gno).*?\(", line)
        if not m or "PASS" not in line:
            continue
        name = m.group(1)
        w = re.search(r"gno\.land/r/cryptocourt/govern:\+(\d+)b", line)
        seen[name] = int(w.group(1)) if w else 0

    for name, budget in BUDGETS.items():
        if name not in seen:
            print(f"MISSING {name} did not run, so its cost was not checked")
            bad += 1
            continue
        got = seen[name]
        if budget is None:
            if got != 0:
                print(f"WROTE   {name} wrote {got}b to the realm and must write "
                      f"nothing at all — a read has started writing")
                bad += 1
            else:
                print(f"ok      {name:<24} wrote nothing")
        elif got > budget:
            print(f"OVER    {name} wrote {got}b against a ceiling of {budget}b")
            bad += 1
        else:
            print(f"ok      {name:<24} {got}b (ceiling {budget}b)")

    for name in sorted(set(seen) - set(BUDGETS)):
        print(f"UNKNOWN {name} has no budget. Add one, or its cost is unwatched.")
        bad += 1

    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
