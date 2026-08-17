#!/usr/bin/env python3
"""Check what the filetests cost, so a gas regression fails the ordinary test run.

`gno test -v` reports the storage each filetest wrote, per realm:

    --- PASS: ./z_write_filetest.gno (... storage: gno.land/r/kourt/govern:+6328b)

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
# Every realm that has filetests, with what each is allowed to write.
#
# This was one realm hardcoded, which is how kourtv2 came to have no filetest at
# all and therefore no guard against the defect below — while govern had one
# from the beginning. check-isolation had the identical drift in the same week
# (it swept 151 of 388 tests), so realms_with_filetests() now cross-checks this
# list against the tree: a realm that grows a filetest without a budget fails
# here rather than going quietly unwatched.
P = "examples/gno.land/p/kourt"
TARGETS = [
    {
        "src": os.path.join(REPO, "realm/r/govern"),
        "dest": "examples/gno.land/r/kourt/govern",
        "deps": ["checkpoint", "grc20votes", "governor"],
        # filetest -> ceiling in bytes written to the realm, or None for
        # "must write nothing at all".
        "budgets": {
            "z_use_filetest.gno": None,
            "z_offer_filetest.gno": 4_000,
            "z_write_filetest.gno": 12_000,
        },
    },
    {
        "src": os.path.join(REPO, "realm/r/kourtv2"),
        "dest": "examples/gno.land/r/kourt/kourtv2",
        "deps": ["checkpoint", "grc20votes", "governor", "twap", "cshares",
                 "tickbook", "curve"],
        # None, and it holds today: the whole read surface — directory, coin,
        # curve, moderation, election, strips, franchise and both render routes
        # — writes zero bytes. Worth stating because two reads in this realm HAD
        # started writing (five election reads via ensureMod; ensureClaimMod
        # ahead of the m-of-n gating it) and both were caught by hand, not here.
        "budgets": {"z_read_filetest.gno": None},
    },
]


def realms_with_filetests():
    """Every realm/r/* that has filetests, so an unbudgeted one cannot hide."""
    out = set()
    rdir = os.path.join(REPO, "realm/r")
    for name in sorted(os.listdir(rdir)):
        d = os.path.join(rdir, name)
        if os.path.isdir(d) and any(f.startswith("z_") and f.endswith("_filetest.gno")
                                    for f in os.listdir(d)):
            out.add(d)
    return out


def stage(root, target):
    pairs = [(os.path.join(REPO, "realm/p", d), f"{P}/{d}/v0") for d in target["deps"]]
    pairs.append((target["src"], target["dest"]))
    for src, rel in pairs:
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

    # Coverage first: a realm that has filetests and no budget entry is the
    # drift this file was reorganised to prevent, and it must fail loudly.
    bad = 0
    covered = {t["src"] for t in TARGETS}
    for d in sorted(realms_with_filetests() - covered):
        print(f"UNWATCHED {os.path.relpath(d, REPO)} has filetests and no TARGETS "
              f"entry — its cost is unbudgeted. Add one.")
        bad += 1

    for target in TARGETS:
        realm = os.path.basename(target["dest"])
        stage(root, target)
        base = os.path.join(root, target["dest"])
        r = subprocess.run(["gno", "test", "-v", "."], cwd=base,
                           capture_output=True, text=True)
        out = r.stdout + r.stderr
        shutil.rmtree(base, ignore_errors=True)
        shutil.rmtree(os.path.join(root, P), ignore_errors=True)

        if r.returncode != 0:
            print(f"check-storage: {realm}'s suite does not pass, so its costs "
                  f"mean nothing. Fix the tests first.", file=sys.stderr)
            return 1

        seen = {}
        for line in out.split("\n"):
            m = re.search(r"(z_\w+_filetest\.gno).*?\(", line)
            if not m or "PASS" not in line:
                continue
            w = re.search(re.escape(target["dest"].split("examples/")[1]) + r":\+(\d+)b", line)
            seen[m.group(1)] = int(w.group(1)) if w else 0

        budgets = target["budgets"]
        for name, budget in budgets.items():
            if name not in seen:
                print(f"MISSING {realm}/{name} did not run, so its cost was not checked")
                bad += 1
                continue
            got = seen[name]
            if budget is None:
                if got != 0:
                    print(f"WROTE   {realm}/{name} wrote {got}b to the realm and must "
                          f"write nothing at all — a read has started writing")
                    bad += 1
                else:
                    print(f"ok      {realm}/{name:<24} wrote nothing")
            elif got > budget:
                print(f"OVER    {realm}/{name} wrote {got}b against a ceiling of {budget}b")
                bad += 1
            else:
                print(f"ok      {realm}/{name:<24} {got}b (ceiling {budget}b)")

        for name in sorted(set(seen) - set(budgets)):
            print(f"UNKNOWN {realm}/{name} has no budget. Add one, or its cost "
                  f"is unwatched.")
            bad += 1

    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
